#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13,<3.14"
# dependencies = [
#     "numpy>=1.26.0",
#     "scipy>=1.11.0",
#     "opencv-python>=4.8.0",
# ]
# ///
"""Render Pico hand-joint overlays onto SpatialMP4 RGB video.

This is the standalone OpenCV/Numpy validation path for Operator Pico
captures. It intentionally avoids Rerun and projects in the raw Operator
Pico capture basis:

    T_H_S = raw_rgb_extrinsics @ Trans_camera([0, 0, norm(sm.HEAD_MODEL_OFFSET)])
    T_W_S = T_W_H @ T_H_S
    P_S = inv(T_W_S) @ P_W_hand
    u = fx * x / z + cx
    v = fy * y / z + cy

The MP4 used here already stores
head-relative RGB extrinsics with an RDF optical frame, so applying that
rotation again introduces the observed 90-degree error. The remaining correction
is the head-model standoff magnitude, applied along the RGB camera optical axis.
"""

from __future__ import annotations

import argparse
import bisect
import importlib
import json
import os
import shutil
import subprocess
import sys
import sysconfig
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Tuple


def _emit(prefix: str, msg: str) -> None:
    print(f"[pico_hand_projection_video] {prefix}{msg}", file=sys.stderr, flush=True)


def info(msg: str) -> None:
    _emit("", msg)


def fatal(msg: str, code: int = 2) -> None:
    _emit("FATAL: ", msg)
    raise SystemExit(code)


def _abi_tag() -> str:
    return sys.implementation.cache_tag or ""


def _python_suffix() -> str:
    return f"python{sys.version_info.major}{sys.version_info.minor}"


def _platform_tag() -> str:
    soabi = sysconfig.get_config_var("SOABI") or ""
    if "darwin" in soabi:
        return "darwin"
    if "linux" in soabi:
        return "linux-gnu"
    return ""


def _has_spatialmp4_so(path: Path) -> bool:
    abi = _abi_tag()
    return path.is_dir() and any(path.glob(f"spatialmp4.{abi}-*.so"))


def _discover_spatialmp4_module_dir(home: Path) -> Optional[Path]:
    py_suffix = _python_suffix()
    quick_candidates = [
        home / "build" / "host_py" / "python",
        home / "build" / py_suffix / "python",
        home / "build" / "rerun_py310" / "python",
        home / "python",
    ]
    for candidate in quick_candidates:
        if _has_spatialmp4_so(candidate):
            return candidate

    for candidate in home.glob("build/**/python"):
        if _has_spatialmp4_so(candidate):
            return candidate
    return None


def _bootstrap_spatialmp4():
    try:
        return importlib.import_module("spatialmp4")
    except ImportError:
        pass

    py_suffix = _python_suffix()
    repo_root = Path(__file__).resolve().parents[3]
    deps_root = Path(os.environ.get("OPERATOR_DEPS_CACHE_ROOT", "~/.cache/operator/deps")).expanduser()

    direct_module_dirs = [
        deps_root / "build" / "spatialmp4" / py_suffix / "python",
        repo_root / ".deps" / "build" / "spatialmp4" / py_suffix / "python",
    ]
    for module_dir in direct_module_dirs:
        if not _has_spatialmp4_so(module_dir):
            continue
        info(f"injecting {module_dir} for SpatialMP4 SDK")
        sys.path.insert(0, str(module_dir))
        try:
            return importlib.import_module("spatialmp4")
        except ImportError as exc:
            info(f"  import failed: {exc}; continuing search")
            sys.path.pop(0)

    home_candidates: List[Path] = []
    if os.environ.get("SPATIALMP4_HOME"):
        home_candidates.append(Path(os.environ["SPATIALMP4_HOME"]).expanduser())
    home_candidates.extend(
        [
            deps_root / "src" / "SpatialMP4",
            repo_root / ".deps" / "src" / "SpatialMP4",
            Path("~/ws/spatialmp4-quest/SpatialMP4").expanduser(),
            Path("~/spatialmp4-quest/SpatialMP4").expanduser(),
            Path("~/SpatialMP4").expanduser(),
        ]
    )

    for home in home_candidates:
        if not home.is_dir():
            continue
        module_dir = _discover_spatialmp4_module_dir(home)
        if module_dir is None:
            continue
        info(f"injecting {module_dir} for SpatialMP4 SDK (home={home})")
        sys.path.insert(0, str(module_dir))
        try:
            return importlib.import_module("spatialmp4")
        except ImportError as exc:
            info(f"  import failed: {exc}; continuing search")
            sys.path.pop(0)

    plat = _platform_tag()
    fatal(
        "SpatialMP4 SDK not importable. Set PYTHONPATH to the built SDK "
        f"directory containing spatialmp4.{_abi_tag()}-{plat}.so, or set "
        "SPATIALMP4_HOME / OPERATOR_DEPS_CACHE_ROOT."
    )


