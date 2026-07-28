"""OLCP framing, capability negotiation, and capture planning."""

from __future__ import annotations

import dataclasses
import json
import socket
import struct
import time
import zlib
from typing import Any, BinaryIO


MAGIC = b"OLCP"
PROTOCOL_VERSION = 1
ACCEPTED_SESSION_PROTOCOL_PREFIXES = ("operator.live_feed.", "operator.live_capture.")
FRAME_HEADER = struct.Struct(">4sBBHQQI")
COMPOSITE_JSON_PREFIX = struct.Struct(">I")
DENSE_POINT = struct.Struct("<fffBBBBf")

TYPE_SESSION_START = 1
TYPE_RGB_CSD = 2
TYPE_RGB_PACKET = 3
TYPE_DEPTH_METADATA = 4
TYPE_DEPTH_FRAME = 5
TYPE_HEAD_POSE = 6
TYPE_CONTROLLER_POSE = 7
TYPE_HAND_JOINTS = 8
TYPE_CONTROLLER_INPUT = 9
TYPE_SESSION_END = 10

FLAG_KEYFRAME = 1
FLAG_COMPOSITE_JSON = 2
FLAG_COMPRESSED_ZLIB = 4

MAX_DECOMPRESSED_DEPTH_BYTES = 64 * 1024 * 1024

TYPE_RESULT_HELLO = 100
TYPE_CAPTURE_REQUEST = 101
TYPE_RESULT_WELCOME = 102
TYPE_ALGORITHM_STATUS = 110
TYPE_MAP_RESET = 111
TYPE_DENSE_MAP_MANIFEST = 112
TYPE_DENSE_MAP_FRAGMENT = 113
TYPE_DENSE_MAP_COMMIT = 114
TYPE_CAMERA_TRAJECTORY = 115
TYPE_MAP_TRANSFORM = 116

JSON_FRAME_TYPES = {
    TYPE_SESSION_START,
    TYPE_RGB_CSD,
    TYPE_DEPTH_METADATA,
    TYPE_HEAD_POSE,
    TYPE_CONTROLLER_POSE,
    TYPE_HAND_JOINTS,
    TYPE_CONTROLLER_INPUT,
    TYPE_SESSION_END,
    TYPE_RESULT_HELLO,
    TYPE_CAPTURE_REQUEST,
    TYPE_RESULT_WELCOME,
    TYPE_ALGORITHM_STATUS,
    TYPE_MAP_RESET,
    TYPE_DENSE_MAP_MANIFEST,
    TYPE_DENSE_MAP_COMMIT,
    TYPE_CAMERA_TRAJECTORY,
    TYPE_MAP_TRANSFORM,
}


@dataclasses.dataclass(frozen=True)
class StreamCapability:
    name: str
    formats: tuple[str, ...]
    frame_types: tuple[int, ...]
    max_hz: float | None = None


@dataclasses.dataclass(frozen=True)
class ResultSinkCapability:
    name: str
    formats: tuple[str, ...]


@dataclasses.dataclass(frozen=True)
class XrCapabilities:
    protocol: str
    device: str
    streams: dict[str, StreamCapability]
    result_sinks: dict[str, ResultSinkCapability]


@dataclasses.dataclass(frozen=True)
class AlgorithmDemand:
    algorithm: str
    required_streams: tuple[str, ...]
    optional_streams: tuple[str, ...]
    result_streams: tuple[str, ...]
    limits: dict[str, Any]


@dataclasses.dataclass(frozen=True)
class CapturePlan:
    capabilities: XrCapabilities
    demand: AlgorithmDemand
    selected_streams: tuple[str, ...]
    result_streams: tuple[str, ...]


@dataclasses.dataclass(frozen=True)
class StreamEvent:
    frame_type: int
    flags: int
    pts_ns: int
    duration_ns: int
    payload: bytes
    recv_monotonic_ns: int = dataclasses.field(default_factory=time.monotonic_ns)

    def payload_json(self) -> dict[str, Any]:
        if self.frame_type not in JSON_FRAME_TYPES:
            raise ValueError(f"frame type {self.frame_type} is not JSON")
        return json.loads(self.payload.decode("utf-8"))


