#!/usr/bin/env python3
"""Publish Galbot G1 RGB cameras as RTSP H.264 streams.

The Galbot SDK exposes compressed RGB frames through get_rgb_data(). This helper
decodes those frames with OpenCV and feeds raw BGR frames into one ffmpeg process
per camera. ffmpeg publishes H.264 RTSP streams to an external RTSP server
(MediaMTX/live555/etc.); xr-bridge then pulls those RTSP URLs as usual.
"""

from __future__ import annotations

import argparse
import os
import signal
import subprocess
import sys
import time
from dataclasses import dataclass
from typing import Dict, List, Optional

import cv2
import numpy as np


@dataclass(frozen=True)
class FeedSpec:
    name: str
    sensor_attr: str
    path: str


FEEDS: Dict[str, FeedSpec] = {
    "head_left_rgb": FeedSpec("head_left_rgb", "HEAD_LEFT_CAMERA", "head_left_rgb"),
    "left_wrist_rgb": FeedSpec("left_wrist_rgb", "LEFT_ARM_CAMERA", "left_wrist_rgb"),
    "right_wrist_rgb": FeedSpec("right_wrist_rgb", "RIGHT_ARM_CAMERA", "right_wrist_rgb"),
}


class FfmpegPublisher:
    def __init__(
        self,
        feed: FeedSpec,
        url: str,
        ffmpeg: str,
        width: int,
        height: int,
        fps: int,
        bitrate: str,
    ) -> None:
        self.feed = feed
        self.url = url
        self.ffmpeg = ffmpeg
        self.width = width
        self.height = height
        self.fps = fps
        self.bitrate = bitrate
        self.proc: Optional[subprocess.Popen[bytes]] = None
        self._last_restart_s = 0.0

    def ensure_running(self) -> bool:
        if self.proc is not None and self.proc.poll() is None:
            return True

        now = time.monotonic()
        if now - self._last_restart_s < 1.0:
            return False
        self._last_restart_s = now

        self.close()
        cmd = [
            self.ffmpeg,
            "-nostdin",
            "-hide_banner",
            "-loglevel",
            "warning",
            "-f",
            "rawvideo",
            "-pix_fmt",
            "bgr24",
            "-s",
            f"{self.width}x{self.height}",
            "-r",
            str(self.fps),
            "-i",
            "pipe:0",
            "-an",
            "-c:v",
            "libx264",
            "-preset",
            "ultrafast",
            "-tune",
            "zerolatency",
            "-b:v",
            self.bitrate,
            "-maxrate",
            self.bitrate,
            "-bufsize",
            self.bitrate,
            "-g",
            str(max(1, self.fps)),
            "-bf",
            "0",
            "-pix_fmt",
            "yuv420p",
            "-f",
            "rtsp",
            "-rtsp_transport",
            "tcp",
            self.url,
        ]
        log(f"[{self.feed.name}] starting ffmpeg -> {self.url}")
        self.proc = subprocess.Popen(
            cmd,
            stdin=subprocess.PIPE,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
        )
        return True

    def write_frame(self, frame_bgr: np.ndarray) -> None:
        if not self.ensure_running() or self.proc is None or self.proc.stdin is None:
            return
        try:
            self.proc.stdin.write(frame_bgr.tobytes())
        except (BrokenPipeError, OSError) as exc:
            log(f"[{self.feed.name}] ffmpeg pipe closed: {exc}")
            self.close()

    def close(self) -> None:
        proc = self.proc
        self.proc = None
        if proc is None:
            return
        try:
            if proc.stdin:
                proc.stdin.close()
        except OSError:
            pass
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=1.0)
            except subprocess.TimeoutExpired:
                proc.kill()


