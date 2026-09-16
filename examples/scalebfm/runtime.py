"""Official exported ScaleBFM policy + host-only MuJoCo execution.

No IsaacLab or robot SDK is needed at runtime. The exported TorchScript wrapper
owns action scale/offset; this code must not apply them a second time.
"""
from __future__ import annotations

from collections import deque
import json
from pathlib import Path

import mujoco
import numpy as np

from tracking import FIVE_POINTS, base_pose_to_xr, rotation_wxyz, wxyz


def validate_metadata(metadata: dict) -> None:
    for key, count in (("joint_names", 29), ("action_names", 29), ("selected_body_names", 14)):
        names = metadata.get(key, [])
        if len(names) != count or any(not isinstance(n, str) or not n for n in names) \
                or len(set(names)) != count:
            raise ValueError(f"Metadata {key} must contain {count} unique names")
    if set(metadata["joint_names"]) != set(metadata["action_names"]):
        raise ValueError("This example requires the full G1 29-DoF policy")
    if not set(FIVE_POINTS).issubset(metadata["selected_body_names"]) \
            or metadata["selected_body_names"][0] != "pelvis":
        raise ValueError("Metadata does not describe G1 five-point control")
    for key in ("stiffness", "damping", "default_dof_pos"):
        values = np.asarray(metadata.get(key, []), dtype=float)
        if values.shape != (29,) or not np.isfinite(values).all():
            raise ValueError(f"Metadata {key} must contain 29 finite values")
        if key != "default_dof_pos" and (values < 0).any():
            raise ValueError(f"Metadata {key} must be non-negative")
    history = metadata.get("history_buffer_size")
    if not isinstance(history, int) or isinstance(history, bool) or not 1 <= history <= 64:
        raise ValueError("Invalid metadata history_buffer_size")
    future = metadata.get("future_idx", [])
    if len(future) != 6 or future[:5] != [0, 1, 2, 3, 4] or not 5 <= future[-1] <= 33:
        raise ValueError("Expected six future reference slots [0,1,2,3,4,X], X=5..33")


