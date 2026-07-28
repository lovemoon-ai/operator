"""Typed Live Feed sample models, camera models, and rigid-transform helpers.

This module holds the pure-data layer of the Live Feed stack: it turns raw OLCP
:class:`~pyoperator.live_feed.protocol.StreamEvent` frames into typed samples
that examples and algorithms can consume without touching sockets, files, or
queues.  Nothing here performs I/O.
"""

from __future__ import annotations

import base64
import dataclasses
import json
import math
import struct
from typing import Any, Iterator, Sequence

from .protocol import (
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
    StreamEvent,
    decode_transport_payload,
    parse_composite_payload,
)


Transform = tuple[tuple[float, float, float, float, float, float, float, float, float], tuple[float, float, float]]
Vec3 = tuple[float, float, float]

DEPTH_PIXEL = struct.Struct("<H")


# ---------------------------------------------------------------------------
# scalar helpers
# ---------------------------------------------------------------------------


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


# ---------------------------------------------------------------------------
# rigid transforms
# ---------------------------------------------------------------------------


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


def apply_transform(transform: Transform, point: Vec3) -> Vec3:
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


# ---------------------------------------------------------------------------
# camera models
# ---------------------------------------------------------------------------


@dataclasses.dataclass(frozen=True)
class PoseSample:
    """A rigid pose sampled at ``pts_ns`` in the Godot monotonic time domain."""

    pts_ns: int
    transform: Transform
    tracking_valid: bool

    @property
    def position(self) -> Vec3:
        return self.transform[1]


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

    def unproject(self, pixel_x: float, pixel_y: float, depth_m: float) -> Vec3 | None:
        """Unproject a depth pixel to a point in the depth-eye frame (OpenXR, -Z forward)."""
        if None not in (self.fx, self.fy, self.cx, self.cy):
            assert self.fx is not None and self.fy is not None and self.cx is not None and self.cy is not None
            if abs(self.fx) < 1e-6 or abs(self.fy) < 1e-6:
                return None
            x = (pixel_x - self.cx) / self.fx * depth_m
            y = -(pixel_y - self.cy) / self.fy * depth_m
            return (x, y, -depth_m)
        if None not in (self.fov_left, self.fov_right, self.fov_top, self.fov_bottom):
            assert self.fov_left is not None
            assert self.fov_right is not None
            assert self.fov_top is not None
            assert self.fov_bottom is not None
            nx = pixel_x / float(self.width)
            ny = pixel_y / float(self.height)
            x = (-self.fov_left + nx * (self.fov_left + self.fov_right)) * depth_m
            y = (self.fov_top - ny * (self.fov_top + self.fov_bottom)) * depth_m
            return (x, y, -depth_m)
        return None


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
    """A decoded RGB24 frame; ``data`` is ``width * height * 3`` bytes."""

    pts_ns: int
    width: int
    height: int
    stereo_layout: str
    cameras: tuple[RgbCameraModel, ...]
    data: bytes

    @property
    def camera_count(self) -> int:
        return max(1, len(self.cameras))

    def eye_width(self) -> int:
        if self.stereo_layout == "side_by_side" and self.camera_count > 1:
            return self.width // self.camera_count
        return self.width


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


# ---------------------------------------------------------------------------
# typed samples
# ---------------------------------------------------------------------------


@dataclasses.dataclass(frozen=True)
class Sample:
    """Base class for every typed Live Feed sample.

    ``kind`` is a stable string (``"head_pose"``, ``"depth_frame"``, ...) so
    example code can branch without importing OLCP frame-type constants.
    """

    kind: str
    frame_type: int
    pts_ns: int
    recv_monotonic_ns: int


