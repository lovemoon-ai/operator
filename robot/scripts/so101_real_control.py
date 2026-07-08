#!/usr/bin/env python3
"""SO-101 real-hardware JSONL control process for robot-adapter.

This control process intentionally keeps LeRobot/Feetech hardware I/O in
Python, close to the SO-101 reference controller. Rust talks to it with one
JSON object per line on stdin/stdout.
"""

from __future__ import annotations

import argparse
import json
import math
import re
import shutil
import sys
import tempfile
import time
from dataclasses import dataclass, field
from numbers import Real
from pathlib import Path
from typing import Any
import xml.etree.ElementTree as ET

try:
    import mujoco
    import numpy as np
except Exception as exc:  # noqa: BLE001 - reported when IK is initialized.
    mujoco = None
    np = None
    MUJOCO_IMPORT_ERROR = exc
else:
    MUJOCO_IMPORT_ERROR = None

MOTOR_NAMES = [
    "shoulder_pan",
    "shoulder_lift",
    "elbow_flex",
    "wrist_flex",
    "wrist_roll",
    "gripper",
]
ARM_MOTOR_NAMES = MOTOR_NAMES[:-1]
EE_SITE = "gripperframe"
GRIPPER_RAD_MIN = -0.17453
GRIPPER_RAD_MAX = 1.74533
REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_KINEMATICS_MODEL = (
    REPO_ROOT
    / "examples"
    / "mujuco-arm-so101"
    / "assets"
    / "so101"
    / "scene_pickplace.xml"
)


@dataclass(frozen=True)
class ReflexConfig:
    current_limit: dict[str, int] = field(
        default_factory=lambda: {
            "shoulder_pan": 430,
            "shoulder_lift": 430,
            "elbow_flex": 430,
            "wrist_flex": 360,
            "wrist_roll": 320,
            "gripper": 260,
        }
    )
    load_limit: dict[str, int] = field(
        default_factory=lambda: {
            "shoulder_pan": 780,
            "shoulder_lift": 780,
            "elbow_flex": 780,
            "wrist_flex": 680,
            "wrist_roll": 640,
            "gripper": 900,
        }
    )
    consecutive_samples: int = 2
    retreat_step: dict[str, float] = field(
        default_factory=lambda: {
            "shoulder_pan": 0.0,
            "shoulder_lift": -2.0,
            "elbow_flex": 2.0,
            "wrist_flex": -2.0,
            "wrist_roll": 0.0,
            "gripper": 0.0,
        }
    )


@dataclass(frozen=True)
class RobotConfig:
    port: str
    max_step: dict[str, float] = field(
        default_factory=lambda: {
            "shoulder_pan": 2.0,
            "shoulder_lift": 3.0,
            "elbow_flex": 3.0,
            "wrist_flex": 3.0,
            "wrist_roll": 3.0,
            "gripper": 3.0,
        }
    )
    goal_tolerance: dict[str, float] = field(
        default_factory=lambda: {
            "shoulder_pan": 1.2,
            "shoulder_lift": 2.2,
            "elbow_flex": 2.2,
            "wrist_flex": 1.8,
            "wrist_roll": 2.0,
            "gripper": 2.0,
        }
    )
    settle_s: float = 0.04
    body_p_coefficient: int = 32
    gripper_p_coefficient: int = 18
    joint_limits_deg: dict[str, tuple[float, float]] = field(
        default_factory=lambda: {
            "shoulder_pan": (-105.0, 105.0),
            "shoulder_lift": (-105.0, 105.0),
            "elbow_flex": (-100.0, 100.0),
            "wrist_flex": (-95.0, 95.0),
            "wrist_roll": (-150.0, 155.0),
            "gripper": (0.0, 100.0),
        }
    )
    reflex: ReflexConfig = field(default_factory=ReflexConfig)


@dataclass(frozen=True)
class ReflexEvent:
    reason: str
    currents: dict[str, int]
    loads: dict[str, int]
    positions: dict[str, float]


class HighCurrentReflex(RuntimeError):
    def __init__(self, event: ReflexEvent):
        super().__init__(event.reason)
        self.event = event


