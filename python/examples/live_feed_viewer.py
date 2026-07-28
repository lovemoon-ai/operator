#!/usr/bin/env python3
"""Example 1 - one-way Live Feed: headset -> pyoperator, visualised live.

Capture data flows in a single direction.  The headset pushes RGB, depth,
head/controller pose, hand joints and controller input over OLCP; this script
decodes them and draws them in real time.  The live-pull port sends one
``capture_request`` control message so the headset can show and enable those
data types, but no algorithm results are returned.

    headset --OLCP :63910--> LiveFeedReceiver --> typed samples --> viewer

Two visualiser backends:

* ``terminal``  - always available, redraws a per-stream dashboard in place.
* ``rerun``     - real 3D/image visualisation; needs ``pip install rerun-sdk``
                  (and ``ffmpeg`` on PATH for RGB images).

Run::

    python python/examples/live_feed_viewer.py
    python python/examples/live_feed_viewer.py --viewer rerun

Then start Live Feed mode on the headset and point it at this host.
"""

from __future__ import annotations

import argparse
import collections
import math
import shutil
import sys
import time
from pathlib import Path
from typing import Any

# Allow running straight from a source checkout without installing.
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from pyoperator.live_feed import (  # noqa: E402
    ControllerInputSample,
    ControllerPoseSample,
    DepthCameraModel,
    DepthFrameSample,
    HandJointsSample,
    HeadPoseSample,
    LiveFeedReceiver,
    LiveFeedSession,
    ReceiverConfig,
    RgbCameraModel,
    RgbConfigSample,
    RgbFrame,
    RgbPacketSample,
    Sample,
    SessionStartSample,
    Transform,
    apply_transform,
    compose_transform,
)


VIEWER_CAPTURE_REQUEST = {
    "schema": "operator.capture_request.v1",
    "protocol": "operator.live_feed.v2",
    "algorithm": "live_feed_viewer",
    "selected_streams": [
        "session.json",
        "rgb.hevc",
        "depth.u16",
        "head_pose.json",
        "hand_joints.json",
    ],
    "result_streams": [],
    # The XR client maps this to stereo_rgb=false, so the encoder and network
    # carry the left camera only instead of sending a side-by-side stereo frame.
    # Keep the aggregate feed below a typical headset Wi-Fi link: RGB is still
    # HEVC, just at a live-view bitrate/rate instead of the 24 Mbps recording
    # preset. Depth is independently lossless-compressed on the wire.
    "limits": {
        "rgb_eye": "left",
        "rgb_max_hz": 15,
        "rgb_bitrate_bps": 4_000_000,
    },
    "stream_frame_types": {},
}

# Rerun follows the same coordinate contract as spatialmp4_to_rrd.py:
# OpenXR world is RUB (right/up/back), while image cameras are RDF
# (right/down/forward).
OPENXR_DEPTH_EYE_FROM_RDF: Transform = (
    (1.0, 0.0, 0.0, 0.0, -1.0, 0.0, 0.0, 0.0, -1.0),
    (0.0, 0.0, 0.0),
)

XR_HAND_JOINT_NAMES = (
    "PALM",
    "WRIST",
    "THUMB_METACARPAL",
    "THUMB_PROXIMAL",
    "THUMB_DISTAL",
    "THUMB_TIP",
    "INDEX_METACARPAL",
    "INDEX_PROXIMAL",
    "INDEX_INTERMEDIATE",
    "INDEX_DISTAL",
    "INDEX_TIP",
    "MIDDLE_METACARPAL",
    "MIDDLE_PROXIMAL",
    "MIDDLE_INTERMEDIATE",
    "MIDDLE_DISTAL",
    "MIDDLE_TIP",
    "RING_METACARPAL",
    "RING_PROXIMAL",
    "RING_INTERMEDIATE",
    "RING_DISTAL",
    "RING_TIP",
    "LITTLE_METACARPAL",
    "LITTLE_PROXIMAL",
    "LITTLE_INTERMEDIATE",
    "LITTLE_DISTAL",
    "LITTLE_TIP",
)

XR_HAND_BONES = (
    (1, 2), (2, 3), (3, 4), (4, 5),
    (1, 6), (6, 7), (7, 8), (8, 9), (9, 10),
    (1, 11), (11, 12), (12, 13), (13, 14), (14, 15),
    (1, 16), (16, 17), (17, 18), (18, 19), (19, 20),
    (1, 21), (21, 22), (22, 23), (23, 24), (24, 25),
)

HAND_COLORS = {
    "left": (80, 180, 255),
    "right": (255, 160, 80),
}

CONTROLLER_COLORS = {
    "left": (120, 220, 255),
    "right": (255, 200, 120),
}


