"""Tests for the synthetic headset used to develop Live Feed apps without hardware.

These also serve as the executable proof that the documented "no headset"
workflow actually works: the simulator CLI drives a real receiver over a real
socket and the expected typed samples come out the other end.
"""

from __future__ import annotations

import io
import math
import socket
import threading
import unittest
from contextlib import redirect_stderr, redirect_stdout

import pytest

from pyoperator.live_feed import LiveFeedReceiver, ReceiverConfig
from pyoperator.live_feed.simulator import (
    SyntheticHeadset,
    main,
    parse_args,
    stream_session,
    walk_position,
)


class WalkPositionTests(unittest.TestCase):
    def test_walk_traces_a_circle_of_the_requested_radius(self) -> None:
        for elapsed in (0.0, 1.0, 2.5, 7.3):
            x, y, z = walk_position(elapsed, radius=2.0)
            self.assertAlmostEqual(math.hypot(x, z), 2.0, places=6)
            # Head height bobs gently around standing height.
            self.assertGreater(y, 1.4)
            self.assertLess(y, 1.8)

    def test_walk_actually_moves_over_time(self) -> None:
        start = walk_position(0.0)
        later = walk_position(2.0)
        self.assertGreater(math.dist(start, later), 0.1)


class SimulatorArgsTests(unittest.TestCase):
    def test_defaults_match_the_documented_ports(self) -> None:
        args = parse_args([])
        self.assertEqual(args.host, "127.0.0.1")
        self.assertEqual(args.push_port, 63910)
        self.assertEqual(args.duration, 20.0)

    def test_overrides(self) -> None:
        args = parse_args(["--host", "10.0.0.5", "--push-port", "1234", "--duration", "0", "--quiet"])
        self.assertEqual(args.host, "10.0.0.5")
        self.assertEqual(args.push_port, 1234)
        self.assertEqual(args.duration, 0.0)
        self.assertTrue(args.quiet)


class SimulatorConnectTests(unittest.TestCase):
    def test_connect_gives_up_after_the_retry_window(self) -> None:
        # Port 1 is reserved and never listening.
        with self.assertRaises(OSError):
            SyntheticHeadset.connect("127.0.0.1", 1, retry_for=0.2, timeout=0.2)

    def test_main_reports_an_unreachable_server(self) -> None:
        error = io.StringIO()
        with redirect_stderr(error), redirect_stdout(io.StringIO()):
            code = main(["--host", "127.0.0.1", "--push-port", "1", "--wait", "0.2"])
        self.assertEqual(code, 1)
        self.assertIn("could not connect", error.getvalue())


@pytest.mark.loopback
@pytest.mark.fake_headset
class SimulatorStreamTests(unittest.TestCase):
    def make_receiver(self) -> LiveFeedReceiver:
        receiver = LiveFeedReceiver(
            ReceiverConfig(
                host="127.0.0.1",
                push_port=0,
                accept_results=False,
                publish_results=False,
                quiet=True,
            )
        )
        self.addCleanup(receiver.close)
        receiver.start()
        return receiver

    def test_stream_session_produces_every_expected_stream(self) -> None:
        receiver = self.make_receiver()

        def drive() -> None:
            with SyntheticHeadset.connect("127.0.0.1", receiver.push_port, retry_for=5.0) as device:
                stream_session(device, duration_s=0.4, rate_hz=60.0, radius=1.0, quiet=True)

        thread = threading.Thread(target=drive, daemon=True)
        thread.start()

        session = receiver.accept(timeout=5.0)
        assert session is not None
        self.addCleanup(session.close)
        kinds = [sample.kind for sample in session.samples()]
        thread.join(timeout=5.0)

        self.assertEqual(kinds[0], "session_start")
        self.assertEqual(kinds[-1], "session_end")
        for expected in (
            "rgb_csd",
            "rgb_packet",
            "depth_metadata",
            "depth_frame",
            "head_pose",
            "controller_pose",
            "controller_input",
            "hand_joints",
        ):
            self.assertIn(expected, kinds)
        self.assertIsNone(session.error)

    def test_simulated_head_actually_moves(self) -> None:
        receiver = self.make_receiver()

        def drive() -> None:
            with SyntheticHeadset.connect("127.0.0.1", receiver.push_port, retry_for=5.0) as device:
                stream_session(device, duration_s=0.5, rate_hz=60.0, radius=1.0, quiet=True)

        thread = threading.Thread(target=drive, daemon=True)
        thread.start()

        session = receiver.accept(timeout=5.0)
        assert session is not None
        self.addCleanup(session.close)
        positions = [
            sample.position for sample in session.samples() if sample.kind == "head_pose"
        ]
        thread.join(timeout=5.0)

        self.assertGreater(len(positions), 5)
        # A stationary simulator would make the roundtrip example look broken.
        spread = max(position[0] for position in positions) - min(position[0] for position in positions)
        self.assertGreater(spread, 0.0)

    def test_main_streams_a_full_session_to_a_receiver(self) -> None:
        receiver = self.make_receiver()
        result: dict[str, int] = {}

        def drive() -> None:
            result["code"] = main(
                [
                    "--host", "127.0.0.1",
                    "--push-port", str(receiver.push_port),
                    "--duration", "0.3",
                    "--rate", "60",
                    "--wait", "5",
                ]
            )

        thread = threading.Thread(target=drive, daemon=True)
        output = io.StringIO()
        with redirect_stdout(output):
            thread.start()
            session = receiver.accept(timeout=5.0)
            assert session is not None
            self.addCleanup(session.close)
            kinds = [sample.kind for sample in session.samples()]
            thread.join(timeout=10.0)

        self.assertEqual(result.get("code"), 0)
        self.assertIn("head_pose", kinds)
        self.assertEqual(kinds[-1], "session_end")

    def test_auth_token_is_forwarded_to_session_start(self) -> None:
        receiver = LiveFeedReceiver(
            ReceiverConfig(
                host="127.0.0.1",
                push_port=0,
                accept_results=False,
                publish_results=False,
                auth_token="s3cret",
                quiet=True,
            )
        )
        self.addCleanup(receiver.close)
        receiver.start()

        def drive() -> None:
            try:
                with SyntheticHeadset.connect("127.0.0.1", receiver.push_port, retry_for=5.0) as device:
                    stream_session(
                        device, duration_s=0.2, rate_hz=30.0, radius=1.0, auth_token="s3cret", quiet=True
                    )
            except OSError:
                pass

        thread = threading.Thread(target=drive, daemon=True)
        thread.start()
        session = receiver.accept(timeout=5.0)
        assert session is not None
        self.addCleanup(session.close)
        kinds = [sample.kind for sample in session.samples()]
        thread.join(timeout=5.0)

        # Correct token: the stream is accepted rather than rejected.
        self.assertIsNone(session.error)
        self.assertEqual(kinds[0], "session_start")


if __name__ == "__main__":
    unittest.main()
