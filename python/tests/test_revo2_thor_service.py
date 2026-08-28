import asyncio
import importlib.util
from pathlib import Path
import stat
import struct
import sys
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch


SCRIPT = Path(__file__).parents[2] / "scripts" / "revo2_thor_service.py"
SPEC = importlib.util.spec_from_file_location("revo2_thor_service", SCRIPT)
service = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = service
SPEC.loader.exec_module(service)


class Revo2ThorServiceTests(unittest.TestCase):
    def _paths(self, root: Path) -> service.ServicePaths:
        bridge = root / "xr-bridge"
        bridge.write_text("#!/bin/sh\n", encoding="utf-8")
        bridge.chmod(bridge.stat().st_mode | stat.S_IXUSR)
        config = root / "revo2_tuning.yaml"
        config.write_text("bridge: {}\n", encoding="utf-8")
        left = root / "left"
        right = root / "right"
        left.touch()
        right.touch()
        return service.ServicePaths(bridge, config, left, right)

    def test_defaults_are_read_only_and_loopback_only(self) -> None:
        args = service.build_parser().parse_args([])
        with tempfile.TemporaryDirectory() as directory:
            runtime = service.runtime_args(args, self._paths(Path(directory)))

        self.assertFalse(runtime.allow_commands)
        self.assertEqual(runtime.bind, "127.0.0.1")
        self.assertEqual(runtime.allowed_source, "127.0.0.1")
        self.assertEqual(runtime.telemetry_host, "127.0.0.1")
        self.assertEqual(runtime.max_current_ma, 500)
        self.assertEqual(runtime.protected_current_ma, 400)
        self.assertEqual(runtime.watchdog_ms, 1000.0)

    def test_allow_commands_requires_explicit_flag(self) -> None:
        args = service.build_parser().parse_args(["--allow-commands"])
        with tempfile.TemporaryDirectory() as directory:
            runtime = service.runtime_args(args, self._paths(Path(directory)))
        self.assertTrue(runtime.allow_commands)

    def test_bridge_uses_local_adapter_and_shared_config(self) -> None:
        args = service.build_parser().parse_args(["--adapter-port", "64010"])
        with tempfile.TemporaryDirectory() as directory:
            paths = self._paths(Path(directory))
            command = service.bridge_command(args, paths)
        self.assertEqual(
            command,
            [
                str(paths.xr_bridge),
                "--config",
                str(paths.bridge_config),
                "--adapter-endpoint",
                "tcp:127.0.0.1:64010",
            ],
        )

    def test_auto_discovers_hands_by_id_and_serial(self) -> None:
        class FakeSdk:
            def __init__(self):
                self.calls = []

            async def auto_detect(self, *, scan_all, port, protocol):
                self.calls.append((scan_all, port, protocol))
                if port.endswith("if01-port0"):
                    return [
                        SimpleNamespace(
                            slave_id=126,
                            serial_number=service.DEFAULT_LEFT_SERIAL,
                        )
                    ]
                if port.endswith("if02-port0"):
                    return [
                        SimpleNamespace(
                            slave_id=127,
                            serial_number=service.DEFAULT_RIGHT_SERIAL,
                        )
                    ]
                return []

        args = service.build_parser().parse_args([])
        sdk = FakeSdk()
        with patch.object(
            service.glob,
            "glob",
            return_value=[
                "/dev/serial/by-id/usb-ftdi-if01-port0",
                "/dev/serial/by-id/usb-ftdi-if02-port0",
            ],
        ):
            left, right = asyncio.run(service._discover_hand_ports(args, sdk))
        self.assertEqual(str(left), "/dev/serial/by-id/usb-ftdi-if01-port0")
        self.assertEqual(str(right), "/dev/serial/by-id/usb-ftdi-if02-port0")

    def test_decode_packet_and_reject_invalid_payloads(self) -> None:
        payload = struct.pack(
            "<4sBBHIQ12f",
            b"BCH2",
            2,
            1,
            service.FLAG_HOLD,
            12,
            34,
            *([0.25] * 6),
            *([0.05] * 6),
        )
        decoded = service.decode_packet(payload)
        self.assertEqual(decoded["side"], 1)
        self.assertEqual(decoded["flags"], service.FLAG_HOLD)
        self.assertEqual(decoded["sequence"], 12)
        self.assertEqual(decoded["q"], (0.25,) * 6)
        self.assertIsNone(service.decode_packet(payload[:-1]))
        self.assertIsNone(service.decode_packet(b"BAD!" + payload[4:]))

    def test_slew_targets_limits_every_motor(self) -> None:
        self.assertEqual(
            service.slew_targets([100] * 6, [0, 80, 100, 120, 400, 1000], 30),
            (70, 80, 100, 120, 130, 130),
        )

    def test_channel_mask_holds_unselected_motors(self) -> None:
        mask = service.parse_channel_mask("index")
        self.assertEqual(mask, (False, False, True, False, False, False))
        self.assertEqual(
            service.masked_targets(
                [400, 400, 50, 50, 50, 50],
                [0, 0, 700, 800, 900, 1000],
                mask,
            ),
            (400, 400, 700, 50, 50, 50),
        )

    def test_channel_mask_enforces_official_thumb_limits(self) -> None:
        mask = service.parse_channel_mask("thumb_flex,thumb_aux")
        self.assertEqual(
            service.masked_targets(
                [0, 0, 0, 0, 0, 0],
                [1000, 1000, 1000, 1000, 1000, 1000],
                mask,
            ),
            (500.0, 870.0, 0, 0, 0, 0),
        )
        self.assertEqual(
            service.masked_targets(
                [650, 920, 0, 0, 0, 0],
                [1000, 1000, 0, 0, 0, 0],
                service.parse_channel_mask("index"),
            ),
            (650, 920, 0, 0, 0, 0),
        )

    def test_stale_command_establishes_a_new_sender_session(self) -> None:
        receiver = service.CommandReceiver("192.0.2.10", reset_after_ns=1_000)

        def packet(sequence: int, sender_ns: int) -> bytes:
            return service.PACKET.pack(
                service.MAGIC,
                service.VERSION,
                0,
                0,
                sequence,
                sender_ns,
                *([0.25] * 12),
            )

        with patch.object(service.time, "monotonic_ns", side_effect=[10_000, 20_000]):
            receiver.datagram_received(packet(100, 9_000), ("192.0.2.10", 5000))
            receiver.datagram_received(packet(1, 100), ("192.0.2.10", 5001))

        self.assertEqual(receiver.commands[0].sequence, 1)
        self.assertEqual(receiver.rejected, 0)

    def test_non_newer_command_is_rejected_while_session_is_fresh(self) -> None:
        receiver = service.CommandReceiver("192.0.2.10", reset_after_ns=10_000)

        def packet(sequence: int) -> bytes:
            return service.PACKET.pack(
                service.MAGIC,
                service.VERSION,
                0,
                0,
                sequence,
                sequence,
                *([0.25] * 12),
            )

        with patch.object(service.time, "monotonic_ns", side_effect=[10_000, 10_100]):
            receiver.datagram_received(packet(100), ("192.0.2.10", 5000))
            receiver.datagram_received(packet(1), ("192.0.2.10", 5001))

        self.assertEqual(receiver.commands[0].sequence, 100)
        self.assertEqual(receiver.rejected, 1)


if __name__ == "__main__":
    unittest.main()