def set_rerun_time_nanos(rr: Any, timeline: str, nanos: int) -> None:
    """Set a relative Rerun timeline across old and current SDK releases."""
    legacy_set_time = getattr(rr, "set_time_nanos", None)
    if legacy_set_time is not None:
        legacy_set_time(timeline, nanos)
        return
    rr.set_time(timeline, duration=nanos / 1_000_000_000.0)


def rerun_scalar(rr: Any, value: float) -> Any:
    """Build the scalar time-series archetype used by the installed SDK."""
    legacy_scalar = getattr(rr, "Scalar", None)
    if legacy_scalar is not None:
        return legacy_scalar(value)
    return rr.Scalars(value)


def rotation_matrix_to_quaternion_xyzw(rotation: list[float] | tuple[float, ...]) -> tuple[float, float, float, float]:
    """Convert a row-major 3×3 rotation to a normalized Rerun quaternion."""
    m00, m01, m02, m10, m11, m12, m20, m21, m22 = rotation
    trace = m00 + m11 + m22
    if trace > 0.0:
        scale = math.sqrt(trace + 1.0) * 2.0
        qw = 0.25 * scale
        qx = (m21 - m12) / scale
        qy = (m02 - m20) / scale
        qz = (m10 - m01) / scale
    elif m00 > m11 and m00 > m22:
        scale = math.sqrt(max(0.0, 1.0 + m00 - m11 - m22)) * 2.0
        qw = (m21 - m12) / scale
        qx = 0.25 * scale
        qy = (m01 + m10) / scale
        qz = (m02 + m20) / scale
    elif m11 > m22:
        scale = math.sqrt(max(0.0, 1.0 + m11 - m00 - m22)) * 2.0
        qw = (m02 - m20) / scale
        qx = (m01 + m10) / scale
        qy = 0.25 * scale
        qz = (m12 + m21) / scale
    else:
        scale = math.sqrt(max(0.0, 1.0 + m22 - m00 - m11)) * 2.0
        qw = (m10 - m01) / scale
        qx = (m02 + m20) / scale
        qy = (m12 + m21) / scale
        qz = 0.25 * scale
    norm = math.sqrt(qx * qx + qy * qy + qz * qz + qw * qw)
    if norm <= 1e-12:
        return (0.0, 0.0, 0.0, 1.0)
    return (qx / norm, qy / norm, qz / norm, qw / norm)


def log_rerun_transform(
    rr: Any,
    entity_path: str,
    translation: list[float],
    rotation: list[float],
    axis_length: float,
) -> None:
    """Log a transform and its axes across Rerun archetype revisions."""
    transform = rr.Transform3D(
        translation=translation,
        rotation=rr.Quaternion(xyzw=rotation_matrix_to_quaternion_xyzw(rotation)),
    )
    if hasattr(rr, "TransformAxes3D"):
        rr.log(
            entity_path,
            transform,
            rr.TransformAxes3D(axis_length),
        )
        return
    rr.log(entity_path, transform)
    if axis_length > 0.0:
        rr.log(
            f"{entity_path}/axes",
            rr.Arrows3D(
                vectors=[
                    [axis_length, 0.0, 0.0],
                    [0.0, axis_length, 0.0],
                    [0.0, 0.0, axis_length],
                ],
                colors=[[255, 60, 60], [60, 255, 60], [60, 60, 255]],
            ),
        )


def depth_intrinsics(model: DepthCameraModel) -> tuple[float, float, float, float] | None:
    """Resolve depth intrinsics, deriving them from OpenXR FOV tangents."""
    if None not in (model.fx, model.fy, model.cx, model.cy):
        assert model.fx is not None and model.fy is not None
        assert model.cx is not None and model.cy is not None
        return model.fx, model.fy, model.cx, model.cy
    if None in (model.fov_left, model.fov_right, model.fov_top, model.fov_bottom):
        return None
    assert model.fov_left is not None and model.fov_right is not None
    assert model.fov_top is not None and model.fov_bottom is not None
    horizontal = model.fov_left + model.fov_right
    vertical = model.fov_top + model.fov_bottom
    if horizontal <= 0.0 or vertical <= 0.0:
        return None
    fx = model.width / horizontal
    fy = model.height / vertical
    cx = fx * model.fov_left
    cy = fy * model.fov_top
    return fx, fy, cx, cy


def depth_colors(depths_m: list[float], minimum: float = 0.15, maximum: float = 6.0) -> list[list[int]]:
    """Small blue→cyan→yellow→red map matching the reference's depth cue."""
    span = max(1e-6, maximum - minimum)
    colors: list[list[int]] = []
    for depth_m in depths_m:
        value = min(1.0, max(0.0, (depth_m - minimum) / span))
        red = int(255 * min(1.0, max(0.0, 1.5 - abs(4.0 * value - 3.0))))
        green = int(255 * min(1.0, max(0.0, 1.5 - abs(4.0 * value - 2.0))))
        blue = int(255 * min(1.0, max(0.0, 1.5 - abs(4.0 * value - 1.0))))
        colors.append([red, green, blue])
    return colors


