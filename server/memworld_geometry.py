"""Quest Camera2 calibration, hand mapping, and MemWorld skeleton rendering."""

from __future__ import annotations

from dataclasses import dataclass
import math
from typing import Any, Iterable

import numpy as np
from PIL import Image, ImageDraw


OUTPUT_WIDTH = 640
OUTPUT_HEIGHT = 352
OPENXR_JOINT_INDICES = (
    1, 2, 3, 4, 5,
    7, 8, 9, 10,
    12, 13, 14, 15,
    17, 18, 19, 20,
    22, 23, 24, 25,
)
HAND_EDGES = tuple(
    edge
    for start in (1, 5, 9, 13, 17)
    for edge in ((0, start), (start, start + 1), (start + 1, start + 2), (start + 2, start + 3))
)
FINGER_COLORS = (
    (0, 255, 255),
    (0, 100, 255),
    (255, 255, 0),
    (255, 0, 255),
    (80, 255, 80),
)
OPENCV_C2W_TO_MEMWORLD = np.asarray(
    (
        (0.0, 1.0, 0.0, 0.0),
        (0.0, 0.0, -1.0, 0.0),
        (1.0, 0.0, 0.0, 0.0),
        (0.0, 0.0, 0.0, 1.0),
    ),
    dtype=np.float64,
)


@dataclass(frozen=True)
class OutputIntrinsics:
    width: int
    height: int
    fx: float
    fy: float
    cx: float
    cy: float
    skew: float
    crop_top: int


@dataclass(frozen=True)
class CameraCalibration:
    calibration_id: str
    source_width: int
    source_height: int
    active_left: float
    active_top: float
    active_width: float
    active_height: float
    fx: float
    fy: float
    cx: float
    cy: float
    skew: float
    distortion: tuple[float, ...]
    lens_translation: tuple[float, float, float]
    lens_rotation_xyzw: tuple[float, float, float, float]

    @classmethod
    def from_json(cls, payload: dict[str, Any]) -> "CameraCalibration":
        if not isinstance(payload, dict) or payload.get("ok") is not True:
            raise ValueError(str(payload.get("error", "camera calibration is unavailable")) if isinstance(payload, dict) else "camera calibration must be an object")
        size = payload.get("selected_yuv_size")
        intrinsics = payload.get("lens_intrinsic_calibration")
        translation = payload.get("lens_pose_translation")
        rotation = payload.get("lens_pose_rotation")
        if not isinstance(size, dict):
            raise ValueError("selected_yuv_size is missing")
        if not isinstance(intrinsics, list) or len(intrinsics) < 4:
            raise ValueError("lens_intrinsic_calibration must contain fx, fy, cx, cy")
        if not isinstance(translation, list) or len(translation) != 3:
            raise ValueError("lens_pose_translation must contain 3 values")
        if not isinstance(rotation, list) or len(rotation) != 4:
            raise ValueError("lens_pose_rotation must contain xyzw")
        source_width = int(size.get("width", 0))
        source_height = int(size.get("height", 0))
        active = payload.get("sensor_active_array_size") or {}
        active_left = float(active.get("left", 0.0))
        active_top = float(active.get("top", 0.0))
        active_width = float(active.get("width", source_width))
        active_height = float(active.get("height", source_height))
        values = [
            source_width, source_height, active_width, active_height,
            *intrinsics[:5], *translation, *rotation,
        ]
        if source_width <= 0 or source_height <= 0 or active_width <= 0 or active_height <= 0:
            raise ValueError("camera dimensions must be positive")
        if not all(math.isfinite(float(value)) for value in values):
            raise ValueError("camera calibration contains non-finite values")
        if round(source_height * OUTPUT_WIDTH / source_width) < OUTPUT_HEIGHT:
            raise ValueError("selected YUV aspect ratio cannot produce a 640x352 bottom crop")
        return cls(
            calibration_id=str(payload.get("calibration_id", "unknown")),
            source_width=source_width,
            source_height=source_height,
            active_left=active_left,
            active_top=active_top,
            active_width=active_width,
            active_height=active_height,
            fx=float(intrinsics[0]),
            fy=float(intrinsics[1]),
            cx=float(intrinsics[2]),
            cy=float(intrinsics[3]),
            skew=float(intrinsics[4]) if len(intrinsics) > 4 else 0.0,
            distortion=tuple(float(value) for value in payload.get("lens_distortion") or ()),
            lens_translation=tuple(float(value) for value in translation),
            lens_rotation_xyzw=tuple(float(value) for value in rotation),
        )

    def _active_crop(self) -> tuple[float, float, float, float]:
        source = np.asarray((self.source_width, self.source_height), dtype=np.float64)
        active = np.asarray((self.active_width, self.active_height), dtype=np.float64)
        scale = source / active
        scale /= max(float(scale[0]), float(scale[1]))
        crop_size = active * scale
        crop_left = self.active_left + (self.active_width - crop_size[0]) * 0.5
        crop_top = self.active_top + (self.active_height - crop_size[1]) * 0.5
        return float(crop_left), float(crop_top), float(crop_size[0]), float(crop_size[1])

    def output_intrinsics(self) -> OutputIntrinsics:
        crop_left, sensor_crop_top, crop_width, crop_height = self._active_crop()
        source_fx = self.fx * self.source_width / crop_width
        source_fy = self.fy * self.source_height / crop_height
        source_cx = (self.cx - crop_left) * self.source_width / crop_width
        source_cy = (self.cy - sensor_crop_top) * self.source_height / crop_height
        source_skew = self.skew * self.source_width / crop_width
        scale = OUTPUT_WIDTH / self.source_width
        scaled_height = round(self.source_height * scale)
        crop_top = scaled_height - OUTPUT_HEIGHT
        return OutputIntrinsics(
            width=OUTPUT_WIDTH,
            height=OUTPUT_HEIGHT,
            fx=source_fx * scale,
            fy=source_fy * scale,
            cx=source_cx * scale,
            cy=source_cy * scale - crop_top,
            skew=source_skew * scale,
            crop_top=crop_top,
        )

    def sensor_to_output(self, sensor_xy: np.ndarray) -> np.ndarray:
        points = np.asarray(sensor_xy, dtype=np.float64)
        crop_left, crop_top, crop_width, crop_height = self._active_crop()
        source_x = (points[:, 0] - crop_left) * self.source_width / crop_width
        source_y = (points[:, 1] - crop_top) * self.source_height / crop_height
        scale = OUTPUT_WIDTH / self.source_width
        output_crop_top = round(self.source_height * scale) - OUTPUT_HEIGHT
        return np.column_stack((source_x * scale, source_y * scale - output_crop_top))


