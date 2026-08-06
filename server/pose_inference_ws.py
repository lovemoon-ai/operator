#!/usr/bin/env python3
"""Serve Quest pose inference over LAN WebSocket and display its QR config."""

from __future__ import annotations

import argparse
import asyncio
import base64
import io
import json
import os
import secrets
import sys
import time
import threading
from http import HTTPStatus
from pathlib import Path
from typing import Any

try:
    import matplotlib
    matplotlib.use("Agg")
    from matplotlib.backends.backend_agg import FigureCanvasAgg
    from matplotlib.figure import Figure
    from PIL import Image
except ImportError as error:
    raise SystemExit(
        "Matplotlib pose rendering dependencies are missing; "
        "run uv pip install --python server/.venv/bin/python "
        "-r server/requirements-pose-inference.txt"
    ) from error

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from server.pose_inference_protocol import LatestPose, pack_image_frame


MAX_POSE_JSON_BYTES = 256 * 1024
TARGET_HZ = 20.0
FRAME_INTERVAL_SECONDS = 1.0 / TARGET_HZ
STATS_INTERVAL_SECONDS = 1.0

HAND_BONES: tuple[tuple[int, int], ...] = (
    (1, 0),
    (1, 2),
    (2, 3),
    (3, 4),
    (4, 5),
    (0, 6),
    (6, 7),
    (7, 8),
    (8, 9),
    (9, 10),
    (0, 11),
    (11, 12),
    (12, 13),
    (13, 14),
    (14, 15),
    (0, 16),
    (16, 17),
    (17, 18),
    (18, 19),
    (19, 20),
    (0, 21),
    (21, 22),
    (22, 23),
    (23, 24),
    (24, 25),
)

_MATPLOTLIB_RENDER_LOCK = threading.Lock()


def _rotate_vector_by_quaternion(
    quaternion: tuple[float, float, float, float],
    vector: tuple[float, float, float],
) -> tuple[float, float, float]:
    x, y, z, w = quaternion
    vx, vy, vz = vector
    tx = 2.0 * (y * vz - z * vy)
    ty = 2.0 * (z * vx - x * vz)
    tz = 2.0 * (x * vy - y * vx)
    return (
        vx + w * tx + y * tz - z * ty,
        vy + w * ty + z * tx - x * tz,
        vz + w * tz + x * ty - y * tx,
    )


def _plot_coordinates(
    position: tuple[float, float, float],
    origin: tuple[float, float, float],
) -> tuple[float, float, float]:
    return (
        position[0] - origin[0],
        -(position[2] - origin[2]),
        position[1] - origin[1],
    )


def _tracked_position(value: Any) -> tuple[float, float, float] | None:
    if not isinstance(value, dict) or value.get("tracked") is not True:
        return None
    position = value.get("position")
    if not isinstance(position, (list, tuple)) or len(position) != 3:
        return None
    if not all(isinstance(component, (int, float)) for component in position):
        return None
    return tuple(float(component) for component in position)