try:
    import cv2  # type: ignore
except ImportError:
    fatal("opencv-python missing; uv should install it from PEP 723 metadata")

try:
    import numpy as np  # type: ignore
except ImportError:
    fatal("numpy missing; uv should install it from PEP 723 metadata")

try:
    from scipy.spatial.transform import Rotation  # type: ignore
except ImportError:
    fatal("scipy missing; uv should install it from PEP 723 metadata")


sm = _bootstrap_spatialmp4()


XR_HAND_BONES: Tuple[Tuple[int, int], ...] = (
    (1, 2), (2, 3), (3, 4), (4, 5),
    (1, 6), (6, 7), (7, 8), (8, 9), (9, 10),
    (1, 11), (11, 12), (12, 13), (13, 14), (14, 15),
    (1, 16), (16, 17), (17, 18), (18, 19), (19, 20),
    (1, 21), (21, 22), (22, 23), (23, 24), (24, 25),
)

HAND_COLORS_BGR: Dict[str, Tuple[int, int, int]] = {
    "left_hand": (255, 180, 80),
    "right_hand": (80, 160, 255),
}


class TimedLookup:
    def __init__(self, frames: Sequence[Any]) -> None:
        valid = [f for f in frames if float(getattr(f, "timestamp", 0.0)) > 0.0]
        valid.sort(key=lambda f: float(f.timestamp))
        self._frames = valid
        self._ts = [float(f.timestamp) for f in valid]

    def __len__(self) -> int:
        return len(self._frames)

    @property
    def frames(self) -> Sequence[Any]:
        return self._frames

    def nearest(self, timestamp: float) -> Tuple[Optional[Any], Optional[float]]:
        if not self._frames:
            return None, None
        idx = bisect.bisect_left(self._ts, timestamp)
        candidates: List[int] = []
        if idx < len(self._ts):
            candidates.append(idx)
        if idx > 0:
            candidates.append(idx - 1)
        best = min(candidates, key=lambda i: abs(self._ts[i] - timestamp))
        return self._frames[best], abs(self._ts[best] - timestamp)

    def nearest_within(self, timestamp: float, max_dt: float) -> Tuple[Optional[Any], Optional[float]]:
        frame, dt = self.nearest(timestamp)
        if frame is None or dt is None or dt > max_dt:
            return None, dt
        return frame, dt


def make_reader(input_path: Path):
    try:
        return sm.Reader(str(input_path), "error")
    except TypeError:
        return sm.Reader(str(input_path))


def pose_to_matrix(pose: Any) -> np.ndarray:
    if hasattr(pose, "as_se3"):
        return np.asarray(pose.as_se3(), dtype=np.float64)
    mat = np.eye(4, dtype=np.float64)
    mat[:3, :3] = Rotation.from_quat([pose.qx, pose.qy, pose.qz, pose.qw]).as_matrix()
    mat[:3, 3] = [pose.x, pose.y, pose.z]
    return mat


def intrinsics_for_eye(reader: Any, eye: str) -> Any:
    return reader.get_rgb_intrinsics_left() if eye == "left" else reader.get_rgb_intrinsics_right()


def extrinsics_for_eye(reader: Any, eye: str) -> np.ndarray:
    extr = reader.get_rgb_extrinsics_left() if eye == "left" else reader.get_rgb_extrinsics_right()
    return np.asarray(extr.as_se3(), dtype=np.float64)


def image_for_eye(frame_rgb: Any, eye: str) -> np.ndarray:
    return frame_rgb.left_rgb if eye == "left" else frame_rgb.right_rgb


def trans_camera(offset_xyz: Sequence[float]) -> np.ndarray:
    mat = np.eye(4, dtype=np.float64)
    mat[:3, 3] = np.asarray(offset_xyz, dtype=np.float64)
    return mat


def pico_camera_extrinsics_with_head_model(
    raw_rgb_extrinsics: np.ndarray,
    head_model_offset: np.ndarray,
) -> Tuple[np.ndarray, float]:
    """Apply Pico head-model standoff along RGB camera RDF +Z, without basis remap."""
    forward_m = float(np.linalg.norm(np.asarray(head_model_offset, dtype=np.float64)))
    return raw_rgb_extrinsics @ trans_camera([0.0, 0.0, forward_m]), forward_m