def build_rerun_blueprint(rrb: Any, observed_streams: frozenset[str]) -> Any:
    """Build a layout from streams actually observed in the current session."""
    left_children = [rrb.Spatial3DView(name="3D World", origin="world")]
    if "controller_input" in observed_streams:
        left_children.append(
            rrb.TextLogView(name="Controller Input", origin="controller_input")
        )
    left = (
        left_children[0]
        if len(left_children) == 1
        else rrb.Vertical(*left_children, row_shares=[7, 3])
    )

    image_views: list[Any] = []
    if "rgb_left" in observed_streams:
        image_views.append(
            rrb.Spatial2DView(
                name="RGB Left",
                origin="world/camera/left/image",
                contents=["world/camera/left/image/**"],
            )
        )
    if "rgb_right" in observed_streams:
        image_views.append(
            rrb.Spatial2DView(
                name="RGB Right",
                origin="world/camera/right/image",
                contents=["world/camera/right/image/**"],
            )
        )
    if "depth_frame" in observed_streams:
        image_views.append(
            rrb.Spatial2DView(
                name="Depth",
                origin="depth2d",
                contents="depth2d/depth",
            )
        )

    plot_streams = {
        "rgb_packet",
        "depth_frame",
        "head_pose",
        "controller_pose",
        "controller_input",
        "hand_joints",
    }
    right_children: list[Any] = []
    if image_views:
        right_children.append(
            image_views[0] if len(image_views) == 1 else rrb.Tabs(*image_views)
        )
    if observed_streams & plot_streams:
        right_children.append(
            rrb.TimeSeriesView(name="Streams + Inputs", origin="plots")
        )
    if not right_children:
        return left
    right = (
        right_children[0]
        if len(right_children) == 1
        else rrb.Vertical(*right_children, row_shares=[7, 3])
    )
    return rrb.Horizontal(left, right, column_shares=[2, 1])


class RateTracker:
    """Rolling arrival-rate estimate over a short window."""

    def __init__(self, window_s: float = 3.0) -> None:
        self.window_s = window_s
        self._times: collections.deque[float] = collections.deque()
        self.total = 0

    def tick(self, now: float | None = None) -> None:
        now = time.monotonic() if now is None else now
        self.total += 1
        self._times.append(now)
        self._trim(now)

    def hz(self, now: float | None = None) -> float:
        now = time.monotonic() if now is None else now
        self._trim(now)
        if len(self._times) < 2:
            return 0.0
        span = self._times[-1] - self._times[0]
        if span <= 0.0:
            return 0.0
        return (len(self._times) - 1) / span

    def _trim(self, now: float) -> None:
        cutoff = now - self.window_s
        while self._times and self._times[0] < cutoff:
            self._times.popleft()


