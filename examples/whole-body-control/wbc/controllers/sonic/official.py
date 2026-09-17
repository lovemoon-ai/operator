"""Load the pinned upstream VR algorithms without launching its CLI or SDK.

Only explicitly named declarations are executed. Their implementations stay
upstream-owned: body/root transforms, anatomical offsets, both calibration
stages are not reimplemented here. Live button/velocity semantics are provided
by Operator's shared gamepad layer; original joystick declarations remain for
upstream conformance checks.
"""
from __future__ import annotations

import ast
from enum import Enum, IntEnum
import hashlib
import importlib
from pathlib import Path
import sys
import types
from typing import Dict

import numpy as np
from scipy.spatial.transform import Rotation

from .parameters import UPSTREAM_COMMIT

STREAMER = "gear_sonic/scripts/pico_manager_thread_server.py"
VISUALIZER = "gear_sonic/utils/teleop/vis/vr3pt_pose_visualizer.py"
FINGERPRINTS = {
    STREAMER: "728557bea52ee8dddea0d8cc6f54d8a74779d071bd6bd193de194080b90e897c",
    VISUALIZER: "f223df8e7e1863e37a423aa80619e0ea42a67f1569df9c1d6e2487af08c4d3a6",
    "gear_sonic/data/robot_model/robot_model.py": "f69e637da1df27441ef86a3dfafc33f35fab41216d2a44cc87515b287989455d",
    "gear_sonic/data/robot_model/instantiation/g1.py": "801fe771bd3a61ec74d59f73952d34605dca089cbca5e42d8333e344d342f864",
    "gear_sonic/data/robot_model/supplemental_info/g1/g1_supplemental_info.py": "d9b07ca20228442f806e9bb85cd082b6952bffee9ce1fcec53288f01a09b49da",
    "gear_sonic/utils/teleop/zmq/zmq_planner_sender.py": "f33d7715d36cda8ae64b7ce48d4f5a4c74d73fb1eb9a6c17fe85b3456b023f63",
    "gear_sonic/utils/teleop/solver/hand/g1_gripper_ik_solver.py": "1819bc011d022e2e9567e5209bc8c5b4f3f328c1275ab5cfeb0a8e0a2e9b9c25",
    "gear_sonic/trl/utils/rotation_conversion.py": "a2c350e42cc4e7eb906755867f1d977733d190925f22419e4b2e285ffac2bfa1",
    "gear_sonic/trl/utils/torch_transform.py": "4d40e3ac765cb2541aacd8af60f1162914e4ce97b4cc8fadc871a7c6a2fe7b41",
    "gear_sonic/trl/utils/kornia_transform.py": "576c2209f8f85f38c59c182d6f504cde34899adca68fea2ad50e626c5e03a0f1",
    "gear_sonic/isaac_utils/rotations.py": "b800cc97757ea452e04c12b16b70a2847b5cb08c041b521e32e7347b05479d99",
    "gear_sonic/isaac_utils/maths.py": "6664aca11cf24e78d749a6c415422566a8c1c29ddd7b8221732874a423ce5bce",
    "gear_sonic/data/human/human_joints_info.pkl": "4de0bae69caf31e8829a2d3e8adecd887f29115af60a0b8d59237dfbfea1c975",
    "gear_sonic/data/robot_model/model_data/g1/g1_29dof_with_hand.urdf": "3dcb9c361753f464fa1f0238cdf800af842909628fd153733075607881c12d62",
    "gear_sonic/data/robot_model/model_data/g1/g1_29dof_with_hand.xml": "58c82f77753db54f8a6ca0a8e020e142b015d8587db6cfc442f9a75f2bc444c6",
    "gear_sonic/data/robot_model/model_data/g1/scene_43dof.xml": "274e7b3755dc1eedcf210af54d1c97749f31457d77ae2c499ec234e804065b21",
}


def source_bytes(upstream: Path, relative: str) -> bytes:
    source = (upstream / relative).read_bytes()
    if hashlib.sha256(source).hexdigest() != FINGERPRINTS[relative]:
        raise ValueError(f"Unsupported SONIC source {relative}; use {UPSTREAM_COMMIT}")
    return source


def declarations(source: bytes, filename: str, names: set[str], namespace: dict):
    tree = ast.parse(source, filename=filename)
    selected, found = [], set()
    for node in tree.body:
        declared = set()
        if isinstance(node, (ast.FunctionDef, ast.ClassDef)):
            declared.add(node.name)
        elif isinstance(node, ast.Assign):
            declared.update(target.id for target in node.targets if isinstance(target, ast.Name))
        if declared & names:
            selected.append(node)
            found.update(declared & names)
    if found != names:
        raise ValueError(f"Incomplete pinned declarations in {filename}: {names - found}")
    tree.body = selected
    exec(compile(tree, filename, "exec"), namespace)


def load_vr_algorithms(upstream: Path):
    module = types.ModuleType("_operator_sonic_vr_algorithms")
    module.__dict__.update(np=np, sRot=Rotation, R=Rotation, Enum=Enum, IntEnum=IntEnum, Dict=Dict)
    declarations(source_bytes(upstream, VISUALIZER), str(upstream / VISUALIZER), {
        "G1_LEFT_WRIST_FRAME", "G1_RIGHT_WRIST_FRAME", "G1_TORSO_FRAME",
        "G1_KEY_FRAME_OFFSETS", "G1_FRAME_MAPPING", "get_g1_key_frame_poses",
    }, module.__dict__)
    declarations(source_bytes(upstream, STREAMER), str(upstream / STREAMER), {
        "LocomotionMode", "StreamMode", "OFFSETS", "_compute_rel_transform",
        "_process_3pt_pose", "ThreePointPose", "JOYSTICK_DEADZONE", "YawAccumulator",
    }, module.__dict__)
    return module


def make_robot_model(upstream: Path):
    for relative in FINGERPRINTS:
        if relative.startswith("gear_sonic/data/robot_model/"):
            source_bytes(upstream, relative)
    root = str(upstream.resolve())
    if root not in sys.path:
        sys.path.insert(0, root)
    module = importlib.import_module("gear_sonic.data.robot_model.instantiation.g1")
    if not Path(module.__file__).resolve().is_relative_to(upstream.resolve()):
        raise RuntimeError("Another gear_sonic checkout is already imported; use a fresh process")
    return module.instantiate_g1_robot_model()
