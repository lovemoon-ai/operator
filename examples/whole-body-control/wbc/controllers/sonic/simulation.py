"""SONIC G1 torque execution: 29 body actions plus official 14 hand commands."""
from collections import deque
import mujoco
import numpy as np
from scipy.spatial.transform import Rotation

from ...tracking import base_pose_to_xr, rotation_wxyz, wxyz


class Simulation:
    DT = .02
    LOW_DT = .005

    def __init__(self, model_path, parameters):
        self.parameters = parameters
        self.model = mujoco.MjModel.from_xml_path(str(model_path.resolve()))
        self.data = mujoco.MjData(self.model)
        self.model.opt.timestep = self.LOW_DT
        self.body_joint_names = parameters["joint_names"]
        self.joint_names = [self.model.joint(i).name for i in range(1,self.model.njnt)]
        self.render_indices = self.model.jnt_qposadr[1:]
        if (self.model.nq, self.model.nv, self.model.nu) not in ((36,35,29),(50,49,43)) \
                or self.model.jnt_type[0] != mujoco.mjtJoint.mjJNT_FREE:
            raise ValueError("SONIC expects a floating G1 with 29 body joints and optional 14 hand joints")
        if not np.any((self.model.geom_type == mujoco.mjtGeom.mjGEOM_PLANE) & (self.model.geom_bodyid == 0)):
            raise ValueError("SONIC scene must include a ground plane")
        ids = [self.model.joint(name).id for name in self.body_joint_names]
        if any(self.model.jnt_type[j] != mujoco.mjtJoint.mjJNT_HINGE for j in ids):
            raise ValueError("SONIC expects scalar hinge joints")
        self.q_indices = self.model.jnt_qposadr[ids]
        self.v_indices = self.model.jnt_dofadr[ids]
        self.actuators = []
        for joint in ids:
            motors = np.flatnonzero((self.model.actuator_trnid[:, 0] == joint)
                & (self.model.actuator_trntype == mujoco.mjtTrn.mjTRN_JOINT))
            if len(motors) != 1:
                raise ValueError("Each SONIC body joint needs one torque actuator")
            self.actuators.append(int(motors[0]))
        if not np.allclose(self.model.actuator_gear[self.actuators, 0], 1) \
                or not np.allclose(self.model.actuator_gainprm[self.actuators, 0], 1) \
                or np.any(self.model.actuator_biastype[self.actuators] != mujoco.mjtBias.mjBIAS_NONE):
            raise ValueError("SONIC expects unit-gear torque motors")
        self.policy_order = parameters["mujoco_to_isaaclab"]
        self.action_order = parameters["isaaclab_to_mujoco"]
        self.hand_targets = None
        self.hand_q_indices = self.hand_v_indices = self.hand_actuators = None
        self.reset()

    def configure_hands(self, robot_model):
        # Match the official simulator/DDS ordering, which enumerates MJCF
        # joints. Its index/middle order differs from Pinocchio's group list.
        names = [name for side in ("left_hand", "right_hand")
                 for name in self.joint_names if side in name]
        expected = (robot_model.supplemental_info.left_hand_actuated_joints
                    + robot_model.supplemental_info.right_hand_actuated_joints)
        if len(names) != 14 or set(names) != set(expected):
            raise ValueError("Official SONIC requires the matching 14 hand joints")
        ids = [self.model.joint(name).id for name in names]
        self.hand_q_indices = self.model.jnt_qposadr[ids]
        self.hand_v_indices = self.model.jnt_dofadr[ids]
        self.hand_actuators = [int(np.flatnonzero(self.model.actuator_trnid[:,0] == j)[0]) for j in ids]
        self.hand_targets = np.zeros(14)

    def feedback(self):
        hands = self.data.qpos[self.hand_q_indices] if self.hand_q_indices is not None else np.zeros(14)
        return {"body_q_measured": self.data.qpos[self.q_indices].tolist(),
                "left_hand_q_measured": hands[:7].tolist(), "right_hand_q_measured": hands[7:].tolist()}

    def command_hands(self, left, right):
        if self.hand_targets is None: return
        if left is not None: self.hand_targets[:7] = np.asarray(left).reshape(7)
        if right is not None: self.hand_targets[7:] = np.asarray(right).reshape(7)

    def reset(self):
        mujoco.mj_resetData(self.model, self.data)
        self.data.qpos[self.q_indices] = self.parameters["default_angles"]
        mujoco.mj_forward(self.model, self.data)
        self.action = np.zeros(29, dtype=np.float32)
        if self.hand_targets is not None: self.hand_targets[:] = 0
        self.history = deque(maxlen=10)
        for _ in range(10):
            self.history.append(self._state())

    def _state(self):
        inverse = rotation_wxyz(self.data.qpos[3:7]).inv()
        return {
            "his_base_angular_velocity_10frame_step1": self.data.qvel[3:6].copy(),
            "his_body_joint_positions_10frame_step1": (
                self.data.qpos[self.q_indices] - self.parameters["default_angles"])[self.policy_order].copy(),
            "his_body_joint_velocities_10frame_step1": self.data.qvel[self.v_indices][self.policy_order].copy(),
            "his_last_actions_10frame_step1": self.action.copy(),
            "his_gravity_dir_10frame_step1": inverse.apply([0., 0., -1.]),
        }

    def decoder_values(self):
        return {key: np.stack([state[key] for state in self.history]) for key in self.history[0]}

    def reference_pose(self):
        # Matches deployment GatherVR3PointPosition: wrist TCPs + torso/head.
        bodies = [self.model.body(name).id for name in
                  ("left_wrist_yaw_link", "right_wrist_yaw_link", "torso_link")]
        offsets = np.array([[.18, -.025, 0], [.18, .025, 0], [0, 0, .35]])
        rotations = rotation_wxyz(self.data.xquat[bodies])
        root_inverse = rotation_wxyz(self.data.qpos[3:7]).inv()
        positions = root_inverse.apply(self.data.xpos[bodies] + rotations.apply(offsets) - self.data.qpos[:3])
        return positions, wxyz(root_inverse * rotations)

    def step(self, action):
        if action.shape != (29,) or not np.isfinite(action).all():
            raise ValueError("SONIC returned invalid actions")
        p = self.parameters
        target = p["default_angles"] + action[self.action_order] * p["g1_action_scale"]
        old_warnings = self.data.warning.number.copy()
        for _ in range(4):
            self.data.ctrl[self.actuators] = p["kps"] * (target - self.data.qpos[self.q_indices]) \
                - p["kds"] * self.data.qvel[self.v_indices]
            if self.hand_targets is not None:
                self.data.ctrl[self.hand_actuators] = 1.5 * (self.hand_targets - self.data.qpos[self.hand_q_indices]) \
                    - .1 * self.data.qvel[self.hand_v_indices]
            mujoco.mj_step(self.model, self.data)
        if not np.isfinite(self.data.qpos).all() or not np.isfinite(self.data.qvel).all() \
                or np.any(self.data.warning.number > old_warnings):
            raise ValueError("SONIC MuJoCo simulation became invalid")
        mujoco.mj_forward(self.model, self.data)
        self.action = action.copy()
        self.history.append(self._state())

    def blueprint_state(self):
        return {"g1.joints": self.data.qpos[self.render_indices].tolist(),
                "g1.base": base_pose_to_xr(self.data.qpos[:3], self.data.qpos[3:7])}