QUEST_CAPTURE_PROFILE = XrCapabilities(
    protocol="operator.live_feed.v1.compat",
    device="quest",
    streams={
        "session.json": StreamCapability("session.json", ("json",), (TYPE_SESSION_START, TYPE_SESSION_END)),
        "rgb.hevc": StreamCapability("rgb.hevc", ("hevc_annexb",), (TYPE_RGB_CSD, TYPE_RGB_PACKET), 60.0),
        "head_pose.json": StreamCapability("head_pose.json", ("json",), (TYPE_HEAD_POSE,), 90.0),
        "depth.u16": StreamCapability(
            "depth.u16",
            ("u16_mm", "json_plus_u16_mm", "zlib_u16_mm"),
            (TYPE_DEPTH_METADATA, TYPE_DEPTH_FRAME),
            30.0,
        ),
        "controller_pose.json": StreamCapability("controller_pose.json", ("json",), (TYPE_CONTROLLER_POSE,), 90.0),
        "controller_input.json": StreamCapability("controller_input.json", ("json",), (TYPE_CONTROLLER_INPUT,), 1000.0),
        "hand_joints.json": StreamCapability("hand_joints.json", ("json",), (TYPE_HAND_JOINTS,), 30.0),
    },
    result_sinks={
        "status.json": ResultSinkCapability("status.json", ("json",)),
        "dense_map.point_cloud_delta": ResultSinkCapability(
            "dense_map.point_cloud_delta",
            ("point_chunk_f32xyz_u8rgba_f32conf",),
        ),
        "camera_trajectory.json": ResultSinkCapability("camera_trajectory.json", ("json",)),
        "map_transform.json": ResultSinkCapability("map_transform.json", ("json",)),
    },
)


#: Maps a `session_start` capability flag to the stream it announces.
#: The headset declares what it *can* send via these `*_expected` booleans;
#: the server decides what it actually *should* send (capture_request).
SESSION_START_STREAM_FLAGS = {
    "depth_expected": "depth.u16",
    "head_pose_expected": "head_pose.json",
    "controller_pose_expected": "controller_pose.json",
    "hand_joints_expected": "hand_joints.json",
    "controller_input_expected": "controller_input.json",
}


def capabilities_from_session_start(
    info: dict[str, Any],
    *,
    template: XrCapabilities = QUEST_CAPTURE_PROFILE,
) -> XrCapabilities:
    """Derive the connected headset's real capabilities from its `session_start`.

    Preferred over the static :data:`QUEST_CAPTURE_PROFILE`: a headset that
    reports ``hand_joints_expected=false`` genuinely cannot supply that stream,
    so planning against the static profile would request data that never
    arrives. Stream metadata (formats, frame types, rates) is taken from
    ``template`` since `session_start` does not carry it.
    """
    streams: dict[str, StreamCapability] = {}
    # session.json is implicit: receiving a session_start proves it.
    if "session.json" in template.streams:
        streams["session.json"] = template.streams["session.json"]

    for flag, stream_name in SESSION_START_STREAM_FLAGS.items():
        if bool(info.get(flag)) and stream_name in template.streams:
            streams[stream_name] = template.streams[stream_name]

    # RGB is announced through its dimensions rather than a boolean.
    try:
        rgb_width = int(info.get("rgb_width", 0))
        rgb_height = int(info.get("rgb_height", 0))
    except (TypeError, ValueError):
        rgb_width = rgb_height = 0
    if rgb_width > 0 and rgb_height > 0 and "rgb.hevc" in template.streams:
        streams["rgb.hevc"] = template.streams["rgb.hevc"]

    device = str(info.get("device", info.get("device_model", template.device)))
    protocol = str(info.get("protocol", template.protocol))
    return XrCapabilities(
        protocol=protocol,
        device=device,
        streams=streams,
        # Result sinks are not described by session_start; the headset's
        # live-pull renderer defines them, so keep the template's set.
        result_sinks=dict(template.result_sinks),
    )


