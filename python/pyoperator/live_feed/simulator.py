"""Synthetic headset that speaks OLCP live-push, for development without hardware.

Lets you run and iterate on a Live Feed application when no Quest/Pico is
attached.  Payload shapes mirror the real producers
(``LiveFeedServerPlugin.kt``, ``pose_sampler.gd``, ``depth_sampler.gd``); keeping
them in sync is what makes host-side testing meaningful.

Run a server in one terminal and this in another::

    python python/examples/live_feed_viewer.py
    python -m pyoperator.live_feed.simulator

This is a development aid, not a headset substitute: RGB packets carry dummy
bytes (no real HEVC bitstream) and depth is a flat synthetic plane.  Behaviour
that depends on real codec or sensor data still needs ``cicd/04_live_feed_e2e.sh``
on a device.
"""

from __future__ import annotations

import argparse
import json
import math
import socket
import struct
import sys
import time
import zlib
from typing import Any

from .protocol import (
    FLAG_COMPRESSED_ZLIB,
    FLAG_COMPOSITE_JSON,
    FLAG_KEYFRAME,
    TYPE_CONTROLLER_INPUT,
    TYPE_CONTROLLER_POSE,
    TYPE_DEPTH_FRAME,
    TYPE_DEPTH_METADATA,
    TYPE_HAND_JOINTS,
    TYPE_HEAD_POSE,
    TYPE_RGB_CSD,
    TYPE_RGB_PACKET,
    TYPE_SESSION_END,
    TYPE_SESSION_START,
    encode_json,
    pack_composite_payload,
    pack_frame,
)


# ---------------------------------------------------------------------------
# payload builders - keep field names identical to the XR producers
# ---------------------------------------------------------------------------


def session_start_payload(
    stream_name: str = "live_sim_0001",
    auth_token: str = "",
    protocol: str = "operator.live_feed.v1",
) -> dict[str, Any]:
    return {
        "contract_version": 6,
        "partial_path": f"/sdcard/{stream_name}.partial",
        "final_path": f"/sdcard/{stream_name}.mp4",
        "session_start_unix_us": 1_700_000_000_000_000,
        "session_start_godot_ticks_us": 12_345_678,
        "rgb_width": 1280,
        "rgb_height": 960,
        "rgb_fps": 30,
        "rgb_camera_count": 2,
        "depth_expected": True,
        "head_pose_expected": True,
        "controller_pose_expected": True,
        "hand_joints_expected": True,
        "controller_input_expected": True,
        "stream_name": stream_name,
        "auth_token": auth_token,
        "protocol": protocol,
    }


def rgb_csd_payload() -> dict[str, Any]:
    return {
        "width": 1280,
        "height": 960,
        "fps": 30,
        "codec": "hevc",
        "bitstream_format": "hevc_annexb",
        "packet_format": "access_unit",
        "stereo_layout": "side_by_side",
        "camera_count": 2,
        "cameras": [
            {
                "fx": 320.0,
                "fy": 320.0,
                "cx": 320.0,
                "cy": 480.0,
                "extrinsics_3x4": [1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0],
                "distortion": [0.0, 0.0, 0.0, 0.0, 0.0],
                "width": 640,
                "height": 960,
            },
            {
                "fx": 320.0,
                "fy": 320.0,
                "cx": 320.0,
                "cy": 480.0,
                "extrinsics_3x4": [1.0, 0.0, 0.0, 0.064, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0],
                "distortion": [0.0, 0.0, 0.0, 0.0, 0.0],
                "width": 640,
                "height": 960,
            },
        ],
        "csd_base64": "",
    }


def head_pose_payload(
    x: float = 0.0,
    y: float = 1.6,
    z: float = 0.0,
    tracking_valid: bool = True,
) -> dict[str, Any]:
    return {
        "position": {"x": x, "y": y, "z": z},
        "rotation": {"x": 0.0, "y": 0.0, "z": 0.0, "w": 1.0},
        "tracking_valid": tracking_valid,
    }


def controller_pose_payload(hand: str = "left", x: float = -0.2) -> dict[str, Any]:
    return {
        "source": f"{hand}_controller",
        "position": {"x": x, "y": 1.2, "z": -0.3},
        "rotation": {"x": 0.0, "y": 0.0, "z": 0.0, "w": 1.0},
        "tracking_valid": True,
    }


def controller_input_payload(
    hand: str = "right",
    pressed_mask: int = 0,
    trigger: float = 0.0,
) -> dict[str, Any]:
    return {
        "controller": f"{hand}_controller",
        "packet_type": 1,
        "available_mask": 0xFFFF,
        "pressed_mask": pressed_mask,
        "touched_mask": 0,
        "changed_mask": 0,
        "trigger_value": trigger,
        "grip_value": 0.25,
        "thumbstick": {"x": 0.5, "y": -0.25},
        "trackpad": {"x": 0.0, "y": 0.0},
    }


