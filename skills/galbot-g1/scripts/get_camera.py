"""
Capture Galbot G1 RGB camera streams and save MP4 videos when ffmpeg is
available.

The Galbot SDK returns compressed RGB image bytes. On the robot image stacks
often do not include Python cv2, so this script writes those JPEG frames
directly and optionally invokes ffmpeg to produce MP4 files.
"""

import argparse
import shutil
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

from galbot_sdk.g1 import GalbotRobot, SensorType


CAMERA_ALIASES = {
    "left": SensorType.LEFT_FRONT_SURROUND_CAMERA,
    "right": SensorType.RIGHT_FRONT_SURROUND_CAMERA,
    "head": SensorType.HEAD_LEFT_CAMERA,
    "left_front": SensorType.LEFT_FRONT_SURROUND_CAMERA,
    "right_front": SensorType.RIGHT_FRONT_SURROUND_CAMERA,
    "left_rear": SensorType.LEFT_REAR_SURROUND_CAMERA,
    "right_rear": SensorType.RIGHT_REAR_SURROUND_CAMERA,
    "left_arm": SensorType.LEFT_ARM_CAMERA,
    "right_arm": SensorType.RIGHT_ARM_CAMERA,
    "head_left": SensorType.HEAD_LEFT_CAMERA,
    "head_right": SensorType.HEAD_RIGHT_CAMERA,
}


def parse_cameras(raw):
    names = [part.strip() for part in raw.split(",") if part.strip()]
    unknown = [name for name in names if name not in CAMERA_ALIASES]
    if unknown:
        valid = ", ".join(sorted(CAMERA_ALIASES))
        raise ValueError(f"unknown camera(s): {unknown}; valid: {valid}")
    return names


def frame_bytes(image_data):
    data = image_data.get("data", b"")
    if not data:
        return b""
    if isinstance(data, bytes):
        return data
    return bytes(data)


def encode_mp4(frame_dir, output_path, fps):
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        return False, "ffmpeg not found"

    cmd = [
        ffmpeg,
        "-y",
        "-hide_banner",
        "-loglevel",
        "error",
        "-framerate",
        str(fps),
        "-i",
        str(frame_dir / "frame_%06d.jpg"),
        "-c:v",
        "libx264",
        "-pix_fmt",
        "yuv420p",
        "-movflags",
        "+faststart",
        str(output_path),
    ]
    try:
        subprocess.run(cmd, check=True)
    except subprocess.CalledProcessError as exc:
        return False, f"ffmpeg failed with exit code {exc.returncode}"
    return True, "ok"


def parse_args():
    parser = argparse.ArgumentParser(description="Capture Galbot G1 camera streams.")
    parser.add_argument(
        "--cameras",
        default="left,right,head",
        help=(
            "comma-separated camera aliases: left,right,head,left_front,right_front,"
            "left_rear,right_rear,left_arm,right_arm,head_left,head_right"
        ),
    )
    parser.add_argument("--duration", type=float, default=5.0, help="capture duration in seconds")
    parser.add_argument("--fps", type=float, default=10.0, help="target capture/encode FPS")
    parser.add_argument("--warmup", type=float, default=5.0, help="sensor warm-up seconds")
    parser.add_argument(
        "--ready-timeout",
        type=float,
        default=8.0,
        help="seconds to wait after warm-up for every requested camera to publish a frame",
    )
    parser.add_argument(
        "--output-dir",
        default="camera_capture",
        help="directory for frames and MP4 outputs",
    )
    parser.add_argument(
        "--no-mp4",
        action="store_true",
        help="only save JPEG frames, do not invoke ffmpeg",
    )
    parser.add_argument(
        "--keep-frames",
        action="store_true",
        help="keep JPEG frame directories even when MP4 encoding succeeds",
    )
    return parser.parse_args()


def wait_for_ready(robot, camera_names, timeout):
    if timeout <= 0.0:
        return set(), set(camera_names)

    ready = set()
    pending = set(camera_names)
    deadline = time.monotonic() + timeout
    while pending and time.monotonic() < deadline:
        for name in list(pending):
            image_data = robot.get_rgb_data(CAMERA_ALIASES[name])
            data = frame_bytes(image_data) if image_data else b""
            if data:
                ready.add(name)
                pending.remove(name)
        if pending:
            time.sleep(0.1)
    return ready, pending


def main():
    args = parse_args()
    if args.duration <= 0.0:
        sys.exit("--duration must be positive")
    if args.fps <= 0.0:
        sys.exit("--fps must be positive")
    if args.ready_timeout < 0.0:
        sys.exit("--ready-timeout must be non-negative")

    try:
        camera_names = parse_cameras(args.cameras)
    except ValueError as exc:
        sys.exit(str(exc))

    output_root = Path(args.output_dir) / datetime.now().strftime("%Y%m%d_%H%M%S")
    output_root.mkdir(parents=True, exist_ok=True)
    frame_dirs = {}
    frame_counts = {name: 0 for name in camera_names}
    miss_counts = {name: 0 for name in camera_names}
    for name in camera_names:
        frame_dir = output_root / f"{name}_frames"
        frame_dir.mkdir(parents=True, exist_ok=True)
        frame_dirs[name] = frame_dir

    robot = GalbotRobot()
    sensors = {CAMERA_ALIASES[name] for name in camera_names}
    ok = robot.init(sensors)
    if not ok:
        robot.destroy()
        sys.exit("robot.init failed")

    print(f"output_dir={output_root}")
    print(f"enabled={camera_names}")
    print(f"warmup={args.warmup}s")
    print(f"ready_timeout={args.ready_timeout}s")
    try:
        time.sleep(args.warmup)
        ready, pending = wait_for_ready(robot, camera_names, args.ready_timeout)
        if ready:
            print(f"ready={sorted(ready)}")
        if pending:
            print(f"not_ready={sorted(pending)}")
        period = 1.0 / args.fps
        deadline = time.monotonic() + args.duration
        next_tick = time.monotonic()
        while time.monotonic() < deadline:
            for name in camera_names:
                image_data = robot.get_rgb_data(CAMERA_ALIASES[name])
                data = frame_bytes(image_data) if image_data else b""
                if not data:
                    miss_counts[name] += 1
                    continue
                idx = frame_counts[name]
                (frame_dirs[name] / f"frame_{idx:06d}.jpg").write_bytes(data)
                frame_counts[name] += 1
            next_tick += period
            sleep_s = next_tick - time.monotonic()
            if sleep_s > 0.0:
                time.sleep(sleep_s)
    finally:
        robot.request_shutdown()
        robot.wait_for_shutdown()
        robot.destroy()

    print("capture_summary")
    for name in camera_names:
        print(f"  {name}: frames={frame_counts[name]} misses={miss_counts[name]}")

    if args.no_mp4:
        return 0

    for name in camera_names:
        if frame_counts[name] == 0:
            print(f"mp4 {name}: skipped, no frames")
            continue
        mp4_path = output_root / f"{name}.mp4"
        encoded, message = encode_mp4(frame_dirs[name], mp4_path, args.fps)
        print(f"mp4 {name}: {message} {mp4_path if encoded else ''}")
        if encoded and not args.keep_frames:
            shutil.rmtree(frame_dirs[name])

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
