"""Pure geometry helpers for OpenXR environment-depth visualization.

The transforms here are runtime-contract based. They deliberately contain no
headset model, product code, or serial-number branches.
"""

from __future__ import annotations

from typing import Optional, Tuple

import numpy as np


# OpenXR depth-eye poses use X-right, Y-up, Z-back. Decoded metric depth
# samples use OpenCV/RDF X-right, Y-down, Z-forward.
OPENXR_DEPTH_EYE_GODOT_FROM_RDF = np.diag([1.0, -1.0, -1.0])


def openxr_depth_camera_pose(local_from_depth_eye: np.ndarray) -> np.ndarray:
    """Return an RDF depth-camera pose from an OpenXR depth-eye pose."""
    pose = np.asarray(local_from_depth_eye, dtype=np.float64)
    if pose.shape != (4, 4) or not np.all(np.isfinite(pose)):
        raise ValueError("local_from_depth_eye must be a finite 4x4 matrix")
    camera_pose = np.array(pose, dtype=np.float64, copy=True)
    camera_pose[:3, :3] = (
        camera_pose[:3, :3] @ OPENXR_DEPTH_EYE_GODOT_FROM_RDF
    )
    return camera_pose


def unproject_environment_depth_via_inverse_projection(
    depth_native_m: np.ndarray,
    inverse_projection_view: np.ndarray,
    near_z: float,
    far_z: Optional[float],
    depth_min_m: float,
    depth_max_m: float,
    stride: int,
) -> Optional[Tuple[np.ndarray, np.ndarray]]:
    """Unproject metric depth with OpenXR's per-frame inverse matrix."""
    depth_native_m = np.asarray(depth_native_m)
    inverse_projection_view = np.asarray(
        inverse_projection_view, dtype=np.float64
    )
    if depth_native_m.ndim != 2 or inverse_projection_view.shape != (4, 4):
        return None
    if not np.all(np.isfinite(inverse_projection_view)):
        return None
    if not np.isfinite(near_z) or near_z <= 0.0:
        return None
    if far_z is None or not np.isfinite(far_z) or far_z < near_z:
        x_param = -2.0 * near_z
        y_param = -1.0
    elif far_z == near_z:
        return None
    else:
        x_param = -2.0 * far_z * near_z / (far_z - near_z)
        y_param = -(far_z + near_z) / (far_z - near_z)

    full_h, full_w = depth_native_m.shape
    sample_stride = max(int(stride), 1)
    row_idx = np.arange(0, full_h, sample_stride, dtype=np.float64)
    col_idx = np.arange(0, full_w, sample_stride, dtype=np.float64)
    rows, cols = np.meshgrid(row_idx, col_idx, indexing="ij")
    depth = depth_native_m[::sample_stride, ::sample_stride].astype(
        np.float64, copy=False
    )

    valid_depth = (
        (depth > depth_min_m)
        & (depth < depth_max_m)
        & np.isfinite(depth)
    )
    if not valid_depth.any():
        return np.zeros((0, 3), dtype=np.float64), np.zeros(
            (0,), dtype=np.float64
        )

    with np.errstate(divide="ignore", invalid="ignore"):
        window_depth = (x_param / depth - y_param + 1.0) / 2.0
    window_depth_finite = np.isfinite(window_depth)
    safe_window_depth = np.where(window_depth_finite, window_depth, 0.0)

    clip = np.stack(
        [
            2.0 * ((cols + 0.5) / full_w) - 1.0,
            2.0 * ((rows + 0.5) / full_h) - 1.0,
            2.0 * safe_window_depth - 1.0,
            np.ones_like(depth, dtype=np.float64),
        ],
        axis=-1,
    ).reshape(-1, 4)
    homogeneous = (inverse_projection_view @ clip.T).T
    w = homogeneous[:, 3]
    valid_w = np.isfinite(w) & (np.abs(w) > 1e-12)
    points = np.full((homogeneous.shape[0], 3), np.nan, dtype=np.float64)
    points[valid_w] = homogeneous[valid_w, :3] / w[valid_w, None]

    valid = (
        valid_w
        & valid_depth.reshape(-1)
        & window_depth_finite.reshape(-1)
        & np.all(np.isfinite(points), axis=1)
    )
    return points[valid], depth.reshape(-1)[valid]


def project_rdf_points_to_image(
    points_rdf: np.ndarray,
    fx: float,
    fy: float,
    cx: float,
    cy: float,
    width: int,
    height: int,
    z_near: float = 0.05,
    flip_projected_y: bool = False,
) -> Tuple[np.ndarray, np.ndarray]:
    """Project camera-local RDF points and return pixel coordinates + mask."""
    points_rdf = np.asarray(points_rdf, dtype=np.float64)
    if points_rdf.ndim != 2 or points_rdf.shape[1] != 3:
        raise ValueError("points_rdf must have shape (N, 3)")
    n = points_rdf.shape[0]
    uv = np.full((n, 2), np.nan, dtype=np.float64)
    if n == 0:
        return uv, np.zeros((0,), dtype=bool)

    z = points_rdf[:, 2]
    with np.errstate(divide="ignore", invalid="ignore"):
        u = points_rdf[:, 0] * float(fx) / z + float(cx)
        v = points_rdf[:, 1] * float(fy) / z + float(cy)
    if flip_projected_y:
        v = (height - 1) - v
    mask = (
        (z > z_near)
        & (u >= 0)
        & (u < width)
        & (v >= 0)
        & (v < height)
        & np.isfinite(u)
        & np.isfinite(v)
    )
    uv[mask, 0] = u[mask]
    uv[mask, 1] = v[mask]
    return uv, mask