DEPTH_FUSION_DEMAND = AlgorithmDemand(
    algorithm="depth_fusion_pointcloud",
    required_streams=("session.json", "depth.u16", "head_pose.json"),
    optional_streams=(),
    result_streams=(
        "status.json",
        "dense_map.point_cloud_delta",
        "camera_trajectory.json",
        "map_transform.json",
    ),
    limits={
        "head_pose_max_hz": 30,
        "depth_policy": "nearest_keyframe",
        "color_source": "synthetic_depth",
    },
)


def to_plain(value: Any) -> Any:
    if dataclasses.is_dataclass(value):
        return {field.name: to_plain(getattr(value, field.name)) for field in dataclasses.fields(value)}
    if isinstance(value, dict):
        return {key: to_plain(item) for key, item in value.items()}
    if isinstance(value, tuple):
        return [to_plain(item) for item in value]
    return value


def encode_json(value: dict[str, Any]) -> bytes:
    return json.dumps(value, separators=(",", ":"), sort_keys=True).encode("utf-8")


def validate_demand(capabilities: XrCapabilities, demand: AlgorithmDemand) -> CapturePlan:
    missing_required = [name for name in demand.required_streams if name not in capabilities.streams]
    if missing_required:
        raise ValueError(f"XR profile does not support required streams: {missing_required}")
    missing_results = [name for name in demand.result_streams if name not in capabilities.result_sinks]
    if missing_results:
        raise ValueError(f"XR profile does not support result sinks: {missing_results}")

    selected = list(demand.required_streams)
    selected.extend(name for name in demand.optional_streams if name in capabilities.streams)
    return CapturePlan(
        capabilities=capabilities,
        demand=demand,
        selected_streams=tuple(selected),
        result_streams=demand.result_streams,
    )


def build_capture_request(plan: CapturePlan) -> dict[str, Any]:
    return {
        "schema": "operator.capture_request.v1",
        "protocol": "operator.live_feed.v2",
        "algorithm": plan.demand.algorithm,
        "selected_streams": list(plan.selected_streams),
        "result_streams": list(plan.result_streams),
        "limits": plan.demand.limits,
        "stream_frame_types": {
            name: list(plan.capabilities.streams[name].frame_types) for name in plan.selected_streams
        },
    }


def pack_frame(frame_type: int, flags: int, pts_ns: int, duration_ns: int, payload: bytes) -> bytes:
    return FRAME_HEADER.pack(MAGIC, PROTOCOL_VERSION, frame_type, flags, pts_ns, duration_ns, len(payload)) + payload


def read_exact(source: socket.socket | BinaryIO, size: int) -> bytes:
    chunks: list[bytes] = []
    remaining = size
    while remaining > 0:
        if isinstance(source, socket.socket):
            chunk = source.recv(remaining)
        else:
            chunk = source.read(remaining)
        if not chunk:
            if remaining == size:
                return b""
            raise EOFError("connection closed mid-frame")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def read_frame(
    source: socket.socket | BinaryIO,
    *,
    max_payload_size: int = 64 * 1024 * 1024,
) -> StreamEvent | None:
    header = read_exact(source, FRAME_HEADER.size)
    if not header:
        return None
    magic, version, frame_type, flags, pts_ns, duration_ns, payload_size = FRAME_HEADER.unpack(header)
    if magic != MAGIC:
        raise ValueError(f"invalid magic {magic!r}")
    if version != PROTOCOL_VERSION:
        raise ValueError(f"unsupported OLCP version {version}")
    if payload_size > max_payload_size:
        raise ValueError(
            f"OLCP payload too large: {payload_size} bytes "
            f"(maximum {max_payload_size})"
        )
    payload = read_exact(source, payload_size)
    if len(payload) != payload_size:
        raise EOFError("connection closed before payload completed")
    return StreamEvent(frame_type, flags, pts_ns, duration_ns, payload)


