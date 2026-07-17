"""Latest-only Operator controller source with physical-arm safety gating."""

from __future__ import annotations

import time
from dataclasses import dataclass

import numpy as np
from operator_isaacteleop import (
    ControllerSample,
    ControlSample,
    Kind,
    LatestSampleStore,
    UnixDatagramReceiver,
)

from .config import OperatorControllerConfig


class OperatorKillRequested(RuntimeError):
    """Operator explicitly disconnected or requested a hard stop."""


@dataclass(frozen=True, slots=True)
class OperatorControllerFrame:
    """One coherent control decision plus the raw timing metadata used to make it."""

    grip_pos: np.ndarray
    grip_quat: np.ndarray
    squeeze: float = 0.0
    trigger: float = 0.0
    tracking: bool = False
    control_fresh: bool = False
    deadman: bool = False
    armed: bool = False
    engaged: bool = False
    reset: bool = False
    kill: bool = False
    sequence: int = -1
    raw_sample_time_ns: int = -1
    common_sample_time_ns: int = -1
    available_time_ns: int = -1
    control_sequence: int = -1
    control_raw_sample_time_ns: int = -1
    control_common_sample_time_ns: int = -1
    control_available_time_ns: int = -1

    @classmethod
    def empty(cls) -> OperatorControllerFrame:
        return cls(
            grip_pos=np.zeros(3, dtype=np.float32),
            grip_quat=np.array([0.0, 0.0, 0.0, 1.0], dtype=np.float32),
        )

    def dataset_frame(self) -> dict[str, np.ndarray]:
        """Exact transport metadata and raw operator command for LeRobotDataset."""

        return {
            "operator.pose": np.concatenate([self.grip_pos, self.grip_quat]).astype(
                np.float32, copy=False
            ),
            "operator.axes": np.asarray([self.squeeze, self.trigger], dtype=np.float32),
            "operator.status": np.asarray(
                [
                    self.tracking,
                    self.control_fresh,
                    self.deadman,
                    self.armed,
                    self.engaged,
                    self.reset,
                    self.kill,
                ],
                dtype=np.uint8,
            ),
            "operator.timestamps_ns": np.asarray(
                [
                    self.raw_sample_time_ns,
                    self.common_sample_time_ns,
                    self.available_time_ns,
                ],
                dtype=np.int64,
            ),
            "operator.sequence": np.asarray([self.sequence], dtype=np.int64),
            "operator.control_timestamps_ns": np.asarray(
                [
                    self.control_raw_sample_time_ns,
                    self.control_common_sample_time_ns,
                    self.control_available_time_ns,
                ],
                dtype=np.int64,
            ),
            "operator.control_sequence": np.asarray([self.control_sequence], dtype=np.int64),
        }


OPERATOR_DATASET_FEATURES: dict[str, dict] = {
    "operator.pose": {
        "dtype": "float32",
        "shape": (7,),
        "names": ["x", "y", "z", "qx", "qy", "qz", "qw"],
    },
    "operator.axes": {
        "dtype": "float32",
        "shape": (2,),
        "names": ["squeeze", "trigger"],
    },
    "operator.status": {
        "dtype": "uint8",
        "shape": (7,),
        "names": [
            "tracking",
            "control_fresh",
            "deadman",
            "armed",
            "engaged",
            "reset",
            "kill",
        ],
    },
    "operator.timestamps_ns": {
        "dtype": "int64",
        "shape": (3,),
        "names": ["raw_sample", "common_sample", "available"],
    },
    "operator.sequence": {
        "dtype": "int64",
        "shape": (1,),
        "names": ["rctl"],
    },
    "operator.control_timestamps_ns": {
        "dtype": "int64",
        "shape": (3,),
        "names": ["raw_sample", "common_sample", "available"],
    },
    "operator.control_sequence": {
        "dtype": "int64",
        "shape": (1,),
        "names": ["ctrl"],
    },
}