def collect_hand_tracks(reader: Any) -> Dict[str, TimedLookup]:
    tracks: Dict[str, TimedLookup] = {}
    for track_id in reader.list_timed_metadata_tracks():
        try:
            frames = reader.get_hand_joint_frames(track_id)
        except Exception:
            continue
        if frames:
            tracks[str(track_id)] = TimedLookup(frames)
    return tracks


def collect_rgb_timestamps(reader: Any, topk: Optional[int]) -> List[float]:
    reader.set_read_mode(sm.ReadMode.RGB_ONLY)
    reader.reset()
    timestamps: List[float] = []
    while reader.has_next():
        frame_rgb = reader.load_rgb()
        timestamps.append(float(frame_rgb.timestamp))
        if topk is not None and len(timestamps) >= topk:
            break
    return timestamps


def fps_from_timestamps(timestamps: Sequence[float], fallback_fps: float) -> float:
    if len(timestamps) >= 2:
        deltas = np.diff(np.asarray(timestamps, dtype=np.float64))
        deltas = deltas[np.isfinite(deltas) & (deltas > 0.0)]
        if deltas.size:
            return float(1.0 / np.median(deltas))
    return float(fallback_fps) if fallback_fps > 0 else 30.0


def project_world_points(
    world_points: np.ndarray,
    T_W_S: np.ndarray,
    K: Any,
    width: int,
    height: int,
    z_near: float,
) -> Tuple[np.ndarray, np.ndarray, np.ndarray]:
    n = world_points.shape[0]
    uv = np.full((n, 2), np.nan, dtype=np.float64)
    if n == 0:
        return uv, np.zeros((0,), dtype=bool), np.zeros((0,), dtype=np.float64)

    T_S_W = np.linalg.inv(T_W_S)
    pts_sensor = (T_S_W[:3, :3] @ world_points.T).T + T_S_W[:3, 3]
    z = pts_sensor[:, 2]
    with np.errstate(divide="ignore", invalid="ignore"):
        u = float(K.fx) * pts_sensor[:, 0] / z + float(K.cx)
        v = float(K.fy) * pts_sensor[:, 1] / z + float(K.cy)
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
    return uv, mask, z


def draw_hand_overlay(
    image_bgr: np.ndarray,
    track_id: str,
    hand_frame: Any,
    T_W_S: np.ndarray,
    K: Any,
    width: int,
    height: int,
    z_near: float,
) -> Dict[str, Any]:
    joints = list(hand_frame.joints)
    if not joints:
        return {"visible": 0, "center": None, "z_range": None}

    points = np.array([[j.x, j.y, j.z] for j in joints], dtype=np.float64)
    joint_ids = np.array([int(j.joint_id) for j in joints], dtype=np.int32)
    uv, mask, z = project_world_points(points, T_W_S, K, width, height, z_near)
    color = HAND_COLORS_BGR.get(track_id, (220, 220, 220))
    id_to_idx = {int(jid): i for i, jid in enumerate(joint_ids)}

    for parent, child in XR_HAND_BONES:
        p_i = id_to_idx.get(parent)
        c_i = id_to_idx.get(child)
        if p_i is None or c_i is None or not (mask[p_i] and mask[c_i]):
            continue
        p0 = tuple(np.round(uv[p_i]).astype(int))
        p1 = tuple(np.round(uv[c_i]).astype(int))
        cv2.line(image_bgr, p0, p1, color, 2, cv2.LINE_AA)

    for point in uv[mask]:
        center = tuple(np.round(point).astype(int))
        cv2.circle(image_bgr, center, 4, color, -1, cv2.LINE_AA)
        cv2.circle(image_bgr, center, 6, (0, 0, 0), 1, cv2.LINE_AA)

    visible = int(mask.sum())
    if visible == 0:
        return {"visible": 0, "center": None, "z_range": None}
    return {
        "visible": visible,
        "center": uv[mask].mean(axis=0).tolist(),
        "z_range": [float(z[mask].min()), float(z[mask].max())],
    }