@dataclasses.dataclass(frozen=True)
class SessionStartSample(Sample):
    info: dict[str, Any]

    @property
    def session_id(self) -> str:
        """The headset calls this ``stream_name``; older payloads used ``session_id``."""
        return str(self.info.get("stream_name", self.info.get("session_id", "")))

    @property
    def protocol(self) -> str:
        return str(self.info.get("protocol", "operator.live_feed.v1"))

    @property
    def contract_version(self) -> int:
        return as_finite_int(self.info.get("contract_version")) or 0

    @property
    def rgb_size(self) -> tuple[int, int]:
        return (
            as_finite_int(self.info.get("rgb_width")) or 0,
            as_finite_int(self.info.get("rgb_height")) or 0,
        )

    def expected_streams(self) -> tuple[str, ...]:
        """Streams the headset announced it will send, from the ``*_expected`` flags."""
        mapping = {
            "depth_expected": "depth",
            "head_pose_expected": "head_pose",
            "controller_pose_expected": "controller_pose",
            "hand_joints_expected": "hand_joints",
            "controller_input_expected": "controller_input",
        }
        return tuple(name for key, name in sorted(mapping.items()) if bool(self.info.get(key)))


@dataclasses.dataclass(frozen=True)
class SessionEndSample(Sample):
    info: dict[str, Any]

    @property
    def session_id(self) -> str:
        return str(self.info.get("stream_name", self.info.get("session_id", "")))

    @property
    def reason(self) -> str:
        return str(self.info.get("reason", ""))


@dataclasses.dataclass(frozen=True)
class RgbConfigSample(Sample):
    """RGB codec-specific data (``rgb_csd``) plus the stream's camera models."""

    config: dict[str, Any]
    cameras: tuple[RgbCameraModel, ...]

    @property
    def width(self) -> int:
        return as_finite_int(self.config.get("width")) or 0

    @property
    def height(self) -> int:
        return as_finite_int(self.config.get("height")) or 0

    @property
    def stereo_layout(self) -> str:
        return str(self.config.get("stereo_layout", "mono"))

    def csd_bytes(self) -> bytes:
        encoded = str(self.config.get("csd_base64", ""))
        if not encoded:
            return b""
        try:
            return base64.b64decode(encoded)
        except Exception:
            return b""


@dataclasses.dataclass(frozen=True)
class RgbPacketSample(Sample):
    """One HEVC/H.264 Annex-B access unit."""

    payload: bytes
    keyframe: bool

    @property
    def size_bytes(self) -> int:
        return len(self.payload)


@dataclasses.dataclass(frozen=True)
class DepthMetadataSample(Sample):
    metadata: dict[str, Any]
    model: DepthCameraModel | None


@dataclasses.dataclass(frozen=True)
class DepthFrameSample(Sample):
    """A 16-bit-millimetre depth image plus the camera model needed to unproject it."""

    metadata: dict[str, Any]
    depth_bytes: bytes
    model: DepthCameraModel | None

    @property
    def width(self) -> int:
        return self.model.width if self.model is not None else 0

    @property
    def height(self) -> int:
        return self.model.height if self.model is not None else 0

    def has_pixels(self) -> bool:
        return self.width > 0 and self.height > 0 and len(self.depth_bytes) >= self.width * self.height * 2

    def depth_mm_at(self, x: int, y: int) -> int:
        offset = (y * self.width + x) * 2
        return DEPTH_PIXEL.unpack_from(self.depth_bytes, offset)[0]

    def iter_points(
        self,
        *,
        stride: int = 1,
        min_depth_m: float = 0.1,
        max_depth_m: float = 8.0,
        max_points: int | None = None,
        world_from_depth_eye: Transform | None = None,
    ) -> Iterator[Vec3]:
        """Unproject depth pixels, optionally into a world frame.

        Yields at most ``max_points`` points; pixels outside the depth range and
        zero (invalid) pixels are skipped.
        """
        model = self.model
        if model is None or not model.has_projection() or not self.has_pixels():
            return
        step = max(1, stride)
        emitted = 0
        for y in range(0, model.height, step):
            for x in range(0, model.width, step):
                if max_points is not None and emitted >= max_points:
                    return
                depth_mm = self.depth_mm_at(x, y)
                if depth_mm <= 0:
                    continue
                depth_m = depth_mm / 1000.0
                if depth_m < min_depth_m or depth_m > max_depth_m:
                    continue
                point = model.unproject(x + 0.5, y + 0.5, depth_m)
                if point is None:
                    return
                if world_from_depth_eye is not None:
                    point = apply_transform(world_from_depth_eye, point)
                if not all(math.isfinite(value) for value in point):
                    continue
                emitted += 1
                yield point


