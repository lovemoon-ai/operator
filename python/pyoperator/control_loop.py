"""Managed XR → retarget → IK → robot loop with safe teardown."""

from __future__ import annotations

from dataclasses import dataclass
import sys
import threading
import time

from .ik import IKSolver
from .retargeting import Retargeter
from .robot import EndEffectorTarget, Robot
from .session import XrSession


@dataclass(frozen=True)
class ControlLoopStats:
    frames: int
    commands: int
    watchdog_stops: int
    started_monotonic: float
    ended_monotonic: float


def run(
    robot: Robot,
    retargeter: Retargeter,
    *,
    session: XrSession | None = None,
    ik: IKSolver | None = None,
    watchdog_timeout: float = 0.5,
    frame_timeout: float = 0.05,
    stop_event: threading.Event | None = None,
) -> ControlLoopStats:
    """Run until ``stop_event``/Ctrl-C; always stop and disconnect the robot."""
    owns_session = session is None
    if session is None:
        session = XrSession()
    stop_event = stop_event or threading.Event()
    frames = commands = watchdog_stops = 0
    frame_id = 0
    started = time.monotonic()
    last_frame_at = started
    watchdog_fired = False
    command_active = False
    robot_connect_attempted = False
    session_start_attempted = False
    try:
        # Mark attempts before calling user code: either method may acquire a
        # resource and then raise, in which case teardown is still required.
        robot_connect_attempted = True
        robot.connect()
        if owns_session:
            session_start_attempted = True
            session.start()
        while not stop_event.is_set():
            frame = session.wait_next(frame_id, frame_timeout)
            now = time.monotonic()
            if frame is None:
                if not bool(getattr(session, "is_running", True)):
                    break
                if now - last_frame_at >= watchdog_timeout and not watchdog_fired:
                    robot.stop("XR frame watchdog timeout")
                    retargeter.reset()
                    watchdog_stops += 1
                    watchdog_fired = True
                    command_active = False
                continue
            frame_id = frame.frame_id
            last_frame_at = now
            watchdog_fired = False
            frames += 1
            state = robot.read_state()
            command = retargeter.retarget(frame, state)
            if command is None:
                if command_active:
                    robot.stop("operator deadman released")
                    command_active = False
                continue
            if isinstance(command, EndEffectorTarget) and ik is not None:
                command = ik.solve(command, state)
            robot.write(command)
            commands += 1
            command_active = True
    finally:
        primary_error = sys.exc_info()[1]
        cleanup_errors: list[BaseException] = []

        if robot_connect_attempted:
            try:
                robot.stop("pyoperator control loop ended")
            except BaseException as error:
                cleanup_errors.append(error)
            try:
                robot.disconnect()
            except BaseException as error:
                cleanup_errors.append(error)
        if owns_session and session_start_attempted:
            try:
                session.close()
            except BaseException as error:
                cleanup_errors.append(error)

        if primary_error is None and cleanup_errors:
            raise cleanup_errors[0]
        if primary_error is not None and cleanup_errors:
            add_note = getattr(primary_error, "add_note", None)
            if add_note is not None:
                for error in cleanup_errors:
                    add_note(f"pyoperator cleanup also failed: {error!r}")
    return ControlLoopStats(frames, commands, watchdog_stops, started, time.monotonic())
