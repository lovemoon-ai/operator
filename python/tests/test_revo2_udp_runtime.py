import importlib.util
from pathlib import Path
import struct
import sys
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).parents[2] / "scripts" / "revo2_udp_runtime.py"
SPEC = importlib.util.spec_from_file_location("revo2_udp_runtime", SCRIPT)
runtime = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = runtime
SPEC.loader.exec_module(runtime)


class Revo2UdpRuntimeTests(unittest.TestCase):
    def test_decode_packet_and_reject_invalid_payloads(self) -> None:
        payload = struct.pack(
            "<4sBBHIQ12f",
            b"BCH2",
            2,
            1,
            runtime.FLAG_HOLD,
            12,
            34,
            *([0.25] * 6),
            *([0.05] * 6),
        )
        decoded = runtime.decode_packet(payload)
        self.assertEqual(decoded["side"], 1)
        self.assertEqual(decoded["flags"], runtime.FLAG_HOLD)
        self.assertEqual(decoded["sequence"], 12)
        self.assertEqual(decoded["q"], (0.25,) * 6)
        self.assertIsNone(runtime.decode_packet(payload[:-1]))
        self.assertIsNone(runtime.decode_packet(b"BAD!" + payload[4:]))

    def test_slew_targets_limits_every_motor(self) -> None:
        self.assertEqual(
            runtime.slew_targets([100] * 6, [0, 80, 100, 120, 400, 1000], 30),
            (70, 80, 100, 120, 130, 130),
        )

    def test_channel_mask_holds_unselected_motors(self) -> None:
        mask = runtime.parse_channel_mask("index")
        self.assertEqual(mask, (False, False, True, False, False, False))
        self.assertEqual(
            runtime.masked_targets(
                [400, 400, 50, 50, 50, 50],
                [0, 0, 700, 800, 900, 1000],
                mask,
            ),
            (400, 400, 700, 50, 50, 50),
        )

    def test_channel_mask_enforces_official_thumb_limits(self) -> None:
        mask = runtime.parse_channel_mask("thumb_flex,thumb_aux")
        self.assertEqual(
            runtime.masked_targets(
                [0, 0, 0, 0, 0, 0],
                [1000, 1000, 1000, 1000, 1000, 1000],
                mask,
            ),
            (500.0, 870.0, 0, 0, 0, 0),
        )
        self.assertEqual(
            runtime.masked_targets(
                [650, 920, 0, 0, 0, 0],
                [1000, 1000, 0, 0, 0, 0],
                runtime.parse_channel_mask("index"),
            ),
            (650, 920, 0, 0, 0, 0),
        )

    def test_stale_command_establishes_a_new_sender_session(self) -> None:
        receiver = runtime.CommandReceiver("192.0.2.10", reset_after_ns=1_000)

        def packet(sequence: int, sender_ns: int) -> bytes:
            return runtime.PACKET.pack(
                runtime.MAGIC,
                runtime.VERSION,
                0,
                0,
                sequence,
                sender_ns,
                *([0.25] * 12),
            )

        with patch.object(runtime.time, "monotonic_ns", side_effect=[10_000, 20_000]):
            receiver.datagram_received(packet(100, 9_000), ("192.0.2.10", 5000))
            receiver.datagram_received(packet(1, 100), ("192.0.2.10", 5001))

        self.assertEqual(receiver.commands[0].sequence, 1)
        self.assertEqual(receiver.rejected, 0)

    def test_non_newer_command_is_rejected_while_session_is_fresh(self) -> None:
        receiver = runtime.CommandReceiver("192.0.2.10", reset_after_ns=10_000)
        payload = lambda sequence: runtime.PACKET.pack(
            runtime.MAGIC,
            runtime.VERSION,
            0,
            0,
            sequence,
            sequence,
            *([0.25] * 12),
        )

        with patch.object(runtime.time, "monotonic_ns", side_effect=[10_000, 10_100]):
            receiver.datagram_received(payload(100), ("192.0.2.10", 5000))
            receiver.datagram_received(payload(1), ("192.0.2.10", 5001))

        self.assertEqual(receiver.commands[0].sequence, 100)
        self.assertEqual(receiver.rejected, 1)


if __name__ == "__main__":
    unittest.main()
