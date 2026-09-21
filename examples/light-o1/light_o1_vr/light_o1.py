"""Locate a Light-O1 checkout and import its NumPy-only Sonic G1 stack.

Text-to-action inference stays in Light-O1's own GPU service. This host only
needs the checkout for the human-action FK adapter, the GEAR-SONIC low-latency
policy wrapper, and the vendored 29-DoF G1 MJCF. None of those import torch.
"""
from __future__ import annotations

import importlib
import sys
from pathlib import Path

import numpy as np

REQUIRED_FILES = (
    "examples/sonic/simulation.py",
    "examples/sonic/adapter.py",
    "examples/sonic/reference.py",
    "examples/sonic/policy.py",
    "examples/sonic/assets/g1/g1_29dof.xml",
    "light_deploy/action_tokenizer/fk.py",
)


def resolve_checkout(path) -> Path:
    root = Path(path).expanduser().resolve()
    missing = [rel for rel in REQUIRED_FILES if not (root / rel).is_file()]
    if missing:
        raise FileNotFoundError(
            f"{root} is not a Light-O1 checkout with the Sonic example; missing {', '.join(missing)}"
        )
    return root


class LightO1:
    """Facade over the Light-O1 modules this example uses.

    Everything the rollout needs goes through this object so tests can supply a
    lightweight stand-in without a checkout, a checkpoint, or MuJoCo.
    """

    def __init__(self, root):
        self.root = resolve_checkout(root)
        existing = sys.modules.get("examples")
        if existing is not None:
            file = getattr(existing, "__file__", None)
            if file is None:
                # A PEP 420 namespace package (for example Operator's own
                # examples/ directory on sys.path) would shadow Light-O1's
                # regular package; drop it and import the real one below.
                del sys.modules["examples"]
            elif Path(file).resolve().parent != self.root / "examples":
                raise RuntimeError(
                    "another top-level 'examples' package is already imported; "
                    "run this example from its own directory"
                )
        if str(self.root) not in sys.path:
            sys.path.insert(0, str(self.root))
        self._simulation = importlib.import_module("examples.sonic.simulation")
        self._adapter = importlib.import_module("examples.sonic.adapter")
        self._reference = importlib.import_module("examples.sonic.reference")
        self._policy = importlib.import_module("examples.sonic.policy")

    @property
    def joint_names(self) -> tuple[str, ...]:
        """The 29 G1 body joints in the policy's MuJoCo order."""
        return tuple(self._policy.JOINT_NAMES)

    @property
    def action_fps(self) -> float:
        return float(self._reference.FPS)

    @property
    def control_hz(self) -> float:
        return float(self._reference.CONTROL_HZ)

    def to_reference(self, action) -> dict[str, np.ndarray]:
        """Public ``(frames, 138)`` human action -> Sonic pelvis-relative reference."""
        return self._adapter.from_human_action(np.asarray(action, dtype=np.float32))

    def reference_stream(self, reference, *, replan_frames: int, lookahead_frames: int):
        return self._reference.ReferenceStream(
            reference, replan_frames=replan_frames, lookahead_frames=lookahead_frames
        )

    def heading(self, rotation: np.ndarray) -> np.ndarray:
        return self._simulation.heading(rotation)

    def simulator(self, checkpoint):
        """Light-O1's closed-loop Sonic simulator: ONNX policy pair + G1 MuJoCo model."""
        path = Path(checkpoint).expanduser().resolve()
        for name in ("model_encoder.onnx", "model_decoder.onnx"):
            if not (path / name).is_file():
                raise FileNotFoundError(f"Sonic low-latency checkpoint is missing {path / name}")
        return self._simulation.SonicSimulator(path)
