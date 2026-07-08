#!/usr/bin/env python3
"""Galbot G1 JSON-line bridge for robot-adapter.

Stdout is reserved for JSON responses. Human-readable logs go to stderr.
The Rust adapter passes configuration through GALBOT_G1_BRIDGE_CONFIG.
"""

from __future__ import annotations

import json
import os
import sys
import time
import traceback
from typing import Any, Dict, Iterable, List, Mapping, Optional


LEFT_ARM = "left_arm"
RIGHT_ARM = "right_arm"
LEFT_GRIPPER = "left_gripper"
RIGHT_GRIPPER = "right_gripper"


DEFAULT_CFG: Dict[str, Any] = {
    "reference_frame": "world",
    "startup_delay_s": 2.0,
    "gripper": {
        "closed_width_m": 0.02,
        "open_width_m": 0.10,
        "velocity_mps": 0.05,
        "effort": 10.0,
    },
    "reset": {
        "joint_groups": ["leg", "head", "left_arm", "right_arm"],
        "joint_positions_rad": [
            0.5,
            1.5,
            1.0,
            0.0,
            0.0,
            0.0,
            0.0,
            2.0,
            -1.5,
            -0.6,
            -1.7,
            0.0,
            -0.8,
            0.0,
            -2.0,
            1.5,
            0.6,
            1.7,
            0.0,
            0.8,
            0.0,
        ],
        "speed_rad_s": 0.12,
        "timeout_s": 20.0,
        "gripper_open_width_m": 0.10,
    },
}


def log(message: str) -> None:
    print(f"[galbot_g1_bridge] {message}", file=sys.stderr, flush=True)


