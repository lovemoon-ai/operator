#!/usr/bin/env python3
from __future__ import annotations


import argparse
import ctypes
import signal
import subprocess
import sys


TONE_CORRECTION_FILTER = (
    "curves=master='0/0 0.2/0.12 0.5/0.35 0.8/0.58 1/0.75',"
    "colorbalance=gm=-0.01:bm=0.015"
)


def build_ffmpeg_command(
    ffmpeg: str,
    fps: int,
    eye: str,
    tone_correction: bool = True,
) -> list[str]:
    command = [
        ffmpeg,
        "-hide_banner",
        "-loglevel",
        "warning",
        "-nostdin",
        "-fflags",
        "nobuffer",
        "-flags",
        "low_delay",
        "-f",
        "mjpeg",
        "-framerate",
        str(fps),
        "-i",
        "pipe:0",
    ]
    filters: list[str] = []
    if eye == "left":
        filters.append("crop=iw/2:ih:0:0")
    elif eye == "right":
        filters.append("crop=iw/2:ih:iw/2:0")
    if tone_correction and eye != "stereo":
        filters.append(TONE_CORRECTION_FILTER)
    if filters:
        command.extend(["-vf", ",".join(filters)])
    command.extend(
        [
            "-an",
            "-c:v",
            "libx264",
            "-preset",
            "ultrafast",
            "-tune",
            "zerolatency",
            "-profile:v",
            "baseline",
            "-level:v",
            "3.1",
            "-pix_fmt",
            "yuv420p",
            "-g",
            str(fps),
            "-keyint_min",
            str(fps),
            "-sc_threshold",
            "0",
            "-bf",
            "0",
            "-x264-params",
            "repeat-headers=1",
            "-flush_packets",
            "1",
            "-f",
            "h264",
            "pipe:1",
        ]
    )
    return command


def set_parent_death_signal() -> None:
    libc = ctypes.CDLL("libc.so.6")
    libc.prctl(1, signal.SIGTERM)


def relay(
    endpoint: str,
    ffmpeg: str,
    fps: int,
    eye: str,
    tone_correction: bool,
) -> int:
    import zmq

    running = True

    def request_stop(_signum: int, _frame: object) -> None:
        nonlocal running
        running = False

    signal.signal(signal.SIGINT, request_stop)
    signal.signal(signal.SIGTERM, request_stop)

    process = subprocess.Popen(
        build_ffmpeg_command(ffmpeg, fps, eye, tone_correction),
        stdin=subprocess.PIPE,
        stdout=sys.stdout.buffer,
        stderr=sys.stderr.buffer,
        bufsize=0,
        preexec_fn=set_parent_death_signal,
    )
    context = zmq.Context()
    socket = context.socket(zmq.SUB)
    socket.setsockopt(zmq.SUBSCRIBE, b"")
    socket.setsockopt(zmq.CONFLATE, 1)
    socket.setsockopt(zmq.LINGER, 0)
    socket.setsockopt(zmq.RCVTIMEO, 1000)
    socket.connect(endpoint)

    try:
        while running and process.poll() is None:
            try:
                frame = socket.recv()
            except zmq.Again:
                continue
            if len(frame) < 4 or not frame.startswith(b"\xff\xd8") or not frame.endswith(b"\xff\xd9"):
                continue
            try:
                process.stdin.write(frame)
            except (BrokenPipeError, OSError):
                break
    finally:
        socket.close(0)
        context.term()
        if process.stdin is not None:
            try:
                process.stdin.close()
            except BrokenPipeError:
                pass
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=2.0)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()

    return process.returncode or 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Convert Unitree teleimager ZMQ JPEG frames to Annex-B H.264"
    )
    parser.add_argument("--endpoint", default="tcp://127.0.0.1:55555")
    parser.add_argument("--ffmpeg", default="/usr/bin/ffmpeg")
    parser.add_argument("--fps", type=int, default=30)
    parser.add_argument("--eye", choices=("left", "right", "stereo"), default="left")
    parser.add_argument(
        "--tone-correction",
        choices=("on", "off"),
        default="on",
        help="compress clipped highlights and reduce the green cast",
    )
    args = parser.parse_args()
    if args.fps < 1 or args.fps > 120:
        parser.error("--fps must be between 1 and 120")
    return args


def main() -> int:
    args = parse_args()
    return relay(
        args.endpoint,
        args.ffmpeg,
        args.fps,
        args.eye,
        args.tone_correction == "on",
    )


if __name__ == "__main__":
    raise SystemExit(main())
