"""Shared Dex3 open/close control, separate from the 29-body-joint policy.

The close posture is SONIC's middle-grasp preset. Trigger (or grip) interpolates
continuously from open to closed on each hand. Ordering is explicit by name,
never inferred from policy or Pinocchio indices.
"""
import mujoco
import numpy as np

HAND_SUFFIXES = ("thumb_0", "thumb_1", "thumb_2", "middle_0", "middle_1", "index_0", "index_1")
HAND_NAMES = tuple(f"{side}_hand_{suffix}_joint" for side in ("left", "right") for suffix in HAND_SUFFIXES)


def hand_targets(commands):
    closed = np.array([0., .7, .7, -1., -1.5, -1., -1.5])
    return (closed * max(commands.left_trigger, commands.left_grip),
            -closed * max(commands.right_trigger, commands.right_grip))


class Dex3:
    def __init__(self, model):
        ids = [mujoco.mj_name2id(model, mujoco.mjtObj.mjOBJ_JOINT, name) for name in HAND_NAMES]
        if any(i < 0 for i in ids):
            raise ValueError("Hand control requires the G1 Dex3 model with all 14 finger joints")
        if any(model.jnt_type[j] != mujoco.mjtJoint.mjJNT_HINGE for j in ids):
            raise ValueError("Dex3 requires scalar hinge joints")
        self.q_indices = model.jnt_qposadr[ids]
        self.v_indices = model.jnt_dofadr[ids]
        self.limits = model.jnt_range[ids]
        self.actuators = []
        for j in ids:
            matches = np.flatnonzero((model.actuator_trnid[:, 0] == j)
                & (model.actuator_trntype == mujoco.mjtTrn.mjTRN_JOINT))
            if len(matches) != 1:
                raise ValueError("Every Dex3 joint needs exactly one torque motor")
            self.actuators.append(int(matches[0]))
        if not np.allclose(model.actuator_gear[self.actuators, 0], 1) \
                or not np.allclose(model.actuator_gainprm[self.actuators, 0], 1) \
                or np.any(model.actuator_biastype[self.actuators] != mujoco.mjtBias.mjBIAS_NONE):
            raise ValueError("Dex3 requires unit-gear torque motors")
        self.reset()

    def reset(self):
        self.targets = np.zeros(14)

    def command(self, commands):
        self.targets = np.clip(np.concatenate(hand_targets(commands)), self.limits[:, 0], self.limits[:, 1])

    def apply(self, data):
        data.ctrl[self.actuators] = 1.5 * (self.targets - data.qpos[self.q_indices]) \
            - .1 * data.qvel[self.v_indices]