def emit(payload: Mapping[str, Any]) -> None:
    sys.stdout.write(json.dumps(payload, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def deep_merge(base: Dict[str, Any], override: Mapping[str, Any]) -> Dict[str, Any]:
    merged = dict(base)
    for key, value in override.items():
        if isinstance(value, Mapping) and isinstance(merged.get(key), Mapping):
            merged[key] = deep_merge(dict(merged[key]), value)
        else:
            merged[key] = value
    return merged


def load_config() -> Dict[str, Any]:
    raw = os.environ.get("GALBOT_G1_BRIDGE_CONFIG", "")
    if not raw:
        return DEFAULT_CFG
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"invalid GALBOT_G1_BRIDGE_CONFIG JSON: {exc}") from exc
    return deep_merge(DEFAULT_CFG, parsed)


def pose_list_to_dict(pose: Iterable[Any]) -> Dict[str, List[float]]:
    values = [float(v) for v in list(pose)[:7]]
    if len(values) < 7:
        raise ValueError(f"pose must have at least 7 values, got {len(values)}")
    return {
        "position": values[:3],
        "rotation": values[3:7],
    }


def pose_dict_to_list(pose: Mapping[str, Any]) -> List[float]:
    position = [float(v) for v in pose.get("position", [])]
    rotation = [float(v) for v in pose.get("rotation", [])]
    if len(position) != 3 or len(rotation) != 4:
        raise ValueError(f"bad pose shape: {pose}")
    return position + rotation


class GalbotBridge:
    def __init__(self, cfg: Mapping[str, Any]) -> None:
        from galbot_sdk.g1 import ControlStatus, G1JointGroup, GalbotRobot

        self.cfg = cfg
        self.ControlStatus = ControlStatus
        self.G1JointGroup = G1JointGroup
        self.robot = GalbotRobot()
        self.last_ee: Dict[str, Dict[str, List[float]]] = {}
        self.last_gripper_norm: Dict[str, float] = {
            LEFT_GRIPPER: 1.0,
            RIGHT_GRIPPER: 1.0,
        }
        self.last_joints: List[float] = []

        log("initializing GalbotRobot")
        if not self.robot.init():
            raise RuntimeError("GalbotRobot.init() returned false")
        startup_delay = float(cfg.get("startup_delay_s", 2.0))
        if startup_delay > 0.0:
            time.sleep(startup_delay)

    def close(self) -> None:
        try:
            self.robot.clear_end_effector_command()
        except Exception as exc:
            log(f"clear_end_effector_command during close failed: {exc}")
        try:
            self.robot.request_shutdown()
            self.robot.wait_for_shutdown()
            self.robot.destroy()
        except Exception as exc:
            log(f"robot shutdown failed: {exc}")

    def ready_payload(self) -> Dict[str, Any]:
        self.refresh_snapshot()
        return {
            "event": "ready",
            "connected": True,
            "ee": self.last_ee,
            "gripper": self.last_gripper_norm,
            "joints": self.last_joints,
        }

    def refresh_snapshot(self) -> None:
        ee_info = self.robot.get_wbc_end_effector_poses()
        if isinstance(ee_info, Mapping):
            lee_pose = ee_info.get("lee_pose")
            ree_pose = ee_info.get("ree_pose")
            if lee_pose is not None:
                self.last_ee[LEFT_ARM] = pose_list_to_dict(lee_pose)
            if ree_pose is not None:
                self.last_ee[RIGHT_ARM] = pose_list_to_dict(ree_pose)

        self._refresh_gripper(LEFT_GRIPPER)
        self._refresh_gripper(RIGHT_GRIPPER)
        self._refresh_joints()

    def _refresh_joints(self) -> None:
        reset_cfg = self.cfg.get("reset", {})
        groups = list(reset_cfg.get("joint_groups", []))
        if not groups:
            return
        try:
            joints = self.robot.get_joint_positions(groups, [])
        except Exception as exc:
            log(f"get_joint_positions failed: {exc}")
            return
        if joints:
            self.last_joints = [float(v) for v in joints]

    def _refresh_gripper(self, name: str) -> None:
        try:
            state = self.robot.get_gripper_state(self._gripper_group(name))
        except Exception as exc:
            log(f"get_gripper_state({name}) failed: {exc}")
            return
        if state is None:
            return
        width = getattr(state, "width", None)
        if width is None:
            return
        self.last_gripper_norm[name] = self._width_to_norm(float(width))

    def handle(self, req: Mapping[str, Any]) -> Dict[str, Any]:
        if req.get("reset") is True:
            return self.reset()
        if req.get("stop") is True:
            self.robot.clear_end_effector_command()
            return self.snapshot_payload()

        ee = req.get("ee", {})
        gripper = req.get("gripper", {})
        if not isinstance(ee, Mapping) or not isinstance(gripper, Mapping):
            raise ValueError("request fields ee/gripper must be objects")

        self.apply_end_effector_targets(ee)
        self.apply_grippers(gripper)
        return self.snapshot_payload()

    def apply_end_effector_targets(self, ee: Mapping[str, Any]) -> None:
        if not ee:
            return
        poses: List[List[float]] = []
        frames: List[str] = []
        reference_frames: List[str] = []
        reference_frame = str(self.cfg.get("reference_frame", "world"))

        for arm in (LEFT_ARM, RIGHT_ARM):
            if arm not in ee:
                continue
            pose = pose_dict_to_list(ee[arm])
            poses.append(pose)
            frames.append(f"{arm}_end_effector_mount_link")
            reference_frames.append(reference_frame)
            self.last_ee[arm] = pose_list_to_dict(pose)

        if not poses:
            return

        kwargs = {
            "poses": poses,
            "end_effector_frames": frames,
            "reference_frames": reference_frames,
        }
        result = self.robot.set_end_effector_command(**kwargs)
        self._check_optional_status("set_end_effector_command", result)

    def apply_grippers(self, gripper: Mapping[str, Any]) -> None:
        for name in (LEFT_GRIPPER, RIGHT_GRIPPER):
            if name not in gripper:
                continue
            value = max(0.0, min(1.0, float(gripper[name])))
            width_m = self._norm_to_width(value)
            group = self._gripper_group(name)
            gcfg = self.cfg.get("gripper", {})
            status = self.robot.set_gripper_command(
                group,
                width_m,
                float(gcfg.get("velocity_mps", 0.05)),
                float(gcfg.get("effort", 10.0)),
                False,
            )
            self._check_status(f"set_gripper_command({name})", status)
            self.last_gripper_norm[name] = value

    def reset(self) -> Dict[str, Any]:
        reset_cfg = self.cfg.get("reset", {})
        self.robot.clear_end_effector_command()

        groups = list(reset_cfg.get("joint_groups", []))
        positions = [float(v) for v in reset_cfg.get("joint_positions_rad", [])]
        if groups and positions:
            status = self.robot.set_joint_positions(
                positions,
                groups,
                [],
                True,
                float(reset_cfg.get("speed_rad_s", 0.12)),
                float(reset_cfg.get("timeout_s", 20.0)),
            )
            self._check_status("set_joint_positions(reset)", status)

        open_width = float(reset_cfg.get("gripper_open_width_m", self._open_width()))
        gcfg = self.cfg.get("gripper", {})
        for name in (LEFT_GRIPPER, RIGHT_GRIPPER):
            status = self.robot.set_gripper_command(
                self._gripper_group(name),
                open_width,
                float(gcfg.get("velocity_mps", 0.05)),
                float(gcfg.get("effort", 10.0)),
                True,
            )
            self._check_status(f"set_gripper_command({name}, reset)", status)
            self.last_gripper_norm[name] = self._width_to_norm(open_width)

        time.sleep(0.2)
        self.refresh_snapshot()
        return self.snapshot_payload()

    def snapshot_payload(self) -> Dict[str, Any]:
        return {
            "connected": True,
            "ee": self.last_ee,
            "gripper": self.last_gripper_norm,
            "joints": self.last_joints,
        }

    def _gripper_group(self, name: str) -> Any:
        if name == LEFT_GRIPPER:
            return self.G1JointGroup.left_gripper
        if name == RIGHT_GRIPPER:
            return self.G1JointGroup.right_gripper
        raise ValueError(f"unknown gripper {name}")

    def _norm_to_width(self, value: float) -> float:
        closed = self._closed_width()
        opened = self._open_width()
        return closed + value * (opened - closed)

    def _width_to_norm(self, width_m: float) -> float:
        closed = self._closed_width()
        opened = self._open_width()
        denom = opened - closed
        if abs(denom) < 1e-9:
            return 1.0
        return max(0.0, min(1.0, (width_m - closed) / denom))

    def _closed_width(self) -> float:
        return float(self.cfg.get("gripper", {}).get("closed_width_m", 0.02))

    def _open_width(self) -> float:
        return float(self.cfg.get("gripper", {}).get("open_width_m", 0.10))

    def _check_status(self, op: str, status: Any) -> None:
        if status is True:
            return
        if status != self.ControlStatus.SUCCESS:
            raise RuntimeError(f"{op} failed: {status}")

    def _check_optional_status(self, op: str, status: Any) -> None:
        if status is None or status is True:
            return
        if status != self.ControlStatus.SUCCESS:
            raise RuntimeError(f"{op} failed: {status}")


def main() -> int:
    bridge: Optional[GalbotBridge] = None
    try:
        cfg = load_config()
        bridge = GalbotBridge(cfg)
        emit(bridge.ready_payload())
    except Exception as exc:
        emit({"error": str(exc)})
        traceback.print_exc(file=sys.stderr)
        return 1

    try:
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                req = json.loads(line)
                if not isinstance(req, Mapping):
                    raise ValueError("request must be a JSON object")
                emit(bridge.handle(req))
            except Exception as exc:
                emit({"error": str(exc)})
                traceback.print_exc(file=sys.stderr)
    finally:
        bridge.close()

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