@dataclasses.dataclass(frozen=True)
class HeadPoseSample(Sample):
    pose: PoseSample
    payload: dict[str, Any]

    @property
    def transform(self) -> Transform:
        return self.pose.transform

    @property
    def position(self) -> Vec3:
        return self.pose.transform[1]

    @property
    def tracking_valid(self) -> bool:
        return self.pose.tracking_valid


@dataclasses.dataclass(frozen=True)
class ControllerPoseSample(Sample):
    hand: str
    pose: PoseSample
    payload: dict[str, Any]

    @property
    def transform(self) -> Transform:
        return self.pose.transform

    @property
    def position(self) -> Vec3:
        return self.pose.transform[1]

    @property
    def tracking_valid(self) -> bool:
        return self.pose.tracking_valid


#: Bit positions of the ``pressed_mask`` / ``touched_mask`` fields in
#: ``controller_input``. Mirrors ``xr/scripts/core/sensors/pose_sampler.gd``.
#: A/B exist only on the right controller, X/Y only on the left.
CONTROLLER_BUTTON_BITS: dict[str, int] = {
    "trigger_click": 1 << 0,
    "trigger_touch": 1 << 1,
    "grip_click": 1 << 2,
    "thumbstick_click": 1 << 3,
    "thumbstick_touch": 1 << 4,
    "a": 1 << 5,
    "a_touch": 1 << 6,
    "b": 1 << 7,
    "b_touch": 1 << 8,
    "x": 1 << 9,
    "x_touch": 1 << 10,
    "y": 1 << 11,
    "y_touch": 1 << 12,
    "menu": 1 << 13,
    "system": 1 << 14,
    "thumbrest_touch": 1 << 15,
    "trackpad_click": 1 << 16,
    "trackpad_touch": 1 << 17,
}

#: ``packet_type`` values on ``controller_input``.
CONTROLLER_PACKET_SNAPSHOT = 1
CONTROLLER_PACKET_EVENT = 2


def decode_button_mask(mask: int) -> tuple[str, ...]:
    """Expand a controller bitmask into sorted button names."""
    return tuple(sorted(name for name, bit in CONTROLLER_BUTTON_BITS.items() if mask & bit))


@dataclasses.dataclass(frozen=True)
class ControllerInputSample(Sample):
    """Controller buttons and axes.

    The wire format carries bitmasks rather than named booleans, so button state
    is exposed through :meth:`pressed_buttons` / :meth:`is_pressed`.
    """

    hand: str
    payload: dict[str, Any]

    @property
    def packet_type(self) -> int:
        return as_finite_int(self.payload.get("packet_type")) or 0

    @property
    def is_snapshot(self) -> bool:
        return self.packet_type == CONTROLLER_PACKET_SNAPSHOT

    @property
    def trigger(self) -> float:
        return self.axis("trigger_value")

    @property
    def grip(self) -> float:
        return self.axis("grip_value")

    @property
    def thumbstick(self) -> tuple[float, float]:
        return self._vec2("thumbstick")

    @property
    def trackpad(self) -> tuple[float, float]:
        return self._vec2("trackpad")

    @property
    def pressed_mask(self) -> int:
        return as_finite_int(self.payload.get("pressed_mask")) or 0

    @property
    def touched_mask(self) -> int:
        return as_finite_int(self.payload.get("touched_mask")) or 0

    @property
    def available_mask(self) -> int:
        return as_finite_int(self.payload.get("available_mask")) or 0

    def axis(self, name: str, default: float = 0.0) -> float:
        value = as_finite_float(self.payload.get(name))
        return default if value is None else value

    def _vec2(self, name: str) -> tuple[float, float]:
        value = self.payload.get(name)
        if not isinstance(value, dict):
            return (0.0, 0.0)
        return (as_finite_float(value.get("x")) or 0.0, as_finite_float(value.get("y")) or 0.0)

    def is_pressed(self, button: str) -> bool:
        bit = CONTROLLER_BUTTON_BITS.get(button)
        return bool(bit is not None and self.pressed_mask & bit)

    def pressed_buttons(self) -> tuple[str, ...]:
        return decode_button_mask(self.pressed_mask)

    def touched_buttons(self) -> tuple[str, ...]:
        return decode_button_mask(self.touched_mask)

    def numeric_axes(self) -> dict[str, float]:
        """Scalar axes flattened for plotting (``thumbstick.x``, ``trigger_value``, ...)."""
        axes: dict[str, float] = {}
        for key in ("trigger_value", "grip_value"):
            value = as_finite_float(self.payload.get(key))
            if value is not None:
                axes[key] = value
        for key in ("thumbstick", "trackpad"):
            value = self.payload.get(key)
            if isinstance(value, dict):
                for component in ("x", "y"):
                    number = as_finite_float(value.get(component))
                    if number is not None:
                        axes[f"{key}.{component}"] = number
        return axes


