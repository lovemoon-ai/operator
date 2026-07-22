import unittest
from unittest.mock import patch

from pyoperator import xr_bridge
from pyoperator.models import BridgeStats


class FakeSession:
    instances = []

    def __init__(self, config) -> None:
        self.config = config
        self.is_running = False
        self.closed = False
        self.calls = []
        self.__class__.instances.append(self)

    def start(self):
        self.is_running = True
        return self

    def close(self) -> None:
        self.is_running = False
        self.closed = True

    def latest(self):
        self.calls.append(("latest",))
        return "latest"

    def wait_next(self, after_frame_id=0, timeout=None):
        self.calls.append(("wait_next", after_frame_id, timeout))
        return "next"

    def frames(self, timeout=None):
        self.calls.append(("frames", timeout))
        return iter(("one", "two"))

    def stats(self):
        self.calls.append(("stats",))
        return BridgeStats(running=self.is_running)


class XrBridgeTests(unittest.TestCase):
    def setUp(self) -> None:
        xr_bridge._default_session = None
        FakeSession.instances.clear()

    def tearDown(self) -> None:
        xr_bridge._default_session = None

    def test_session_before_start_has_actionable_error(self) -> None:
        with self.assertRaisesRegex(RuntimeError, r"xr_bridge.start\(\)"):
            xr_bridge.session()

    def test_singleton_start_delegates_all_public_operations(self) -> None:
        with patch("pyoperator.xr_bridge.XrSession", FakeSession):
            started = xr_bridge.start(name="sdk", pose_port=1234)
            self.assertIs(xr_bridge.start(name="ignored"), started)
            self.assertEqual(len(FakeSession.instances), 1)
            self.assertEqual(started.config.name, "sdk")
            self.assertEqual(started.config.pose_port, 1234)
            self.assertEqual(xr_bridge.latest(), "latest")
            self.assertEqual(xr_bridge.wait_next(7, timeout=0.2), "next")
            self.assertEqual(list(xr_bridge.frames(timeout=0.3)), ["one", "two"])
            self.assertTrue(xr_bridge.stats().running)
            xr_bridge.stop()
            self.assertTrue(started.closed)
            self.assertIsNone(xr_bridge._default_session)
            xr_bridge.stop()

    def test_start_replaces_a_stopped_default_session(self) -> None:
        with patch("pyoperator.xr_bridge.XrSession", FakeSession):
            first = xr_bridge.start()
            first.is_running = False
            second = xr_bridge.start()
        self.assertIsNot(first, second)
        self.assertEqual(len(FakeSession.instances), 2)