class Simulation:
    DT = 0.02
    LOW_DT = 0.005

    def __init__(self, xml_path: Path, metadata: dict):
        validate_metadata(metadata)
        self.metadata = metadata
        self.model = mujoco.MjModel.from_xml_path(str(xml_path.resolve()))
        self.data = mujoco.MjData(self.model)
        self.model.opt.timestep = self.LOW_DT
        self.joint_names = metadata["joint_names"]
        self.body_names = metadata["selected_body_names"]
        if self.model.nq != 36 or self.model.nv != 35 or self.model.nu != 29 \
                or self.model.jnt_type[0] != mujoco.mjtJoint.mjJNT_FREE:
            raise ValueError("Use ScaleBridge's floating-base g1_29dof.xml, not a kinematic XR model")
        joint_ids = [self._id(mujoco.mjtObj.mjOBJ_JOINT, n) for n in self.joint_names]
        self.q_indices = self.model.jnt_qposadr[joint_ids]
        self.v_indices = self.model.jnt_dofadr[joint_ids]
        action_joint_ids = [self._id(mujoco.mjtObj.mjOBJ_JOINT, n) for n in metadata["action_names"]]
        if any(self.model.jnt_type[i] != mujoco.mjtJoint.mjJNT_HINGE for i in joint_ids):
            raise ValueError("Expected 29 scalar hinge joints")
        self.action_q_indices = self.model.jnt_qposadr[action_joint_ids]
        self.action_v_indices = self.model.jnt_dofadr[action_joint_ids]
        self.actuators = []
        for joint_id in action_joint_ids:
            matches = np.flatnonzero(
                (self.model.actuator_trnid[:, 0] == joint_id)
                & (self.model.actuator_trntype == mujoco.mjtTrn.mjTRN_JOINT)
            )
            if len(matches) != 1:
                raise ValueError("Every G1 action needs exactly one joint motor")
            self.actuators.append(int(matches[0]))
        if not np.allclose(self.model.actuator_gear[self.actuators, 0], 1):
            raise ValueError("Expected unit-gear torque motors")
        if not np.allclose(self.model.actuator_gainprm[self.actuators, 0], 1) \
                or np.any(self.model.actuator_biastype[self.actuators] != mujoco.mjtBias.mjBIAS_NONE):
            raise ValueError("Expected torque motors, not position servos")
        self.body_ids = [self._id(mujoco.mjtObj.mjOBJ_BODY, n) for n in self.body_names]
        self.kp = np.asarray(metadata["stiffness"])
        self.kd = np.asarray(metadata["damping"])
        self.reset()

    def _id(self, kind, name: str) -> int:
        index = mujoco.mj_name2id(self.model, kind, name)
        if index < 0:
            raise ValueError(f"MuJoCo model is missing {name}")
        return index

    def reset(self) -> None:
        mujoco.mj_resetData(self.model, self.data)
        self.data.qpos[2] = 0.76  # ScaleBridge g1_29dof asset root_height.
        self.data.qpos[self.q_indices] = self.metadata["default_dof_pos"]
        mujoco.mj_forward(self.model, self.data)
        self.action = np.zeros(29, dtype=np.float32)
        self.history: deque = deque(maxlen=self.metadata["history_buffer_size"])
        for _ in range(self.history.maxlen):
            self.history.append(self._state())

    def reference_pose(self) -> tuple[np.ndarray, np.ndarray]:
        return self.data.xpos[self.body_ids].copy(), self.data.xquat[self.body_ids].copy()

    def _state(self) -> tuple[np.ndarray, ...]:
        return tuple(np.asarray(v, dtype=np.float32).copy() for v in (
            self.data.qpos[3:7], self.data.qvel[3:6],
            self.data.qpos[self.q_indices], self.data.qvel[self.v_indices], self.action,
        ))

    def inputs(self, positions: np.ndarray, rotations: np.ndarray, offsets: np.ndarray,
               local_tracking: bool) -> list[np.ndarray]:
        base = rotation_wxyz(self.data.qpos[3:7]).inv()
        # Match ScaleBridge reference_forcing: replace position, not orientation.
        root_position = positions[0, 0] if local_tracking else self.data.qpos[:3]
        target_positions = base.apply((positions - root_position).reshape(-1, 3)).reshape(1, 6, 14, 3)
        target_rotations = wxyz(base * rotation_wxyz(rotations.reshape(-1, 4))).reshape(1, 6, 14, 4)
        history = [np.stack([h[i] for h in self.history])[None] for i in range(5)]
        # The actual upstream exporter uses (1,6,1) int64 *step indices*, despite
        # the migration README abbreviating the shape to (6,).
        return [*history, target_positions.astype(np.float32), target_rotations.astype(np.float32),
                np.array([4], dtype=np.int64), offsets.reshape(1, 6, 1).astype(np.int64)]

    def step(self, target: np.ndarray, action: np.ndarray) -> None:
        if target.shape != (29,) or action.shape != (29,) \
                or not np.isfinite(target).all() or not np.isfinite(action).all():
            raise ValueError("ScaleBFM returned invalid joint targets/actions")
        old_warnings = self.data.warning.number.copy()
        for _ in range(4):
            torque = self.kp * (target - self.data.qpos[self.action_q_indices]) \
                - self.kd * self.data.qvel[self.action_v_indices]
            self.data.ctrl[self.actuators] = torque
            # The upstream XML's actuatorfrcrange enforces joint torque limits.
            mujoco.mj_step(self.model, self.data)
        if not np.isfinite(self.data.qpos).all() or not np.isfinite(self.data.qvel).all() \
                or np.any(self.data.warning.number > old_warnings):
            raise ValueError("MuJoCo state became non-finite")
        mujoco.mj_forward(self.model, self.data)
        self.action = action.copy()
        self.history.append(self._state())

    def blueprint_state(self) -> dict:
        return {
            "g1.joints": self.data.qpos[self.q_indices].tolist(),
            "g1.base": base_pose_to_xr(self.data.qpos[:3], self.data.qpos[3:7]),
        }