@dataclass(frozen=True)
class RenderedSkeleton:
    image: Image.Image
    camera_c2w: np.ndarray
    model_c2w: np.ndarray
    drawn_joints: int
    frame_id: int
    capture_time_ns: int
    calibration_id: str


def quaternion_xyzw_to_matrix(values: Iterable[float]) -> np.ndarray:
    quaternion = np.asarray(tuple(values), dtype=np.float64)
    if quaternion.shape != (4,) or not np.isfinite(quaternion).all():
        raise ValueError("quaternion must contain four finite values")
    norm = float(np.linalg.norm(quaternion))
    if norm <= 0.0:
        raise ValueError("quaternion norm must be positive")
    x, y, z, w = quaternion / norm
    return np.asarray(
        (
            (1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)),
            (2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)),
            (2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)),
        ),
        dtype=np.float64,
    )


def _pose_matrix(position: Iterable[float], rotation_xyzw: Iterable[float]) -> np.ndarray:
    result = np.eye(4, dtype=np.float64)
    result[:3, :3] = quaternion_xyzw_to_matrix(rotation_xyzw)
    position_array = np.asarray(tuple(position), dtype=np.float64)
    if position_array.shape != (3,) or not np.isfinite(position_array).all():
        raise ValueError("position must contain three finite values")
    result[:3, 3] = position_array
    return result


def camera_c2w_from_pose(head: dict[str, Any], calibration: CameraCalibration) -> np.ndarray:
    if not isinstance(head, dict) or head.get("tracked") is not True:
        raise ValueError("tracked head pose is required")
    world_head = _pose_matrix(head.get("position", ()), head.get("rotation", ()))
    head_camera = _pose_matrix(calibration.lens_translation, calibration.lens_rotation_xyzw)
    return world_head @ head_camera


def memworld_c2w(camera_c2w: np.ndarray) -> np.ndarray:
    matrix = np.asarray(camera_c2w, dtype=np.float64)
    if matrix.shape != (4, 4) or not np.isfinite(matrix).all():
        raise ValueError("camera c2w must be a finite 4x4 matrix")
    return matrix @ OPENCV_C2W_TO_MEMWORLD


def map_openxr_hand(hand: Any) -> tuple[np.ndarray | None, ...]:
    if not isinstance(hand, dict) or hand.get("tracking") is not True:
        return tuple(None for _ in OPENXR_JOINT_INDICES)
    joints = hand.get("joints")
    if not isinstance(joints, list):
        return tuple(None for _ in OPENXR_JOINT_INDICES)
    result: list[np.ndarray | None] = []
    for source_index in OPENXR_JOINT_INDICES:
        joint = joints[source_index] if source_index < len(joints) else None
        position = joint.get("position") if isinstance(joint, dict) and joint.get("tracked") is True else None
        point = np.asarray(position, dtype=np.float64) if isinstance(position, (list, tuple)) and len(position) == 3 else None
        result.append(point if point is not None and np.isfinite(point).all() else None)
    return tuple(result)


