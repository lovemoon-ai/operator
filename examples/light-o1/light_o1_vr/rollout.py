"""Closed-loop GEAR-SONIC tracking of a Light-O1 action, recorded tick by tick.

This reproduces the control schedule of Light-O1's ``examples.sonic.simulation``
(100 warm-up ticks held by a virtual crane, 75 settle ticks releasing it, then
50 Hz tracking with four 5 ms torque steps per tick), but publishes the actual
simulated G1 state after every tick instead of rendering video frames. The
headset therefore shows what the policy really did, including a fall.
"""
from __future__ import annotations

import json
from pathlib import Path
import threading

import numpy as np

SETTLE_TICKS = 75
FALL_HEIGHT = 0.35
ROOT_DIM = 7  # position xyz + quaternion wxyz, MuJoCo Z-up


class Trajectory:
    """Thread-safe append-only recording of G1 states.

    Each frame is ``[x, y, z, qw, qx, qy, qz, joints...]`` with joints in
    ``joint_names`` order. Frames become visible to readers as soon as they
    are appended, so playback can start while the rollout is still running.
    """

    def __init__(self, joint_names, *, prompt: str = "", reasoning: str = "",
                 planned_s: float = 0.0, control_hz: float = 50.0):
        self.joint_names = tuple(joint_names)
        self.prompt = prompt
        self.reasoning = reasoning
        self.planned_s = float(planned_s)
        self.control_hz = float(control_hz)
        self.settle_frames = 0
        self.fell_at: float | None = None
        self.survived_s = 0.0
        self.done = False
        self.cancelled = False
        self.error: str | None = None
        self._frames: list[np.ndarray] = []
        self._lock = threading.Lock()

    @property
    def frame_dim(self) -> int:
        return ROOT_DIM + len(self.joint_names)

    def append(self, frame, *, settle: bool = False) -> None:
        array = np.asarray(frame, dtype=float)
        if array.shape != (self.frame_dim,) or not np.isfinite(array).all():
            raise ValueError(f"expected a finite frame of length {self.frame_dim}, got {array.shape}")
        with self._lock:
            self._frames.append(array.copy())
            if settle:
                self.settle_frames += 1

    def __len__(self) -> int:
        with self._lock:
            return len(self._frames)

    def frame(self, index: int) -> np.ndarray:
        with self._lock:
            if not self._frames:
                raise IndexError("trajectory has no frames yet")
            return self._frames[max(0, min(index, len(self._frames) - 1))]

    def frames(self) -> np.ndarray:
        with self._lock:
            if not self._frames:
                return np.zeros((0, self.frame_dim))
            return np.stack(self._frames)

    def finish(self, *, survived_s: float) -> None:
        self.survived_s = float(survived_s)
        self.done = True

    def cancel(self) -> None:
        self.cancelled = True
        self.done = True

    def fail(self, message: str) -> None:
        self.error = message
        self.done = True

    @property
    def ok(self) -> bool:
        return self.done and self.error is None and not self.cancelled and len(self) > 0

    @property
    def duration_s(self) -> float:
        return len(self) / self.control_hz

    def summary(self) -> dict:
        return {
            "prompt": self.prompt, "frames": len(self), "settle_frames": self.settle_frames,
            "control_hz": self.control_hz, "planned_s": self.planned_s, "survived_s": self.survived_s,
            "fell_at": self.fell_at, "cancelled": self.cancelled, "error": self.error,
        }

    def save(self, path) -> Path:
        target = Path(path)
        if target.suffix != ".npz":
            raise ValueError("trajectory path must end in .npz")
        metadata = {**self.summary(), "reasoning": self.reasoning, "joint_names": list(self.joint_names)}
        with target.open("wb") as file:
            np.savez_compressed(file, frames=self.frames(),
                                metadata=np.array(json.dumps(metadata, allow_nan=False)))
        return target

    @classmethod
    def load(cls, path) -> "Trajectory":
        with np.load(Path(path), allow_pickle=False) as archive:
            metadata = json.loads(archive["metadata"].item())
            frames = np.asarray(archive["frames"], dtype=float)
        trajectory = cls(metadata["joint_names"], prompt=metadata.get("prompt", ""),
                         reasoning=metadata.get("reasoning", ""), planned_s=metadata.get("planned_s", 0.0),
                         control_hz=metadata.get("control_hz", 50.0))
        for frame in frames:
            trajectory.append(frame)
        trajectory.settle_frames = int(metadata.get("settle_frames", 0))
        trajectory.fell_at = metadata.get("fell_at")
        trajectory.finish(survived_s=float(metadata.get("survived_s", 0.0)))
        return trajectory


def robot_state(simulator) -> np.ndarray:
    """Floating base plus the policy's 29 body joints from the live MuJoCo state."""
    qpos = simulator.data.qpos
    return np.concatenate((qpos[:3], qpos[3:7], qpos[simulator.qadr])).astype(float)


def idle_state(simulator) -> np.ndarray:
    """The default standing pose Light-O1 starts every rollout from."""
    simulator.reset()
    return robot_state(simulator)


class SonicRollout:
    """Run one reference through the Sonic simulator, recording into ``trajectory``.

    ``run()`` blocks; the owner decides which thread executes it. Only one
    rollout may use a given simulator at a time.
    """

    def __init__(self, light_o1, simulator, reference, trajectory: Trajectory, *,
                 replan_frames: int = 8, lookahead_frames: int = 12,
                 cancel: threading.Event | None = None, fall_height: float = FALL_HEIGHT):
        if replan_frames < 1 or lookahead_frames < 1:
            raise ValueError("replan_frames and lookahead_frames must be positive")
        if not 0 < fall_height < 1:
            raise ValueError("fall_height must be a pelvis height in metres between 0 and 1")
        self.light_o1 = light_o1
        self.simulator = simulator
        self.reference = reference
        self.trajectory = trajectory
        self.replan_frames = replan_frames
        self.lookahead_frames = lookahead_frames
        self.cancel = cancel or threading.Event()
        self.fall_height = fall_height

    def run(self) -> Trajectory:
        trajectory, sim = self.trajectory, self.simulator
        hz = trajectory.control_hz
        try:
            stream = self.light_o1.reference_stream(
                self.reference, replan_frames=self.replan_frames, lookahead_frames=self.lookahead_frames)
            trajectory.planned_s = stream.frames / self.light_o1.action_fps
            sim.reset()
            sim.warmup()
            tick = 0
            for start, end, chunk in stream:
                if start == 0:
                    sim.heading_alignment = (self.light_o1.heading(sim.rotation())
                                             @ self.light_o1.heading(self.reference["root_rotation"][0]).T)
                    for settle in range(SETTLE_TICKS):
                        if self.cancel.is_set():
                            trajectory.cancel()
                            return trajectory
                        sim.step(chunk, 0, crane_scale=1 - settle / SETTLE_TICKS)
                        trajectory.append(robot_state(sim), settle=True)
                for frame in range(end - start):
                    if self.cancel.is_set():
                        trajectory.cancel()
                        return trajectory
                    sim.step(chunk, frame)
                    tick += 1
                    trajectory.append(robot_state(sim))
                    if sim.data.qpos[2] < self.fall_height:
                        trajectory.fell_at = tick / hz
                        break
                if trajectory.fell_at is not None:
                    break
            trajectory.finish(survived_s=tick / hz)
        except Exception as exc:  # The headset must learn why the robot stopped.
            trajectory.fail(f"{type(exc).__name__}: {exc}")
        return trajectory