class ConnectionStats:
    """Counts one client's traffic and produces a per-second snapshot."""

    def __init__(self, start_time: float | None = None) -> None:
        self._window_started_at = time.monotonic() if start_time is None else start_time
        self._pose_count = 0
        self._image_count = 0
        self._pose_bytes = 0
        self._image_bytes = 0
        self._latest_pose_frame_id: int | None = None
        self._head_tracked_count = 0
        self._left_hand_tracked_count = 0
        self._right_hand_tracked_count = 0
        self._pose_to_image_latency_total_ns = 0
        self._pose_to_image_latency_max_ns = 0
        self._pose_to_image_latency_count = 0

    def record_pose(self, byte_count: int, pose: dict[str, Any]) -> None:
        self._pose_count += 1
        self._pose_bytes += byte_count
        self._latest_pose_frame_id = int(pose["frame_id"])
        head = pose.get("head")
        left = pose.get("left")
        right = pose.get("right")
        if isinstance(head, dict) and head.get("tracked") is True:
            self._head_tracked_count += 1
        if isinstance(left, dict) and left.get("tracking") is True:
            self._left_hand_tracked_count += 1
        if isinstance(right, dict) and right.get("tracking") is True:
            self._right_hand_tracked_count += 1

    def record_image(self, byte_count: int) -> None:
        self._image_count += 1
        self._image_bytes += byte_count

    def record_pose_to_image_latency(self, elapsed_ns: int) -> None:
        self._pose_to_image_latency_total_ns += elapsed_ns
        self._pose_to_image_latency_max_ns = max(self._pose_to_image_latency_max_ns, elapsed_ns)
        self._pose_to_image_latency_count += 1

    def snapshot_if_due(self, now: float | None = None) -> dict[str, int | float | None] | None:
        current_time = time.monotonic() if now is None else now
        elapsed = current_time - self._window_started_at
        if elapsed < STATS_INTERVAL_SECONDS:
            return None
        snapshot: dict[str, int | float | None] = {
            "pose_rx_fps": round(self._pose_count / elapsed, 1),
            "image_tx_fps": round(self._image_count / elapsed, 1),
            "pose_rx_bytes": self._pose_bytes,
            "image_tx_bytes": self._image_bytes,
            "latest_pose_frame_id": self._latest_pose_frame_id,
            "head_tracked_fps": round(self._head_tracked_count / elapsed, 1),
            "left_hand_tracked_fps": round(self._left_hand_tracked_count / elapsed, 1),
            "right_hand_tracked_fps": round(self._right_hand_tracked_count / elapsed, 1),
            "pose_to_image_avg_ms": round(
                self._pose_to_image_latency_total_ns / max(1, self._pose_to_image_latency_count) / 1_000_000,
                1,
            ),
            "pose_to_image_max_ms": round(self._pose_to_image_latency_max_ns / 1_000_000, 1),
        }
        self._window_started_at = current_time
        self._pose_count = 0
        self._image_count = 0
        self._pose_bytes = 0
        self._image_bytes = 0
        self._head_tracked_count = 0
        self._left_hand_tracked_count = 0
        self._right_hand_tracked_count = 0
        self._pose_to_image_latency_total_ns = 0
        self._pose_to_image_latency_max_ns = 0
        self._pose_to_image_latency_count = 0
        return snapshot


class FirstPoseLogger:
    """Print one complete compact pose sample for each client connection."""

    def __init__(self) -> None:
        self._logged = False

    def log(self, pose: dict[str, Any]) -> None:
        if self._logged:
            return
        public_pose = {
            key: value for key, value in pose.items() if not key.startswith("_")
        }
        print(
            "POSE_SAMPLE "
            + json.dumps(public_pose, separators=(",", ":"), ensure_ascii=False),
            flush=True,
        )
        self._logged = True


def build_qr_payload(websocket_url: str, token: str) -> dict[str, str]:
    return {"mode": "pose_inference", "url": websocket_url, "token": token}


def is_websocket_path(path: str) -> bool:
    return path == "/pose-inference"


def html_headers() -> dict[str, str]:
    return {"Content-Type": "text/html; charset=utf-8"}


def validate_client_message(message: dict[str, Any], token: str) -> str:
    message_type = message.get("type")
    if message_type == "hello":
        if not secrets.compare_digest(str(message.get("token", "")), token):
            raise ValueError("invalid token")
        return "hello"
    if message_type == "pose":
        if not isinstance(message.get("frame_id"), int) or not isinstance(message.get("capture_time_ns"), int):
            raise ValueError("pose requires integer frame_id and capture_time_ns")
        return "pose"
    raise ValueError("unsupported message type")