def _distort(normalized: np.ndarray, coefficients: tuple[float, ...]) -> np.ndarray:
    if len(coefficients) < 5 or not any(abs(value) > 1e-12 for value in coefficients[:5]):
        return normalized
    x = normalized[:, 0]
    y = normalized[:, 1]
    k1, k2, k3, p1, p2 = coefficients[:5]
    r2 = x * x + y * y
    radial = 1.0 + k1 * r2 + k2 * r2 * r2 + k3 * r2 * r2 * r2
    return np.column_stack((
        x * radial + 2.0 * p1 * x * y + p2 * (r2 + 2.0 * x * x),
        y * radial + p1 * (r2 + 2.0 * y * y) + 2.0 * p2 * x * y,
    ))


def project_world_points(
    world_points: np.ndarray,
    camera_c2w: np.ndarray,
    calibration: CameraCalibration,
) -> tuple[np.ndarray, np.ndarray]:
    points = np.asarray(world_points, dtype=np.float64).reshape((-1, 3))
    projected = np.full((len(points), 2), np.nan, dtype=np.float64)
    finite = np.isfinite(points).all(axis=1)
    homogeneous = np.column_stack((np.where(finite[:, None], points, 0.0), np.ones(len(points))))
    camera = (np.linalg.inv(camera_c2w) @ homogeneous.T).T[:, :3]
    valid = finite & np.isfinite(camera).all(axis=1) & (camera[:, 2] > 1e-4)
    if np.any(valid):
        normalized = _distort(camera[valid, :2] / camera[valid, 2:3], calibration.distortion)
        sensor = np.column_stack((
            calibration.fx * normalized[:, 0] + calibration.skew * normalized[:, 1] + calibration.cx,
            calibration.fy * normalized[:, 1] + calibration.cy,
        ))
        projected[valid] = calibration.sensor_to_output(sensor)
    return projected, valid


def _draw_hand(
    draw: ImageDraw.ImageDraw,
    hand: tuple[np.ndarray | None, ...],
    camera_c2w: np.ndarray,
    calibration: CameraCalibration,
    base_color: tuple[int, int, int],
) -> int:
    availability = np.asarray([point is not None for point in hand], dtype=bool)
    points = np.asarray([point if point is not None else (0.0, 0.0, 0.0) for point in hand])
    xy, valid = project_world_points(points, camera_c2w, calibration)
    valid &= availability
    for finger_index, start in enumerate((1, 5, 9, 13, 17)):
        color = FINGER_COLORS[finger_index]
        for first, second in ((0, start), (start, start + 1), (start + 1, start + 2), (start + 2, start + 3)):
            if valid[first] and valid[second]:
                draw.line((*xy[first], *xy[second]), fill=(0, 0, 0), width=9)
                draw.line((*xy[first], *xy[second]), fill=color, width=5)
    for index, point in enumerate(xy):
        if not valid[index]:
            continue
        x, y = (int(round(point[0])), int(round(point[1])))
        radius = 6 if index == 0 else 4
        draw.ellipse((x - radius - 2, y - radius - 2, x + radius + 2, y + radius + 2), fill=(0, 0, 0))
        draw.ellipse((x - radius, y - radius, x + radius, y + radius), fill=base_color)
    return int(valid.sum())


def render_hand_skeleton(pose: dict[str, Any], calibration: CameraCalibration) -> RenderedSkeleton:
    camera_c2w = camera_c2w_from_pose(pose.get("head"), calibration)
    image = Image.new("RGB", (OUTPUT_WIDTH, OUTPUT_HEIGHT), (0, 0, 0))
    draw = ImageDraw.Draw(image)
    drawn = _draw_hand(draw, map_openxr_hand(pose.get("left")), camera_c2w, calibration, (0, 255, 80))
    drawn += _draw_hand(draw, map_openxr_hand(pose.get("right")), camera_c2w, calibration, (0, 170, 255))
    return RenderedSkeleton(
        image=image,
        camera_c2w=camera_c2w,
        model_c2w=memworld_c2w(camera_c2w),
        drawn_joints=drawn,
        frame_id=int(pose["frame_id"]),
        capture_time_ns=int(pose["capture_time_ns"]),
        calibration_id=calibration.calibration_id,
    )