def draw_header(image_bgr: np.ndarray, frame_index: int, timestamp: float, eye: str) -> None:
    lines = [
        f"operator pico: T_W_S=T_W_H@(T_I_S_{eye}@HeadModelForward)",
        f"frame={frame_index}  timestamp={timestamp:.3f}s",
    ]
    x, y = 18, 32
    for line in lines:
        cv2.putText(image_bgr, line, (x + 1, y + 1), cv2.FONT_HERSHEY_SIMPLEX, 0.72, (0, 0, 0), 3, cv2.LINE_AA)
        cv2.putText(image_bgr, line, (x, y), cv2.FONT_HERSHEY_SIMPLEX, 0.72, (255, 255, 255), 1, cv2.LINE_AA)
        y += 28


def find_binary(name: str) -> Optional[str]:
    found = shutil.which(name)
    if found:
        return found
    deps_root = Path(os.environ.get("OPERATOR_DEPS_CACHE_ROOT", "~/.cache/operator/deps")).expanduser()
    candidate = deps_root / "build" / "spatialmp4" / "host_deps" / "ffmpeg" / name
    if candidate.exists():
        return str(candidate)
    return None


def transcode_h264(input_mp4: Path, output_mp4: Path) -> bool:
    ffmpeg = find_binary("ffmpeg")
    if ffmpeg is None:
        info("ffmpeg not found; keeping mp4v output only")
        return False
    cmd = [
        ffmpeg,
        "-y",
        "-v",
        "error",
        "-i",
        str(input_mp4),
        "-c:v",
        "libx264",
        "-pix_fmt",
        "yuv420p",
        "-movflags",
        "+faststart",
        str(output_mp4),
    ]
    try:
        subprocess.run(cmd, check=True)
    except subprocess.CalledProcessError as exc:
        info(f"ffmpeg H.264 transcode failed: {exc}")
        return False
    return True


def default_output_paths(input_path: Path, output_dir: Optional[Path], eye: str) -> Tuple[Path, Path]:
    out_dir = output_dir or Path("/tmp") / f"pico_hand_projection_{input_path.stem}" / "final_video"
    out_dir.mkdir(parents=True, exist_ok=True)
    base = f"{input_path.stem}_{eye}_hand_overlay_operator_head_model_forward"
    return out_dir / f"{base}.mp4", out_dir / f"{base}_h264.mp4"