def hand_joints_payload(hand: str = "left", joint_count: int = 26) -> dict[str, Any]:
    joints = [
        {
            "joint": index,
            "flags": 3,
            "radius_m": 0.008,
            "position": {"x": 0.01 * index, "y": 1.0, "z": -0.4},
            "rotation": {"x": 0.0, "y": 0.0, "z": 0.0, "w": 1.0},
        }
        for index in range(joint_count)
    ]
    # The headset nests the array as a JSON *string* under joints_json.
    return {"hand": hand, "joints_json": json.dumps(joints)}


def depth_frame_frame(
    pts_ns: int,
    width: int = 8,
    height: int = 4,
    depth_mm: int = 1500,
    compress: bool = True,
) -> bytes:
    """Composite depth frame exactly as ``LivePushWriter.write_depth_frame`` sends it."""
    metadata = {
        "width": width,
        "height": height,
        "fov_left": 1.0,
        "fov_right": 1.0,
        "fov_top": 0.8,
        "fov_bottom": 0.8,
        "metadata_json": json.dumps(
            {
                "source": "XR_META_environment_depth",
                "sample_storage": "u16_unorm_le",
                "near_z": 0.1,
                "far_z": 10.0,
                "fov_tangent": {"left": 1.0, "right": 1.0, "top": 0.8, "bottom": 0.8},
                "local_from_depth_eye": {
                    "position": {"x": 0.0, "y": 1.6, "z": 0.0},
                    "rotation": {"x": 0.0, "y": 0.0, "z": 0.0, "w": 1.0},
                },
            }
        ),
    }
    pixels = b"".join(struct.pack("<H", depth_mm) for _ in range(width * height))
    wire_pixels = zlib.compress(pixels, level=1) if compress and len(pixels) >= 256 else pixels
    flags = FLAG_COMPOSITE_JSON
    if len(wire_pixels) + 32 < len(pixels):
        metadata["wire_compression"] = "zlib"
        metadata["uncompressed_size_bytes"] = len(pixels)
        flags |= FLAG_COMPRESSED_ZLIB
    else:
        wire_pixels = pixels
    payload = pack_composite_payload(metadata, wire_pixels)
    return pack_frame(TYPE_DEPTH_FRAME, flags, pts_ns, 200_000_000, payload)


# ---------------------------------------------------------------------------
# client
# ---------------------------------------------------------------------------


class SyntheticHeadset:
    """Live-push client used by tests and by the ``simulator`` CLI."""

    def __init__(self, host: str, port: int, timeout: float = 5.0) -> None:
        self.conn = socket.create_connection((host, port), timeout=timeout)
        self.conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)

    @classmethod
    def connect(cls, host: str, port: int, retry_for: float = 0.0, timeout: float = 5.0) -> "SyntheticHeadset":
        """Connect, optionally retrying until ``retry_for`` seconds have passed."""
        deadline = time.monotonic() + retry_for
        while True:
            try:
                return cls(host, port, timeout=timeout)
            except OSError:
                if time.monotonic() >= deadline:
                    raise
                time.sleep(0.1)

    def close(self) -> None:
        try:
            self.conn.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        self.conn.close()

    def __enter__(self) -> "SyntheticHeadset":
        return self

    def __exit__(self, *_exc: Any) -> None:
        self.close()

    def send_raw(self, data: bytes) -> None:
        self.conn.sendall(data)

    def send_json(self, frame_type: int, value: dict[str, Any], pts_ns: int = 0, duration_ns: int = 0) -> None:
        self.conn.sendall(pack_frame(frame_type, 0, pts_ns, duration_ns, encode_json(value)))

    def session_start(self, **kwargs: Any) -> None:
        self.send_json(TYPE_SESSION_START, session_start_payload(**kwargs))

    def session_end(self, stream_name: str = "live_sim_0001", reason: str = "finish") -> None:
        self.send_json(TYPE_SESSION_END, {"stream_name": stream_name, "reason": reason})

    def rgb_csd(self) -> None:
        self.send_json(TYPE_RGB_CSD, rgb_csd_payload())

    def rgb_packet(self, pts_ns: int, payload: bytes = b"\x00\x00\x00\x01\x26", keyframe: bool = True) -> None:
        flags = FLAG_KEYFRAME if keyframe else 0
        self.conn.sendall(pack_frame(TYPE_RGB_PACKET, flags, pts_ns, 0, payload))

    def head_pose(self, pts_ns: int, **kwargs: Any) -> None:
        self.send_json(TYPE_HEAD_POSE, head_pose_payload(**kwargs), pts_ns=pts_ns, duration_ns=11_111_000)

    def controller_pose(self, pts_ns: int, **kwargs: Any) -> None:
        self.send_json(
            TYPE_CONTROLLER_POSE, controller_pose_payload(**kwargs), pts_ns=pts_ns, duration_ns=11_111_000
        )

    def controller_input(self, pts_ns: int, **kwargs: Any) -> None:
        self.send_json(
            TYPE_CONTROLLER_INPUT, controller_input_payload(**kwargs), pts_ns=pts_ns, duration_ns=1_000_000
        )

    def hand_joints(self, pts_ns: int, **kwargs: Any) -> None:
        self.send_json(TYPE_HAND_JOINTS, hand_joints_payload(**kwargs), pts_ns=pts_ns, duration_ns=33_333_000)

    def depth_metadata(self, pts_ns: int, width: int = 8, height: int = 4) -> None:
        self.send_json(
            TYPE_DEPTH_METADATA,
            {
                "width": width,
                "height": height,
                "intrinsics": {
                    "fx": 4.0,
                    "fy": 4.0,
                    "cx": width / 2.0,
                    "cy": height / 2.0,
                    "extrinsics_3x4": [1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0],
                    "distortion": [0.0],
                    "width": width,
                    "height": height,
                },
            },
            pts_ns=pts_ns,
        )

    def depth_frame(self, pts_ns: int, **kwargs: Any) -> None:
        self.conn.sendall(depth_frame_frame(pts_ns, **kwargs))


