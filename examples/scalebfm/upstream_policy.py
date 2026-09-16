"""Reconstruct the real policy from the pinned upstream standalone exporter.

The upstream file is a CLI, not an importable library: it parses argv and
imports TensorRT at module scope. Load only its model/math declarations, with
an exact source fingerprint, without running that CLI or replacing its math.
"""
from __future__ import annotations

import ast
import hashlib
import math
from pathlib import Path
import sys
import types
import xml.etree.ElementTree as ET

import numpy as np

EXPORTER_SHA256 = "df14138699427ab602a83286efdd80277ed0e7ae81a70e26221375e1600eebe6"
EXPORTER_PATH = "ScaleTrack/scripts/pretrain/rsl_rl/play_export_check_humanoid_transformer_onboard.py"
DECLARATIONS = {
    "quat_apply", "quat_apply_inverse", "quat_mul", "quat_mul_inverse_left",
    "quat_mul_inverse_right", "RoPEPositionalEncoding", "RMSNorm", "SwiGLU",
    "HumanoidTransformerBlock", "TaskEmbedder", "HumanoidTransformer",
    "HumanoidTransformerPolicyWrapperWithMode", "build_mode_mappings", "parse_xml",
}


def load_definitions(upstream: Path):
    import torch

    path = upstream / EXPORTER_PATH
    source = path.read_bytes()
    if hashlib.sha256(source).hexdigest() != EXPORTER_SHA256:
        raise ValueError("Unsupported ScaleBFM exporter source; use upstream commit abd6f17c02fe0baabc14709feb8d9ea4959aa621")
    name = "_operator_scalebfm_exporter"
    if name in sys.modules:
        return sys.modules[name]
    tree = ast.parse(source, filename=str(path))
    tree.body = [node for node in tree.body
                 if isinstance(node, (ast.FunctionDef, ast.ClassDef)) and node.name in DECLARATIONS]
    if {node.name for node in tree.body} != DECLARATIONS:
        raise ValueError("Upstream exporter declarations are incomplete")
    module = types.ModuleType(name)
    module.__file__ = str(path)
    module.__dict__.update(torch=torch, nn=torch.nn, np=np, math=math, ET=ET)
    sys.modules[name] = module
    try:
        exec(compile(tree, str(path), "exec"), module.__dict__)
    except Exception:
        del sys.modules[name]
        raise
    return module


def reconstruct(checkpoint: Path, metadata: dict, mode_table: Path, upstream: Path,
                model: Path, device: str):
    import torch
    from tracking import FIVE_POINTS

    definitions = load_definitions(upstream)
    architecture = metadata["policy_architecture"]
    if metadata["joint_names"] != metadata["action_names"]:
        raise ValueError("The official raw-checkpoint wrapper requires matching joint/action ordering")
    actor = definitions.HumanoidTransformer(
        architecture["prop_obs_dim"], architecture["action_dim"], architecture["output_dim"],
        architecture["embedding_dim"], architecture["num_heads"], architecture["ff_dim"],
        architecture["num_layers"],
    )
    embedder = definitions.TaskEmbedder(
        architecture["task_obs_dim"], architecture["embedding_dim"],
        architecture["reduced_task_dim"], architecture["task_embedder_hidden_dims"],
    )
    # Do not load optimizer/critic tensors onto the GPU or unpickle arbitrary objects.
    state = torch.load(checkpoint, weights_only=True, map_location="cpu")["model_state_dict"]
    actor.load_state_dict({k.removeprefix("actor."): v for k, v in state.items()
                           if k.startswith("actor.")}, strict=True)
    embedder.load_state_dict({k.removeprefix("actor_task_embedder."): v for k, v in state.items()
                              if k.startswith("actor_task_embedder.")}, strict=True)
    modes = torch.load(mode_table, weights_only=True, map_location="cpu").float()
    if modes.shape != (8, 14) or not torch.all((modes == 0) | (modes == 1)):
        raise ValueError("Expected the official binary 8-mode, 14-link mode table")
    selected = metadata["selected_body_names"]
    five = {selected.index(name) for name in FIVE_POINTS}
    if set(torch.nonzero(modes[4]).flatten().tolist()) != five:
        raise ValueError("Mode table row 4 does not select pelvis, wrists and ankles")
    mappings = definitions.build_mode_mappings(
        modes, metadata["mode_feature_dims"], metadata["mode_mapping_with_time"]
    )
    if architecture["task_obs_dim"] != mappings.shape[-1] + modes.shape[-1]:
        raise ValueError("Task embedding dimensions disagree with the mode table")
    body_names, joint_names, parents, axes, translation, rotation = deployment_kinematics(model)
    if set(joint_names) != set(metadata["joint_names"]):
        raise ValueError("Kinematic model and checkpoint joint names disagree")
    rotation = rotation / rotation.norm(dim=-1, keepdim=True)
    wrapper = definitions.HumanoidTransformerPolicyWrapperWithMode(
        actor, embedder, mappings, modes,
        torch.tensor([metadata["default_dof_pos"]], dtype=torch.float32),
        torch.tensor([metadata["action_scale"]], dtype=torch.float32),
        metadata["history_buffer_size"], len(metadata["future_idx"]),
        translation, rotation, parents, axes,
        torch.tensor([body_names.index(name) for name in selected]),
        torch.tensor([metadata["joint_names"].index(name) for name in joint_names]),
    )
    return wrapper.eval().to(device)


def deployment_kinematics(path: Path):
    """Feed the exporter's FK from the same compiled model used by simulation.

    Its XML parser assumes one joint per body; ScaleBridge adds a fixed IMU
    leaf, which violates that assumption. Select only the floating root and
    29 hinge bodies. Reject any fixed intermediary rather than silently losing
    its transform. MuJoCo normalizes body quaternions and resolves defaults.
    """
    import mujoco
    import torch

    model = mujoco.MjModel.from_xml_path(str(path))
    if model.njnt != 30 or model.jnt_type[0] != mujoco.mjtJoint.mjJNT_FREE \
            or np.any(model.jnt_type[1:] != mujoco.mjtJoint.mjJNT_HINGE):
        raise ValueError("Expected one floating root and 29 hinge joints")
    bodies = model.jnt_bodyid.tolist()
    if len(set(bodies)) != 30 or not np.allclose(model.jnt_pos[1:], 0) \
            or not np.allclose(model.qpos0[7:], 0):
        raise ValueError("Exporter FK requires one zero-reference hinge at each body origin")
    by_id = {body_id: i for i, body_id in enumerate(bodies)}
    parents = [-1]
    for body_id in bodies[1:]:
        parent = int(model.body_parentid[body_id])
        if parent not in by_id:
            raise ValueError("Exporter FK does not support fixed intermediate links")
        parents.append(by_id[parent])
    return (
        [model.body(i).name for i in bodies],
        [model.joint(i).name for i in range(1, 30)],
        torch.tensor(parents, dtype=torch.long),
        torch.tensor(model.jnt_axis[1:], dtype=torch.float32),
        torch.tensor(model.body_pos[bodies[1:]], dtype=torch.float32),
        torch.tensor(model.body_quat[bodies[1:]], dtype=torch.float32),
    )