def write_projection_video(args: argparse.Namespace) -> Dict[str, Any]:
    input_path = args.input.expanduser().resolve()
    if not input_path.exists():
        fatal(f"input MP4 not found: {input_path}")

    reader = make_reader(input_path)
    if not reader.has_rgb():
        fatal("input MP4 has no RGB stream")

    hand_lookups = collect_hand_tracks(reader)
    if not hand_lookups:
        fatal("input MP4 has no hand_joints timed-metadata tracks")
    head_lookup = TimedLookup(reader.get_rigid_pose_frames("head"))
    if len(head_lookup) == 0:
        fatal("input MP4 has no valid rigid_pose:head track")

    rgb_w = int(reader.get_rgb_width())
    rgb_h = int(reader.get_rgb_height())
    K = intrinsics_for_eye(reader, args.eye)
    raw_rgb_extrinsics = extrinsics_for_eye(reader, args.eye)
    head_model_offset = np.asarray(sm.HEAD_MODEL_OFFSET, dtype=np.float64)
    T_H_S, head_model_forward_m = pico_camera_extrinsics_with_head_model(
        raw_rgb_extrinsics,
        head_model_offset,
    )

    timestamps = collect_rgb_timestamps(reader, args.topk)
    fps = fps_from_timestamps(timestamps, float(reader.get_rgb_fps()))
    mp4v_path, h264_path = default_output_paths(input_path, args.output_dir, args.eye)

    writer = cv2.VideoWriter(
        str(mp4v_path),
        cv2.VideoWriter_fourcc(*"mp4v"),
        fps,
        (rgb_w, rgb_h),
    )
    if not writer.isOpened():
        fatal(f"failed to open VideoWriter: {mp4v_path}")

    reader.set_read_mode(sm.ReadMode.RGB_ONLY)
    reader.reset()
    processed = 0
    total_visible = 0
    per_track_samples: List[Dict[str, Any]] = []
    preview_target = timestamps[0] + args.preview_seconds if timestamps else None
    preview_written = False
    preview_path = mp4v_path.parent / f"preview_{int(args.preview_seconds)}s.jpg"

    while reader.has_next():
        frame_rgb = reader.load_rgb()
        timestamp = float(frame_rgb.timestamp)
        head_pose, head_dt = head_lookup.nearest(timestamp)
        if head_pose is None:
            continue

        image_bgr = np.asarray(image_for_eye(frame_rgb, args.eye)).copy()
        T_W_H = pose_to_matrix(head_pose)
        T_W_S = T_W_H @ T_H_S

        for track_id, lookup in hand_lookups.items():
            hand_frame, hand_dt = lookup.nearest_within(timestamp, args.max_hand_dt)
            if hand_frame is None:
                if processed < args.summary_sample_frames:
                    per_track_samples.append(
                        {
                            "frame": processed,
                            "timestamp": timestamp,
                            "track": track_id,
                            "head_dt_ms": None if head_dt is None else head_dt * 1000.0,
                            "hand_dt_ms": None if hand_dt is None else hand_dt * 1000.0,
                            "visible": 0,
                            "center": None,
                            "z_range": None,
                        }
                    )
                continue
            stats = draw_hand_overlay(
                image_bgr,
                track_id,
                hand_frame,
                T_W_S,
                K,
                rgb_w,
                rgb_h,
                args.z_near,
            )
            total_visible += int(stats["visible"])
            if processed < args.summary_sample_frames:
                per_track_samples.append(
                    {
                        "frame": processed,
                        "timestamp": timestamp,
                        "track": track_id,
                        "head_dt_ms": None if head_dt is None else head_dt * 1000.0,
                        "hand_dt_ms": None if hand_dt is None else hand_dt * 1000.0,
                        **stats,
                    }
                )

        draw_header(image_bgr, processed, timestamp, args.eye)
        writer.write(image_bgr)

        if (
            not preview_written
            and preview_target is not None
            and timestamp >= preview_target
        ):
            cv2.imwrite(str(preview_path), image_bgr)
            preview_written = True

        processed += 1
        if args.topk is not None and processed >= args.topk:
            break

    writer.release()
    if not preview_written and processed > 0:
        cv2.imwrite(str(preview_path), image_bgr)

    summary: Dict[str, Any] = {
        "mp4": str(input_path),
        "eye": args.eye,
        "output_mp4": str(mp4v_path),
        "preview": str(preview_path) if preview_path.exists() else None,
        "frames": processed,
        "fps_from_timestamps": fps,
        "reader_rgb_fps": float(reader.get_rgb_fps()),
        "size": [rgb_w, rgb_h],
        "camera_chain": "T_H_S = raw_rgb_extrinsics @ Trans_camera([0, 0, norm(sm.HEAD_MODEL_OFFSET)]); T_W_S = T_W_H @ T_H_S",
        "head_model_offset": head_model_offset.tolist(),
        "head_model_forward_m": head_model_forward_m,
        "raw_rgb_extrinsics": raw_rgb_extrinsics.tolist(),
        "effective_t_h_s": T_H_S.tolist(),
        "hand_points_basis": "raw Godot/OpenXR world coordinates from hand_joints metadata",
        "hand_tracks": list(hand_lookups.keys()),
        "head_frames": len(head_lookup),
        "visible_joint_splats": total_visible,
        "per_track_samples": per_track_samples,
    }
    summary_path = mp4v_path.parent / f"{mp4v_path.stem}_summary.json"
    summary_path.write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    summary["summary"] = str(summary_path)
    return summary


def parse_args(argv: Optional[Sequence[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Render Pico hand poses onto SpatialMP4 left/right RGB using pure OpenCV/Numpy projection.",
    )
    parser.add_argument("--input", required=True, type=Path, help="Input SpatialMP4 capture.")
    parser.add_argument("--output-dir", type=Path, default=None, help="Directory for video, preview, and summary.")
    parser.add_argument("--eye", choices=("left", "right"), default="left", help="RGB eye image and calibration to use.")
    parser.add_argument("--max-hand-dt", type=float, default=0.08, help="Max seconds between RGB and hand sample.")
    parser.add_argument("--z-near", type=float, default=0.05, help="Near clipping plane for projected joints.")
    parser.add_argument("--preview-seconds", type=float, default=7.0, help="Preview frame time relative to first RGB timestamp.")
    parser.add_argument("--summary-sample-frames", type=int, default=10, help="Number of early RGB frames sampled in summary.")
    parser.add_argument("--topk", type=int, default=None, help="Limit processing to first K RGB frames.")
    return parser.parse_args(argv)


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = parse_args(argv)
    summary = write_projection_video(args)
    info(f"wrote mp4v: {summary['output_mp4']}")
    if summary.get("output_h264"):
        info(f"wrote h264: {summary['output_h264']}")
    if summary.get("preview"):
        info(f"wrote preview: {summary['preview']}")
    info(f"wrote summary: {summary['summary']}")
    info(f"frames={summary['frames']} fps={summary['fps_from_timestamps']:.6f}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
