import threading
import unittest
from types import MappingProxyType
from unittest.mock import patch

from pyoperator.control_loop import run
from pyoperator.models import Pose, frame_from_dict
from pyoperator.retargeting import PoseDeltaRetargeter
from pyoperator.robot import EndEffectorTarget, JointTarget, RobotState

from test_models import sample_frame


class FakeRobot:
    def __init__(self) -> None:
        self.commands = []
        self.stops = []
        self.connected = False

    def connect(self) -> None:
        self.connected = True

    def disconnect(self) -> None:
        self.connected = False

    def read_state(self) -> RobotState:
        return RobotState(
            timestamp_ns=1,
            ee_poses=MappingProxyType(
                {"end_effector": Pose(valid=True, position=(0.3, 0.0, 0.2))}
            ),
        )

    def write(self, command) -> None:
        self.commands.append(command)

    def stop(self, reason="stop") -> None:
        self.stops.append(reason)


class FakeSession:
    def __init__(self, stop: threading.Event) -> None:
        self.stop = stop
        self.index = 0

    def wait_next(self, frame_id, timeout):
        del frame_id, timeout
        self.index += 1
        if self.index == 1:
            return frame_from_dict(sample_frame(1))
        self.stop.set()
        return frame_from_dict(sample_frame(2))


class SequenceSession:
    def __init__(self, frames) -> None:
        self._frames = list(frames)
        self.running = True
        self.started = False
        self.closed = False

    @property
    def is_running(self) -> bool:
        return self.running

    def start(self):
        self.started = True
        return self

    def close(self) -> None:
        self.closed = True
        self.running = False

    def wait_next(self, _frame_id, _timeout):
        if self._frames:
            value = self._frames.pop(0)
            if value is not None:
                return value
        self.running = False
        return None


class ResettingRetargeter:
    def __init__(self, command=None) -> None:
        self.command = command
        self.resets = 0

    def reset(self) -> None:
        self.resets += 1

    def retarget(self, _frame, _state):
        return self.command


class SequenceRetargeter(ResettingRetargeter):
    def __init__(self, commands) -> None:
        super().__init__()
        self.commands = list(commands)

    def retarget(self, _frame, _state):
        return self.commands.pop(0)


class RecordingIK:
    def __init__(self) -> None:
        self.calls = []

    def solve(self, target, state):
        self.calls.append((target, state))
        return JointTarget((0.1, 0.2), gripper=target.gripper, timestamp_ns=target.timestamp_ns)


