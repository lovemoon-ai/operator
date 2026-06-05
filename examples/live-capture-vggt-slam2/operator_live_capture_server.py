#!/usr/bin/env python3
from __future__ import annotations

import argparse
import base64
import dataclasses
import io
import json
import queue
import socket
import struct
import sys
import threading
import time
from pathlib import Path
from typing import Any, BinaryIO, Callable, Iterable


MAGIC = b"OLCP"
PROTOCOL_VERSION = 1
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
TYPE_DENSE_POINT_CHUNK = 112
TYPE_CAMERA_TRAJECTORY = 113
TYPE_MAP_TRANSFORM = 114
TYPE_MESH_CHUNK = 115

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
    protocol="operator.live_capture.v1.compat",
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


VGGT_SLAM2_DEMAND = AlgorithmDemand(
    algorithm="vggt_slam2",
    required_streams=("session.json", "rgb.hevc"),
    optional_streams=("head_pose.json", "depth.u16"),
    result_streams=(
        "status.json",
        "dense_map.point_cloud_delta",
        "camera_trajectory.json",
        "map_transform.json",
    ),
    limits={
        "rgb_max_hz": 15,
        "head_pose_max_hz": 30,
        "depth_policy": "nearest_keyframe",
        "submap_size": 16,
        "overlap": 1,
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
        "protocol": "operator.live_capture.v2",
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
        "schema": "operator.dense_point_chunk.v1",
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


class ResultPublisher:
    def __init__(
        self,
        session_dir: Path,
        queues: SessionQueues,
        send_frame: Callable[[int, int, int, int, bytes], None],
    ) -> None:
        self.session_dir = session_dir
        self.queues = queues
        self.send_frame = send_frame
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
        payload = pack_composite_payload(metadata, points)
        event = StreamEvent(TYPE_DENSE_POINT_CHUNK, FLAG_COMPOSITE_JSON, pts_ns, 0, payload)
        self.queues.result.put_drop_oldest(event)
        chunk_path = self.chunk_dir / f"{metadata['chunk_id']}.bin"
        chunk_path.write_bytes(points)
        log_value = dict(metadata)
        log_value["binary_uri"] = str(chunk_path.relative_to(self.session_dir))
        self._write_log(event, log_value)
        self.send_frame(TYPE_DENSE_POINT_CHUNK, FLAG_COMPOSITE_JSON, pts_ns, 0, payload)

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


class MockVggtSlam2Worker(threading.Thread):
    def __init__(
        self,
        plan: CapturePlan,
        queues: SessionQueues,
        publisher: ResultPublisher,
        stop_event: threading.Event,
        map_id: str,
        mock_map_every: int,
    ) -> None:
        super().__init__(name="mock-vggt-slam2", daemon=True)
        self.plan = plan
        self.queues = queues
        self.publisher = publisher
        self.stop_event = stop_event
        self.map_id = map_id
        self.mock_map_every = max(1, mock_map_every)
        self.submap_size = int(plan.demand.limits.get("submap_size", 16))
        self.overlap = int(plan.demand.limits.get("overlap", 1))
        self.frame_counter = 0
        self.map_version = 0
        self.submap_id = 0
        self.keyframes: list[tuple[int, int]] = []

    def run(self) -> None:
        self.publisher.publish_json(
            TYPE_ALGORITHM_STATUS,
            {
                "schema": "operator.algorithm_status.v1",
                "algorithm": self.plan.demand.algorithm,
                "state": "running",
                "message": "mock VGGT-SLAM2 worker started",
            },
        )
        while not self.stop_event.is_set():
            try:
                event = self.queues.rgb_packet.get(timeout=0.2)
            except queue.Empty:
                continue
            self.frame_counter += 1
            is_keyframe = (event.flags & FLAG_KEYFRAME) != 0
            if not is_keyframe and self.frame_counter % self.mock_map_every != 0:
                continue
            self.keyframes.append((self.frame_counter, event.pts_ns))
            if len(self.keyframes) >= self.submap_size + self.overlap:
                self._publish_submap(event.pts_ns)
                keep = max(0, self.overlap)
                self.keyframes = self.keyframes[-keep:] if keep else []
        self.publisher.publish_json(
            TYPE_ALGORITHM_STATUS,
            {
                "schema": "operator.algorithm_status.v1",
                "algorithm": self.plan.demand.algorithm,
                "state": "stopped",
                "frames_seen": self.frame_counter,
                "map_version": self.map_version,
            },
        )

    def _publish_submap(self, pts_ns: int) -> None:
        first_frame = self.keyframes[0][0]
        last_frame = self.keyframes[-1][0]
        self.map_version += 1
        self.submap_id += 1
        self.publisher.publish_json(
            TYPE_ALGORITHM_STATUS,
            {
                "schema": "operator.algorithm_status.v1",
                "algorithm": self.plan.demand.algorithm,
                "state": "submap_ready",
                "submap_id": self.submap_id,
                "map_version": self.map_version,
                "frame_id_range": [first_frame, last_frame],
            },
            pts_ns=pts_ns,
        )
        metadata, points = make_dense_point_payload(
            self.map_id,
            self.map_version,
            self.submap_id,
            (first_frame, last_frame),
        )
        self.publisher.publish_dense_chunk(metadata, points, pts_ns=pts_ns)
        self.publisher.publish_json(
            TYPE_CAMERA_TRAJECTORY,
            {
                "schema": "operator.camera_trajectory.v1",
                "map_id": self.map_id,
                "map_version": self.map_version,
                "coordinate_frame": "map",
                "poses": [
                    {
                        "frame_id": frame_id,
                        "pts_ns": frame_pts_ns,
                        "T_map_camera": identity_matrix(),
                    }
                    for frame_id, frame_pts_ns in self.keyframes
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


class LiveCaptureServer:
    def __init__(
        self,
        host: str,
        port: int,
        out_dir: Path,
        plan: CapturePlan,
        max_queue: int,
        auth_token: str,
        send_capture_request_to_xr: bool,
        send_results_to_xr: bool,
        max_events: int | None,
        mock_map_every: int,
    ) -> None:
        self.host = host
        self.port = port
        self.out_dir = out_dir
        self.plan = plan
        self.max_queue = max_queue
        self.auth_token = auth_token
        self.send_capture_request_to_xr = send_capture_request_to_xr
        self.send_results_to_xr = send_results_to_xr
        self.max_events = max_events
        self.mock_map_every = mock_map_every
        self._send_lock = threading.Lock()

    def serve_forever(self) -> None:
        self.out_dir.mkdir(parents=True, exist_ok=True)
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as server:
            server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            server.bind((self.host, self.port))
            server.listen(1)
            print(f"listening on {self.host}:{self.port}", flush=True)
            while True:
                conn, peer = server.accept()
                with conn:
                    conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                    print(f"accepted {peer[0]}:{peer[1]}", flush=True)
                    try:
                        self._handle_connection(conn, peer)
                    except Exception as error:
                        print(f"connection failed: {error}", file=sys.stderr, flush=True)

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
                lambda frame_type, flags, pts_ns, duration_ns, payload: self._send_result_frame(
                    conn, frame_type, flags, pts_ns, duration_ns, payload
                ),
            )
            worker = MockVggtSlam2Worker(
                self.plan,
                queues,
                publisher,
                stop_event,
                map_id=session_dir.name,
                mock_map_every=self.mock_map_every,
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
        while True:
            event = read_frame(conn)
            if event is None:
                break
            count += 1
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
        if self.auth_token and payload.get("auth_token") != self.auth_token:
            raise PermissionError("session auth token mismatch")

    def _send_result_frame(
        self,
        conn: socket.socket,
        frame_type: int,
        flags: int,
        pts_ns: int,
        duration_ns: int,
        payload: bytes,
    ) -> None:
        if not self.send_results_to_xr:
            return
        with self._send_lock:
            conn.sendall(pack_frame(frame_type, flags, pts_ns, duration_ns, payload))

    def _send_control_json(self, conn: socket.socket, frame_type: int, value: dict[str, Any]) -> None:
        payload = encode_json(value)
        with self._send_lock:
            conn.sendall(pack_frame(frame_type, 0, 0, 0, payload))

    def _make_session_dir(self, peer: tuple[str, int]) -> Path:
        timestamp = time.strftime("%Y%m%d_%H%M%S")
        safe_peer = f"{peer[0].replace('.', '_')}_{peer[1]}"
        return self.out_dir / f"session_{timestamp}_{safe_peer}_{time.monotonic_ns()}"


def get_demand(name: str) -> AlgorithmDemand:
    if name == "vggt_slam2":
        return VGGT_SLAM2_DEMAND
    raise ValueError(f"unknown algorithm: {name}")


def run_self_test() -> None:
    plan = validate_demand(QUEST_CAPTURE_PROFILE, VGGT_SLAM2_DEMAND)
    request = build_capture_request(plan)
    assert request["selected_streams"] == ["session.json", "rgb.hevc", "head_pose.json", "depth.u16"]

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
    print("self-test ok")


def print_plan(plan: CapturePlan) -> None:
    print(json.dumps(build_capture_request(plan), indent=2, sort_keys=True))


def parse_args(argv: Iterable[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=63910)
    parser.add_argument("--out", type=Path, default=Path("live_capture_out"))
    parser.add_argument("--algorithm", default="vggt_slam2")
    parser.add_argument("--max-queue", type=int, default=256)
    parser.add_argument("--auth-token", default="")
    parser.add_argument("--max-events", type=int)
    parser.add_argument("--mock-map-every", type=int, default=30)
    parser.add_argument("--send-capture-request-to-xr", action="store_true")
    parser.add_argument("--send-results-to-xr", action="store_true")
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

    server = LiveCaptureServer(
        host=args.host,
        port=args.port,
        out_dir=args.out,
        plan=plan,
        max_queue=args.max_queue,
        auth_token=args.auth_token,
        send_capture_request_to_xr=args.send_capture_request_to_xr,
        send_results_to_xr=args.send_results_to_xr,
        max_events=args.max_events,
        mock_map_every=args.mock_map_every,
    )
    server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