class MatplotlibPoseRenderer:
    WIDTH = 960
    HEIGHT = 540
    DPI = 100
    BACKGROUND = "#10192c"

    def __init__(self) -> None:
        self._figure = Figure(
            figsize=(self.WIDTH / self.DPI, self.HEIGHT / self.DPI),
            dpi=self.DPI,
            facecolor=self.BACKGROUND,
        )
        self._canvas = FigureCanvasAgg(self._figure)
        self._axes = self._figure.add_subplot(111, projection="3d")
        self._origin: tuple[float, float, float] | None = None
        self._configure_axes()
        (self._head_marker,) = self._axes.plot(
            [], [], [], linestyle="None", marker="o", markersize=9,
            color="#56e39f",
        )
        (self._head_direction,) = self._axes.plot(
            [], [], [], color="#56e39f", linewidth=3.0,
        )
        (self._left_points,) = self._axes.plot(
            [], [], [], linestyle="None", marker="o", markersize=3,
            color="#50c8ff",
        )
        (self._left_bones,) = self._axes.plot(
            [], [], [], color="#50c8ff", linewidth=2.0,
        )
        (self._right_points,) = self._axes.plot(
            [], [], [], linestyle="None", marker="o", markersize=3,
            color="#ff9f43",
        )
        (self._right_bones,) = self._axes.plot(
            [], [], [], color="#ff9f43", linewidth=2.0,
        )
        self._status_text = self._axes.text2D(
            0.02,
            0.96,
            "",
            transform=self._axes.transAxes,
            color="white",
            fontsize=10,
            verticalalignment="top",
        )
        self._dynamic_artists = (
            self._head_direction,
            self._left_bones,
            self._right_bones,
            self._head_marker,
            self._left_points,
            self._right_points,
            self._status_text,
        )
        self._canvas.draw()
        self._background = self._canvas.copy_from_bbox(self._figure.bbox)

    def _configure_axes(self) -> None:
        axes = self._axes
        axes.set_facecolor(self.BACKGROUND)
        axes.set_xlim(-0.9, 0.9)
        axes.set_ylim(-0.9, 0.9)
        axes.set_zlim(-1.0, 0.5)
        axes.set_box_aspect((1.8, 1.8, 1.5))
        axes.view_init(elev=16.0, azim=-72.0)
        axes.set_xlabel("X right", color="white")
        axes.set_ylabel("-Z forward", color="white")
        axes.set_zlabel("Y up", color="white")
        axes.tick_params(colors="#b7c9db")
        axes.grid(True, alpha=0.25)
        axes.set_title("Operator Quest Pose", color="white")

    def render(
        self,
        pose: dict[str, Any],
        image_sequence: int,
    ) -> tuple[int, int, bytes]:
        with _MATPLOTLIB_RENDER_LOCK:
            self._draw_frame(pose, image_sequence)
            self._canvas.restore_region(self._background)
            for artist in self._dynamic_artists:
                self._axes.draw_artist(artist)
            self._canvas.blit(self._figure.bbox)
            rgba = Image.frombuffer(
                "RGBA",
                (self.WIDTH, self.HEIGHT),
                self._canvas.buffer_rgba(),
                "raw",
                "RGBA",
                0,
                1,
            )
            output = io.BytesIO()
            rgba.convert("RGB").save(
                output,
                format="JPEG",
                quality=80,
                optimize=True,
            )
            return self.WIDTH, self.HEIGHT, output.getvalue()

    def _draw_frame(self, pose: dict[str, Any], image_sequence: int) -> None:
        head = pose.get("head")
        head_position = _tracked_position(head)
        if head_position is not None and self._origin is None:
            self._origin = head_position
        origin = self._origin or (0.0, 0.0, 0.0)

        if head_position is None:
            self._head_marker.set_data_3d([], [], [])
            self._head_direction.set_data_3d([], [], [])
        else:
            hx, hy, hz = _plot_coordinates(head_position, origin)
            self._head_marker.set_data_3d([hx], [hy], [hz])
            rotation = head.get("rotation") if isinstance(head, dict) else None
            if (
                isinstance(rotation, (list, tuple))
                and len(rotation) == 4
                and all(isinstance(value, (int, float)) for value in rotation)
            ):
                forward = _rotate_vector_by_quaternion(
                    tuple(float(value) for value in rotation),
                    (0.0, 0.0, -0.25),
                )
                fx, fy, fz = _plot_coordinates(forward, (0.0, 0.0, 0.0))
                self._head_direction.set_data_3d(
                    [hx, hx + fx],
                    [hy, hy + fy],
                    [hz, hz + fz],
                )
            else:
                self._head_direction.set_data_3d([], [], [])

        self._update_hand(
            pose.get("left"), origin, self._left_points, self._left_bones
        )
        self._update_hand(
            pose.get("right"), origin, self._right_points, self._right_bones
        )

        left_tracking = bool(
            isinstance(pose.get("left"), dict)
            and pose["left"].get("tracking") is True
        )
        right_tracking = bool(
            isinstance(pose.get("right"), dict)
            and pose["right"].get("tracking") is True
        )
        self._status_text.set_text(
            f"pose={pose.get('frame_id', '?')}  image={image_sequence}\n"
            f"left={left_tracking}  right={right_tracking}"
        )

    def _update_hand(
        self,
        hand: Any,
        origin: tuple[float, float, float],
        points_artist: Any,
        bones_artist: Any,
    ) -> None:
        if not isinstance(hand, dict) or hand.get("tracking") is not True:
            points_artist.set_data_3d([], [], [])
            bones_artist.set_data_3d([], [], [])
            return
        joints = hand.get("joints")
        if not isinstance(joints, list):
            points_artist.set_data_3d([], [], [])
            bones_artist.set_data_3d([], [], [])
            return

        plotted: dict[int, tuple[float, float, float]] = {}
        for index, joint in enumerate(joints[:26]):
            position = _tracked_position(joint)
            if position is not None:
                plotted[index] = _plot_coordinates(position, origin)

        points_artist.set_data_3d(
            [value[0] for value in plotted.values()],
            [value[1] for value in plotted.values()],
            [value[2] for value in plotted.values()],
        )
        bone_x: list[float] = []
        bone_y: list[float] = []
        bone_z: list[float] = []
        for start, end in HAND_BONES:
            if start not in plotted or end not in plotted:
                continue
            first = plotted[start]
            second = plotted[end]
            bone_x.extend((first[0], second[0], float("nan")))
            bone_y.extend((first[1], second[1], float("nan")))
            bone_z.extend((first[2], second[2], float("nan")))
        bones_artist.set_data_3d(bone_x, bone_y, bone_z)