class StreamState:
    """Everything the dashboard needs to know about the current session."""

    def __init__(self) -> None:
        self.rates: dict[str, RateTracker] = collections.defaultdict(RateTracker)
        self.session_id = ""
        self.device_note = ""
        self.expected_streams: tuple[str, ...] = ()
        self.newest_pts_ns = 0

        self.head_position: tuple[float, float, float] | None = None
        self.head_valid = False
        self.head_path_m = 0.0
        self._last_head: tuple[float, float, float] | None = None

        self.controllers: dict[str, tuple[float, float, float]] = {}
        self.controller_input: dict[str, ControllerInputSample] = {}
        self.hands: dict[str, int] = {}

        self.rgb_config: dict[str, Any] = {}
        self.rgb_bytes = 0
        self.rgb_keyframes = 0
        self.depth_size = (0, 0)
        self.depth_valid_ratio = 0.0
        self.depth_mean_m = 0.0
        self.rgb_frames_decoded = 0
        self.rgb_decoder_note = ""

    def update(self, sample: Sample) -> None:
        self.rates[sample.kind].tick()
        self.newest_pts_ns = max(self.newest_pts_ns, sample.pts_ns)

        if isinstance(sample, SessionStartSample):
            self.session_id = sample.session_id
            self.expected_streams = sample.expected_streams()
            width, height = sample.rgb_size
            self.device_note = f"contract v{sample.contract_version} rgb {width}x{height}"
        elif isinstance(sample, HeadPoseSample):
            self.head_valid = sample.tracking_valid
            position = sample.position
            self.head_position = position
            if self._last_head is not None:
                self.head_path_m += math.dist(self._last_head, position)
            self._last_head = position
        elif isinstance(sample, ControllerPoseSample):
            self.controllers[sample.hand] = sample.position
        elif isinstance(sample, ControllerInputSample):
            self.controller_input[sample.hand] = sample
        elif isinstance(sample, HandJointsSample):
            self.hands[sample.hand] = sample.joint_count
        elif isinstance(sample, RgbConfigSample):
            self.rgb_config = sample.config
        elif isinstance(sample, RgbPacketSample):
            self.rgb_bytes += sample.size_bytes
            if sample.keyframe:
                self.rgb_keyframes += 1
        elif isinstance(sample, DepthFrameSample):
            self._update_depth(sample)

    def _update_depth(self, sample: DepthFrameSample) -> None:
        self.depth_size = (sample.width, sample.height)
        if not sample.has_pixels():
            return
        # Sample a sparse grid; scanning every pixel per frame is wasted work
        # for a status readout.
        width, height = sample.width, sample.height
        step = max(1, min(width, height) // 32)
        total = 0
        valid = 0
        depth_sum = 0.0
        for y in range(0, height, step):
            for x in range(0, width, step):
                total += 1
                depth_mm = sample.depth_mm_at(x, y)
                if depth_mm > 0:
                    valid += 1
                    depth_sum += depth_mm / 1000.0
        if total:
            self.depth_valid_ratio = valid / total
        self.depth_mean_m = depth_sum / valid if valid else 0.0


class TerminalVisualizer:
    """Dependency-free dashboard that redraws in place."""

    name = "terminal"

    def __init__(self, refresh_hz: float = 8.0) -> None:
        self.interval = 1.0 / max(1.0, refresh_hz)
        self._last_draw = 0.0
        self._lines_drawn = 0

    def setup(self) -> None:
        print("waiting for headset live-push connection...", flush=True)

    def on_sample(self, sample: Sample, state: StreamState) -> None:
        return

    def render(self, state: StreamState, session: LiveFeedSession, force: bool = False) -> None:
        now = time.monotonic()
        if not force and now - self._last_draw < self.interval:
            return
        self._last_draw = now

        width = shutil.get_terminal_size((100, 30)).columns
        lines: list[str] = []
        lines.append(f"session {state.session_id or '<pending>'}  {state.device_note}")
        if state.expected_streams:
            lines.append(f"headset announced: {', '.join(state.expected_streams)}")
        lines.append("-" * min(width, 78))

        for kind in (
            "rgb_packet",
            "depth_frame",
            "head_pose",
            "controller_pose",
            "controller_input",
            "hand_joints",
        ):
            tracker = state.rates.get(kind)
            if tracker is None or tracker.total == 0:
                lines.append(f"  {kind:<18} {'--':>8}      0")
                continue
            lines.append(f"  {kind:<18} {tracker.hz(now):>6.1f}Hz {tracker.total:>7}")

        lines.append("-" * min(width, 78))
        if state.head_position is not None:
            x, y, z = state.head_position
            flag = "" if state.head_valid else "  [TRACKING LOST]"
            lines.append(f"  head      x={x:+.3f} y={y:+.3f} z={z:+.3f}  path={state.head_path_m:.2f}m{flag}")
        for hand in ("left", "right"):
            position = state.controllers.get(hand)
            controls = state.controller_input.get(hand)
            if position is None and controls is None:
                continue
            parts = [f"  {hand:<9}"]
            if position is not None:
                parts.append(f"x={position[0]:+.3f} y={position[1]:+.3f} z={position[2]:+.3f}")
            if controls is not None:
                parts.append(f"trig={controls.trigger:.2f} grip={controls.grip:.2f}")
                stick = controls.thumbstick
                parts.append(f"stick=({stick[0]:+.2f},{stick[1]:+.2f})")
                pressed = controls.pressed_buttons()
                if pressed:
                    parts.append("[" + ",".join(pressed) + "]")
            lines.append(" ".join(parts))
        for hand, count in sorted(state.hands.items()):
            lines.append(f"  hand {hand:<4} joints={count}")

        if state.depth_size != (0, 0):
            lines.append(
                f"  depth     {state.depth_size[0]}x{state.depth_size[1]}"
                f"  valid={state.depth_valid_ratio * 100:.0f}%  mean={state.depth_mean_m:.2f}m"
            )
        if state.rgb_config:
            codec = state.rgb_config.get("codec", "?")
            layout = state.rgb_config.get("stereo_layout", "?")
            lines.append(
                f"  rgb       {state.rgb_config.get('width', 0)}x{state.rgb_config.get('height', 0)}"
                f" {codec} {layout}  {state.rgb_bytes / (1024 * 1024):.1f}MiB"
                f"  keyframes={state.rgb_keyframes}"
            )
        if state.rgb_decoder_note:
            lines.append(f"  decoder   {state.rgb_decoder_note}")

        lines.append("-" * min(width, 78))
        lines.append(f"  {session.stats.summary()}")

        self._clear()
        body = "\n".join(line[: width - 1] for line in lines)
        print(body, flush=True)
        self._lines_drawn = len(lines)

    def _clear(self) -> None:
        if self._lines_drawn:
            sys.stdout.write(f"\033[{self._lines_drawn}A\033[J")

    def teardown(self, state: StreamState) -> None:
        print()


class RerunVisualizer:
    """Rerun backend: images, 3D poses, hand skeletons, depth point clouds."""

    name = "rerun"

    def __init__(self, app_id: str = "operator-live-feed", spawn: bool = True) -> None:
        try:
            import rerun as rr  # type: ignore[import-not-found]
            import rerun.blueprint as rrb  # type: ignore[import-not-found]
        except ImportError as error:  # pragma: no cover - depends on optional dep
            raise SystemExit(
                "rerun backend needs the SDK: pip install rerun-sdk\n"
                f"(import failed: {error})"
            ) from error
        self.rr = rr
        self.rrb = rrb
        self.app_id = app_id
        self.spawn = spawn
        self._reset_session_state()

    def _reset_session_state(self) -> None:
        self._trail: collections.deque[tuple[float, float, float]] = collections.deque(maxlen=2000)
        self._head_history: collections.deque[tuple[int, Transform]] = collections.deque(maxlen=2000)
        self._rgb_cameras: tuple[RgbCameraModel, ...] = ()
        self._rgb_pinhole_signature: tuple[Any, ...] = ()
        self._depth_pinhole_signature: tuple[Any, ...] = ()
        self._observed_streams: set[str] = set()
        self._blueprint_signature: frozenset[str] | None = None
        self._floor_logged = False
        self._last_stats_log = 0.0

    def setup(self) -> None:
        self.rr.init(self.app_id, spawn=self.spawn)
        self._update_blueprint(force=True)
        self._log_static_scene()

    def _observe(self, *stream_names: str) -> None:
        before = len(self._observed_streams)
        self._observed_streams.update(stream_names)
        if len(self._observed_streams) != before:
            self._update_blueprint()

    def _update_blueprint(self, force: bool = False) -> None:
        signature = frozenset(self._observed_streams)
        if not force and signature == self._blueprint_signature:
            return
        self._blueprint_signature = signature
        self.rr.send_blueprint(build_rerun_blueprint(self.rrb, signature))

    def _log_static_scene(self) -> None:
        rr = self.rr
        rr.log("world", rr.ViewCoordinates.RUB, static=True)
        rr.log(
            "world/xyz",
            rr.Arrows3D(
                vectors=[[0.5, 0.0, 0.0], [0.0, 0.5, 0.0], [0.0, 0.0, 0.5]],
                colors=[[255, 60, 60], [60, 255, 60], [60, 60, 255]],
                labels=["X+", "Y+", "Z+"],
            ),
            static=True,
        )

    def _begin_session(self) -> None:
        rr = self.rr
        clear = getattr(rr, "Clear", None)
        if clear is not None:
            rr.log("/", clear(recursive=True), static=True)
        self._reset_session_state()
        self._log_static_scene()
        self._update_blueprint(force=True)

    def on_sample(self, sample: Sample, state: StreamState) -> None:
        rr = self.rr
        # pts_ns is the headset's monotonic clock; use it as the timeline so
        # streams line up with each other rather than with host wall time.
        set_rerun_time_nanos(rr, "headset_pts", sample.pts_ns)

        if isinstance(sample, SessionStartSample):
            self._begin_session()
        elif isinstance(sample, RgbConfigSample):
            self._rgb_cameras = sample.cameras
            self._log_rgb_pinholes(sample.cameras)
        elif isinstance(sample, HeadPoseSample):
            self._observe("head_pose")
            self._log_head(sample)
        elif isinstance(sample, ControllerPoseSample):
            self._observe("controller_pose")
            self._log_controller(sample)
        elif isinstance(sample, ControllerInputSample):
            self._observe("controller_input")
            for axis, value in sample.numeric_axes().items():
                rr.log(f"plots/controller/{sample.hand}/{axis}", rerun_scalar(rr, value))
            pressed = ", ".join(sample.pressed_buttons()) or "-"
            packet = "snapshot" if sample.is_snapshot else "event"
            rr.log(
                f"controller_input/{sample.hand}",
                rr.TextLog(f"{packet}: {pressed}"),
            )
        elif isinstance(sample, HandJointsSample):
            self._observe("hand_joints")
            self._log_hand(sample)
        elif isinstance(sample, DepthFrameSample):
            if sample.has_pixels():
                self._observe("depth_frame")
                self._log_depth(sample)
        elif isinstance(sample, RgbPacketSample):
            self._observe("rgb_packet")
            rr.log("plots/rgb/packet_bytes", rerun_scalar(rr, float(sample.size_bytes)))

    def _log_head(self, sample: HeadPoseSample) -> None:
        rr = self.rr
        rotation, translation = sample.transform
        self._head_history.append((sample.pts_ns, sample.transform))
        log_rerun_transform(
            rr,
            "world/rigid/head",
            list(translation),
            list(rotation),
            0.1,
        )
        rr.log(
            "world/rigid/head/marker",
            rr.Points3D(
                positions=[list(translation)],
                colors=[[220, 220, 220]],
                radii=[0.02],
            ),
        )
        forward = [-rotation[2] * 0.5, -rotation[5] * 0.5, -rotation[8] * 0.5]
        rr.log(
            "world/rigid/head/gaze",
            rr.Arrows3D(
                origins=[list(translation)],
                vectors=[forward],
                colors=[[255, 80, 200]],
                radii=0.015,
            ),
        )
        self._trail.append(translation)
        if len(self._trail) > 1:
            rr.log(
                "world/trajectory/head",
                rr.LineStrips3D(
                    [list(self._trail)],
                    colors=[[255, 215, 0]],
                    radii=0.01,
                ),
            )
        rr.log(
            "plots/tracking/head_valid",
            rerun_scalar(rr, 1.0 if sample.tracking_valid else 0.0),
        )
        if not self._floor_logged:
            self._log_floor(translation[1] - 1.2)
            self._floor_logged = True

    def _log_floor(self, y: float) -> None:
        strips: list[list[list[float]]] = []
        for coordinate in range(-4, 5):
            value = float(coordinate)
            strips.append([[value, y, -4.0], [value, y, 4.0]])
            strips.append([[-4.0, y, value], [4.0, y, value]])
        self.rr.log(
            "world/floor",
            self.rr.LineStrips3D(
                strips,
                colors=[[80, 80, 80]] * len(strips),
                radii=0.002,
            ),
            static=True,
        )

    def _log_controller(self, sample: ControllerPoseSample) -> None:
        rr = self.rr
        rotation, translation = sample.transform
        entity_path = f"world/rigid/{sample.hand}_controller"
        log_rerun_transform(
            rr,
            entity_path,
            list(translation),
            list(rotation),
            0.08,
        )
        rr.log(
            f"{entity_path}/marker",
            rr.Points3D(
                positions=[list(translation)],
                colors=[CONTROLLER_COLORS.get(sample.hand, (220, 220, 220))],
                radii=[0.015],
            ),
        )
        rr.log(
            f"plots/tracking/{sample.hand}_controller_valid",
            rerun_scalar(rr, 1.0 if sample.tracking_valid else 0.0),
        )

    def _log_hand(self, sample: HandJointsSample) -> None:
        rr = self.rr
        color = HAND_COLORS.get(sample.hand, (200, 200, 200))
        positions = [list(joint.position) for joint in sample.joints]
        radii = [max(0.004, joint.radius_m) for joint in sample.joints]
        labels = [
            XR_HAND_JOINT_NAMES[joint.index]
            if 0 <= joint.index < len(XR_HAND_JOINT_NAMES)
            else f"J{joint.index}"
            for joint in sample.joints
        ]
        joints_path = f"world/hands/{sample.hand}/joints"
        bones_path = f"world/hands/{sample.hand}/bones"
        rr.log(
            joints_path,
            rr.Points3D(
                positions,
                radii=radii,
                colors=[color] * len(positions),
                labels=labels,
                show_labels=False,
            ),
        )
        position_by_id = {
            joint.index: list(joint.position)
            for joint in sample.joints
        }
        strips = [
            [position_by_id[parent], position_by_id[child]]
            for parent, child in XR_HAND_BONES
            if parent in position_by_id and child in position_by_id
        ]
        rr.log(
            bones_path,
            rr.LineStrips3D(
                strips,
                colors=[color] * len(strips),
                radii=0.0025,
            ),
        )

    def _head_transform_nearest(self, pts_ns: int) -> Transform | None:
        if not self._head_history:
            return None
        return min(self._head_history, key=lambda item: abs(item[0] - pts_ns))[1]

    @staticmethod
    def _camera_label(index: int) -> str:
        if index == 0:
            return "left"
        if index == 1:
            return "right"
        return f"camera_{index}"

    def _log_rgb_pinholes(self, cameras: tuple[RgbCameraModel, ...]) -> None:
        signature = tuple(
            (camera.index, camera.width, camera.height, camera.fx, camera.fy, camera.cx, camera.cy)
            for camera in cameras
        )
        if not signature or signature == self._rgb_pinhole_signature:
            return
        self._rgb_pinhole_signature = signature
        rr = self.rr
        for camera in cameras:
            label = self._camera_label(camera.index)
            rr.log(
                f"world/camera/{label}/image",
                rr.Pinhole(
                    resolution=[camera.width, camera.height],
                    focal_length=[camera.fx, camera.fy],
                    principal_point=[camera.cx, camera.cy],
                    camera_xyz=rr.ViewCoordinates.RDF,
                ),
                static=True,
            )

    def log_rgb_frame(self, frame: RgbFrame) -> None:
        try:
            import numpy as np
        except ImportError:
            return
        rr = self.rr
        set_rerun_time_nanos(rr, "headset_pts", frame.pts_ns)
        image = np.frombuffer(frame.data, dtype=np.uint8).reshape(frame.height, frame.width, 3)
        cameras = frame.cameras or self._rgb_cameras
        if not cameras:
            cameras = (
                RgbCameraModel(
                    index=0,
                    width=frame.width,
                    height=frame.height,
                    fx=frame.width / 2.0,
                    fy=frame.width / 2.0,
                    cx=frame.width / 2.0,
                    cy=frame.height / 2.0,
                ),
            )
        if frame.stereo_layout != "side_by_side":
            cameras = cameras[:1]
        observed_rgb = ["rgb_left"]
        if frame.stereo_layout == "side_by_side" and len(cameras) > 1:
            observed_rgb.append("rgb_right")
        self._observe(*observed_rgb)
        self._log_rgb_pinholes(cameras)

        head_transform = self._head_transform_nearest(frame.pts_ns)
        offset_x = 0
        for camera in cameras:
            label = self._camera_label(camera.index)
            if frame.stereo_layout == "side_by_side":
                width = min(camera.width, max(0, frame.width - offset_x))
                eye_image = image[:, offset_x : offset_x + width]
                offset_x += camera.width
            else:
                eye_image = image
            if eye_image.size == 0:
                continue
            rr.log(
                f"world/camera/{label}/image",
                rr.Image(eye_image, color_model="RGB"),
            )
            if head_transform is None:
                continue
            local_from_camera = camera.local_from_camera or OPENXR_DEPTH_EYE_FROM_RDF
            world_from_camera = compose_transform(head_transform, local_from_camera)
            rotation, translation = world_from_camera
            log_rerun_transform(
                rr,
                f"world/camera/{label}",
                list(translation),
                list(rotation),
                0.0,
            )

    def _log_depth(self, sample: DepthFrameSample) -> None:
        rr = self.rr
        if not sample.has_pixels():
            return
        try:
            import numpy as np
        except ImportError:
            return

        depth_mm = np.frombuffer(sample.depth_bytes, dtype="<u2").reshape(sample.height, sample.width)
        # OpenXR environment depth has its first stored row at the bottom.
        # Log metric float data, matching spatialmp4_to_rrd.py. Keeping the
        # uint16 millimetre buffer while using a metre-valued depth_range makes
        # virtually every valid pixel clamp to the same color.
        depth_for_2d = np.flipud(depth_mm).astype(np.float32) / 1000.0
        rr.log(
            "depth2d/depth",
            rr.DepthImage(
                depth_for_2d,
                meter=1.0,
                depth_range=(0.15, 6.0),
                colormap="turbo",
            ),
        )

        model = sample.model
        if model is None:
            return
        intrinsics = depth_intrinsics(model)
        signature = (
            model.width,
            model.height,
            intrinsics,
        )
        if intrinsics is not None and signature != self._depth_pinhole_signature:
            self._depth_pinhole_signature = signature
            fx, fy, cx, cy = intrinsics
            rr.log(
                "world/depth_camera/image",
                rr.Pinhole(
                    resolution=[model.width, model.height],
                    focal_length=[fx, fy],
                    principal_point=[cx, (model.height - 1) - cy],
                    camera_xyz=rr.ViewCoordinates.RDF,
                ),
                static=True,
            )

        world_from_depth_eye: Transform | None
        if model.depth_eye_to_local is not None and model.depth_eye_transform_is_absolute:
            world_from_depth_eye = model.depth_eye_to_local
        else:
            head_transform = self._head_transform_nearest(sample.pts_ns)
            if head_transform is None:
                world_from_depth_eye = None
            elif model.depth_eye_to_local is None:
                world_from_depth_eye = head_transform
            else:
                world_from_depth_eye = compose_transform(head_transform, model.depth_eye_to_local)
        if world_from_depth_eye is None:
            return

        world_from_depth_camera = compose_transform(
            world_from_depth_eye,
            OPENXR_DEPTH_EYE_FROM_RDF,
        )
        rotation, translation = world_from_depth_camera
        log_rerun_transform(
            rr,
            "world/depth_camera",
            list(translation),
            list(rotation),
            0.0,
        )

        points_depth_eye = list(
            sample.iter_points(
                stride=4,
                min_depth_m=0.15,
                max_depth_m=6.0,
                max_points=20000,
            )
        )
        points_world = [
            list(apply_transform(world_from_depth_eye, point))
            for point in points_depth_eye
        ]
        depths_m = [-point[2] for point in points_depth_eye]
        rr.log(
            "world/depth_pointcloud",
            rr.Points3D(
                points_world,
                colors=depth_colors(depths_m),
                radii=0.006,
            ),
        )

    def render(self, state: StreamState, session: LiveFeedSession, force: bool = False) -> None:
        rr = self.rr
        now = time.monotonic()
        if not force and now - self._last_stats_log < 0.25:
            return
        self._last_stats_log = now
        for kind, tracker in state.rates.items():
            rr.log(f"plots/rates/{kind}", rerun_scalar(rr, tracker.hz(now)))
        rr.log("plots/stats/dropped", rerun_scalar(rr, float(session.stats.dropped)))

    def teardown(self, state: StreamState) -> None:
        return


def log_rgb_frames(session: LiveFeedSession, visualizer: Any, state: StreamState) -> None:
    """Push any newly decoded RGB frame into the visualiser."""
    decoder = session.rgb_decoder
    if decoder is None:
        return
    state.rgb_decoder_note = decoder.disabled_reason or f"ffmpeg {decoder.decoded_count} frames"
    if decoder.decoded_count == state.rgb_frames_decoded:
        return
    state.rgb_frames_decoded = decoder.decoded_count
    frame = decoder.latest_frame()
    if frame is None or not isinstance(visualizer, RerunVisualizer):
        return
    visualizer.log_rgb_frame(frame)


def build_visualizer(name: str) -> Any:
    if name == "rerun":
        return RerunVisualizer()
    if name == "terminal":
        return TerminalVisualizer()
    # auto
    try:
        import rerun  # noqa: F401
    except ImportError:
        return TerminalVisualizer()
    return RerunVisualizer()


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--host", default="0.0.0.0", help="bind address for the push listener")
    parser.add_argument("--push-port", type=int, default=63910, help="OLCP live-push port")
    parser.add_argument("--result-port", type=int, default=63912, help="OLCP live-pull port")
    parser.add_argument(
        "--no-accept-results",
        action="store_true",
        help="do not listen on the live-pull port at all (headset will retry connecting)",
    )
    parser.add_argument("--viewer", choices=("auto", "terminal", "rerun"), default="auto")
    parser.add_argument(
        "--decode-rgb",
        action=argparse.BooleanOptionalAction,
        default=None,
        help="decode RGB via ffmpeg (default: on for Rerun, off for terminal)",
    )
    parser.add_argument("--ffmpeg", default="ffmpeg", help="ffmpeg binary to use for RGB decoding")
    parser.add_argument("--record-dir", type=Path, default=None, help="also persist the raw stream here")
    parser.add_argument("--auth-token", default="", help="require this token in session_start")
    parser.add_argument("--max-queue", type=int, default=256, help="bounded queue depth per session")
    parser.add_argument("--no-qr", action="store_true", help="do not print the connection QR code")
    parser.add_argument("--once", action="store_true", help="exit after the first session ends")
    return parser.parse_args(argv)


def run_session(session: LiveFeedSession, visualizer: Any) -> StreamState:
    state = StreamState()
    for sample in session.samples():
        state.update(sample)
        visualizer.on_sample(sample, state)
        log_rgb_frames(session, visualizer, state)
        visualizer.render(state, session)
    visualizer.render(state, session, force=True)
    return state


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    visualizer = build_visualizer(args.viewer)

    config = ReceiverConfig(
        host=args.host,
        push_port=args.push_port,
        result_host=args.host,
        result_port=args.result_port,
        # Accept the live-pull connection but never publish: this example is
        # headset -> pyoperator except for the one capture-request control
        # message that makes the requested data types visible in the XR UI.
        accept_results=not args.no_accept_results,
        publish_results=False,
        capture_request=VIEWER_CAPTURE_REQUEST,
        max_queue=args.max_queue,
        auth_token=args.auth_token,
        record_dir=args.record_dir,
        decode_rgb=(
            args.decode_rgb
            if args.decode_rgb is not None
            else isinstance(visualizer, RerunVisualizer)
        ),
        ffmpeg_bin=args.ffmpeg,
        quiet=isinstance(visualizer, TerminalVisualizer),
        # The terminal dashboard silences runtime logs, but the connection
        # banner still has to show -- it is how the operator finds this host.
        show_connection_banner=True,
        show_qr=not args.no_qr,
        banner_label="Live Feed viewer",
    )

    visualizer.setup()
    print(
        f"live feed viewer [{visualizer.name}] — input data types announced; "
        "algorithm results disabled",
        flush=True,
    )

    try:
        with LiveFeedReceiver(config) as receiver:
            for session in receiver.sessions():
                state = run_session(session, visualizer)
                visualizer.teardown(state)
                print(f"session ended: {session.stats.summary()}", flush=True)
                if session.error is not None:
                    print(f"stream error: {session.error}", file=sys.stderr, flush=True)
                if args.once:
                    break
    except KeyboardInterrupt:
        print("\ninterrupted", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
