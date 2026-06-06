#!/usr/bin/env python3
from __future__ import annotations

import argparse
import base64
import collections
import dataclasses
import io
import json
import math
import queue
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path
from typing import Any, BinaryIO, Callable, Iterable


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

TYPE_CAPTURE_REQUEST = 101
TYPE_CAPTURE_ACCEPT = 102
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
    TYPE_CAPTURE_REQUEST,
    TYPE_CAPTURE_ACCEPT,
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


Transform = tuple[tuple[float, float, float, float, float, float, float, float, float], tuple[float, float, float]]


@dataclasses.dataclass(frozen=True)
class PoseSample:
    pts_ns: int
    transform: Transform
    tracking_valid: bool


@dataclasses.dataclass(frozen=True)
class DepthCameraModel:
    width: int
    height: int
    fx: float | None = None
    fy: float | None = None
    cx: float | None = None
    cy: float | None = None
    fov_left: float | None = None
    fov_right: float | None = None
    fov_top: float | None = None
    fov_bottom: float | None = None
    depth_eye_to_local: Transform | None = None
    depth_eye_transform_is_absolute: bool = False

    def with_fallback(self, fallback: "DepthCameraModel | None") -> "DepthCameraModel":
        if fallback is None:
            return self
        return DepthCameraModel(
            width=self.width or fallback.width,
            height=self.height or fallback.height,
            fx=self.fx if self.fx is not None else fallback.fx,
            fy=self.fy if self.fy is not None else fallback.fy,
            cx=self.cx if self.cx is not None else fallback.cx,
            cy=self.cy if self.cy is not None else fallback.cy,
            fov_left=self.fov_left if self.fov_left is not None else fallback.fov_left,
            fov_right=self.fov_right if self.fov_right is not None else fallback.fov_right,
            fov_top=self.fov_top if self.fov_top is not None else fallback.fov_top,
            fov_bottom=self.fov_bottom if self.fov_bottom is not None else fallback.fov_bottom,
            depth_eye_to_local=self.depth_eye_to_local if self.depth_eye_to_local is not None else fallback.depth_eye_to_local,
            depth_eye_transform_is_absolute=(
                self.depth_eye_transform_is_absolute
                if self.depth_eye_to_local is not None
                else fallback.depth_eye_transform_is_absolute
            ),
        )

    def has_projection(self) -> bool:
        has_intrinsics = None not in (self.fx, self.fy, self.cx, self.cy)
        has_fov = None not in (self.fov_left, self.fov_right, self.fov_top, self.fov_bottom)
        return self.width > 0 and self.height > 0 and (has_intrinsics or has_fov)


@dataclasses.dataclass(frozen=True)
class RgbCameraModel:
    index: int
    width: int
    height: int
    fx: float
    fy: float
    cx: float
    cy: float
    local_from_camera: Transform | None = None


@dataclasses.dataclass(frozen=True)
class RgbFrame:
    pts_ns: int
    width: int
    height: int
    stereo_layout: str
    cameras: tuple[RgbCameraModel, ...]
    data: bytes


class DroppingQueue:
    def __init__(self, name: str, maxsize: int) -> None:
        self.name = name
        self._queue: queue.Queue[StreamEvent] = queue.Queue(maxsize=maxsize)
        self.dropped = 0

    def put_drop_oldest(self, event: StreamEvent) -> None:
        try:
            self._queue.put_nowait(event)
            return
        except queue.Full:
            pass
        try:
            self._queue.get_nowait()
            self.dropped += 1
        except queue.Empty:
            pass
        try:
            self._queue.put_nowait(event)
        except queue.Full:
            self.dropped += 1

    def get(self, timeout: float) -> StreamEvent:
        return self._queue.get(timeout=timeout)

    def get_nowait(self) -> StreamEvent:
        return self._queue.get_nowait()

    def qsize(self) -> int:
        return self._queue.qsize()


@dataclasses.dataclass
class SessionQueues:
    session: DroppingQueue
    rgb_csd: DroppingQueue
    rgb_packet: DroppingQueue
    depth: DroppingQueue
    head_pose: DroppingQueue
    controller: DroppingQueue
    hands: DroppingQueue
    result: DroppingQueue

    @classmethod
    def create(cls, maxsize: int) -> "SessionQueues":
        return cls(
            session=DroppingQueue("session", maxsize),
            rgb_csd=DroppingQueue("rgb_csd", maxsize),
            rgb_packet=DroppingQueue("rgb_packet", maxsize),
            depth=DroppingQueue("depth", maxsize),
            head_pose=DroppingQueue("head_pose", maxsize),
            controller=DroppingQueue("controller", maxsize),
            hands=DroppingQueue("hands", maxsize),
            result=DroppingQueue("result", maxsize),
        )


