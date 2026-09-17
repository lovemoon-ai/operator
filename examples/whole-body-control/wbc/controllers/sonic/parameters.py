"""Read data from the pinned SONIC deployment header, without executing it.

Source: NVlabs/GR00T-WholeBodyControl a0732b642c0333077e127a2f56ab0014c196bca4.
The header fingerprint includes joint order, scales, offsets and PD gains.
Only arithmetic constants are accepted, not arbitrary Python or C++ code.
"""
import ast
import hashlib
import operator
import re
from pathlib import Path

import numpy as np

UPSTREAM_COMMIT = "a0732b642c0333077e127a2f56ab0014c196bca4"
HEADER = "gear_sonic_deploy/src/g1/g1_deploy_onnx_ref/include/policy_parameters.hpp"
HEADER_SHA256 = "b9332adf07c2c9b75c9b1e0756e57c7a1c2a890d8bb0aa53c3f1905fb739b791"


def arithmetic(expression, names):
    def visit(node):
        if isinstance(node, ast.Constant) and type(node.value) in (int, float):
            return node.value
        if isinstance(node, ast.Name):
            return names[node.id]
        if isinstance(node, ast.UnaryOp) and isinstance(node.op, (ast.UAdd, ast.USub)):
            return visit(node.operand) * (-1 if isinstance(node.op, ast.USub) else 1)
        operations = {ast.Add: operator.add, ast.Sub: operator.sub, ast.Mult: operator.mul, ast.Div: operator.truediv}
        if isinstance(node, ast.BinOp) and type(node.op) in operations:
            return operations[type(node.op)](visit(node.left), visit(node.right))
        raise ValueError("Unsupported expression in SONIC parameters")
    return visit(ast.parse(expression.strip(), mode="eval").body)


def load_parameters(upstream: Path):
    source = (upstream / HEADER).read_bytes()
    if hashlib.sha256(source).hexdigest() != HEADER_SHA256:
        raise ValueError(f"Unsupported SONIC deployment parameters; use upstream {UPSTREAM_COMMIT}")
    text = source.decode()
    joint_block = re.search(r"default_angles\s*=\s*\{(.*?)\};", text, re.S).group(1)
    joint_names = re.findall(r"//\s*(\w+_joint)", joint_block)
    text = re.sub(r"/\*.*?\*/|//[^\n]*", "", text, flags=re.S)
    constants = {}
    for name, expr in re.findall(r"const double (\w+)\s*=\s*([^;]+);", text):
        constants[name] = arithmetic(expr, constants)
    values = {"joint_names": joint_names}
    for name, elements in re.findall(r"const std::(?:array|vector)<[^;]+?>\s+(\w+)\s*=\s*\{([^{}]+)\};", text):
        values[name] = np.asarray([arithmetic(e, constants) for e in elements.split(",") if e.strip()])
    for key in ("default_angles", "g1_action_scale", "kps", "kds"):
        if values[key].shape != (29,) or not np.isfinite(values[key]).all():
            raise ValueError(f"Invalid SONIC {key}")
    if len(set(joint_names)) != 29:
        raise ValueError("SONIC parameters must describe 29 unique body joints")
    for key in ("isaaclab_to_mujoco", "mujoco_to_isaaclab"):
        values[key] = values[key].astype(int)
        if sorted(values[key]) != list(range(29)):
            raise ValueError("Invalid SONIC joint permutation")
    return values