class ControlLoopTests(unittest.TestCase):
    def test_managed_loop_commands_and_safes_robot(self) -> None:
        stop = threading.Event()
        robot = FakeRobot()
        stats = run(
            robot,
            PoseDeltaRetargeter(),
            session=FakeSession(stop),
            stop_event=stop,
        )
        self.assertEqual(stats.frames, 2)
        self.assertEqual(len(robot.commands), 2)
        self.assertFalse(robot.connected)
        self.assertIn("control loop ended", robot.stops[-1])

    def test_none_command_counts_frame_but_does_not_write(self) -> None:
        robot = FakeRobot()
        session = SequenceSession([frame_from_dict(sample_frame())])
        stats = run(robot, ResettingRetargeter(), session=session)
        self.assertEqual(stats.frames, 1)
        self.assertEqual(stats.commands, 0)
        self.assertEqual(robot.commands, [])

    def test_deadman_release_stops_an_active_robot_immediately(self) -> None:
        robot = FakeRobot()
        frames = [frame_from_dict(sample_frame(1)), frame_from_dict(sample_frame(2))]
        target = JointTarget((0.1, 0.2))
        stats = run(
            robot,
            SequenceRetargeter([target, None]),
            session=SequenceSession(frames),
        )
        self.assertEqual(stats.commands, 1)
        self.assertEqual(robot.commands, [target])
        self.assertIn("operator deadman released", robot.stops)

    def test_end_effector_target_passes_through_ik(self) -> None:
        robot = FakeRobot()
        session = SequenceSession([frame_from_dict(sample_frame())])
        target = EndEffectorTarget(
            ee_pose=Pose(valid=True, position=(0.5, 0.0, 0.2)),
            gripper=0.7,
            timestamp_ns=10,
        )
        ik = RecordingIK()
        stats = run(robot, ResettingRetargeter(target), session=session, ik=ik)
        self.assertEqual(stats.commands, 1)
        self.assertEqual(len(ik.calls), 1)
        self.assertEqual(robot.commands, [JointTarget((0.1, 0.2), gripper=0.7, timestamp_ns=10)])

    def test_watchdog_fires_once_and_resets_retargeter(self) -> None:
        class WatchdogSession(SequenceSession):
            def __init__(self) -> None:
                super().__init__([])
                self.calls = 0

            def wait_next(self, _frame_id, _timeout):
                self.calls += 1
                if self.calls >= 2:
                    self.running = False
                return None

        robot = FakeRobot()
        retargeter = ResettingRetargeter()
        with patch("pyoperator.control_loop.time.monotonic", side_effect=[0.0, 0.6, 0.7, 0.8]):
            stats = run(
                robot,
                retargeter,
                session=WatchdogSession(),
                watchdog_timeout=0.5,
            )
        self.assertEqual(stats.watchdog_stops, 1)
        self.assertEqual(retargeter.resets, 1)
        self.assertIn("XR frame watchdog timeout", robot.stops)

    def test_exception_still_stops_and_disconnects_robot(self) -> None:
        class FailingRobot(FakeRobot):
            def read_state(self):
                raise RuntimeError("robot read failed")

        robot = FailingRobot()
        session = SequenceSession([frame_from_dict(sample_frame())])
        with self.assertRaisesRegex(RuntimeError, "robot read failed"):
            run(robot, ResettingRetargeter(JointTarget((0.1,))), session=session)
        self.assertFalse(robot.connected)
        self.assertIn("pyoperator control loop ended", robot.stops)

    def test_owned_session_is_started_and_closed(self) -> None:
        robot = FakeRobot()
        owned = SequenceSession([])
        with patch("pyoperator.control_loop.XrSession", return_value=owned):
            stats = run(robot, ResettingRetargeter())
        self.assertEqual(stats.frames, 0)
        self.assertTrue(owned.started)
        self.assertTrue(owned.closed)

    def test_owned_session_start_failure_still_cleans_up_robot_and_session(self) -> None:
        class FailingStartSession(SequenceSession):
            def start(self):
                self.started = True
                raise RuntimeError("bind failed")

        robot = FakeRobot()
        owned = FailingStartSession([])
        with patch("pyoperator.control_loop.XrSession", return_value=owned):
            with self.assertRaisesRegex(RuntimeError, "bind failed"):
                run(robot, ResettingRetargeter())
        self.assertFalse(robot.connected)
        self.assertIn("pyoperator control loop ended", robot.stops)
        self.assertTrue(owned.closed)

    def test_cleanup_continues_after_stop_failure(self) -> None:
        class StopFailingRobot(FakeRobot):
            def stop(self, reason="stop") -> None:
                self.stops.append(reason)
                raise RuntimeError("stop failed")

        robot = StopFailingRobot()
        owned = SequenceSession([])
        with patch("pyoperator.control_loop.XrSession", return_value=owned):
            with self.assertRaisesRegex(RuntimeError, "stop failed"):
                run(robot, ResettingRetargeter())
        self.assertFalse(robot.connected)
        self.assertTrue(owned.closed)

    def test_partial_robot_connect_failure_still_attempts_disconnect(self) -> None:
        class PartialConnectRobot(FakeRobot):
            def connect(self) -> None:
                self.connected = True
                raise RuntimeError("connect failed")

        robot = PartialConnectRobot()
        with self.assertRaisesRegex(RuntimeError, "connect failed"):
            run(robot, ResettingRetargeter(), session=SequenceSession([]))
        self.assertFalse(robot.connected)
        self.assertIn("pyoperator control loop ended", robot.stops)