class OperatorControllerSource:
    """Read fresh ``RCTL/LCTL + CTRL`` packets from Operator's UDS gateway.

    ``run_toggle`` maintains a local armed latch. Releasing grip/deadman only
    disengages the clutch so it can be repositioned; a stale/missing CTRL
    channel disarms and requires an explicit re-arm. ``kill`` is surfaced to
    the owner so it can disconnect the follower and disable torque promptly.
    """

    def __init__(
        self,
        config: OperatorControllerConfig,
        *,
        receiver: UnixDatagramReceiver | None = None,
    ) -> None:
        self.config = config
        self._kind = Kind.RIGHT_CONTROLLER if config.hand_side == "right" else Kind.LEFT_CONTROLLER
        self._base_T_anchor = _validate_transform(config.base_T_anchor)
        self._receiver = receiver
        self._owns_receiver = receiver is None
        self._armed = not config.require_run_toggle
        self._connected = False
        self._last_frame = OperatorControllerFrame.empty()

    @property
    def is_connected(self) -> bool:
        return self._connected

    @property
    def last_frame(self) -> OperatorControllerFrame:
        return self._last_frame

    def connect(self) -> None:
        if self._connected:
            return
        if self._receiver is None:
            store = LatestSampleStore(
                expected_token=self.config.token,
                max_age_ns=int(self.config.max_age_ms * 1_000_000),
                transform_coordinates=False,
            )
            self._receiver = UnixDatagramReceiver(self.config.socket_path, store=store)
        self._receiver.start(background=True)
        self._connected = True

    def close(self) -> None:
        if self._receiver is not None and self._owns_receiver:
            self._receiver.close()
            self._receiver = None
        self._connected = False
        self._armed = not self.config.require_run_toggle
        self._last_frame = OperatorControllerFrame.empty()

    def disarm(self) -> None:
        self._armed = not self.config.require_run_toggle

    def wait_for_tracking(self) -> OperatorControllerFrame:
        deadline = time.monotonic() + self.config.wait_timeout_s
        while time.monotonic() < deadline:
            frame = self.read()
            if frame.kill:
                raise OperatorKillRequested("Operator requested stop while waiting for tracking")
            if frame.tracking and frame.control_fresh:
                return frame
            time.sleep(1.0 / 30.0)
        raise TimeoutError(
            f"no fresh {self._kind.name} + CTRL packets arrived at "
            f"{self.config.socket_path} within {self.config.wait_timeout_s:.1f}s"
        )

    def read(self, *, now_ns: int | None = None) -> OperatorControllerFrame:
        if not self._connected or self._receiver is None:
            raise RuntimeError("OperatorControllerSource is not connected")
        now = time.monotonic_ns() if now_ns is None else now_ns
        bundle = self._receiver.snapshot(now_ns=now)
        timed_controller = bundle.get(self._kind)
        timed_control = bundle.get(Kind.CONTROL)

        controller = timed_controller.value if timed_controller is not None else None
        control = timed_control.value if timed_control is not None else None
        if controller is not None and not isinstance(controller, ControllerSample):
            raise TypeError(f"{self._kind.name} did not contain ControllerSample")
        if control is not None and not isinstance(control, ControlSample):
            raise TypeError("CTRL did not contain ControlSample")

        control_fresh = control is not None
        if not control_fresh:
            self._armed = False if self.config.require_run_toggle else True
        elif control.kill:
            self._armed = False
        elif control.reset:
            self._armed = False if self.config.require_run_toggle else True
        elif control.run_toggle and self.config.require_run_toggle:
            self._armed = not self._armed

        tracking = bool(controller is not None and controller.grip.valid)
        pose = controller.grip if tracking else None
        if pose is None:
            grip_pos = np.zeros(3, dtype=np.float32)
            grip_quat = np.array([0.0, 0.0, 0.0, 1.0], dtype=np.float32)
            squeeze = trigger = 0.0
        else:
            try:
                grip_pos, grip_quat = _transform_pose(
                    self._base_T_anchor,
                    np.asarray(pose.position, dtype=np.float64),
                    np.asarray(pose.orientation_xyzw, dtype=np.float64),
                )
            except ValueError:
                tracking = False
                grip_pos = np.zeros(3, dtype=np.float32)
                grip_quat = np.array([0.0, 0.0, 0.0, 1.0], dtype=np.float32)
                squeeze = trigger = 0.0
            else:
                squeeze = float(np.clip(controller.squeeze, 0.0, 1.0))
                trigger = float(np.clip(controller.trigger, 0.0, 1.0))

        deadman = bool(control.deadman) if control is not None else False
        killed = bool(control.kill) if control is not None else False
        reset = bool(control.reset) if control is not None else False
        engaged = bool(
            tracking
            and control_fresh
            and self._armed
            and deadman
            and not killed
            and squeeze > self.config.clutch_threshold
        )
        frame = OperatorControllerFrame(
            grip_pos=grip_pos,
            grip_quat=grip_quat,
            squeeze=squeeze,
            trigger=trigger,
            tracking=tracking,
            control_fresh=control_fresh,
            deadman=deadman,
            armed=self._armed,
            engaged=engaged,
            reset=reset,
            kill=killed,
            sequence=timed_controller.sequence if timed_controller is not None else -1,
            raw_sample_time_ns=(
                timed_controller.raw_sample_time_ns if timed_controller is not None else -1
            ),
            common_sample_time_ns=(
                timed_controller.common_sample_time_ns if timed_controller is not None else -1
            ),
            available_time_ns=(
                timed_controller.available_time_ns if timed_controller is not None else -1
            ),
            control_sequence=timed_control.sequence if timed_control is not None else -1,
            control_raw_sample_time_ns=(
                timed_control.raw_sample_time_ns if timed_control is not None else -1
            ),
            control_common_sample_time_ns=(
                timed_control.common_sample_time_ns if timed_control is not None else -1
            ),
            control_available_time_ns=(
                timed_control.available_time_ns if timed_control is not None else -1
            ),
        )
        self._last_frame = frame
        return frame


