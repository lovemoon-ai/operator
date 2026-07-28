"""OLCP Live Feed server and depth-fusion reference worker."""

from __future__ import annotations

import base64
import collections
import io
import json
import math
import queue
import socket
import struct
import sys
import tempfile
import threading
import time
from pathlib import Path
from typing import Any, BinaryIO

from . import qr
from .decoders import RgbHevcDecoder
from .models import (
    DepthCameraModel,
    PoseSample,
    RgbCameraModel,
    RgbFrame,
    Transform,
    apply_transform,
    compose_transform,
    depth_model_from_metadata,
    identity_matrix,
    identity_transform,
    invert_transform,
    parse_pose_sample,
    rgb_cameras_from_config,
    transform_to_matrix,
)
from .protocol import (
    ACCEPTED_SESSION_PROTOCOL_PREFIXES,
    DENSE_POINT,
    DEPTH_FUSION_DEMAND,
    FLAG_COMPOSITE_JSON,
    JSON_FRAME_TYPES,
    QUEST_CAPTURE_PROFILE,
    TYPE_ALGORITHM_STATUS,
    TYPE_CAMERA_TRAJECTORY,
    TYPE_CAPTURE_REQUEST,
    TYPE_CONTROLLER_INPUT,
    TYPE_CONTROLLER_POSE,
    TYPE_DENSE_MAP_COMMIT,
    TYPE_DENSE_MAP_FRAGMENT,
    TYPE_DENSE_MAP_MANIFEST,
    TYPE_DEPTH_FRAME,
    TYPE_DEPTH_METADATA,
    TYPE_HAND_JOINTS,
    TYPE_HEAD_POSE,
    TYPE_MAP_RESET,
    TYPE_MAP_TRANSFORM,
    TYPE_RGB_CSD,
    TYPE_RGB_PACKET,
    TYPE_SESSION_END,
    TYPE_SESSION_START,
    CapturePlan,
    StreamEvent,
    build_capture_request,
    capabilities_from_session_start,
    decode_depth_frame_payload,
    decode_transport_payload,
    encode_json,
    pack_composite_payload,
    pack_frame,
    parse_composite_payload,
    read_frame,
    to_plain,
    validate_demand,
)
from .results import ResultChannel, ResultPublisher, make_dense_point_payload
from .runtime import DroppingQueue, SessionQueues

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
        if publisher.results_dir is None:
            raise ValueError("DepthFusionPointCloudWorker needs a ResultPublisher with a session_dir")
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
        expected_size = model.width * model.height * 2
        try:
            depth_bytes = decode_transport_payload(
                depth_bytes,
                event.flags,
                expected_size=expected_size,
            )
        except ValueError as error:
            self.skipped_depth_frames += 1
            self._publish_skip_status(event.pts_ns, f"bad compressed depth payload: {error}")
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
        return model.unproject(pixel_x, pixel_y, depth_m)

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
        show_connection_banner: bool = True,
        show_qr: bool = True,
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
        self.show_connection_banner = show_connection_banner
        self.show_qr = show_qr
        self.accept_result_connections = (
            send_capture_request_to_xr or send_results_to_xr
        )
        #: Plan resolved against the connected headset's real capabilities.
        #: None until a session_start has been negotiated.
        self.negotiated_plan: CapturePlan | None = None
        self._publisher_lock = threading.Lock()
        self._active_publisher: ResultPublisher | None = None
        self.result_channel = ResultChannel(
            result_host,
            result_port,
            self.accept_result_connections,
            auth_token=auth_token,
            # The headset's settings page connects here before any capture
            # starts, so this is the moment to tell it what to send.
            on_client_connected=self._on_result_client_connected,
        )

    def serve_forever(self) -> None:
        self.out_dir.mkdir(parents=True, exist_ok=True)
        self.result_channel.start()
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as server:
                server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                server.bind((self.host, self.port))
                server.listen(1)
                print(f"push listening on {self.host}:{self.port}", flush=True)
                if self.show_connection_banner:
                    # Announce from inside the server so every entry point gets
                    # it without having to remember to print it. Keep it as the
                    # final startup output so short terminals retain the QR's
                    # complete quiet zone.
                    self.result_channel.wait_bound(2.0)
                    qr.print_connection_banner(
                        self.host,
                        self.port,
                        (
                            self.result_channel.port
                            if self.accept_result_connections
                            else None
                        ),
                        self.auth_token,
                        show_qr=self.show_qr,
                    )
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
                self._send_result_frame,
                session_dir=session_dir,
                event_sink=queues.result.put_drop_oldest,
                max_fragment_bytes=self.result_fragment_bytes,
            )
            with self._publisher_lock:
                self._active_publisher = publisher
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
                # capture_request is sent from _route_frame once session_start
                # arrives: only then do we know the headset's real capabilities.
                self._read_loop(conn, session_dir, events_log, rgb_stream, queues)
            finally:
                stop_event.set()
                worker.join(timeout=2.0)
                with self._publisher_lock:
                    if self._active_publisher is publisher:
                        self._active_publisher = None
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
                self._negotiate_capture(conn, event, session_dir)
                continue
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
            try:
                metadata, depth_bytes = decode_depth_frame_payload(event)
                depth_name = f"depth_{event.pts_ns:020d}.u16"
                (session_dir / "depth" / depth_name).write_bytes(depth_bytes)
                log_payload = {
                    "metadata": metadata,
                    "binary_uri": f"depth/{depth_name}",
                    "binary_size": len(depth_bytes),
                    "wire_size": len(event.payload),
                }
            except Exception as error:
                log_payload = {
                    "binary_size": len(event.payload),
                    "decode_error": str(error),
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

    def _announce_capture_request(self) -> None:
        """Tell a freshly connected XR client which streams this algorithm wants.

        Sent on the result (live-pull) channel rather than the push socket,
        because the headset's settings page opens that connection before any
        capture exists and the push socket is write-only on the device. The
        payload is the algorithm's demand: the headset intersects it with what
        it can actually provide.
        """
        if not self.send_capture_request_to_xr:
            return
        plan = self.negotiated_plan or self.plan
        request = build_capture_request(plan)
        self.result_channel.send_frame(TYPE_CAPTURE_REQUEST, 0, 0, 0, encode_json(request))
        print(f"capture request announced: streams={list(plan.selected_streams)}", flush=True)

    def _on_result_client_connected(self) -> None:
        """Confirm control state, then rebuild the latest result snapshot."""
        self._announce_capture_request()
        if not self.send_results_to_xr:
            return
        with self._publisher_lock:
            publisher = self._active_publisher
        if publisher is None:
            return
        replayed = publisher.replay_snapshot()
        print(f"result snapshot replayed: chunks={replayed}", flush=True)

    def _send_result_frame(
        self,
        frame_type: int,
        flags: int,
        pts_ns: int,
        duration_ns: int,
        payload: bytes,
    ) -> None:
        """Send algorithm output without disabling the shared control listener."""
        if not self.send_results_to_xr:
            return
        self.result_channel.send_frame(
            frame_type,
            flags,
            pts_ns,
            duration_ns,
            payload,
        )

    def _negotiate_capture(self, conn: socket.socket, event: StreamEvent, session_dir: Path) -> None:
        """Plan the capture against the headset's real capabilities and tell it.

        The headset announces what it can supply through the `*_expected` flags
        in `session_start`; the algorithm declares what it needs. Intersecting
        the two here is what makes the captured stream set a server-side
        decision instead of a headset-side setting.
        """
        try:
            info = event.payload_json()
        except Exception as error:
            print(f"capture negotiation skipped, bad session_start: {error}", file=sys.stderr, flush=True)
            return

        capabilities = capabilities_from_session_start(info)
        try:
            plan = validate_demand(capabilities, self.plan.demand)
        except ValueError as error:
            # The headset cannot supply what the algorithm needs. Keep serving
            # (partial data is still worth recording) but make the gap loud.
            print(
                f"capture negotiation failed: {error}; "
                f"headset offers {sorted(capabilities.streams)}",
                file=sys.stderr,
                flush=True,
            )
            return

        self.negotiated_plan = plan
        request = build_capture_request(plan)
        (session_dir / "capture_plan.json").write_text(
            json.dumps(
                {
                    "capabilities": to_plain(plan.capabilities),
                    "demand": to_plain(plan.demand),
                    "selected_streams": list(plan.selected_streams),
                    "result_streams": list(plan.result_streams),
                    "capture_request": request,
                    "negotiated": True,
                },
                indent=2,
                sort_keys=True,
            )
            + "\n"
        )
        print(f"capture negotiated: streams={list(plan.selected_streams)}", flush=True)
        # Re-announce on the result channel: the negotiated plan can be
        # narrower than what was advertised when the settings page connected.
        if self.send_capture_request_to_xr:
            self._announce_capture_request()

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
            lambda frame_type, flags, pts_ns, duration_ns, payload: sent.append(
                (frame_type, flags, pts_ns, duration_ns, payload)
            ),
            session_dir=Path(temp_dir),
            event_sink=SessionQueues.create(8).result.put_drop_oldest,
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
        publisher = ResultPublisher(lambda *_args: None, session_dir=Path(temp_dir))
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
