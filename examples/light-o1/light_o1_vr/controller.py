"""Prompt selection, one text->motion pipeline at a time, and 50 Hz playback.

``MotionSession`` knows nothing about XR transport. It consumes controller
commands (stick: prompt, A: generate, B: replay) and typed prompts, runs
Light-O1 generation plus the Sonic rollout on a worker thread, and on every
host tick returns the complete Blueprint state: the G1 pose to show right now
plus the label text. Playback starts as soon as a short prefix of the rollout
exists and simply holds the newest frame if the simulation ever falls behind
real time.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum
import threading
import time
from typing import Callable

import numpy as np

from .controls import Commands, HELP
from .generator import GenerationCancelled, GenerationError, GeneratedAction
from .presentation import frame_to_state
from .prompts import PromptLibrary
from .rollout import SonicRollout, Trajectory


class Phase(str, Enum):
    IDLE = "idle"
    GENERATING = "generating"
    SIMULATING = "simulating"
    PLAYING = "playing"
    DONE = "done"
    FAILED = "failed"
    STOPPED = "stopped"


ACTIVE_PHASES = frozenset((Phase.GENERATING, Phase.SIMULATING, Phase.PLAYING))


@dataclass
class Job:
    prompt: str
    started: float
    replay: bool = False
    phase: Phase = Phase.GENERATING
    error: str = ""
    generated: GeneratedAction | None = None
    trajectory: Trajectory | None = None
    cancel: threading.Event = field(default_factory=threading.Event)
    thread: threading.Thread | None = None
    play_start: float | None = None
    play_index: int = -1
    generation_s: float = 0.0


class MotionSession:
    def __init__(self, *, generator, light_o1, simulator, prompts, idle_state, control_hz: float = 50.0,
                 replan_frames: int = 8, lookahead_frames: int = 12, prebuffer_s: float = 0.5,
                 seed: int = 0, thinking: bool = True, clock: Callable[[], float] = time.monotonic,
                 rollout_factory: Callable[..., object] | None = None):
        if control_hz <= 0 or prebuffer_s < 0:
            raise ValueError("control_hz must be positive and prebuffer_s non-negative")
        self.generator = generator
        self.light_o1 = light_o1
        self.simulator = simulator
        self.prompts = prompts if isinstance(prompts, PromptLibrary) else PromptLibrary(prompts)
        self.control_hz = float(control_hz)
        self.prebuffer_frames = max(1, int(round(prebuffer_s * control_hz)))
        self.replan_frames = replan_frames
        self.lookahead_frames = lookahead_frames
        self.seed = seed
        self.thinking = thinking
        self.clock = clock
        self.rollout_factory = rollout_factory or self._default_rollout
        self._idle = np.asarray(idle_state, dtype=float)
        self._shown = self._idle
        self._lock = threading.Lock()
        self._job: Job | None = None
        self._last_ok: Trajectory | None = None
        self._sample = 0
        self._closed = False
        self._notice = ""
        self._notice_until = 0.0

    # -- public API ---------------------------------------------------------
    @property
    def phase(self) -> Phase:
        with self._lock:
            return self._job.phase if self._job is not None else Phase.IDLE

    @property
    def active(self) -> bool:
        return self.phase in ACTIVE_PHASES

    @property
    def last_trajectory(self) -> Trajectory | None:
        with self._lock:
            return self._last_ok

    def status_line(self, now: float | None = None) -> str:
        """The label text on one line, for host logs."""
        now = self.clock() if now is None else now
        with self._lock:
            return self._status_text_locked(self._job, now).replace("\n", " | ")

    def handle_commands(self, commands: Commands | None, now: float | None = None) -> None:
        """Apply one tick of controller edges: stick selects, A generates, B replays."""
        if not commands:
            return
        now = self.clock() if now is None else now
        if commands.next:
            self.prompts.next()
        if commands.prev:
            self.prompts.prev()
        busy = self.phase in (Phase.GENERATING, Phase.SIMULATING)
        if commands.generate:
            if busy:
                self._notify("Still generating - wait for the motion to start", now)
            else:
                self.start()
        if commands.replay:
            if busy:
                self._notify("Still generating - replay is available afterwards", now)
            elif self.replay() is None:
                self._notify("Nothing to replay yet - press A to generate first", now)

    def _notify(self, text: str, now: float, seconds: float = 2.0) -> None:
        with self._lock:
            self._notice = text
            self._notice_until = now + seconds

    def submit(self, text: str) -> str:
        """Typed prompt from the host: select it and start generating."""
        prompt = self.prompts.select(text)
        self.start(prompt)
        return prompt

    def start(self, prompt: str | None = None) -> Job:
        if self._closed:
            raise RuntimeError("session is closed")
        prompt = self.prompts.current if prompt is None else prompt
        with self._lock:
            previous = self._job
            if previous is not None:
                previous.cancel.set()
            job = Job(prompt=prompt, started=self.clock())
            job.thread = threading.Thread(
                target=self._run_pipeline, args=(job, previous), name="light-o1-pipeline", daemon=True)
            self._job = job
        job.thread.start()
        return job

    def replay(self) -> Job | None:
        with self._lock:
            trajectory = self._last_ok
            if trajectory is None:
                return None
            previous = self._job
            if previous is not None:
                previous.cancel.set()
            job = Job(prompt=trajectory.prompt, started=self.clock(), replay=True,
                      phase=Phase.PLAYING, trajectory=trajectory)
            self._job = job
        return job

    def stop(self) -> None:
        with self._lock:
            job = self._job
            if job is None:
                return
            job.cancel.set()
            if job.phase in ACTIVE_PHASES:
                job.phase = Phase.STOPPED

    def close(self, timeout: float = 5.0) -> None:
        self._closed = True
        self.stop()
        with self._lock:
            thread = self._job.thread if self._job is not None else None
        if thread is not None and thread.is_alive():
            thread.join(timeout)

    def tick(self, now: float | None = None) -> dict:
        """Advance playback and return the full Blueprint state for this tick."""
        now = self.clock() if now is None else now
        with self._lock:
            job = self._job
            frame = self._advance_locked(job, now)
            text = self._status_text_locked(job, now)
        self._shown = frame
        self._sample += 1
        joints, base = frame_to_state(frame)
        return {"g1.joints": joints, "g1.base": base, "g1.sample": self._sample, "g1.visible": True,
                "ui.text": text}

    # -- worker -------------------------------------------------------------
    def _default_rollout(self, reference, trajectory, cancel):
        return SonicRollout(self.light_o1, self.simulator, reference, trajectory,
                            replan_frames=self.replan_frames, lookahead_frames=self.lookahead_frames,
                            cancel=cancel)

    def _run_pipeline(self, job: Job, previous: Job | None) -> None:
        try:
            generated = self.generator.generate(job.prompt, seed=self.seed, thinking=self.thinking,
                                                cancel=job.cancel)
        except GenerationCancelled:
            self._finish(job, Phase.STOPPED)
            return
        except GenerationError as exc:
            self._finish(job, Phase.FAILED, str(exc))
            return
        except Exception as exc:  # A generator bug must not take the XR session down.
            self._finish(job, Phase.FAILED, f"{type(exc).__name__}: {exc}")
            return
        job.generation_s = self.clock() - job.started
        # The simulator is shared: wait for any earlier pipeline to release it.
        if previous is not None and previous.thread is not None:
            previous.thread.join()
        if job.cancel.is_set():
            self._finish(job, Phase.STOPPED)
            return
        try:
            reference = self.light_o1.to_reference(generated.action)
            trajectory = Trajectory(self.light_o1.joint_names, prompt=job.prompt,
                                    reasoning=generated.reasoning, planned_s=generated.seconds,
                                    control_hz=self.control_hz)
            with self._lock:
                job.generated = generated
                job.trajectory = trajectory
                if job.phase == Phase.GENERATING:
                    job.phase = Phase.SIMULATING
            self.rollout_factory(reference, trajectory, job.cancel).run()
        except Exception as exc:
            self._finish(job, Phase.FAILED, f"{type(exc).__name__}: {exc}")
            return
        with self._lock:
            if trajectory.error:
                job.error = trajectory.error
                job.phase = Phase.FAILED
            elif trajectory.cancelled:
                if job.phase in ACTIVE_PHASES:
                    job.phase = Phase.STOPPED
            elif trajectory.ok:
                self._last_ok = trajectory

    def _finish(self, job: Job, phase: Phase, error: str = "") -> None:
        with self._lock:
            job.error = error
            job.phase = phase

    # -- playback -----------------------------------------------------------
    def _advance_locked(self, job: Job | None, now: float) -> np.ndarray:
        if job is None:
            return self._idle
        trajectory = job.trajectory
        if trajectory is None or len(trajectory) == 0:
            return self._shown
        if job.phase in (Phase.STOPPED, Phase.FAILED, Phase.DONE):
            return trajectory.frame(job.play_index) if job.play_index >= 0 else self._shown
        available = len(trajectory)
        if job.play_start is None:
            if available < self.prebuffer_frames and not trajectory.done:
                return self._shown
            job.play_start = now
            job.phase = Phase.PLAYING
        index = int((now - job.play_start) * self.control_hz)
        if index >= available:
            index = available - 1
            if trajectory.done:
                job.phase = Phase.FAILED if trajectory.error else Phase.DONE
                if trajectory.error:
                    job.error = trajectory.error
            else:
                # Simulation is slower than real time: hold and re-anchor so no frame is skipped.
                job.play_start = now - index / self.control_hz
        job.play_index = index
        return trajectory.frame(index)

    def _status_text_locked(self, job: Job | None, now: float) -> str:
        header = f"Prompt {self.prompts.index + 1}/{len(self.prompts)}: {self.prompts.current}"
        footer = self._notice if self._notice and now < self._notice_until else HELP
        return f"{header}\n{self._phase_text_locked(job, now)}\n{footer}"

    def _phase_text_locked(self, job: Job | None, now: float) -> str:
        if job is None:
            return "Ready - press A to generate"
        trajectory = job.trajectory
        suffix = " (replay)" if job.replay else ""
        if job.phase == Phase.GENERATING:
            status = f"Light-O1 generating... {now - job.started:.0f}s"
        elif job.phase == Phase.SIMULATING:
            simulated = len(trajectory) / self.control_hz if trajectory is not None else 0.0
            planned = trajectory.planned_s if trajectory is not None else 0.0
            status = f"Sonic G1 simulating... {simulated:.1f}/{planned:.1f}s"
        elif job.phase == Phase.PLAYING:
            played = max(job.play_index, 0) / self.control_hz
            if trajectory is None:
                total = 0.0
            elif trajectory.done:
                total = trajectory.duration_s
            else:  # still simulating: settle ticks so far plus the planned tracking time
                total = trajectory.settle_frames / self.control_hz + trajectory.planned_s
            status = f"Playing{suffix} {played:.1f}/{total:.1f}s"
        elif job.phase == Phase.DONE:
            if trajectory is not None and trajectory.fell_at is not None:
                status = f"Done{suffix} - G1 fell at {trajectory.fell_at:.1f}s"
            else:
                seconds = trajectory.survived_s if trajectory is not None else 0.0
                status = f"Done{suffix} - {seconds:.1f}s, G1 stayed up"
        elif job.phase == Phase.FAILED:
            status = f"Failed: {job.error[:90]}"
        else:
            status = "Stopped"
        if job.prompt.lower() != self.prompts.current.lower():
            status += f" [{job.prompt[:40]}]"
        return status