def parse_composite_payload(payload: bytes) -> tuple[dict[str, Any], bytes]:
    if len(payload) < COMPOSITE_JSON_PREFIX.size:
        raise ValueError("composite payload is too short")
    (json_size,) = COMPOSITE_JSON_PREFIX.unpack(payload[: COMPOSITE_JSON_PREFIX.size])
    json_start = COMPOSITE_JSON_PREFIX.size
    json_end = json_start + json_size
    if json_end > len(payload):
        raise ValueError("composite JSON section exceeds payload size")
    metadata = json.loads(payload[json_start:json_end].decode("utf-8"))
    return metadata, payload[json_end:]


def pack_composite_payload(metadata: dict[str, Any], binary: bytes) -> bytes:
    metadata_json = encode_json(metadata)
    return COMPOSITE_JSON_PREFIX.pack(len(metadata_json)) + metadata_json + binary


def decode_transport_payload(
    payload: bytes,
    flags: int,
    *,
    expected_size: int | None = None,
    max_output_size: int = MAX_DECOMPRESSED_DEPTH_BYTES,
) -> bytes:
    """Decode optional OLCP binary-payload compression with strict size bounds.

    Depth frames use a per-frame flag so old uncompressed producers and new
    adaptive producers can share one connection. ``expected_size`` should be
    ``width * height * 2`` whenever the depth model is known.
    """
    if not (flags & FLAG_COMPRESSED_ZLIB):
        return payload
    if max_output_size <= 0:
        raise ValueError("maximum decompressed payload size must be positive")
    if expected_size is not None and (
        expected_size < 0 or expected_size > max_output_size
    ):
        raise ValueError(
            f"invalid expected decompressed size: {expected_size} "
            f"(maximum {max_output_size})"
        )

    output_limit = expected_size if expected_size is not None else max_output_size
    decoder = zlib.decompressobj()
    try:
        decoded = decoder.decompress(payload, output_limit + 1)
        if len(decoded) > output_limit or decoder.unconsumed_tail:
            raise ValueError(
                f"decompressed payload exceeds {output_limit} bytes"
            )
        if not decoder.eof:
            raise ValueError("compressed payload is truncated")
        if decoder.unused_data:
            raise ValueError("compressed payload has trailing data")
        decoded += decoder.flush()
    except zlib.error as error:
        raise ValueError(f"invalid zlib payload: {error}") from error

    if len(decoded) > output_limit:
        raise ValueError(f"decompressed payload exceeds {output_limit} bytes")
    if expected_size is not None and len(decoded) != expected_size:
        raise ValueError(
            f"decompressed payload size mismatch: {len(decoded)} != {expected_size}"
        )
    return decoded


def decode_depth_frame_payload(
    event: StreamEvent,
    *,
    expected_size: int | None = None,
) -> tuple[dict[str, Any], bytes]:
    """Return depth metadata and canonical raw uint16 bytes from an OLCP frame."""
    if event.frame_type != TYPE_DEPTH_FRAME:
        raise ValueError(f"frame type {event.frame_type} is not depth")
    metadata: dict[str, Any] = {}
    binary = event.payload
    if event.flags & FLAG_COMPOSITE_JSON:
        metadata, binary = parse_composite_payload(binary)
    if expected_size is None:
        try:
            width = int(metadata.get("width", 0))
            height = int(metadata.get("height", 0))
        except (TypeError, ValueError):
            width = height = 0
        if width > 0 and height > 0:
            expected_size = width * height * 2
    return metadata, decode_transport_payload(
        binary,
        event.flags,
        expected_size=expected_size,
    )


def get_demand(name: str) -> AlgorithmDemand:
    if name in ("depth_fusion_pointcloud", "depth_fusion"):
        return DEPTH_FUSION_DEMAND
    if name == "vggt_slam2":
        raise ValueError(
            "vggt_slam2 is not implemented by this dependency-free demo; "
            "use --algorithm depth_fusion_pointcloud or replace DepthFusionPointCloudWorker"
        )
    raise ValueError(f"unknown algorithm: {name}")