def _validate_transform(value: list[list[float]]) -> np.ndarray:
    transform = np.asarray(value, dtype=np.float64)
    if transform.shape != (4, 4):
        raise ValueError(f"base_T_anchor must be 4x4, got {transform.shape}")
    if not np.all(np.isfinite(transform)):
        raise ValueError("base_T_anchor must contain only finite values")
    if not np.allclose(transform[3], [0.0, 0.0, 0.0, 1.0], atol=1e-6):
        raise ValueError("base_T_anchor must be a homogeneous transform")
    rotation = transform[:3, :3]
    if not np.allclose(rotation.T @ rotation, np.eye(3), atol=1e-5):
        raise ValueError("base_T_anchor rotation must be orthonormal")
    if not np.isclose(np.linalg.det(rotation), 1.0, atol=1e-5):
        raise ValueError("base_T_anchor rotation must have determinant +1")
    return transform


def _transform_pose(
    base_T_anchor: np.ndarray,  # noqa: N803
    position: np.ndarray,
    orientation_xyzw: np.ndarray,
) -> tuple[np.ndarray, np.ndarray]:
    """Match IsaacTeleop ControllerTransform: p'=R p+t, q'=quat(R)*q."""

    rotation = base_T_anchor[:3, :3]
    translation = base_T_anchor[:3, 3]
    quat_norm = float(np.linalg.norm(orientation_xyzw))
    if quat_norm <= 1e-12 or not np.isfinite(quat_norm):
        raise ValueError("controller grip orientation must be a finite non-zero quaternion")
    input_quat = orientation_xyzw / quat_norm
    rotation_quat = _rotation_matrix_to_quat_xyzw(rotation)
    output_quat = _quat_multiply_xyzw(rotation_quat, input_quat)
    output_quat /= np.linalg.norm(output_quat)
    return (
        (rotation @ position + translation).astype(np.float32),
        output_quat.astype(np.float32),
    )


def _quat_multiply_xyzw(q1: np.ndarray, q2: np.ndarray) -> np.ndarray:
    x1, y1, z1, w1 = q1
    x2, y2, z2, w2 = q2
    return np.asarray(
        [
            w1 * x2 + x1 * w2 + y1 * z2 - z1 * y2,
            w1 * y2 - x1 * z2 + y1 * w2 + z1 * x2,
            w1 * z2 + x1 * y2 - y1 * x2 + z1 * w2,
            w1 * w2 - x1 * x2 - y1 * y2 - z1 * z2,
        ],
        dtype=np.float64,
    )


def _rotation_matrix_to_quat_xyzw(rotation: np.ndarray) -> np.ndarray:
    trace = float(np.trace(rotation))
    if trace > 0.0:
        s = 2.0 * np.sqrt(trace + 1.0)
        quat = np.asarray(
            [
                (rotation[2, 1] - rotation[1, 2]) / s,
                (rotation[0, 2] - rotation[2, 0]) / s,
                (rotation[1, 0] - rotation[0, 1]) / s,
                0.25 * s,
            ]
        )
    else:
        axis = int(np.argmax(np.diag(rotation)))
        if axis == 0:
            s = 2.0 * np.sqrt(1.0 + rotation[0, 0] - rotation[1, 1] - rotation[2, 2])
            quat = np.asarray(
                [
                    0.25 * s,
                    (rotation[0, 1] + rotation[1, 0]) / s,
                    (rotation[0, 2] + rotation[2, 0]) / s,
                    (rotation[2, 1] - rotation[1, 2]) / s,
                ]
            )
        elif axis == 1:
            s = 2.0 * np.sqrt(1.0 + rotation[1, 1] - rotation[0, 0] - rotation[2, 2])
            quat = np.asarray(
                [
                    (rotation[0, 1] + rotation[1, 0]) / s,
                    0.25 * s,
                    (rotation[1, 2] + rotation[2, 1]) / s,
                    (rotation[0, 2] - rotation[2, 0]) / s,
                ]
            )
        else:
            s = 2.0 * np.sqrt(1.0 + rotation[2, 2] - rotation[0, 0] - rotation[1, 1])
            quat = np.asarray(
                [
                    (rotation[0, 2] + rotation[2, 0]) / s,
                    (rotation[1, 2] + rotation[2, 1]) / s,
                    0.25 * s,
                    (rotation[1, 0] - rotation[0, 1]) / s,
                ]
            )
    return quat / np.linalg.norm(quat)