def log_stats(stats: ConnectionStats) -> None:
    snapshot = stats.snapshot_if_due()
    if snapshot is None:
        return
    print(
        "POSE_STATS pose_rx_fps={pose_rx_fps:.1f} image_tx_fps={image_tx_fps:.1f} "
        "head_tracked_fps={head_tracked_fps:.1f} "
        "left_hand_tracked_fps={left_hand_tracked_fps:.1f} "
        "right_hand_tracked_fps={right_hand_tracked_fps:.1f} "
        "pose_rx_bytes={pose_rx_bytes} image_tx_bytes={image_tx_bytes} "
        "latest_pose_frame_id={latest_pose_frame_id} pose_to_image_avg_ms={pose_to_image_avg_ms:.1f} "
        "pose_to_image_max_ms={pose_to_image_max_ms:.1f}".format(**snapshot),
        flush=True,
    )


async def run_inference(
    connection: Any,
    latest: LatestPose,
    stats: ConnectionStats,
    renderer: Any | None = None,
) -> None:
    """Render and emit the newest pose without accumulating frames."""
    renderer = MatplotlibPoseRenderer() if renderer is None else renderer
    loop = asyncio.get_running_loop()
    next_frame_at = loop.time()
    source_pose: dict[str, Any] | None = None
    image_sequence = 0
    while True:
        pose = latest.take()
        if pose is not None:
            source_pose = pose
        if source_pose is None:
            log_stats(stats)
            await asyncio.sleep(0.005)
            continue
        await asyncio.sleep(max(0.0, next_frame_at - loop.time()))
        pose = latest.take()
        if pose is not None:
            source_pose = pose
        image_sequence += 1
        width, height, jpeg = await asyncio.to_thread(
            renderer.render,
            source_pose,
            image_sequence,
        )
        packet = pack_image_frame(
            source_pose["frame_id"],
            source_pose["capture_time_ns"],
            width,
            height,
            jpeg,
        )
        await connection.send(packet)
        stats.record_image(len(packet))
        stats.record_pose_to_image_latency(
            time.perf_counter_ns() - source_pose["_server_received_ns"]
        )
        log_stats(stats)
        next_frame_at += FRAME_INTERVAL_SECONDS
        if next_frame_at < loop.time():
            next_frame_at = loop.time()