@dataclasses.dataclass(frozen=True)
class HandJoint:
    index: int
    position: Vec3
    rotation: tuple[float, float, float, float]
    radius_m: float
    flags: int


@dataclasses.dataclass(frozen=True)
class HandJointsSample(Sample):
    """One hand's skeleton; ``joints`` is index-ordered per ``XRHandTracker``."""

    hand: str
    joints: tuple[HandJoint, ...]
    payload: dict[str, Any]

    @property
    def joint_count(self) -> int:
        return len(self.joints)

    def positions(self) -> tuple[Vec3, ...]:
        return tuple(joint.position for joint in self.joints)


@dataclasses.dataclass(frozen=True)
class UnknownSample(Sample):
    payload: bytes


def _hand_label(payload: dict[str, Any], default: str = "unknown") -> str:
    """Normalise the headset's hand identifier to ``"left"`` / ``"right"``.

    ``controller_pose`` uses ``source: "left_controller"``, ``controller_input``
    uses ``controller: "right_controller"``, and ``hand_joints`` uses
    ``hand: "left"``.
    """
    for key in ("hand", "source", "controller"):
        value = payload.get(key)
        if isinstance(value, str) and value.strip():
            text = value.strip().lower()
            if text.startswith("left"):
                return "left"
            if text.startswith("right"):
                return "right"
            return text
    return default


def _extract_hand_joints(payload: dict[str, Any]) -> tuple[HandJoint, ...]:
    """Parse ``joints_json`` (a JSON string holding an array of joint records)."""
    raw = payload.get("joints_json")
    joints: Any
    if isinstance(raw, str):
        if not raw.strip():
            return ()
        try:
            joints = json.loads(raw)
        except json.JSONDecodeError:
            return ()
    else:
        joints = payload.get("joints", raw)
    if not isinstance(joints, list):
        return ()

    parsed: list[HandJoint] = []
    for index, joint in enumerate(joints):
        if not isinstance(joint, dict):
            continue
        position = joint.get("position")
        if not isinstance(position, dict):
            continue
        x = as_finite_float(position.get("x"))
        y = as_finite_float(position.get("y"))
        z = as_finite_float(position.get("z"))
        if None in (x, y, z):
            continue
        assert x is not None and y is not None and z is not None
        rotation = joint.get("rotation") if isinstance(joint.get("rotation"), dict) else {}
        parsed.append(
            HandJoint(
                index=as_finite_int(joint.get("joint")) if joint.get("joint") is not None else index,
                position=(x, y, z),
                rotation=(
                    as_finite_float(rotation.get("x")) or 0.0,
                    as_finite_float(rotation.get("y")) or 0.0,
                    as_finite_float(rotation.get("z")) or 0.0,
                    as_finite_float(rotation.get("w")) or 1.0,
                ),
                radius_m=as_finite_float(joint.get("radius_m")) or 0.0,
                flags=as_finite_int(joint.get("flags")) or 0,
            )
        )
    return tuple(parsed)