def log(message: str) -> None:
    print(f"[galbot_g1_rgb_rtsp] {message}", file=sys.stderr, flush=True)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rtsp-base", default="rtsp://127.0.0.1:8554")
    parser.add_argument(
        "--feeds",
        default="head_left_rgb,left_wrist_rgb,right_wrist_rgb",
        help="Comma-separated feed names",
    )
    parser.add_argument("--width", type=int, default=640)
    parser.add_argument("--height", type=int, default=480)
    parser.add_argument("--fps", type=int, default=15)
    parser.add_argument("--bitrate", default="1500k")
    parser.add_argument("--warmup-s", type=float, default=5.0)
    parser.add_argument("--ffmpeg", default=os.environ.get("FFMPEG", "ffmpeg"))
    return parser.parse_args()


def selected_feeds(names_csv: str) -> List[FeedSpec]:
    out: List[FeedSpec] = []
    for raw in names_csv.split(","):
        name = raw.strip()
        if not name:
            continue
        if name not in FEEDS:
            raise SystemExit(f"unknown feed {name!r}; known: {', '.join(sorted(FEEDS))}")
        out.append(FEEDS[name])
    if not out:
        raise SystemExit("at least one feed must be selected")
    return out


def rtsp_url(base: str, feed: FeedSpec) -> str:
    return f"{base.rstrip('/')}/{feed.path}"


def decode_rgb_frame(image_data: dict) -> Optional[np.ndarray]:
    raw = image_data.get("data")
    if not raw:
        return None
    arr = np.frombuffer(bytes(raw), np.uint8)
    frame = cv2.imdecode(arr, cv2.IMREAD_COLOR)
    if frame is None:
        fmt = image_data.get("format", "")
        log(f"failed to decode RGB frame format={fmt!r} bytes={len(raw)}")
    return frame


def resize_frame(frame: np.ndarray, width: int, height: int) -> np.ndarray:
    if frame.shape[1] == width and frame.shape[0] == height:
        return frame
    return cv2.resize(frame, (width, height), interpolation=cv2.INTER_AREA)


def request_robot_shutdown(robot: object) -> None:
    for method in ("request_shutdown", "wait_for_shutdown", "destroy"):
        fn = getattr(robot, method, None)
        if callable(fn):
            try:
                fn()
            except Exception as exc:  # pragma: no cover - best-effort shutdown
                log(f"{method} failed during shutdown: {exc}")


def main() -> int:
    args = parse_args()
    feeds = selected_feeds(args.feeds)

    from galbot_sdk.g1 import GalbotRobot, SensorType

    sensors = {getattr(SensorType, feed.sensor_attr) for feed in feeds}
    publishers = [
        FfmpegPublisher(
            feed=feed,
            url=rtsp_url(args.rtsp_base, feed),
            ffmpeg=args.ffmpeg,
            width=args.width,
            height=args.height,
            fps=args.fps,
            bitrate=args.bitrate,
        )
        for feed in feeds
    ]

    stop = False

    def _handle_stop(_signum: int, _frame: object) -> None:
        nonlocal stop
        stop = True

    signal.signal(signal.SIGINT, _handle_stop)
    signal.signal(signal.SIGTERM, _handle_stop)

    robot = GalbotRobot()
    try:
        log(f"initializing sensors: {', '.join(feed.sensor_attr for feed in feeds)}")
        robot.init(sensors)
        if args.warmup_s > 0:
            time.sleep(args.warmup_s)

        period_s = 1.0 / max(1, args.fps)
        next_tick = time.monotonic()
        sensor_by_feed = {feed.name: getattr(SensorType, feed.sensor_attr) for feed in feeds}

        while not stop:
            loop_start = time.monotonic()
            for publisher in publishers:
                sensor = sensor_by_feed[publisher.feed.name]
                data = robot.get_rgb_data(sensor)
                if not data:
                    continue
                frame = decode_rgb_frame(data)
                if frame is None:
                    continue
                frame = resize_frame(frame, args.width, args.height)
                publisher.write_frame(frame)

            next_tick += period_s
            sleep_s = next_tick - time.monotonic()
            if sleep_s > 0:
                time.sleep(sleep_s)
            elif time.monotonic() - loop_start > period_s * 2:
                next_tick = time.monotonic()
    finally:
        for publisher in publishers:
            publisher.close()
        request_robot_shutdown(robot)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