async def websocket_handler(connection: Any, token: str) -> None:
    latest = LatestPose()
    stats = ConnectionStats()
    sample_logger = FirstPoseLogger()
    inference_task: asyncio.Task[None] | None = None
    authenticated = False
    try:
        async for raw in connection:
            if not isinstance(raw, str) or len(raw.encode("utf-8")) > MAX_POSE_JSON_BYTES:
                await connection.close(1003, "expected bounded JSON messages")
                return
            try:
                message = json.loads(raw)
                if not isinstance(message, dict):
                    raise ValueError("message must be an object")
                kind = validate_client_message(message, token)
            except (json.JSONDecodeError, ValueError) as error:
                await connection.close(1008, str(error))
                return
            if kind == "hello":
                authenticated = True
                await connection.send(json.dumps({"type": "ready", "target_hz": 20}))
                if inference_task is None:
                    inference_task = asyncio.create_task(run_inference(connection, latest, stats))
            elif not authenticated:
                await connection.close(1008, "send hello before pose")
                return
            else:
                message["_server_received_ns"] = time.perf_counter_ns()
                sample_logger.log(message)
                latest.replace(message)
                stats.record_pose(len(raw.encode("utf-8")), message)
    finally:
        if inference_task is not None:
            inference_task.cancel()
            await asyncio.gather(inference_task, return_exceptions=True)


def qr_page(config: dict[str, str]) -> bytes:
    escaped = json.dumps(config).replace("&", "&amp;").replace("<", "&lt;")
    import qrcode

    image = qrcode.make(json.dumps(config, separators=(",", ":")))
    output = io.BytesIO()
    image.save(output, format="PNG")
    encoded = base64.b64encode(output.getvalue()).decode("ascii")
    return f"""<!doctype html><meta charset=\"utf-8\"><title>Operator Pose Inference</title>
<style>body{{font:18px system-ui;text-align:center;margin:40px;background:#10192c;color:#e9f4ff}}img{{width:420px;max-width:90vw;background:white;padding:16px}}code{{display:block;overflow-wrap:anywhere;margin:24px auto;max-width:760px}}</style>
<h1>Operator Pose Inference</h1><p>Scan this QR code from the Quest Pose Inference settings.</p>
<img alt=\"Quest connection QR code\" src=\"data:image/png;base64,{encoded}\"><code>{escaped}</code>""".encode("utf-8")


async def process_request(connection: Any, request: Any, config: dict[str, str]) -> Any:
    if is_websocket_path(request.path):
        return None
    if request.path != "/":
        return connection.respond(HTTPStatus.NOT_FOUND, "Not found\n")
    response = connection.respond(HTTPStatus.OK, qr_page(config).decode("utf-8"))
    del response.headers["Content-Type"]
    response.headers["Content-Type"] = html_headers()["Content-Type"]
    return response


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=63920)
    parser.add_argument("--public-host", default="", help="LAN address placed in the Quest QR URL")
    parser.add_argument("--token", default=os.environ.get("POSE_INFERENCE_TOKEN", ""))
    parser.add_argument("--print-config", action="store_true")
    return parser.parse_args()


async def main() -> None:
    args = parse_args()
    public_host = args.public_host or args.host
    if public_host in ("0.0.0.0", "::"):
        raise SystemExit("--public-host is required when --host is a wildcard address")
    token = args.token or secrets.token_urlsafe(24)
    config = build_qr_payload(f"ws://{public_host}:{args.port}/pose-inference", token)
    if args.print_config:
        print(json.dumps(config, indent=2))
        return
    from websockets.asyncio.server import serve

    print("Quest QR page: http://%s:%d/" % (public_host, args.port), flush=True)
    print("POSE_INFERENCE_TOKEN=%s" % token, flush=True)
    async with serve(
        lambda connection: websocket_handler(connection, token),
        args.host,
        args.port,
        process_request=lambda connection, request: process_request(connection, request, config),
    ):
        await asyncio.Future()


if __name__ == "__main__":
    asyncio.run(main())