def parse_sample(event: StreamEvent, *, depth_model: DepthCameraModel | None = None) -> Sample:
    """Turn a raw OLCP frame into a typed :class:`Sample`.

    ``depth_model`` carries the most recent depth camera model forward so that
    depth frames whose composite metadata omits intrinsics still unproject.
    Unrecognised or malformed frames become :class:`UnknownSample` rather than
    raising, so a single bad frame never kills a stream.
    """
    base = dict(
        frame_type=event.frame_type,
        pts_ns=event.pts_ns,
        recv_monotonic_ns=event.recv_monotonic_ns,
    )

    def _json() -> dict[str, Any] | None:
        try:
            value = event.payload_json()
        except Exception:
            return None
        return value if isinstance(value, dict) else None

    if event.frame_type == TYPE_SESSION_START:
        payload = _json()
        if payload is not None:
            return SessionStartSample(kind="session_start", info=payload, **base)
    elif event.frame_type == TYPE_SESSION_END:
        payload = _json()
        if payload is not None:
            return SessionEndSample(kind="session_end", info=payload, **base)
    elif event.frame_type == TYPE_RGB_CSD:
        payload = _json()
        if payload is not None:
            return RgbConfigSample(
                kind="rgb_csd",
                config=payload,
                cameras=rgb_cameras_from_config(payload),
                **base,
            )
    elif event.frame_type == TYPE_RGB_PACKET:
        return RgbPacketSample(
            kind="rgb_packet",
            payload=event.payload,
            keyframe=bool(event.flags & FLAG_KEYFRAME),
            **base,
        )
    elif event.frame_type == TYPE_DEPTH_METADATA:
        payload = _json()
        if payload is not None:
            return DepthMetadataSample(
                kind="depth_metadata",
                metadata=payload,
                model=depth_model_from_metadata(payload, depth_model),
                **base,
            )
    elif event.frame_type == TYPE_DEPTH_FRAME:
        metadata: dict[str, Any] = {}
        depth_bytes = event.payload
        if event.flags & FLAG_COMPOSITE_JSON:
            try:
                metadata, depth_bytes = parse_composite_payload(event.payload)
            except Exception:
                return UnknownSample(kind="unknown", payload=event.payload, **base)
        model = depth_model_from_metadata(metadata, depth_model)
        expected_size = (
            model.width * model.height * DEPTH_PIXEL.size
            if model is not None and model.width > 0 and model.height > 0
            else None
        )
        try:
            depth_bytes = decode_transport_payload(
                depth_bytes,
                event.flags,
                expected_size=expected_size,
            )
        except ValueError:
            return UnknownSample(kind="unknown", payload=event.payload, **base)
        return DepthFrameSample(
            kind="depth_frame",
            metadata=metadata,
            depth_bytes=depth_bytes,
            model=model,
            **base,
        )
    elif event.frame_type == TYPE_HEAD_POSE:
        payload = _json()
        pose = parse_pose_sample(event)
        if payload is not None and pose is not None:
            return HeadPoseSample(kind="head_pose", pose=pose, payload=payload, **base)
    elif event.frame_type == TYPE_CONTROLLER_POSE:
        payload = _json()
        pose = parse_pose_sample(event)
        if payload is not None and pose is not None:
            return ControllerPoseSample(
                kind="controller_pose",
                hand=_hand_label(payload),
                pose=pose,
                payload=payload,
                **base,
            )
    elif event.frame_type == TYPE_CONTROLLER_INPUT:
        payload = _json()
        if payload is not None:
            return ControllerInputSample(
                kind="controller_input",
                hand=_hand_label(payload),
                payload=payload,
                **base,
            )
    elif event.frame_type == TYPE_HAND_JOINTS:
        payload = _json()
        if payload is not None:
            return HandJointsSample(
                kind="hand_joints",
                hand=_hand_label(payload),
                joints=_extract_hand_joints(payload),
                payload=payload,
                **base,
            )

    return UnknownSample(kind="unknown", payload=event.payload, **base)


def sample_kinds() -> tuple[str, ...]:
    return (
        "session_start",
        "session_end",
        "rgb_csd",
        "rgb_packet",
        "depth_metadata",
        "depth_frame",
        "head_pose",
        "controller_pose",
        "controller_input",
        "hand_joints",
        "unknown",
    )


def sequence_to_vec3(values: Sequence[float]) -> Vec3:
    return (float(values[0]), float(values[1]), float(values[2]))
