import asyncio
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from pyoperator.models import frame_from_dict
from pyoperator.replay import FrameRecorder, ReplaySession, load
from pyoperator.session import BridgeConfig, XrSession

from test_models import sample_frame


class FakeNative:
    def __init__(self, **kwargs) -> None:
        self.kwargs = kwargs
        self.running = False
        self.payload = json.dumps(sample_frame(3))
        self.wait_calls = []
        self.close_calls = 0

    def start(self) -> None:
        self.running = True

    def close(self) -> None:
        self.running = False
        self.close_calls += 1

    def is_running(self) -> bool:
        return self.running

    def latest_json(self):
        return self.payload

    def wait_next_json(self, after, timeout):
        self.wait_calls.append((after, timeout))
        return self.payload if after < 3 else None

    def stats_json(self) -> str:
        return json.dumps(
            {
                "running": self.running,
                "connected": True,
                "frames_received": 1,
                "parse_errors": 2,
                "last_frame_id": 3,
                "last_timestamp_ns": 1003,
                "last_error": "bad frame",
            }
        )


class SessionReplayTests(unittest.TestCase):
    def test_session_makes_one_native_call_per_frame(self) -> None:
        config = BridgeConfig(name="test", pose_port=1001, discovery_unicast_targets=("127.0.0.1",))
        session = XrSession(config, _native_factory=FakeNative).start()
        self.assertEqual(session.wait_next(timeout=0.1).frame_id, 3)
        self.assertEqual(session._native.wait_calls, [(0, 0.1)])
        self.assertEqual(session._native.kwargs["name"], "test")
        self.assertEqual(session._native.kwargs["pose_port"], 1001)
        self.assertEqual(session._native.kwargs["discovery_unicast_targets"], ["127.0.0.1"])
        self.assertEqual(session.latest().frame_id, 3)
        stats = session.stats()
        self.assertTrue(stats.connected)
        self.assertEqual(stats.parse_errors, 2)
        self.assertEqual(stats.last_frame_id, 3)
        self.assertEqual(stats.last_timestamp_ns, 1003)
        self.assertEqual(stats.last_error, "bad frame")
        session.close()

    def test_session_context_manager_and_async_wait(self) -> None:
        async def exercise() -> None:
            with XrSession(_native_factory=FakeNative) as session:
                self.assertTrue(session.is_running)
                frame = await session.wait_next_async(timeout=0.25)
                self.assertEqual(frame.frame_id, 3)
            self.assertFalse(session.is_running)
            self.assertEqual(session._native.close_calls, 1)

        asyncio.run(exercise())

    def test_frames_iterator_advances_frame_id_and_stops_with_session(self) -> None:
        class FiniteNative(FakeNative):
            def __init__(self, **kwargs) -> None:
                super().__init__(**kwargs)
                self.next_id = 1

            def wait_next_json(self, after, timeout):
                self.wait_calls.append((after, timeout))
                if self.next_id > 2:
                    self.running = False
                    return None
                payload = json.dumps(sample_frame(self.next_id))
                self.next_id += 1
                return payload

        session = XrSession(_native_factory=FiniteNative).start()
        self.assertEqual([frame.frame_id for frame in session.frames(timeout=0.1)], [1, 2])
        self.assertEqual(session._native.wait_calls, [(0, 0.1), (1, 0.1), (2, 0.1)])

    def test_missing_native_extension_has_actionable_error(self) -> None:
        with patch("pyoperator.session._NativeSession", None), patch(
            "pyoperator.session._native_import_error", ImportError("missing")
        ):
            with self.assertRaisesRegex(RuntimeError, r"pip install -e ./python"):
                XrSession()

    def test_recording_replays_same_models(self) -> None:
        original = frame_from_dict(sample_frame(4))
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "capture.xrf.jsonl"
            with FrameRecorder(path) as recorder:
                recorder.write(original)
            replay = ReplaySession(path).start()
            self.assertEqual(replay.wait_next(), original)
            self.assertIsNone(replay.wait_next(after_frame_id=4))

    def test_recorder_requires_context_and_rejects_bad_header(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "capture.xrf.jsonl"
            with self.assertRaisesRegex(RuntimeError, "context manager"):
                FrameRecorder(path).write(frame_from_dict(sample_frame()))
            path.write_text('{"type":"other","schema_version":1}\n', encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "recording v1"):
                load(path)

    def test_replay_frames_stats_close_and_realtime_pacing(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "capture.xrf.jsonl"
            first = sample_frame(1)
            second = sample_frame(2)
            first["timestamp_ns"] = 1_000_000_000
            second["timestamp_ns"] = 1_250_000_000
            with FrameRecorder(path) as recorder:
                recorder.write(frame_from_dict(first))
                recorder.write(frame_from_dict(second))

            with patch("pyoperator.replay.time.monotonic", side_effect=[10.0, 10.0, 10.0]), patch(
                "pyoperator.replay.time.sleep"
            ) as sleep:
                replay = ReplaySession(path, realtime=True).start()
                frames = list(replay.frames())
            self.assertEqual([frame.frame_id for frame in frames], [1, 2])
            sleep.assert_called_once_with(0.25)
            stats = replay.stats()
            self.assertFalse(stats.running)
            self.assertFalse(stats.connected)
            self.assertEqual(stats.frames_received, 2)
            self.assertEqual(stats.last_frame_id, 2)
            replay.close()
            self.assertFalse(replay.is_running)

            replay.start()
            self.assertEqual(replay.wait_next(after_frame_id=1).frame_id, 2)