def walk_position(elapsed_s: float, radius: float = 1.0) -> tuple[float, float, float]:
    """A slow horizontal circle with a gentle bob, so trails are clearly visible."""
    angle = elapsed_s * 0.6
    return (
        radius * math.cos(angle),
        1.6 + 0.08 * math.sin(elapsed_s * 1.7),
        radius * math.sin(angle),
    )


def stream_session(
    device: SyntheticHeadset,
    *,
    duration_s: float,
    rate_hz: float,
    radius: float,
    stream_name: str = "live_sim_0001",
    auth_token: str = "",
    quiet: bool = False,
) -> int:
    """Send one synthetic session. Returns the number of frames sent."""
    device.session_start(stream_name=stream_name, auth_token=auth_token)
    device.rgb_csd()
    device.depth_metadata(0)

    period = 1.0 / max(1.0, rate_hz)
    started = time.monotonic()
    frames = 3
    index = 0
    next_tick = started

    while True:
        now = time.monotonic()
        elapsed = now - started
        if duration_s > 0 and elapsed >= duration_s:
            break

        pts_ns = time.monotonic_ns()
        x, y, z = walk_position(elapsed, radius)
        device.head_pose(pts_ns, x=x, y=y, z=z)
        device.controller_pose(pts_ns, hand="left", x=x - 0.2)
        device.controller_pose(pts_ns, hand="right", x=x + 0.2)
        device.controller_input(
            pts_ns, hand="right", trigger=abs(math.sin(elapsed))
        )
        frames += 4

        # Lower-rate streams, like the real headset.
        if index % 3 == 0:
            device.rgb_packet(pts_ns, keyframe=(index == 0))
            device.depth_frame(pts_ns)
            device.hand_joints(pts_ns, hand="left")
            frames += 3

        index += 1
        if not quiet and index % 60 == 0:
            print(f"  sent {frames} frames ({elapsed:.1f}s)", flush=True)

        next_tick += period
        sleep_for = next_tick - time.monotonic()
        if sleep_for > 0:
            time.sleep(sleep_for)
        else:
            next_tick = time.monotonic()

    device.session_end(stream_name=stream_name)
    frames += 1
    return frames


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Synthetic headset that pushes OLCP frames to a Live Feed server.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--host", default="127.0.0.1", help="Live Feed server host")
    parser.add_argument("--push-port", type=int, default=63910, help="OLCP live-push port")
    parser.add_argument("--duration", type=float, default=20.0, help="seconds to stream (0 = forever)")
    parser.add_argument("--rate", type=float, default=30.0, help="pose sample rate in Hz")
    parser.add_argument("--radius", type=float, default=1.0, help="radius of the simulated walk (m)")
    parser.add_argument("--stream-name", default="live_sim_0001", help="session id sent in session_start")
    parser.add_argument("--auth-token", default="", help="token to put in session_start")
    parser.add_argument(
        "--wait", type=float, default=10.0, help="seconds to retry connecting before giving up"
    )
    parser.add_argument("--quiet", action="store_true", help="suppress progress output")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    if not args.quiet:
        print(f"connecting to {args.host}:{args.push_port} ...", flush=True)
    try:
        device = SyntheticHeadset.connect(args.host, args.push_port, retry_for=args.wait)
    except OSError as error:
        print(f"could not connect to {args.host}:{args.push_port}: {error}", file=sys.stderr, flush=True)
        return 1

    try:
        with device:
            if not args.quiet:
                print(f"streaming synthetic session '{args.stream_name}'", flush=True)
            frames = stream_session(
                device,
                duration_s=args.duration,
                rate_hz=args.rate,
                radius=args.radius,
                stream_name=args.stream_name,
                auth_token=args.auth_token,
                quiet=args.quiet,
            )
        if not args.quiet:
            print(f"done: {frames} frames sent", flush=True)
    except KeyboardInterrupt:
        print("\ninterrupted", flush=True)
    except (BrokenPipeError, ConnectionResetError):
        print("server closed the connection", file=sys.stderr, flush=True)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
