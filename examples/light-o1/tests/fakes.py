"""Deterministic stand-ins for the Light-O1 facade and the Sonic simulator.

They reproduce the *shapes* of the real objects (a reference stream that yields
2.5 control ticks per action frame, a simulator with ``data.qpos``/``qadr``)
so the rollout and session logic can be exercised without a checkout, ONNX
weights, or MuJoCo. They do not imitate the policy.
"""
from types import SimpleNamespace

import numpy as np

from light_o1_vr.generator import GeneratedAction

JOINT_NAMES = tuple(f"joint_{i}" for i in range(29))


class FakeStream:
    def __init__(self, reference, *, replan_frames, lookahead_frames):
        if replan_frames < 1 or lookahead_frames < 1:
            raise ValueError("positive frames")
        self.frames = len(reference["joints"])
        self.replan_frames = replan_frames

    def __iter__(self):
        for start in range(0, self.frames, self.replan_frames):
            end = min(start + self.replan_frames, self.frames)
            yield round(start * 2.5), round(end * 2.5), {"joints": np.zeros((4, 24, 3))}


class FakeLightO1:
    joint_names = JOINT_NAMES
    action_fps = 20.0
    control_hz = 50.0

    def __init__(self, fail_reference=False):
        self.fail_reference = fail_reference
        self.references = 0

    def to_reference(self, action):
        if self.fail_reference:
            raise ValueError("bad action")
        self.references += 1
        frames = len(action)
        return {"joints": np.zeros((frames, 24, 3), np.float32),
                "root_rotation": np.tile(np.eye(3, dtype=np.float32), (frames, 1, 1)),
                "wrist_rotation": np.tile(np.eye(3, dtype=np.float32), (frames, 2, 1, 1))}

    def reference_stream(self, reference, *, replan_frames, lookahead_frames):
        return FakeStream(reference, replan_frames=replan_frames, lookahead_frames=lookahead_frames)

    def heading(self, rotation):
        return np.eye(3)


class FakeSimulator:
    """Each control tick moves the pelvis 1 cm forward and bends the first joint."""

    def __init__(self, fall_after_ticks=None, step_hook=None):
        self.data = SimpleNamespace(qpos=np.zeros(36))
        self.qadr = np.arange(7, 36)
        self.heading_alignment = np.eye(3)
        self.model = SimpleNamespace(name="fake")
        self.fall_after_ticks = fall_after_ticks
        self.step_hook = step_hook
        self.steps = 0
        self.resets = 0
        self.warmups = 0
        self.reset()

    def reset(self):
        self.data.qpos[:] = 0.0
        self.data.qpos[2] = 0.8
        self.data.qpos[3] = 1.0
        self.data.qpos[7:] = 0.25
        self.steps = 0
        self.resets += 1

    def warmup(self):
        self.warmups += 1

    def rotation(self):
        return np.eye(3)

    def step(self, chunk, frame, crane_scale=0.0):
        self.steps += 1
        self.data.qpos[0] += 0.01
        self.data.qpos[7] = 0.25 + 0.1 * frame
        if self.fall_after_ticks is not None and self.steps > self.fall_after_ticks:
            self.data.qpos[2] = 0.2
        if self.step_hook is not None:
            self.step_hook(self)


class FakeGenerator:
    """Returns a fixed-length zero action; optionally blocks until released."""

    source = "fake"

    def __init__(self, frames=8, gate=None, error=None):
        self.frames = frames
        self.gate = gate
        self.error = error
        self.calls = []

    def ready(self):
        return True

    def generate(self, prompt, *, seed=0, thinking=True, cancel=None):
        self.calls.append((prompt, seed, thinking))
        if self.gate is not None:
            while not self.gate.wait(0.01):
                if cancel is not None and cancel.is_set():
                    from light_o1_vr.generator import GenerationCancelled
                    raise GenerationCancelled("cancelled by test")
        if self.error is not None:
            raise self.error
        return GeneratedAction(prompt=prompt, action=np.zeros((self.frames, 138), np.float32),
                               reasoning="fake reasoning", source=self.source)


def blueprint_for_tests(distance=2.5, face_user=True):
    """The example Blueprint with a stand-in asset (no GLB needed)."""
    from pyoperator import BlueprintComponent
    from light_o1_vr.presentation import blueprint

    def component(id, asset_port, **kwargs):
        return BlueprintComponent.robot_model(id, asset_sha256="a" * 64, asset_size=100, asset_port=asset_port,
                                              joint_names=list(JOINT_NAMES), **kwargs)

    return blueprint(SimpleNamespace(component=component), 63904, distance=distance, face_user=face_user)