QUEST_CAPTURE_PROFILE = XrCapabilities(
    protocol="operator.live_feed.v1.compat",
    device="quest",
    streams={
        "session.json": StreamCapability("session.json", ("json",), (TYPE_SESSION_START, TYPE_SESSION_END)),
        "rgb.hevc": StreamCapability("rgb.hevc", ("hevc_annexb",), (TYPE_RGB_CSD, TYPE_RGB_PACKET), 60.0),
        "head_pose.json": StreamCapability("head_pose.json", ("json",), (TYPE_HEAD_POSE,), 90.0),
        "depth.u16": StreamCapability(
            "depth.u16",
            ("u16_mm", "json_plus_u16_mm"),
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


def read_frame(source: socket.socket | BinaryIO) -> StreamEvent | None:
    header = read_exact(source, FRAME_HEADER.size)
    if not header:
        return None
    magic, version, frame_type, flags, pts_ns, duration_ns, payload_size = FRAME_HEADER.unpack(header)
    if magic != MAGIC:
        raise ValueError(f"invalid magic {magic!r}")
    if version != PROTOCOL_VERSION:
        raise ValueError(f"unsupported OLCP version {version}")
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


def identity_matrix() -> list[list[float]]:
    return [
        [1.0, 0.0, 0.0, 0.0],
        [0.0, 1.0, 0.0, 0.0],
        [0.0, 0.0, 1.0, 0.0],
        [0.0, 0.0, 0.0, 1.0],
    ]


def identity_transform() -> Transform:
    return ((
        1.0, 0.0, 0.0,
        0.0, 1.0, 0.0,
        0.0, 0.0, 1.0,
    ), (0.0, 0.0, 0.0))


def transform_to_matrix(transform: Transform) -> list[list[float]]:
    rotation, translation = transform
    return [
        [rotation[0], rotation[1], rotation[2], translation[0]],
        [rotation[3], rotation[4], rotation[5], translation[1]],
        [rotation[6], rotation[7], rotation[8], translation[2]],
        [0.0, 0.0, 0.0, 1.0],
    ]


def as_finite_float(value: Any) -> float | None:
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    return number if math.isfinite(number) else None


def as_finite_int(value: Any) -> int | None:
    try:
        number = int(value)
    except (TypeError, ValueError):
        return None
    return number


def quaternion_to_rotation(qx: float, qy: float, qz: float, qw: float) -> tuple[float, float, float, float, float, float, float, float, float]:
    norm = math.sqrt(qx * qx + qy * qy + qz * qz + qw * qw)
    if norm <= 1e-9 or not math.isfinite(norm):
        return identity_transform()[0]
    qx /= norm
    qy /= norm
    qz /= norm
    qw /= norm
    xx = qx * qx
    yy = qy * qy
    zz = qz * qz
    xy = qx * qy
    xz = qx * qz
    yz = qy * qz
    wx = qw * qx
    wy = qw * qy
    wz = qw * qz
    return (
        1.0 - 2.0 * (yy + zz), 2.0 * (xy - wz), 2.0 * (xz + wy),
        2.0 * (xy + wz), 1.0 - 2.0 * (xx + zz), 2.0 * (yz - wx),
        2.0 * (xz - wy), 2.0 * (yz + wx), 1.0 - 2.0 * (xx + yy),
    )


def transform_from_position_rotation(position: Any, rotation: Any) -> Transform | None:
    if not isinstance(position, dict) or not isinstance(rotation, dict):
        return None
    px = as_finite_float(position.get("x"))
    py = as_finite_float(position.get("y"))
    pz = as_finite_float(position.get("z"))
    qx = as_finite_float(rotation.get("x"))
    qy = as_finite_float(rotation.get("y"))
    qz = as_finite_float(rotation.get("z"))
    qw = as_finite_float(rotation.get("w"))
    if None in (px, py, pz, qx, qy, qz, qw):
        return None
    return (quaternion_to_rotation(qx, qy, qz, qw), (px, py, pz))


def transform_from_record(record: Any) -> Transform | None:
    if not isinstance(record, dict):
        return None
    return transform_from_position_rotation(record.get("position"), record.get("rotation"))


def transform_from_extrinsics_3x4(values: Any) -> Transform | None:
    if not isinstance(values, list) or len(values) != 12:
        return None
    floats = [as_finite_float(value) for value in values]
    if any(value is None for value in floats):
        return None
    assert all(value is not None for value in floats)
    return ((
        floats[0], floats[1], floats[2],
        floats[4], floats[5], floats[6],
        floats[8], floats[9], floats[10],
    ), (floats[3], floats[7], floats[11]))


def apply_transform(transform: Transform, point: tuple[float, float, float]) -> tuple[float, float, float]:
    rotation, translation = transform
    x, y, z = point
    return (
        rotation[0] * x + rotation[1] * y + rotation[2] * z + translation[0],
        rotation[3] * x + rotation[4] * y + rotation[5] * z + translation[1],
        rotation[6] * x + rotation[7] * y + rotation[8] * z + translation[2],
    )


def compose_transform(parent: Transform, child: Transform) -> Transform:
    parent_rotation, parent_translation = parent
    child_rotation, child_translation = child
    rotation = (
        parent_rotation[0] * child_rotation[0] + parent_rotation[1] * child_rotation[3] + parent_rotation[2] * child_rotation[6],
        parent_rotation[0] * child_rotation[1] + parent_rotation[1] * child_rotation[4] + parent_rotation[2] * child_rotation[7],
        parent_rotation[0] * child_rotation[2] + parent_rotation[1] * child_rotation[5] + parent_rotation[2] * child_rotation[8],
        parent_rotation[3] * child_rotation[0] + parent_rotation[4] * child_rotation[3] + parent_rotation[5] * child_rotation[6],
        parent_rotation[3] * child_rotation[1] + parent_rotation[4] * child_rotation[4] + parent_rotation[5] * child_rotation[7],
        parent_rotation[3] * child_rotation[2] + parent_rotation[4] * child_rotation[5] + parent_rotation[5] * child_rotation[8],
        parent_rotation[6] * child_rotation[0] + parent_rotation[7] * child_rotation[3] + parent_rotation[8] * child_rotation[6],
        parent_rotation[6] * child_rotation[1] + parent_rotation[7] * child_rotation[4] + parent_rotation[8] * child_rotation[7],
        parent_rotation[6] * child_rotation[2] + parent_rotation[7] * child_rotation[5] + parent_rotation[8] * child_rotation[8],
    )
    translation = apply_transform(parent, child_translation)
    return (rotation, translation)


def invert_transform(transform: Transform) -> Transform:
    rotation, translation = transform
    inverse_rotation = (
        rotation[0], rotation[3], rotation[6],
        rotation[1], rotation[4], rotation[7],
        rotation[2], rotation[5], rotation[8],
    )
    tx, ty, tz = translation
    inverse_translation = (
        -(inverse_rotation[0] * tx + inverse_rotation[1] * ty + inverse_rotation[2] * tz),
        -(inverse_rotation[3] * tx + inverse_rotation[4] * ty + inverse_rotation[5] * tz),
        -(inverse_rotation[6] * tx + inverse_rotation[7] * ty + inverse_rotation[8] * tz),
    )
    return inverse_rotation, inverse_translation


def parse_pose_sample(event: StreamEvent) -> PoseSample | None:
    try:
        payload = event.payload_json()
    except Exception:
        return None
    transform = transform_from_position_rotation(payload.get("position"), payload.get("rotation"))
    if transform is None:
        return None
    return PoseSample(
        pts_ns=event.pts_ns,
        transform=transform,
        tracking_valid=bool(payload.get("tracking_valid", True)),
    )


def parse_nested_metadata_json(metadata: dict[str, Any]) -> dict[str, Any]:
    nested = metadata.get("metadata_json")
    if not isinstance(nested, str) or not nested.strip():
        return {}
    try:
        parsed = json.loads(nested)
    except json.JSONDecodeError:
        return {}
    return parsed if isinstance(parsed, dict) else {}


def depth_model_from_metadata(
    metadata: dict[str, Any],
    fallback: DepthCameraModel | None = None,
) -> DepthCameraModel | None:
    nested = parse_nested_metadata_json(metadata)
    intrinsics = metadata.get("intrinsics")
    if not isinstance(intrinsics, dict):
        intrinsics = nested.get("intrinsics") if isinstance(nested.get("intrinsics"), dict) else {}
    fov = nested.get("fov_tangent") if isinstance(nested.get("fov_tangent"), dict) else {}

    width = as_finite_int(metadata.get("width"))
    height = as_finite_int(metadata.get("height"))
    if width is None:
        width = as_finite_int(intrinsics.get("width")) if isinstance(intrinsics, dict) else None
    if height is None:
        height = as_finite_int(intrinsics.get("height")) if isinstance(intrinsics, dict) else None
    if width is None and fallback is not None:
        width = fallback.width
    if height is None and fallback is not None:
        height = fallback.height
    if width is None or height is None or width <= 0 or height <= 0:
        return fallback

    local_from_depth_eye = transform_from_record(nested.get("local_from_depth_eye"))
    transform_is_absolute = local_from_depth_eye is not None
    if local_from_depth_eye is None and isinstance(intrinsics, dict):
        local_from_depth_eye = transform_from_extrinsics_3x4(intrinsics.get("extrinsics_3x4"))

    model = DepthCameraModel(
        width=width,
        height=height,
        fx=as_finite_float(intrinsics.get("fx")) if isinstance(intrinsics, dict) else None,
        fy=as_finite_float(intrinsics.get("fy")) if isinstance(intrinsics, dict) else None,
        cx=as_finite_float(intrinsics.get("cx")) if isinstance(intrinsics, dict) else None,
        cy=as_finite_float(intrinsics.get("cy")) if isinstance(intrinsics, dict) else None,
        fov_left=as_finite_float(metadata.get("fov_left", fov.get("left"))),
        fov_right=as_finite_float(metadata.get("fov_right", fov.get("right"))),
        fov_top=as_finite_float(metadata.get("fov_top", fov.get("top"))),
        fov_bottom=as_finite_float(metadata.get("fov_bottom", fov.get("bottom"))),
        depth_eye_to_local=local_from_depth_eye,
        depth_eye_transform_is_absolute=transform_is_absolute,
    )
    return model.with_fallback(fallback)


def rgb_cameras_from_config(config: dict[str, Any]) -> tuple[RgbCameraModel, ...]:
    cameras = config.get("cameras")
    if not isinstance(cameras, list):
        cameras = []
    parsed: list[RgbCameraModel] = []
    for index, camera in enumerate(cameras):
        if not isinstance(camera, dict):
            continue
        width = as_finite_int(camera.get("width"))
        height = as_finite_int(camera.get("height"))
        fx = as_finite_float(camera.get("fx"))
        fy = as_finite_float(camera.get("fy"))
        cx = as_finite_float(camera.get("cx"))
        cy = as_finite_float(camera.get("cy"))
        if width is None or height is None or width <= 0 or height <= 0:
            continue
        if None in (fx, fy, cx, cy):
            continue
        assert fx is not None and fy is not None and cx is not None and cy is not None
        parsed.append(
            RgbCameraModel(
                index=index,
                width=width,
                height=height,
                fx=fx,
                fy=fy,
                cx=cx,
                cy=cy,
                local_from_camera=transform_from_extrinsics_3x4(camera.get("extrinsics_3x4")),
            )
        )
    if parsed:
        return tuple(parsed)

    width = as_finite_int(config.get("width"))
    height = as_finite_int(config.get("height"))
    if width is None or height is None or width <= 0 or height <= 0:
        return ()
    camera_count = max(1, as_finite_int(config.get("camera_count")) or 1)
    layout = str(config.get("stereo_layout", "mono"))
    camera_width = width // camera_count if layout == "side_by_side" and camera_count > 1 else width
    return tuple(
        RgbCameraModel(
            index=index,
            width=camera_width,
            height=height,
            fx=float(camera_width),
            fy=float(camera_width),
            cx=float(camera_width) * 0.5,
            cy=float(height) * 0.5,
        )
        for index in range(camera_count)
    )


class RgbHevcDecoder:
    def __init__(self, ffmpeg_bin: str = "ffmpeg", enabled: bool = True, max_frames: int = 24) -> None:
        self.enabled = enabled
        self.ffmpeg_bin = shutil.which(ffmpeg_bin) if ffmpeg_bin else None
        self.max_frames = max(1, max_frames)
        self.width = 0
        self.height = 0
        self.stereo_layout = "mono"
        self.cameras: tuple[RgbCameraModel, ...] = ()
        self.frames: collections.deque[RgbFrame] = collections.deque(maxlen=self.max_frames)
        self.decoded_count = 0
        self.failed = False
        self.disabled_reason = "" if self.ffmpeg_bin else f"ffmpeg not found: {ffmpeg_bin}"
        self._proc: subprocess.Popen[bytes] | None = None
        self._reader: threading.Thread | None = None
        self._lock = threading.Lock()
        self._pending_pts: queue.Queue[int] = queue.Queue(maxsize=256)
        self._configured_signature: tuple[int, int, str, int] | None = None

    def close(self) -> None:
        proc = self._proc
        self._proc = None
        if proc is not None:
            try:
                if proc.stdin:
                    proc.stdin.close()
            except OSError:
                pass
            try:
                proc.terminate()
            except OSError:
                pass
            try:
                proc.wait(timeout=1.0)
            except subprocess.TimeoutExpired:
                proc.kill()
        if self._reader is not None:
            self._reader.join(timeout=1.0)
            self._reader = None

    def configure(self, config: dict[str, Any]) -> None:
        if not self.enabled or self.failed:
            return
        if self.ffmpeg_bin is None:
            return
        width = as_finite_int(config.get("width"))
        height = as_finite_int(config.get("height"))
        if width is None or height is None or width <= 0 or height <= 0:
            self.disabled_reason = "missing RGB frame dimensions"
            return
        cameras = rgb_cameras_from_config(config)
        layout = str(config.get("stereo_layout", "mono"))
        signature = (width, height, layout, len(cameras))
        if self._configured_signature != signature:
            self.close()
            self.width = width
            self.height = height
            self.stereo_layout = layout
            self.cameras = cameras
            self._configured_signature = signature
            self._start_process()
        csd_base64 = str(config.get("csd_base64", ""))
        if csd_base64:
            try:
                self._write_bytes(base64.b64decode(csd_base64))
            except Exception as error:
                self.failed = True
                self.disabled_reason = f"bad rgb_csd: {error}"

    def submit_packet(self, event: StreamEvent) -> None:
        if self._proc is None or self.failed:
            return
        try:
            self._pending_pts.put_nowait(event.pts_ns)
        except queue.Full:
            try:
                self._pending_pts.get_nowait()
            except queue.Empty:
                pass
            try:
                self._pending_pts.put_nowait(event.pts_ns)
            except queue.Full:
                pass
        self._write_bytes(event.payload)

    def nearest_frame(self, pts_ns: int, max_delta_ns: int = 500_000_000) -> RgbFrame | None:
        with self._lock:
            frames = list(self.frames)
        if not frames:
            return None
        best = min(frames, key=lambda frame: abs(frame.pts_ns - pts_ns))
        if pts_ns > 0 and best.pts_ns > 0 and abs(best.pts_ns - pts_ns) > max_delta_ns:
            return frames[-1]
        return best

    def _start_process(self) -> None:
        assert self.ffmpeg_bin is not None
        command = [
            self.ffmpeg_bin,
            "-hide_banner",
            "-loglevel",
            "error",
            "-f",
            "hevc",
            "-i",
            "pipe:0",
            "-an",
            "-f",
            "rawvideo",
            "-pix_fmt",
            "rgb24",
            "pipe:1",
        ]
        try:
            self._proc = subprocess.Popen(
                command,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                bufsize=0,
            )
        except OSError as error:
            self.failed = True
            self.disabled_reason = f"failed to start ffmpeg: {error}"
            return
        self._reader = threading.Thread(target=self._reader_loop, name="rgb-hevc-decoder", daemon=True)
        self._reader.start()

    def _write_bytes(self, payload: bytes) -> None:
        proc = self._proc
        if proc is None or proc.stdin is None or self.failed:
            return
        try:
            proc.stdin.write(payload)
            proc.stdin.flush()
        except (BrokenPipeError, OSError) as error:
            self.failed = True
            self.disabled_reason = f"ffmpeg stdin failed: {error}"

    def _reader_loop(self) -> None:
        proc = self._proc
        if proc is None or proc.stdout is None:
            return
        frame_size = self.width * self.height * 3
        while frame_size > 0:
            try:
                data = read_exact(proc.stdout, frame_size)
            except Exception as error:
                self.disabled_reason = f"ffmpeg stdout failed: {error}"
                return
            if not data:
                return
            try:
                pts_ns = self._pending_pts.get_nowait()
            except queue.Empty:
                pts_ns = time.monotonic_ns()
            frame = RgbFrame(
                pts_ns=pts_ns,
                width=self.width,
                height=self.height,
                stereo_layout=self.stereo_layout,
                cameras=self.cameras,
                data=data,
            )
            with self._lock:
                self.frames.append(frame)
                self.decoded_count += 1


def make_dense_point_payload(
    map_id: str,
    map_version: int,
    submap_id: int,
    frame_ids: tuple[int, int],
    point_count: int = 512,
) -> tuple[dict[str, Any], bytes]:
    points = bytearray()
    for index in range(point_count):
        col = index % 32
        row = index // 32
        x = (col - 16) * 0.035
        y = (row - 8) * 0.035
        z = 1.0 + 0.01 * ((index + submap_id) % 17)
        r = (40 + index * 3) % 256
        g = (120 + index * 5) % 256
        b = (200 + submap_id * 11) % 256
        points.extend(DENSE_POINT.pack(x, y, z, r, g, b, 255, 0.75))
    metadata = {
        "schema": "operator.dense_map_chunk.v1",
        "map_id": map_id,
        "map_version": map_version,
        "submap_id": submap_id,
        "chunk_id": f"submap_{submap_id:04d}_chunk_0000",
        "operation": "upsert",
        "frame_id_range": list(frame_ids),
        "coordinate_frame": "map",
        "T_openxr_map": identity_matrix(),
        "point_format": "f32xyz_u8rgba_f32conf",
        "point_stride_bytes": DENSE_POINT.size,
        "point_count": point_count,
    }
    return metadata, bytes(points)


class ResultChannel:
    def __init__(self, host: str, port: int, enabled: bool) -> None:
        self.host = host
        self.port = port
        self.enabled = enabled
        self._stop = threading.Event()
        self._lock = threading.Lock()
        self._server: socket.socket | None = None
        self._conn: socket.socket | None = None
        self._thread: threading.Thread | None = None

    def start(self) -> None:
        if not self.enabled:
            print("result return disabled", flush=True)
            return
        self._thread = threading.Thread(target=self._serve, name="live-feed-result-channel", daemon=True)
        self._thread.start()

    def close(self) -> None:
        self._stop.set()
        with self._lock:
            self._close_conn_locked()
            if self._server is not None:
                try:
                    self._server.close()
                except OSError:
                    pass
                self._server = None
        if self._thread is not None:
            self._thread.join(timeout=1.0)

    def send_frame(self, frame_type: int, flags: int, pts_ns: int, duration_ns: int, payload: bytes) -> None:
        if not self.enabled:
            return
        frame = pack_frame(frame_type, flags, pts_ns, duration_ns, payload)
        with self._lock:
            if self._conn is None:
                return
            try:
                self._conn.sendall(frame)
            except OSError as error:
                print(f"result send failed: {error}", file=sys.stderr, flush=True)
                self._close_conn_locked()

    def _serve(self) -> None:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as server:
            server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            server.bind((self.host, self.port))
            server.listen(1)
            server.settimeout(0.5)
            with self._lock:
                self._server = server
            print(f"result listening on {self.host}:{self.port}", flush=True)
            while not self._stop.is_set():
                try:
                    conn, peer = server.accept()
                except socket.timeout:
                    continue
                except OSError:
                    break
                conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                conn.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
                with self._lock:
                    self._close_conn_locked()
                    self._conn = conn
                print(f"result accepted {peer[0]}:{peer[1]}", flush=True)

    def _close_conn_locked(self) -> None:
        if self._conn is None:
            return
        try:
            self._conn.close()
        except OSError:
            pass
        self._conn = None


class ResultPublisher:
    def __init__(
        self,
        session_dir: Path,
        queues: SessionQueues,
        send_frame: Callable[[int, int, int, int, bytes], None],
        max_fragment_bytes: int = 1024 * 1024,
    ) -> None:
        self.session_dir = session_dir
        self.queues = queues
        self.send_frame = send_frame
        self.max_fragment_bytes = max(64 * 1024, max_fragment_bytes)
        self.results_dir = session_dir / "results"
        self.chunk_dir = self.results_dir / "map_chunks"
        self.results_dir.mkdir(parents=True, exist_ok=True)
        self.chunk_dir.mkdir(parents=True, exist_ok=True)
        self._log = (self.results_dir / "results.ndjson").open("a", encoding="utf-8")

    def close(self) -> None:
        self._log.close()

    def publish_json(self, frame_type: int, value: dict[str, Any], pts_ns: int = 0) -> None:
        payload = encode_json(value)
        event = StreamEvent(frame_type, 0, pts_ns, 0, payload)
        self.queues.result.put_drop_oldest(event)
        self._write_log(event, value)
        self.send_frame(frame_type, 0, pts_ns, 0, payload)

    def publish_dense_chunk(self, metadata: dict[str, Any], points: bytes, pts_ns: int = 0) -> None:
        chunk_path = self.chunk_dir / f"{metadata['chunk_id']}.bin"
        chunk_path.write_bytes(points)
        stride = max(1, int(metadata.get("point_stride_bytes", DENSE_POINT.size)))
        fragment_bytes = self.max_fragment_bytes - (self.max_fragment_bytes % stride)
        fragment_bytes = max(stride, fragment_bytes)
        fragment_count = max(1, math.ceil(len(points) / fragment_bytes)) if points else 1
        manifest = {
            "schema": "operator.dense_map_manifest.v1",
            "map_id": metadata.get("map_id", ""),
            "map_version": int(metadata.get("map_version", 0)),
            "submap_id": int(metadata.get("submap_id", 0)),
            "chunks": [
                {
                    "chunk_id": metadata["chunk_id"],
                    "operation": metadata.get("operation", "upsert"),
                    "encoding": metadata.get("encoding", metadata.get("point_format", "")),
                    "point_format": metadata.get("point_format", ""),
                    "point_stride_bytes": int(metadata.get("point_stride_bytes", 0)),
                    "point_count": int(metadata.get("point_count", 0)),
                    "fragment_count": fragment_count,
                    "coordinate_frame": metadata.get("coordinate_frame", "map"),
                    "payload_size_bytes": len(points),
                }
            ],
            "T_openxr_map": metadata.get("T_openxr_map", identity_matrix()),
        }
        self.publish_json(TYPE_DENSE_MAP_MANIFEST, manifest, pts_ns=pts_ns)

        for fragment_index in range(fragment_count):
            start = fragment_index * fragment_bytes
            end = min(len(points), start + fragment_bytes)
            fragment = points[start:end]
            fragment_metadata = dict(metadata)
            fragment_metadata.update(
                {
                    "schema": "operator.dense_map_fragment.v1",
                    "fragment_index": fragment_index,
                    "fragment_count": fragment_count,
                    "payload_size_bytes": len(fragment),
                    "total_payload_size_bytes": len(points),
                }
            )
            payload = pack_composite_payload(fragment_metadata, fragment)
            event = StreamEvent(TYPE_DENSE_MAP_FRAGMENT, FLAG_COMPOSITE_JSON, pts_ns, 0, payload)
            self.queues.result.put_drop_oldest(event)
            log_value = dict(fragment_metadata)
            log_value["binary_uri"] = str(chunk_path.relative_to(self.session_dir))
            self._write_log(event, log_value)
            self.send_frame(TYPE_DENSE_MAP_FRAGMENT, FLAG_COMPOSITE_JSON, pts_ns, 0, payload)

        commit = {
            "schema": "operator.dense_map_commit.v1",
            "map_id": metadata.get("map_id", ""),
            "map_version": int(metadata.get("map_version", 0)),
            "committed_chunks": [metadata["chunk_id"]],
        }
        self.publish_json(TYPE_DENSE_MAP_COMMIT, commit, pts_ns=pts_ns)

    def _write_log(self, event: StreamEvent, value: dict[str, Any]) -> None:
        record = {
            "recv_monotonic_ns": event.recv_monotonic_ns,
            "frame_type": event.frame_type,
            "flags": event.flags,
            "pts_ns": event.pts_ns,
            "payload": value,
        }
        self._log.write(json.dumps(record, sort_keys=True) + "\n")
        self._log.flush()


class DepthFusionPointCloudWorker(threading.Thread):
    def __init__(
        self,
        plan: CapturePlan,
        queues: SessionQueues,
        publisher: ResultPublisher,
        stop_event: threading.Event,
        map_id: str,
        publish_interval_s: float,
        point_stride: int,
        min_depth_m: float,
        max_depth_m: float,
        max_points_per_update: int,
        rgb_colorize: bool,
        ffmpeg_bin: str,
    ) -> None:
        super().__init__(name="depth-fusion-pointcloud", daemon=True)
        self.plan = plan
        self.queues = queues
        self.publisher = publisher
        self.stop_event = stop_event
        self.map_id = map_id
        self.publish_interval_s = max(0.1, publish_interval_s)
        self.point_stride = max(1, point_stride)
        self.min_depth_m = max(0.0, min_depth_m)
        self.max_depth_m = max(self.min_depth_m + 0.1, max_depth_m)
        self.max_points_per_update = max(1, max_points_per_update)
        self.rgb_decoder = RgbHevcDecoder(ffmpeg_bin=ffmpeg_bin, enabled=rgb_colorize)
        self.poses: collections.deque[PoseSample] = collections.deque(maxlen=1200)
        self.latest_depth_model: DepthCameraModel | None = None
        self.rgb_config: dict[str, Any] = {}
        self.rgb_packet_count = 0
        self.rgb_colored_points = 0
        self.synthetic_colored_points = 0
        self.depth_frame_count = 0
        self.reconstructed_frame_count = 0
        self.skipped_depth_frames = 0
        self.pending_points = bytearray()
        self.pending_point_count = 0
        self.global_point_count = 0
        self.map_version = 0
        self.submap_id = 0
        self._last_publish = time.monotonic()
        self._last_status_log = self._last_publish
        self._last_status_depth_frames = 0
        self._last_status_reconstructed_frames = 0
        self._global_file = (publisher.results_dir / "global_pointcloud.bin").open("ab")

    def run(self) -> None:
        try:
            self.publisher.publish_json(
                TYPE_ALGORITHM_STATUS,
                {
                    "schema": "operator.algorithm_status.v1",
                    "algorithm": self.plan.demand.algorithm,
                    "state": "running",
                    "message": "depth fusion pointcloud worker started",
                    "publish_interval_s": self.publish_interval_s,
                    "point_stride": self.point_stride,
                    "depth_range_m": [self.min_depth_m, self.max_depth_m],
                    "rgb_colorize": self.rgb_decoder.enabled,
                    "rgb_decoder": self.rgb_decoder.ffmpeg_bin or self.rgb_decoder.disabled_reason,
                },
            )
            self.publisher.publish_json(
                TYPE_MAP_RESET,
                {
                    "schema": "operator.map_reset.v1",
                    "map_id": self.map_id,
                    "map_version": 0,
                    "reason": "new live reconstruction session",
                },
            )
            while not self.stop_event.is_set():
                self._drain_pose_queue()
                self._drain_rgb_queues()
                self._process_one_depth_event(timeout=0.05)
                self._maybe_log_status()
                if time.monotonic() - self._last_publish >= self.publish_interval_s:
                    self._publish_pending_delta()
            self._drain_pose_queue(limit=4096)
            self._drain_rgb_queues(limit=4096)
            self._drain_remaining_depth_events()
            self._publish_pending_delta()
            self._log_status("stopped", force=True)
            self.publisher.publish_json(
                TYPE_ALGORITHM_STATUS,
                {
                    "schema": "operator.algorithm_status.v1",
                    "algorithm": self.plan.demand.algorithm,
                    "state": "stopped",
                    "depth_frames": self.depth_frame_count,
                    "reconstructed_frames": self.reconstructed_frame_count,
                    "skipped_depth_frames": self.skipped_depth_frames,
                    "rgb_packets": self.rgb_packet_count,
                    "rgb_frames_decoded": self.rgb_decoder.decoded_count,
                    "rgb_colored_points": self.rgb_colored_points,
                    "synthetic_colored_points": self.synthetic_colored_points,
                    "color_source": "rgb" if self.rgb_colored_points > 0 else "synthetic_depth",
                    "global_point_count": self.global_point_count,
                    "map_version": self.map_version,
                },
            )
        except Exception as error:
            self.publisher.publish_json(
                TYPE_ALGORITHM_STATUS,
                {
                    "schema": "operator.algorithm_status.v1",
                    "algorithm": self.plan.demand.algorithm,
                    "state": "error",
                    "message": str(error),
                },
            )
            self._log_status("error", force=True, message=str(error))
            raise
        finally:
            self.rgb_decoder.close()
            self._global_file.close()

    def _maybe_log_status(self) -> None:
        now = time.monotonic()
        if now - self._last_status_log < 1.0:
            return
        self._log_status("running", now=now)

    def _log_status(self, state: str, *, now: float | None = None, force: bool = False, message: str = "") -> None:
        now = time.monotonic() if now is None else now
        elapsed = max(0.0, now - self._last_status_log)
        depth_delta = self.depth_frame_count - self._last_status_depth_frames
        reconstructed_delta = self.reconstructed_frame_count - self._last_status_reconstructed_frames
        depth_fps = depth_delta / elapsed if elapsed > 0.0 else 0.0
        reconstructed_fps = reconstructed_delta / elapsed if elapsed > 0.0 else 0.0
        queue_summary = (
            f"queues depth={self.queues.depth.qsize()} rgb={self.queues.rgb_packet.qsize()} "
            f"pose={self.queues.head_pose.qsize()}"
        )
        drop_summary = (
            f"drops depth={self.queues.depth.dropped} rgb={self.queues.rgb_packet.dropped} "
            f"pose={self.queues.head_pose.dropped}"
        )
        parts = [
            f"algorithm status state={state}",
            f"map={self.map_id}",
            f"depth_frames={self.depth_frame_count}",
            f"reconstructed={self.reconstructed_frame_count}",
            f"skipped={self.skipped_depth_frames}",
            f"depth_fps={depth_fps:.1f}",
            f"reconstruct_fps={reconstructed_fps:.1f}",
            f"global_points={self.global_point_count}",
            f"pending_points={self.pending_point_count}",
            f"map_version={self.map_version}",
            f"rgb_packets={self.rgb_packet_count}",
            f"rgb_decoded={self.rgb_decoder.decoded_count}",
            f"rgb_colored={self.rgb_colored_points}",
            f"synthetic_colored={self.synthetic_colored_points}",
            queue_summary,
            drop_summary,
        ]
        if self.rgb_decoder.disabled_reason:
            parts.append(f"rgb_decoder_status={self.rgb_decoder.disabled_reason}")
        if message:
            parts.append(f"message={message}")
        print(" ".join(parts), flush=True)
        if force or elapsed >= 1.0:
            self._last_status_log = now
            self._last_status_depth_frames = self.depth_frame_count
            self._last_status_reconstructed_frames = self.reconstructed_frame_count

    def _drain_pose_queue(self, limit: int = 512) -> None:
        for _ in range(limit):
            try:
                event = self.queues.head_pose.get_nowait()
            except queue.Empty:
                return
            sample = parse_pose_sample(event)
            if sample is not None and sample.tracking_valid:
                self.poses.append(sample)

    def _drain_rgb_queues(self, limit: int = 512) -> None:
        for _ in range(limit):
            try:
                event = self.queues.rgb_csd.get_nowait()
            except queue.Empty:
                break
            try:
                self.rgb_config = event.payload_json()
                self.rgb_decoder.configure(self.rgb_config)
            except Exception:
                self.rgb_config = {}
        for _ in range(limit):
            try:
                event = self.queues.rgb_packet.get_nowait()
            except queue.Empty:
                return
            self.rgb_packet_count += 1
            self.rgb_decoder.submit_packet(event)

    def _process_one_depth_event(self, timeout: float) -> None:
        try:
            event = self.queues.depth.get(timeout=timeout)
        except queue.Empty:
            return
        self._handle_depth_event(event)

    def _drain_remaining_depth_events(self) -> None:
        while True:
            try:
                event = self.queues.depth.get_nowait()
            except queue.Empty:
                return
            self._handle_depth_event(event)

    def _handle_depth_event(self, event: StreamEvent) -> None:
        if event.frame_type == TYPE_DEPTH_METADATA:
            try:
                payload = event.payload_json()
            except Exception:
                return
            self.latest_depth_model = depth_model_from_metadata(payload, self.latest_depth_model)
            return
        if event.frame_type != TYPE_DEPTH_FRAME:
            return
        self.depth_frame_count += 1
        metadata: dict[str, Any] = {}
        depth_bytes = event.payload
        if event.flags & FLAG_COMPOSITE_JSON:
            try:
                metadata, depth_bytes = parse_composite_payload(event.payload)
            except Exception as error:
                self.skipped_depth_frames += 1
                self._publish_skip_status(event.pts_ns, f"bad composite depth payload: {error}")
                return
        model = depth_model_from_metadata(metadata, self.latest_depth_model)
        if model is not None:
            self.latest_depth_model = model
        if model is None or not model.has_projection():
            self.skipped_depth_frames += 1
            self._publish_skip_status(event.pts_ns, "missing depth projection metadata")
            return
        world_from_depth_eye = self._resolve_world_from_depth_eye(model, event.pts_ns)
        added = self._append_depth_points(event, metadata, depth_bytes, model, world_from_depth_eye)
        if added > 0:
            self.reconstructed_frame_count += 1
        else:
            self.skipped_depth_frames += 1

    def _resolve_world_from_depth_eye(self, model: DepthCameraModel, pts_ns: int) -> Transform:
        depth_eye_transform = model.depth_eye_to_local or identity_transform()
        if model.depth_eye_transform_is_absolute:
            return depth_eye_transform
        pose = self._nearest_pose(pts_ns)
        if pose is None:
            return depth_eye_transform
        return compose_transform(pose.transform, depth_eye_transform)

    def _nearest_pose(self, pts_ns: int) -> PoseSample | None:
        if not self.poses:
            return None
        best = min(self.poses, key=lambda pose: abs(pose.pts_ns - pts_ns))
        if abs(best.pts_ns - pts_ns) > 500_000_000:
            return None
        return best

    def _append_depth_points(
        self,
        event: StreamEvent,
        metadata: dict[str, Any],
        depth_bytes: bytes,
        model: DepthCameraModel,
        world_from_depth_eye: Transform,
    ) -> int:
        width = int(model.width)
        height = int(model.height)
        expected = width * height * 2
        if width <= 0 or height <= 0 or len(depth_bytes) < expected:
            self._publish_skip_status(event.pts_ns, f"depth payload too short: {len(depth_bytes)} < {expected}")
            return 0
        frame_index = self.depth_frame_count
        rgb_frame = self.rgb_decoder.nearest_frame(event.pts_ns)
        pose = self._nearest_pose(event.pts_ns)
        added = 0
        for y in range(0, height, self.point_stride):
            for x in range(0, width, self.point_stride):
                if self.pending_point_count >= self.max_points_per_update:
                    return added
                offset = (y * width + x) * 2
                depth_mm = struct.unpack_from("<H", depth_bytes, offset)[0]
                if depth_mm <= 0:
                    continue
                z_m = depth_mm / 1000.0
                if z_m < self.min_depth_m or z_m > self.max_depth_m:
                    continue
                point_depth_eye = self._unproject(model, x + 0.5, y + 0.5, z_m)
                if point_depth_eye is None:
                    return added
                point_world = apply_transform(world_from_depth_eye, point_depth_eye)
                if not all(math.isfinite(value) for value in point_world):
                    continue
                r, g, b = self._point_color(
                    frame_index,
                    z_m,
                    x + 0.5,
                    y + 0.5,
                    model,
                    point_world,
                    rgb_frame,
                    pose,
                )
                packed = DENSE_POINT.pack(point_world[0], point_world[1], point_world[2], r, g, b, 255, 1.0)
                self.pending_points.extend(packed)
                self._global_file.write(packed)
                self.pending_point_count += 1
                self.global_point_count += 1
                added += 1
        if added:
            self._global_file.flush()
        return added

    def _unproject(
        self,
        model: DepthCameraModel,
        pixel_x: float,
        pixel_y: float,
        depth_m: float,
    ) -> tuple[float, float, float] | None:
        if None not in (model.fx, model.fy, model.cx, model.cy):
            assert model.fx is not None and model.fy is not None and model.cx is not None and model.cy is not None
            if abs(model.fx) < 1e-6 or abs(model.fy) < 1e-6:
                return None
            x = (pixel_x - model.cx) / model.fx * depth_m
            y = -(pixel_y - model.cy) / model.fy * depth_m
            return (x, y, -depth_m)
        if None not in (model.fov_left, model.fov_right, model.fov_top, model.fov_bottom):
            assert model.fov_left is not None
            assert model.fov_right is not None
            assert model.fov_top is not None
            assert model.fov_bottom is not None
            nx = pixel_x / float(model.width)
            ny = pixel_y / float(model.height)
            x = (-model.fov_left + nx * (model.fov_left + model.fov_right)) * depth_m
            y = (model.fov_top - ny * (model.fov_top + model.fov_bottom)) * depth_m
            return (x, y, -depth_m)
        return None

    def _point_color(
        self,
        frame_index: int,
        depth_m: float,
        depth_pixel_x: float,
        depth_pixel_y: float,
        depth_model: DepthCameraModel,
        point_world: tuple[float, float, float],
        rgb_frame: RgbFrame | None,
        pose: PoseSample | None,
    ) -> tuple[int, int, int]:
        rgb = self._sample_rgb_color(rgb_frame, pose, point_world, depth_pixel_x, depth_pixel_y, depth_model)
        if rgb is not None:
            self.rgb_colored_points += 1
            return rgb
        self.synthetic_colored_points += 1
        return self._synthetic_point_color(frame_index, depth_m)

    def _sample_rgb_color(
        self,
        frame: RgbFrame | None,
        pose: PoseSample | None,
        point_world: tuple[float, float, float],
        depth_pixel_x: float,
        depth_pixel_y: float,
        depth_model: DepthCameraModel,
    ) -> tuple[int, int, int] | None:
        if frame is None or not frame.data:
            return None
        if pose is not None:
            for camera in frame.cameras:
                sampled = self._sample_rgb_projected(frame, camera, pose, point_world)
                if sampled is not None:
                    return sampled
        return self._sample_rgb_by_depth_pixel(frame, depth_pixel_x, depth_pixel_y, depth_model)

    def _sample_rgb_projected(
        self,
        frame: RgbFrame,
        camera: RgbCameraModel,
        pose: PoseSample,
        point_world: tuple[float, float, float],
    ) -> tuple[int, int, int] | None:
        if camera.local_from_camera is None:
            return None
        world_from_camera = compose_transform(pose.transform, camera.local_from_camera)
        camera_from_world = invert_transform(world_from_camera)
        px, py, pz = apply_transform(camera_from_world, point_world)
        forward_m = -pz
        if forward_m <= 0.03:
            return None
        u = camera.fx * px / forward_m + camera.cx
        v = -camera.fy * py / forward_m + camera.cy
        if u < 0.0 or v < 0.0 or u >= camera.width or v >= camera.height:
            return None
        return self._sample_rgb_pixel(frame, camera.index, int(u), int(v))

    def _sample_rgb_by_depth_pixel(
        self,
        frame: RgbFrame,
        depth_pixel_x: float,
        depth_pixel_y: float,
        depth_model: DepthCameraModel,
    ) -> tuple[int, int, int] | None:
        camera = frame.cameras[0] if frame.cameras else RgbCameraModel(0, frame.width, frame.height, 1.0, 1.0, 0.0, 0.0)
        u = int(depth_pixel_x / max(1.0, float(depth_model.width)) * camera.width)
        v = int(depth_pixel_y / max(1.0, float(depth_model.height)) * camera.height)
        return self._sample_rgb_pixel(frame, camera.index, u, v)

    def _sample_rgb_pixel(self, frame: RgbFrame, camera_index: int, x: int, y: int) -> tuple[int, int, int] | None:
        if frame.width <= 0 or frame.height <= 0:
            return None
        camera_offsets = self._camera_x_offsets(frame)
        camera = frame.cameras[camera_index] if 0 <= camera_index < len(frame.cameras) else None
        camera_width = camera.width if camera is not None else frame.width
        camera_height = camera.height if camera is not None else frame.height
        if x < 0 or y < 0 or x >= camera_width or y >= camera_height:
            return None
        sample_x = camera_offsets.get(camera_index, 0) + x
        sample_y = y
        if sample_x < 0 or sample_y < 0 or sample_x >= frame.width or sample_y >= frame.height:
            return None
        offset = (sample_y * frame.width + sample_x) * 3
        if offset + 2 >= len(frame.data):
            return None
        return (frame.data[offset], frame.data[offset + 1], frame.data[offset + 2])

    def _camera_x_offsets(self, frame: RgbFrame) -> dict[int, int]:
        if not frame.cameras:
            return {0: 0}
        if frame.stereo_layout != "side_by_side":
            return {camera.index: 0 for camera in frame.cameras}
        offsets: dict[int, int] = {}
        x = 0
        for camera in frame.cameras:
            offsets[camera.index] = x
            x += camera.width
        return offsets

    def _synthetic_point_color(self, frame_index: int, depth_m: float) -> tuple[int, int, int]:
        depth_alpha = min(1.0, max(0.0, (depth_m - self.min_depth_m) / (self.max_depth_m - self.min_depth_m)))
        r = int(60 + 140 * (1.0 - depth_alpha))
        g = int(90 + (frame_index * 17) % 120)
        b = int(80 + 160 * depth_alpha)
        return (max(0, min(255, r)), max(0, min(255, g)), max(0, min(255, b)))

    def _publish_pending_delta(self) -> None:
        self._last_publish = time.monotonic()
        if self.pending_point_count <= 0:
            return
        self.map_version += 1
        self.submap_id += 1
        chunk_id = f"global_delta_{self.map_version:06d}"
        metadata = {
            "schema": "operator.dense_map_chunk.v1",
            "map_id": self.map_id,
            "map_version": self.map_version,
            "submap_id": self.submap_id,
            "chunk_id": chunk_id,
            "operation": "upsert",
            "coordinate_frame": "map",
            "T_openxr_map": identity_matrix(),
            "point_format": "f32xyz_u8rgba_f32conf",
            "encoding": "f32xyz_u8rgba_f32conf",
            "point_stride_bytes": DENSE_POINT.size,
            "point_count": self.pending_point_count,
            "global_point_count": self.global_point_count,
            "color_source": "rgb" if self.rgb_colored_points > 0 else "synthetic_depth",
            "rgb_frames_decoded": self.rgb_decoder.decoded_count,
            "delta": True,
        }
        points = bytes(self.pending_points)
        pts_ns = time.monotonic_ns()
        self.publisher.publish_json(
            TYPE_ALGORITHM_STATUS,
            {
                "schema": "operator.algorithm_status.v1",
                "algorithm": self.plan.demand.algorithm,
                "state": "pointcloud_delta_ready",
                "map_version": self.map_version,
                "chunk_id": chunk_id,
                "point_count": self.pending_point_count,
                "global_point_count": self.global_point_count,
                "color_source": "rgb" if self.rgb_colored_points > 0 else "synthetic_depth",
                "rgb_colored_points": self.rgb_colored_points,
                "synthetic_colored_points": self.synthetic_colored_points,
                "rgb_frames_decoded": self.rgb_decoder.decoded_count,
            },
            pts_ns=pts_ns,
        )
        self.publisher.publish_dense_chunk(metadata, points, pts_ns=pts_ns)
        self._publish_trajectory(pts_ns)
        self.pending_points = bytearray()
        self.pending_point_count = 0

    def _publish_trajectory(self, pts_ns: int) -> None:
        poses = list(self.poses)[-60:]
        self.publisher.publish_json(
            TYPE_CAMERA_TRAJECTORY,
            {
                "schema": "operator.camera_trajectory.v1",
                "map_id": self.map_id,
                "map_version": self.map_version,
                "coordinate_frame": "map",
                "poses": [
                    {
                        "frame_id": index,
                        "pts_ns": pose.pts_ns,
                        "T_map_camera": transform_to_matrix(pose.transform),
                    }
                    for index, pose in enumerate(poses)
                ],
            },
            pts_ns=pts_ns,
        )
        self.publisher.publish_json(
            TYPE_MAP_TRANSFORM,
            {
                "schema": "operator.map_transform.v1",
                "map_id": self.map_id,
                "map_version": self.map_version,
                "T_openxr_map": identity_matrix(),
            },
            pts_ns=pts_ns,
        )

    def _publish_skip_status(self, pts_ns: int, reason: str) -> None:
        if self.skipped_depth_frames <= 5 or self.skipped_depth_frames % 30 == 0:
            self.publisher.publish_json(
                TYPE_ALGORITHM_STATUS,
                {
                    "schema": "operator.algorithm_status.v1",
                    "algorithm": self.plan.demand.algorithm,
                    "state": "depth_frame_skipped",
                    "reason": reason,
                    "skipped_depth_frames": self.skipped_depth_frames,
                },
                pts_ns=pts_ns,
            )


class LiveFeedServer:
    def __init__(
        self,
        host: str,
        port: int,
        result_host: str,
        result_port: int,
        out_dir: Path,
        plan: CapturePlan,
        max_queue: int,
        auth_token: str,
        send_capture_request_to_xr: bool,
        send_results_to_xr: bool,
        max_events: int | None,
        publish_interval_s: float,
        point_stride: int,
        min_depth_m: float,
        max_depth_m: float,
        max_points_per_update: int,
        result_fragment_bytes: int,
        rgb_colorize: bool,
        ffmpeg_bin: str,
    ) -> None:
        self.host = host
        self.port = port
        self.result_host = result_host
        self.result_port = result_port
        self.out_dir = out_dir
        self.plan = plan
        self.max_queue = max_queue
        self.auth_token = auth_token
        self.send_capture_request_to_xr = send_capture_request_to_xr
        self.send_results_to_xr = send_results_to_xr
        self.max_events = max_events
        self.publish_interval_s = publish_interval_s
        self.point_stride = point_stride
        self.min_depth_m = min_depth_m
        self.max_depth_m = max_depth_m
        self.max_points_per_update = max_points_per_update
        self.result_fragment_bytes = result_fragment_bytes
        self.rgb_colorize = rgb_colorize
        self.ffmpeg_bin = ffmpeg_bin
        self.result_channel = ResultChannel(result_host, result_port, send_results_to_xr)

    def serve_forever(self) -> None:
        self.out_dir.mkdir(parents=True, exist_ok=True)
        self.result_channel.start()
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as server:
                server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                server.bind((self.host, self.port))
                server.listen(1)
                print(f"push listening on {self.host}:{self.port}", flush=True)
                while True:
                    conn, peer = server.accept()
                    with conn:
                        conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                        print(f"push accepted {peer[0]}:{peer[1]}", flush=True)
                        try:
                            self._handle_connection(conn, peer)
                        except Exception as error:
                            print(f"connection failed: {error}", file=sys.stderr, flush=True)
        finally:
            self.result_channel.close()

    def _handle_connection(self, conn: socket.socket, peer: tuple[str, int]) -> None:
        queues = SessionQueues.create(self.max_queue)
        session_dir = self._make_session_dir(peer)
        session_dir.mkdir(parents=True, exist_ok=False)
        (session_dir / "depth").mkdir()
        capture_plan = {
            "capabilities": to_plain(self.plan.capabilities),
            "demand": to_plain(self.plan.demand),
            "selected_streams": list(self.plan.selected_streams),
            "result_streams": list(self.plan.result_streams),
            "capture_request": build_capture_request(self.plan),
        }
        (session_dir / "capture_plan.json").write_text(json.dumps(capture_plan, indent=2, sort_keys=True) + "\n")

        stop_event = threading.Event()
        with (session_dir / "events.ndjson").open("a", encoding="utf-8") as events_log, (
            session_dir / "rgb.h265"
        ).open("ab") as rgb_stream:
            publisher = ResultPublisher(
                session_dir,
                queues,
                self.result_channel.send_frame,
                max_fragment_bytes=self.result_fragment_bytes,
            )
            worker = DepthFusionPointCloudWorker(
                self.plan,
                queues,
                publisher,
                stop_event,
                map_id=session_dir.name,
                publish_interval_s=self.publish_interval_s,
                point_stride=self.point_stride,
                min_depth_m=self.min_depth_m,
                max_depth_m=self.max_depth_m,
                max_points_per_update=self.max_points_per_update,
                rgb_colorize=self.rgb_colorize,
                ffmpeg_bin=self.ffmpeg_bin,
            )
            worker.start()
            try:
                if self.send_capture_request_to_xr:
                    self._send_control_json(conn, TYPE_CAPTURE_REQUEST, build_capture_request(self.plan))
                self._read_loop(conn, session_dir, events_log, rgb_stream, queues)
            finally:
                stop_event.set()
                worker.join(timeout=2.0)
                publisher.close()
        print(f"session saved to {session_dir}", flush=True)

    def _read_loop(
        self,
        conn: socket.socket,
        session_dir: Path,
        events_log: Any,
        rgb_stream: BinaryIO,
        queues: SessionQueues,
    ) -> None:
        count = 0
        saw_session_start = False
        while True:
            try:
                event = read_frame(conn)
            except EOFError as error:
                print(f"push closed: {error}", flush=True)
                break
            if event is None:
                break
            count += 1
            if not saw_session_start:
                if event.frame_type != TYPE_SESSION_START:
                    raise ValueError(f"first OLCP frame must be session_start, got type={event.frame_type}")
                saw_session_start = True
            self._route_frame(event, session_dir, events_log, rgb_stream, queues)
            if event.frame_type == TYPE_SESSION_END:
                break
            if self.max_events is not None and count >= self.max_events:
                print(f"max events reached: {self.max_events}", flush=True)
                break

    def _route_frame(
        self,
        event: StreamEvent,
        session_dir: Path,
        events_log: Any,
        rgb_stream: BinaryIO,
        queues: SessionQueues,
    ) -> None:
        log_payload: Any
        if event.frame_type in JSON_FRAME_TYPES:
            log_payload = event.payload_json()
            if event.frame_type == TYPE_RGB_CSD:
                csd_base64 = str(log_payload.get("csd_base64", ""))
                if csd_base64:
                    rgb_stream.write(base64.b64decode(csd_base64))
                    rgb_stream.flush()
        elif event.frame_type == TYPE_DEPTH_FRAME and (event.flags & FLAG_COMPOSITE_JSON):
            metadata, depth_bytes = parse_composite_payload(event.payload)
            depth_name = f"depth_{event.pts_ns:020d}.u16"
            (session_dir / "depth" / depth_name).write_bytes(depth_bytes)
            log_payload = {
                "metadata": metadata,
                "binary_uri": f"depth/{depth_name}",
                "binary_size": len(depth_bytes),
            }
        else:
            log_payload = {
                "binary_size": len(event.payload),
            }

        if event.frame_type == TYPE_RGB_PACKET:
            rgb_stream.write(event.payload)
            rgb_stream.flush()

        record = {
            "recv_monotonic_ns": event.recv_monotonic_ns,
            "frame_type": event.frame_type,
            "flags": event.flags,
            "pts_ns": event.pts_ns,
            "duration_ns": event.duration_ns,
            "payload": log_payload,
        }
        events_log.write(json.dumps(record, sort_keys=True) + "\n")
        events_log.flush()

        if event.frame_type in (TYPE_SESSION_START, TYPE_SESSION_END):
            queues.session.put_drop_oldest(event)
            self._validate_session_start(event)
        elif event.frame_type == TYPE_RGB_CSD:
            queues.rgb_csd.put_drop_oldest(event)
        elif event.frame_type == TYPE_RGB_PACKET:
            queues.rgb_packet.put_drop_oldest(event)
        elif event.frame_type in (TYPE_DEPTH_METADATA, TYPE_DEPTH_FRAME):
            queues.depth.put_drop_oldest(event)
        elif event.frame_type == TYPE_HEAD_POSE:
            queues.head_pose.put_drop_oldest(event)
        elif event.frame_type in (TYPE_CONTROLLER_POSE, TYPE_CONTROLLER_INPUT):
            queues.controller.put_drop_oldest(event)
        elif event.frame_type == TYPE_HAND_JOINTS:
            queues.hands.put_drop_oldest(event)

    def _validate_session_start(self, event: StreamEvent) -> None:
        if event.frame_type != TYPE_SESSION_START:
            return
        payload = event.payload_json()
        protocol = str(payload.get("protocol", "operator.live_feed.v1"))
        if not protocol.startswith(ACCEPTED_SESSION_PROTOCOL_PREFIXES):
            raise ValueError(f"unsupported session protocol: {protocol}")
        if self.auth_token and payload.get("auth_token") != self.auth_token:
            raise PermissionError("session auth token mismatch")

    def _send_control_json(self, conn: socket.socket, frame_type: int, value: dict[str, Any]) -> None:
        payload = encode_json(value)
        conn.sendall(pack_frame(frame_type, 0, 0, 0, payload))

    def _make_session_dir(self, peer: tuple[str, int]) -> Path:
        timestamp = time.strftime("%Y%m%d_%H%M%S")
        safe_peer = f"{peer[0].replace('.', '_')}_{peer[1]}"
        return self.out_dir / f"session_{timestamp}_{safe_peer}_{time.monotonic_ns()}"


def get_demand(name: str) -> AlgorithmDemand:
    if name in ("depth_fusion_pointcloud", "depth_fusion"):
        return DEPTH_FUSION_DEMAND
    if name == "vggt_slam2":
        raise ValueError(
            "vggt_slam2 is not implemented by this dependency-free demo; "
            "use --algorithm depth_fusion_pointcloud or replace DepthFusionPointCloudWorker"
        )
    raise ValueError(f"unknown algorithm: {name}")


def run_self_test() -> None:
    plan = validate_demand(QUEST_CAPTURE_PROFILE, DEPTH_FUSION_DEMAND)
    request = build_capture_request(plan)
    assert request["selected_streams"] == ["session.json", "depth.u16", "head_pose.json"]

    payload = encode_json({"session_id": "test", "auth_token": "secret"})
    frame_bytes = pack_frame(TYPE_SESSION_START, 0, 123, 0, payload)
    event = read_frame(io.BytesIO(frame_bytes))
    assert event is not None
    assert event.frame_type == TYPE_SESSION_START
    assert event.payload_json()["session_id"] == "test"

    metadata, points = make_dense_point_payload("map", 1, 1, (1, 17), point_count=8)
    composite = pack_composite_payload(metadata, points)
    parsed_metadata, parsed_points = parse_composite_payload(composite)
    assert parsed_metadata["point_count"] == 8
    assert parsed_points == points
    assert len(points) == 8 * DENSE_POINT.size

    depth_model = depth_model_from_metadata(
        {"width": 2, "height": 2, "fov_left": 1.0, "fov_right": 1.0, "fov_top": 1.0, "fov_bottom": 1.0}
    )
    assert depth_model is not None and depth_model.has_projection()
    pose = parse_pose_sample(
        StreamEvent(
            TYPE_HEAD_POSE,
            0,
            100,
            0,
            encode_json(
                {
                    "position": {"x": 1.0, "y": 2.0, "z": 3.0},
                    "rotation": {"x": 0.0, "y": 0.0, "z": 0.0, "w": 1.0},
                    "tracking_valid": True,
                }
            ),
        )
    )
    assert pose is not None
    assert apply_transform(pose.transform, (0.0, 0.0, -1.0)) == (1.0, 2.0, 2.0)
    rgb_cameras = rgb_cameras_from_config(
        {
            "width": 4,
            "height": 2,
            "stereo_layout": "mono",
            "cameras": [
                {
                    "width": 4,
                    "height": 2,
                    "fx": 2.0,
                    "fy": 2.0,
                    "cx": 2.0,
                    "cy": 1.0,
                    "extrinsics_3x4": [
                        1.0, 0.0, 0.0, 0.0,
                        0.0, 1.0, 0.0, 0.0,
                        0.0, 0.0, 1.0, 0.0,
                    ],
                }
            ],
        }
    )
    assert len(rgb_cameras) == 1
    with tempfile.TemporaryDirectory() as temp_dir:
        sent: list[tuple[int, int, int, int, bytes]] = []
        publisher = ResultPublisher(
            Path(temp_dir),
            SessionQueues.create(8),
            lambda frame_type, flags, pts_ns, duration_ns, payload: sent.append(
                (frame_type, flags, pts_ns, duration_ns, payload)
            ),
        )
        publisher.publish_dense_chunk(metadata, points, pts_ns=456)
        publisher.close()
        assert [frame[0] for frame in sent] == [
            TYPE_DENSE_MAP_MANIFEST,
            TYPE_DENSE_MAP_FRAGMENT,
            TYPE_DENSE_MAP_COMMIT,
        ]
        assert sent[1][1] == FLAG_COMPOSITE_JSON
    with tempfile.TemporaryDirectory() as temp_dir:
        publisher = ResultPublisher(Path(temp_dir), SessionQueues.create(8), lambda *_args: None)
        worker = DepthFusionPointCloudWorker(
            plan,
            SessionQueues.create(8),
            publisher,
            threading.Event(),
            "test_map",
            publish_interval_s=1.0,
            point_stride=1,
            min_depth_m=0.1,
            max_depth_m=5.0,
            max_points_per_update=16,
            rgb_colorize=False,
            ffmpeg_bin="ffmpeg",
        )
        rgb_data = bytes([
            1, 2, 3,     4, 5, 6,     7, 8, 9,     10, 11, 12,
            13, 14, 15,  16, 17, 18,  19, 20, 21,  22, 23, 24,
        ])
        frame = RgbFrame(pts_ns=100, width=4, height=2, stereo_layout="mono", cameras=rgb_cameras, data=rgb_data)
        sampled = worker._sample_rgb_projected(frame, rgb_cameras[0], pose, (1.0, 2.0, 2.0))
        assert sampled == (19, 20, 21)
        worker.rgb_decoder.close()
        worker._global_file.close()
        publisher.close()
    print("self-test ok")


def print_plan(plan: CapturePlan) -> None:
    print(json.dumps(build_capture_request(plan), indent=2, sort_keys=True))


def parse_args(argv: Iterable[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", "--push-port", dest="port", type=int, default=63910)
    parser.add_argument("--result-host", "--pull-host", dest="result_host", default="")
    parser.add_argument("--result-port", "--pull-port", dest="result_port", type=int, default=63912)
    parser.add_argument("--out", type=Path, default=Path("live_feed_out"))
    parser.add_argument("--algorithm", default="depth_fusion_pointcloud")
    parser.add_argument("--max-queue", type=int, default=256)
    parser.add_argument("--auth-token", default="")
    parser.add_argument("--max-events", type=int)
    parser.add_argument("--publish-interval-s", type=float, default=1.0)
    parser.add_argument("--point-stride", type=int, default=4)
    parser.add_argument("--min-depth-m", type=float, default=0.20)
    parser.add_argument("--max-depth-m", type=float, default=5.0)
    parser.add_argument("--max-points-per-update", type=int, default=80_000)
    parser.add_argument("--result-fragment-bytes", type=int, default=1024 * 1024)
    parser.add_argument("--rgb-colorize", dest="rgb_colorize", action="store_true", default=True)
    parser.add_argument("--no-rgb-colorize", dest="rgb_colorize", action="store_false")
    parser.add_argument("--ffmpeg-bin", default="ffmpeg")
    parser.add_argument("--send-capture-request-to-xr", action="store_true")
    parser.add_argument("--send-results-to-xr", dest="send_results_to_xr", action="store_true", default=True)
    parser.add_argument("--no-send-results-to-xr", dest="send_results_to_xr", action="store_false")
    parser.add_argument("--print-plan", action="store_true")
    parser.add_argument("--self-test", action="store_true")
    return parser.parse_args(list(argv))


def main(argv: Iterable[str]) -> int:
    args = parse_args(argv)
    if args.self_test:
        run_self_test()
        return 0

    demand = get_demand(args.algorithm)
    plan = validate_demand(QUEST_CAPTURE_PROFILE, demand)
    if args.print_plan:
        print_plan(plan)
        return 0

    server = LiveFeedServer(
        host=args.host,
        port=args.port,
        result_host=args.result_host or args.host,
        result_port=args.result_port,
        out_dir=args.out,
        plan=plan,
        max_queue=args.max_queue,
        auth_token=args.auth_token,
        send_capture_request_to_xr=args.send_capture_request_to_xr,
        send_results_to_xr=args.send_results_to_xr,
        max_events=args.max_events,
        publish_interval_s=args.publish_interval_s,
        point_stride=args.point_stride,
        min_depth_m=args.min_depth_m,
        max_depth_m=args.max_depth_m,
        max_points_per_update=args.max_points_per_update,
        result_fragment_bytes=args.result_fragment_bytes,
        rgb_colorize=args.rgb_colorize,
        ffmpeg_bin=args.ffmpeg_bin,
    )
    server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