class Policy:
    def __init__(self, checkpoint: Path, metadata_path: Path | None = None, *,
                 backend: str = "tensorrt", device: str = "cuda", upstream: Path | None = None,
                 mode_table: Path | None = None, model: Path | None = None, threads: int = 2):
        if not checkpoint.is_file():
            raise FileNotFoundError(f"Missing ScaleBFM checkpoint: {checkpoint}")
        if metadata_path is None:
            metadata_path = checkpoint.with_name(checkpoint.stem + "_metadata.json")
            if not metadata_path.is_file():
                metadata_path = checkpoint.parent / "metadata.json"
        self.metadata = json.loads(metadata_path.read_text())
        validate_metadata(self.metadata)
        try:
            import torch
        except ImportError as exc:
            raise RuntimeError("Install PyTorch in the example environment; see README") from exc
        if threads < 1:
            raise ValueError("threads must be positive")
        torch.set_num_threads(threads)
        if device == "cuda" and not torch.cuda.is_available():
            raise RuntimeError("--device cuda requires an NVIDIA CUDA GPU and CUDA-enabled PyTorch")
        self.torch = torch
        self.device = device
        self.backend = backend
        exported = self.metadata.get("operator_export", {})
        if backend == "torchscript" and exported.get("device", device) != device:
            raise ValueError("TorchScript trace device differs from --device; export a trace for this device")
        if backend == "torch":
            if upstream is None or model is None:
                raise ValueError("Raw checkpoint inference requires --upstream and --model")
            from upstream_policy import reconstruct
            self.module = reconstruct(checkpoint, self.metadata,
                                      mode_table or checkpoint.parent / "mode_table.pt",
                                      upstream, model, device)
            return
        if backend not in ("torchscript", "tensorrt"):
            raise ValueError(f"Unsupported policy backend: {backend}")
        if backend == "tensorrt":
            if device != "cuda":
                raise ValueError("TensorRT requires --device cuda")
            try:
                import torch_tensorrt  # noqa: F401 -- register TensorRT TorchScript ops
            except ImportError as exc:
                raise RuntimeError("Install checkpoint-compatible Torch-TensorRT or use --backend torch") from exc
        try:
            self.module = torch.jit.load(str(checkpoint), map_location=device).eval()
        except Exception as exc:
            raise RuntimeError(f"Cannot load {backend} artifact; raw weights need --backend torch, TensorRT requires a compatible engine") from exc

    def tensors(self, arrays: list[np.ndarray]) -> list:
        return [self.torch.from_numpy(np.ascontiguousarray(a)).to(self.device) for a in arrays]

    def infer(self, arrays: list[np.ndarray]) -> tuple[np.ndarray, np.ndarray]:
        with self.torch.inference_mode():
            target, action = self.module(*self.tensors(arrays))
            return target.cpu().numpy().reshape(-1), action.cpu().numpy().reshape(-1)


def add_policy_arguments(parser) -> None:
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--metadata", type=Path, help="Defaults to adjacent *_metadata.json or metadata.json")
    parser.add_argument("--model", type=Path, required=True, help="ScaleBridge g1_29dof.xml (with meshes)")
    parser.add_argument("--backend", choices=("torch", "torchscript", "tensorrt"), default="torch")
    parser.add_argument("--device", choices=("cpu", "cuda"), default="cuda")
    parser.add_argument("--upstream", type=Path, help="Pinned ScaleBFM source root, needed for raw checkpoint")
    parser.add_argument("--mode-table", type=Path, help="Defaults to mode_table.pt beside raw checkpoint")
    parser.add_argument("--threads", type=int, default=2, help="PyTorch CPU thread count")


def policy_from_args(args) -> Policy:
    return Policy(args.checkpoint, args.metadata, backend=args.backend, device=args.device,
                  upstream=args.upstream, mode_table=args.mode_table, model=args.model, threads=args.threads)