def emit(obj: dict[str, Any]) -> None:
    sys.stdout.write(json.dumps(obj, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def log(message: str) -> None:
    print(message, file=sys.stderr, flush=True)


def make_bus(port: str):
    from lerobot.motors import Motor, MotorNormMode
    from lerobot.motors.feetech import FeetechMotorsBus

    return FeetechMotorsBus(
        port=port,
        motors={
            "shoulder_pan": Motor(1, "sts3215", MotorNormMode.DEGREES),
            "shoulder_lift": Motor(2, "sts3215", MotorNormMode.DEGREES),
            "elbow_flex": Motor(3, "sts3215", MotorNormMode.DEGREES),
            "wrist_flex": Motor(4, "sts3215", MotorNormMode.DEGREES),
            "wrist_roll": Motor(5, "sts3215", MotorNormMode.DEGREES),
            "gripper": Motor(6, "sts3215", MotorNormMode.RANGE_0_100),
        },
    )


def decode_feetech_load(raw: int) -> int:
    magnitude = int(raw) & 0x03FF
    return -magnitude if int(raw) & 0x0400 else magnitude


def _bridge_indices(model: "mujoco.MjModel") -> dict[str, Any]:
    arm_jids = []
    arm_actids = []
    for name in ARM_MOTOR_NAMES:
        jid = mujoco.mj_name2id(model, mujoco.mjtObj.mjOBJ_JOINT, name)
        aid = mujoco.mj_name2id(model, mujoco.mjtObj.mjOBJ_ACTUATOR, name)
        if jid < 0 or aid < 0:
            raise RuntimeError(f"missing actuator/joint '{name}'")
        arm_jids.append(jid)
        arm_actids.append(aid)

    grip_actid = mujoco.mj_name2id(model, mujoco.mjtObj.mjOBJ_ACTUATOR, "gripper")
    grip_jid = mujoco.mj_name2id(model, mujoco.mjtObj.mjOBJ_JOINT, "gripper")
    site_id = mujoco.mj_name2id(model, mujoco.mjtObj.mjOBJ_SITE, EE_SITE)
    if grip_actid < 0 or grip_jid < 0:
        raise RuntimeError("missing gripper actuator/joint")
    if site_id < 0:
        raise RuntimeError(f"missing site '{EE_SITE}'")

    jids = list(arm_jids) + [grip_jid]
    return {
        "qadr": [int(model.jnt_qposadr[j]) for j in jids],
        "arm_jids": arm_jids,
        "arm_qadr": [int(model.jnt_qposadr[j]) for j in arm_jids],
        "arm_dofadr": [int(model.jnt_dofadr[j]) for j in arm_jids],
        "arm_actids": arm_actids,
        "grip_actid": grip_actid,
        "site_id": site_id,
    }


def _quat_xyzw_from_mat(mat: "np.ndarray") -> list[float]:
    quat_wxyz = np.zeros(4, dtype=np.float64)
    mujoco.mju_mat2Quat(quat_wxyz, np.asarray(mat, dtype=np.float64).reshape(9))
    return [
        float(quat_wxyz[1]),
        float(quat_wxyz[2]),
        float(quat_wxyz[3]),
        float(quat_wxyz[0]),
    ]


def _mat_from_quat_xyzw(rot: list[float]) -> "np.ndarray":
    quat_wxyz = np.array([rot[3], rot[0], rot[1], rot[2]], dtype=np.float64)
    norm = np.linalg.norm(quat_wxyz)
    if norm <= 1.0e-9:
        quat_wxyz[:] = [1.0, 0.0, 0.0, 0.0]
    else:
        quat_wxyz /= norm
    mat = np.zeros(9, dtype=np.float64)
    mujoco.mju_quat2Mat(mat, quat_wxyz)
    return mat.reshape(3, 3)


def _target_axis_from_pose(ee_pose: dict[str, Any]) -> "np.ndarray | None":
    rot = ee_pose.get("rotation")
    if rot is None:
        return None
    rotation = read_float_list(rot, expected=4, name="ee_pose.rotation")
    return _mat_from_quat_xyzw(rotation)[:, 0].copy()


def _gripper_position_to_rad(value: float) -> float:
    v = max(0.0, min(100.0, float(value))) / 100.0
    return GRIPPER_RAD_MIN + v * (GRIPPER_RAD_MAX - GRIPPER_RAD_MIN)


def _clamp_ctrl(model: "mujoco.MjModel", act_id: int, value: float) -> float:
    if bool(model.actuator_ctrllimited[act_id]):
        lo, hi = model.actuator_ctrlrange[act_id]
        return float(np.clip(value, lo, hi))
    return float(value)


def _load_mujoco_model(model_path: Path) -> "mujoco.MjModel":
    try:
        return mujoco.MjModel.from_xml_path(str(model_path))
    except ValueError as exc:
        err = str(exc)
        if (
            "unrecognized attribute: 'kv'" not in err
            and "unrecognized attribute: 'maxhullvert'" not in err
            and "resource not found" not in err
        ):
            raise
        with tempfile.TemporaryDirectory(prefix="so101_ik_model_") as tmp_name:
            tmp_dir = Path(tmp_name)
            shutil.copytree(model_path.parent, tmp_dir / model_path.parent.name)
            patched_xml = tmp_dir / model_path.parent.name / "so101.xml"
            _patch_kinematics_xml(patched_xml)
            patched_model = tmp_dir / model_path.parent.name / model_path.name
            log("SO-101 IK model: using stripped kinematics-only XML")
            return mujoco.MjModel.from_xml_path(str(patched_model))


def _patch_kinematics_xml(path: Path) -> None:
    tree = ET.parse(path)
    root = tree.getroot()

    def patch_element(elem: ET.Element) -> None:
        for attr in [
            "kv",
            "maxhullvert",
            "resolution",
            "sensorsize",
            "focal",
            "autolimits",
        ]:
            elem.attrib.pop(attr, None)

    def patch_tree(elem: ET.Element) -> None:
        patch_element(elem)
        kept = []
        for child in list(elem):
            if child.tag in ("mesh", "camera"):
                continue
            if child.tag == "body" and child.attrib.get("name") == "camera_mount":
                continue
            if child.tag == "geom" and (
                child.attrib.get("type") == "mesh" or "mesh" in child.attrib
            ):
                continue
            patch_tree(child)
            kept.append(child)
        elem[:] = kept
        if elem.tag == "body" and not any(child.tag == "inertial" for child in elem):
            ET.SubElement(
                elem,
                "inertial",
                {
                    "pos": "0 0 0",
                    "mass": "0.01",
                    "diaginertia": "1e-5 1e-5 1e-5",
                },
            )

    patch_tree(root)
    text = ET.tostring(root, encoding="unicode")
    # ElementTree may preserve unknown whitespace around removed attributes
    # poorly; this regex is a final guard for schema drift in older MuJoCo.
    text = re.sub(r'\s+(kv|maxhullvert|resolution|sensorsize|focal|autolimits)="[^"]*"', "", text)
    path.write_text(text, encoding="utf-8")


def ik_pose(
    model: "mujoco.MjModel",
    data: "mujoco.MjData",
    idx: dict[str, Any],
    target_pos: "np.ndarray",
    target_axis_world: "np.ndarray | None" = None,
    ori_weight: float = 1.0,
    max_iters: int = 96,
    tol: float = 1.0e-3,
    lam: float = 0.05,
    step: float = 0.4,
) -> tuple["np.ndarray", float]:
    """Damped least-squares IK on the five SO-101 arm joints."""
    jacp = np.zeros((3, model.nv))
    jacr = np.zeros((3, model.nv))
    last_err = np.inf

    for _ in range(max_iters):
        mujoco.mj_forward(model, data)
        site_xmat = data.site_xmat[idx["site_id"]].reshape(3, 3)
        pos_err = target_pos - data.site_xpos[idx["site_id"]]

        if target_axis_world is not None:
            cur_axis = site_xmat[:, 0]
            ori_err = np.cross(cur_axis, target_axis_world) * ori_weight
            err = np.concatenate([pos_err, ori_err])
            mujoco.mj_jacSite(model, data, jacp, jacr, idx["site_id"])
            jac = np.vstack(
                [
                    jacp[:, idx["arm_dofadr"]],
                    jacr[:, idx["arm_dofadr"]] * ori_weight,
                ]
            )
            damp = (lam**2) * np.eye(6)
        else:
            err = pos_err
            mujoco.mj_jacSite(model, data, jacp, jacr, idx["site_id"])
            jac = jacp[:, idx["arm_dofadr"]]
            damp = (lam**2) * np.eye(3)

        last_err = float(np.linalg.norm(pos_err))
        if last_err < tol and (
            target_axis_world is None or np.linalg.norm(err[3:]) < 5.0e-3
        ):
            break

        dq = jac.T @ np.linalg.solve(jac @ jac.T + damp, err)
        for k, qpos_addr in enumerate(idx["arm_qadr"]):
            data.qpos[qpos_addr] += step * dq[k]
        for k, jid in enumerate(idx["arm_jids"]):
            lo, hi = model.jnt_range[jid]
            qpos_addr = idx["arm_qadr"][k]
            data.qpos[qpos_addr] = np.clip(data.qpos[qpos_addr], lo, hi)

    return np.array([data.qpos[qpos_addr] for qpos_addr in idx["arm_qadr"]]), last_err


class SO101Kinematics:
    def __init__(self, model_path: Path):
        if MUJOCO_IMPORT_ERROR is not None:
            raise RuntimeError(f"mujoco/numpy unavailable: {MUJOCO_IMPORT_ERROR}")
        if not model_path.exists():
            raise RuntimeError(f"MuJoCo model XML not found: {model_path}")
        self.model = _load_mujoco_model(model_path)
        self.data = mujoco.MjData(self.model)
        self.ik_data = mujoco.MjData(self.model)
        self.idx = _bridge_indices(self.model)
        self.home_key = mujoco.mj_name2id(self.model, mujoco.mjtObj.mjOBJ_KEY, "home")

    def seed_from_positions(self, positions: dict[str, float], data: "mujoco.MjData") -> None:
        if self.home_key >= 0:
            mujoco.mj_resetDataKeyframe(self.model, data, self.home_key)
        else:
            mujoco.mj_resetData(self.model, data)
        for name, qpos_addr in zip(MOTOR_NAMES, self.idx["qadr"]):
            if name == "gripper":
                data.qpos[qpos_addr] = _gripper_position_to_rad(positions[name])
            else:
                data.qpos[qpos_addr] = math.radians(float(positions[name]))
        mujoco.mj_forward(self.model, data)

    def snapshot(self, positions: dict[str, float]) -> dict[str, Any]:
        self.seed_from_positions(positions, self.data)
        site_id = self.idx["site_id"]
        return {
            "position": [float(x) for x in self.data.site_xpos[site_id]],
            "rotation": _quat_xyzw_from_mat(self.data.site_xmat[site_id]),
        }

    def solve(
        self,
        positions: dict[str, float],
        ee_pose: dict[str, Any],
    ) -> tuple[dict[str, float], float]:
        target_pos = np.array(
            read_float_list(ee_pose.get("position"), expected=3, name="ee_pose.position"),
            dtype=np.float64,
        )
        target_axis = _target_axis_from_pose(ee_pose)

        self.seed_from_positions(positions, self.ik_data)
        q_target, pos_err = ik_pose(
            self.model,
            self.ik_data,
            self.idx,
            target_pos,
            target_axis_world=target_axis,
        )

        target: dict[str, float] = {}
        for k, name in enumerate(ARM_MOTOR_NAMES):
            act_id = self.idx["arm_actids"][k]
            q_rad = _clamp_ctrl(self.model, act_id, float(q_target[k]))
            target[name] = math.degrees(q_rad)
        return target, pos_err


def bus_scalar(value: Any, *, register: str, motor: str) -> Real:
    if isinstance(value, Real):
        return value
    if hasattr(value, "item"):
        item = value.item()
        if isinstance(item, Real):
            return item
    if isinstance(value, (tuple, list)) and value:
        return bus_scalar(value[0], register=register, motor=motor)
    raise TypeError(f"Expected scalar bus value for {register} on {motor}, got {value!r}")


class SO101SafeController:
    def __init__(self, cfg: RobotConfig):
        self.cfg = cfg
        self.bus = make_bus(cfg.port)
        self._last_safe_position: dict[str, float] | None = None
        self._current_hits = {name: 0 for name in MOTOR_NAMES}
        self._load_hits = {name: 0 for name in MOTOR_NAMES}

    @property
    def is_connected(self) -> bool:
        return bool(self.bus.is_connected)

    def connect(self) -> None:
        self.bus.connect(handshake=True)
        self.bus.calibration = self.bus.read_calibration()
        self._last_safe_position = self.positions()

    def disconnect(self, disable_torque: bool = True) -> None:
        if self.bus.is_connected:
            self.bus.disconnect(disable_torque=disable_torque)

    def configure_conservative(self) -> None:
        current = self.positions()
        torque_state = self._raw_register("Torque_Enable")
        if any(int(v) for v in torque_state.values()):
            self.bus.sync_write("Goal_Position", current, normalize=True)
            self.bus.disable_torque()
        for motor in MOTOR_NAMES:
            self.bus.write("Acceleration", motor, 80, normalize=False)
            self.bus.write(
                "P_Coefficient",
                motor,
                self.cfg.gripper_p_coefficient
                if motor == "gripper"
                else self.cfg.body_p_coefficient,
                normalize=False,
            )
            self.bus.write("I_Coefficient", motor, 0, normalize=False)
            self.bus.write("D_Coefficient", motor, 32, normalize=False)
        self.bus.write("Max_Torque_Limit", "gripper", 420, normalize=False)
        self.bus.write(
            "Protection_Current",
            "gripper",
            min(self.cfg.reflex.current_limit["gripper"], 250),
            normalize=False,
        )
        self.bus.write("Overload_Torque", "gripper", 20, normalize=False)
        self.bus.sync_write("Goal_Position", current, normalize=True)
        self.bus.enable_torque()

    def enable_torque(self) -> None:
        if not self.bus.is_connected:
            self.connect()
        self.bus.enable_torque()
        self.bus.sync_write("Goal_Position", self.positions(), normalize=True)

    def emergency_stop(self) -> None:
        if not self.bus.is_connected:
            return
        current = self.positions()
        self.bus.sync_write("Goal_Position", current, normalize=True)
        self.bus.disable_torque()

    def _raw_register(self, register: str) -> dict[str, int]:
        values = self.bus.sync_read(register, normalize=False, num_retry=1)
        return {
            name: int(bus_scalar(value, register=register, motor=name))
            for name, value in values.items()
        }

    def positions(self) -> dict[str, float]:
        raw = self._raw_register("Present_Position")
        ids_values = {self.bus.motors[name].id: value for name, value in raw.items()}
        normalized = self.bus._normalize(ids_values)
        id_to_name = {motor.id: name for name, motor in self.bus.motors.items()}
        return {
            id_to_name[id_]: float(
                bus_scalar(value, register="Present_Position", motor=id_to_name[id_])
            )
            for id_, value in normalized.items()
        }

    def currents(self) -> dict[str, int]:
        return self._raw_register("Present_Current")

    def loads(self) -> dict[str, int]:
        raw = self._raw_register("Present_Load")
        return {k: decode_feetech_load(int(v)) for k, v in raw.items()}

    def snapshot(self) -> dict[str, Any]:
        positions = self.positions()
        return {
            "positions": [positions[name] for name in MOTOR_NAMES],
            "currents": self.currents(),
            "loads": self.loads(),
            "ts_ns": time.time_ns(),
        }

    def clamp_target(self, target: dict[str, float]) -> dict[str, float]:
        clamped = dict(target)
        for name, value in clamped.items():
            limits = self.cfg.joint_limits_deg.get(name)
            if limits is None:
                continue
            lo, hi = limits
            clamped[name] = max(lo, min(hi, float(value)))
        return clamped

    def check_reflex(self) -> None:
        currents = self.currents()
        loads = self.loads()
        positions = self.positions()
        reasons: list[str] = []
        cfg = self.cfg.reflex
        for motor in MOTOR_NAMES:
            if abs(currents[motor]) > cfg.current_limit[motor]:
                self._current_hits[motor] += 1
            else:
                self._current_hits[motor] = 0
            if abs(loads[motor]) > cfg.load_limit[motor]:
                self._load_hits[motor] += 1
            else:
                self._load_hits[motor] = 0
            if self._current_hits[motor] >= cfg.consecutive_samples:
                reasons.append(f"{motor} current {currents[motor]} > {cfg.current_limit[motor]}")
            if self._load_hits[motor] >= cfg.consecutive_samples:
                reasons.append(f"{motor} load {loads[motor]} > {cfg.load_limit[motor]}")
        if reasons:
            event = ReflexEvent("; ".join(reasons), currents, loads, positions)
            self._reflex_retreat()
            raise HighCurrentReflex(event)
        self._last_safe_position = positions

    def _reflex_retreat(self) -> None:
        current = self.positions()
        target = dict(self._last_safe_position or current)
        for motor, step in self.cfg.reflex.retreat_step.items():
            target[motor] = float(current[motor] + step)
        self.bus.sync_write("Goal_Position", target, normalize=True)
        time.sleep(0.15)
        self.bus.sync_write("Goal_Position", self.positions(), normalize=True)

    def move_to(
        self,
        target: dict[str, float],
        timeout_s: float = 6.0,
        tolerance: dict[str, float] | float | None = None,
        allow_stall_success: bool = True,
    ) -> None:
        current = self.positions()
        full_target = {name: float(target.get(name, current[name])) for name in MOTOR_NAMES}
        full_target = self.clamp_target(full_target)
        if tolerance is None:
            tolerances = self.cfg.goal_tolerance
        elif isinstance(tolerance, dict):
            tolerances = {
                name: float(tolerance.get(name, self.cfg.goal_tolerance[name]))
                for name in MOTOR_NAMES
            }
        else:
            tolerances = {name: float(tolerance) for name in MOTOR_NAMES}

        started = time.monotonic()
        last_progress_t = started
        last_error = sum(abs(full_target[name] - current[name]) for name in MOTOR_NAMES)
        while True:
            self.check_reflex()
            current = self.positions()
            errors = {name: abs(full_target[name] - current[name]) for name in MOTOR_NAMES}
            if all(errors[name] <= tolerances[name] for name in MOTOR_NAMES):
                self.bus.sync_write("Goal_Position", full_target, normalize=True)
                return
            total_error = sum(errors.values())
            if total_error < last_error - 0.25:
                last_error = total_error
                last_progress_t = time.monotonic()
            elif allow_stall_success and (
                time.monotonic() - last_progress_t > 1.0
                and all(
                    abs(self.currents()[name]) < self.cfg.reflex.current_limit[name] * 0.35
                    for name in MOTOR_NAMES
                )
                and all(
                    abs(self.loads()[name]) < self.cfg.reflex.load_limit[name] * 0.35
                    for name in MOTOR_NAMES
                )
            ):
                self.bus.sync_write("Goal_Position", current, normalize=True)
                return
            if time.monotonic() - started > timeout_s:
                self.bus.sync_write("Goal_Position", current, normalize=True)
                raise TimeoutError(f"Timed out moving toward {full_target}; current={current}")
            step_target = {}
            for name in MOTOR_NAMES:
                delta = full_target[name] - current[name]
                max_step = self.cfg.max_step[name]
                if abs(delta) > max_step:
                    delta = max_step if delta > 0 else -max_step
                step_target[name] = current[name] + delta
            self.bus.sync_write("Goal_Position", step_target, normalize=True)
            time.sleep(self.cfg.settle_s)

    def command_once(self, target: dict[str, float]) -> None:
        """Issue one bounded arm step and a direct gripper goal.

        Arm joints are stepped by `max_step` so streamed teleop frames cannot
        create a large instantaneous setpoint jump. The gripper receives its
        full target because the adapter sends gripper changes sparsely; Feetech
        acceleration/current limits still apply.
        """
        self.check_reflex()
        current = self.positions()
        target = self.clamp_target(target)
        step_target = {}
        for name in MOTOR_NAMES:
            delta = float(target[name]) - current[name]
            if name != "gripper":
                max_step = self.cfg.max_step[name]
                if abs(delta) > max_step:
                    delta = max_step if delta > 0 else -max_step
            step_target[name] = current[name] + delta
        self.bus.sync_write("Goal_Position", step_target, normalize=True)
        time.sleep(self.cfg.settle_s)
        self.check_reflex()


def gripper_value_to_position(value: Any) -> float:
    return 8.0 + max(0.0, min(1.0, float(value))) * (85.0 - 8.0)


def read_float_list(value: Any, *, expected: int, name: str) -> list[float]:
    if not isinstance(value, list):
        raise ValueError(f"{name} must be a list")
    if len(value) != expected:
        raise ValueError(f"{name} must contain {expected} floats")
    out = [float(v) for v in value]
    if not all(v == v and abs(v) != float("inf") for v in out):
        raise ValueError(f"{name} contains non-finite value")
    return out


def command_target(controller: SO101SafeController, msg: dict[str, Any]) -> dict[str, float]:
    target = controller.positions()
    if "positions" in msg and msg["positions"] is not None:
        arm_positions = read_float_list(msg["positions"], expected=5, name="positions")
        for name, value in zip(ARM_MOTOR_NAMES, arm_positions):
            target[name] = value
    if "gripper" in msg and msg["gripper"] is not None:
        target["gripper"] = gripper_value_to_position(msg["gripper"])
    return target


def snapshot_with_ee(
    controller: SO101SafeController,
    kinematics: SO101Kinematics,
    *,
    ik_error: float | None = None,
) -> dict[str, Any]:
    snapshot = controller.snapshot()
    positions = dict(zip(MOTOR_NAMES, snapshot["positions"]))
    snapshot["ee"] = kinematics.snapshot(positions)
    if ik_error is not None:
        snapshot["ik_error"] = ik_error
    return snapshot


def run_bridge(args: argparse.Namespace) -> int:
    cfg = RobotConfig(port=args.port)
    controller = SO101SafeController(cfg)
    try:
        controller.connect()
        if not args.no_configure:
            controller.configure_conservative()
        kinematics_model = args.kinematics_model.resolve()
        kinematics = SO101Kinematics(kinematics_model)
        log(f"SO-101 IK model loaded: {kinematics_model}")
        emit(
            {
                "event": "ready",
                "joint_names": MOTOR_NAMES,
                **snapshot_with_ee(controller, kinematics),
            }
        )

        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
                if not isinstance(msg, dict):
                    raise ValueError("message must be a JSON object")

                if msg.get("reset"):
                    controller.move_to(
                        {
                            "shoulder_pan": 0.0,
                            "shoulder_lift": -90.0,
                            "elbow_flex": 90.0,
                            "wrist_flex": 0.0,
                            "wrist_roll": 0.0,
                            "gripper": 85.0,
                        },
                        timeout_s=args.reset_timeout,
                    )
                    emit(snapshot_with_ee(controller, kinematics))
                elif msg.get("stop"):
                    controller.emergency_stop()
                    emit(snapshot_with_ee(controller, kinematics))
                elif msg.get("enable"):
                    controller.enable_torque()
                    emit(snapshot_with_ee(controller, kinematics))
                elif isinstance(msg.get("ee_pose"), dict):
                    current = controller.positions()
                    arm_target, ik_error = kinematics.solve(current, msg["ee_pose"])
                    target = dict(current)
                    target.update(arm_target)
                    if msg.get("gripper") is not None:
                        target["gripper"] = gripper_value_to_position(msg["gripper"])
                    controller.command_once(target)
                    emit(snapshot_with_ee(controller, kinematics, ik_error=ik_error))
                elif "positions" in msg or "gripper" in msg:
                    target = command_target(controller, msg)
                    controller.command_once(target)
                    emit(snapshot_with_ee(controller, kinematics))
                else:
                    raise ValueError("unknown message")
            except HighCurrentReflex as exc:
                emit(
                    {
                        "reflex": exc.event.reason,
                        "currents": exc.event.currents,
                        "loads": exc.event.loads,
                        "positions": [exc.event.positions[name] for name in MOTOR_NAMES],
                        "ts_ns": time.time_ns(),
                    }
                )
            except Exception as exc:  # noqa: BLE001 - bridge returns errors over JSONL.
                emit({"error": str(exc), "ts_ns": time.time_ns()})
    finally:
        controller.disconnect(disable_torque=True)
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)
    control = sub.add_parser(
        "control",
        aliases=["bridge"],
        help="run stdin/stdout JSONL control process",
    )
    control.add_argument(
        "--port",
        required=True,
        help="Feetech serial port, e.g. /dev/ttyACM0",
    )
    control.add_argument(
        "--reset-timeout",
        type=float,
        default=8.0,
        help="reset/home move timeout in seconds",
    )
    control.add_argument(
        "--no-configure",
        action="store_true",
        help="skip conservative servo PID/torque setup",
    )
    control.add_argument(
        "--kinematics-model",
        type=Path,
        default=DEFAULT_KINEMATICS_MODEL,
        help="SO-101 MuJoCo XML used for FK/IK",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if args.cmd in ("control", "bridge"):
        return run_bridge(args)
    raise AssertionError(args.cmd)


if __name__ == "__main__":
    raise SystemExit(main())
