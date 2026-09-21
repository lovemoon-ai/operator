import asyncio
import importlib.util
import json
import math
from pathlib import Path
import socket
import stat
import struct
import sys
import tempfile
import time
import unittest
from types import SimpleNamespace
from unittest.mock import patch


SCRIPT = (
    Path(__file__).parents[2]
    / "examples"
    / "brainco-revo2"
    / "revo2_thor_service.py"
)
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
        self.assertEqual(runtime.touch_rate, 20.0)
        self.assertEqual(runtime.touch_timeout_ms, 15.0)

    def test_allow_commands_requires_explicit_flag(self) -> None:
        args = service.build_parser().parse_args(["--allow-commands"])
        with tempfile.TemporaryDirectory() as directory:
            runtime = service.runtime_args(args, self._paths(Path(directory)))
        self.assertTrue(runtime.allow_commands)

    def test_blueprint_uses_builtin_components(self) -> None:
        blueprint = service.build_revo2_blueprint().to_dict()
        self.assertEqual(blueprint["blueprint_id"], service.REVO2_BLUEPRINT_ID)
        components = {
            component["id"]: component for component in blueprint["components"]
        }
        self.assertEqual(components["left_hand_status"]["type"], "status_lamp")
        self.assertEqual(components["right_hand_status"]["anchor"], "right_palm")
        self.assertNotIn("text", components["left_hand_status"]["bindings"])
        self.assertNotIn("text", components["right_hand_status"]["bindings"])
        self.assertEqual(
            components[service.REVO2_CONTROL_COMPONENT_ID]["type"], "menu_item"
        )
        self.assertTrue(
            components[service.REVO2_CONTROL_COMPONENT_ID]["user_overridable"]
        )
        tactile = components[service.REVO2_TACTILE_COMPONENT_ID]
        self.assertEqual(tactile["type"], "fingertip_tactile")
        self.assertEqual(
            tactile["bindings"]["left_normal"], "left.touch_normal"
        )
        self.assertEqual(
            tactile["bindings"]["right_status"], "right.touch_status"
        )

    def test_blueprint_state_requires_allowed_connected_hands(self) -> None:
        adapter = service.Revo2UdpHostedAdapter(command_host="127.0.0.1")
        now_ns = time.monotonic_ns()
        adapter._values = {
            "revo2_left_position": [0.0] * 6,
            "revo2_right_position": [0.0] * 6,
        }
        adapter._value_received_ns = {
            "revo2_left_position": now_ns,
            "revo2_right_position": now_ns,
        }
        values = service.revo2_blueprint_values(
            adapter,
            allow_commands=True,
            command_side="both",
            runtime_ready=True,
        )
        service.build_revo2_blueprint().validate_state_values(values)
        self.assertTrue(values["control.available"])
        self.assertFalse(values["control.enabled"])
        self.assertEqual(values["left.status"], "active")
        self.assertNotIn("left.status_text", values)
        self.assertNotIn("right.status_text", values)

        read_only = service.revo2_blueprint_values(
            adapter,
            allow_commands=False,
            command_side="both",
            runtime_ready=True,
        )
        self.assertTrue(read_only["control.available"])
        self.assertFalse(read_only["control.enabled"])
        self.assertIn("read-only", read_only["service.status_text"])

    def test_blueprint_state_carries_fingertip_tactile_feedback(self) -> None:
        adapter = service.Revo2UdpHostedAdapter(command_host="127.0.0.1")
        now_ns = time.monotonic_ns()
        adapter._values = {
            "revo2_left_position": [0.0] * 6,
            "revo2_right_position": [0.0] * 6,
            "revo2_left_touch_normal": [1, 2, 3, 4, 5],
            "revo2_left_touch_tangential": [6, 7, 8, 9, 10],
            "revo2_left_touch_direction": [0, 45, 90, 180, 270],
            "revo2_left_touch_proximity": [11, 12, 13, 14, 15],
            "revo2_left_touch_status": [0.0, 1.0, 2.0, 3.0, 4.0],
        }
        adapter._value_received_ns = {
            key: now_ns for key in adapter._values
        }
        adapter._timestamp_ns = 123456
        values = service.revo2_blueprint_values(
            adapter,
            allow_commands=False,
            command_side="both",
            runtime_ready=True,
        )
        service.build_revo2_blueprint().validate_state_values(values)
        self.assertEqual(values["left.touch_normal"], [1, 2, 3, 4, 5])
        self.assertEqual(values["left.touch_status"], [0, 1, 2, 3, 4])
        self.assertTrue(
            all(isinstance(value, int) for value in values["left.touch_status"])
        )
        self.assertNotIn("right.touch_normal", values)
        self.assertEqual(values["tactile.sample_ns"], 123456)
        blueprint = service.HostedBlueprint()
        blueprint.set_blueprint(service.build_revo2_blueprint())
        self.assertEqual(blueprint.update(values), 1)
        blueprint.close()

    def test_blueprint_event_controls_server_side_gate(self) -> None:
        async def exercise() -> None:
            args = service.build_parser().parse_args(["--allow-commands"])
            adapter = service.Revo2UdpHostedAdapter(command_host="127.0.0.1")
            now_ns = time.monotonic_ns()
            adapter._values = {
                "revo2_left_position": [0.0] * 6,
                "revo2_right_position": [0.0] * 6,
            }
            adapter._value_received_ns = {
                "revo2_left_position": now_ns,
                "revo2_right_position": now_ns,
            }
            blueprint = service.HostedBlueprint()
            blueprint.set_blueprint(service.build_revo2_blueprint())
            runtime_ready = asyncio.Event()
            runtime_ready.set()
            stopping = asyncio.Event()
            task = asyncio.create_task(
                service.run_revo2_blueprint(
                    blueprint,
                    adapter,
                    args,
                    runtime_ready,
                    stopping,
                )
            )
            blueprint._push_event(
                {
                    "schema": "operator.blueprint_event.v1",
                    "blueprint_id": service.REVO2_BLUEPRINT_ID,
                    "blueprint_revision": 1,
                    "sequence": 1,
                    "timestamp_ns": 1,
                    "component_id": service.REVO2_CONTROL_COMPONENT_ID,
                    "action": service.REVO2_CONTROL_ACTION,
                    "value": True,
                }
            )
            await asyncio.sleep(0.06)
            self.assertTrue(adapter.control_enabled)
            adapter._value_received_ns = {
                "revo2_left_position": 0,
                "revo2_right_position": 0,
            }
            await asyncio.sleep(0.06)
            self.assertFalse(adapter.control_enabled)
            stopping.set()
            await asyncio.wait_for(task, timeout=0.2)
            blueprint.close()

        asyncio.run(exercise())

    def test_read_only_palm_event_unlocks_input_preview_only(self) -> None:
        async def exercise() -> None:
            args = service.build_parser().parse_args([])
            adapter = service.Revo2UdpHostedAdapter(command_host="127.0.0.1")
            now_ns = time.monotonic_ns()
            adapter._values = {
                "revo2_left_position": [0.0] * 6,
                "revo2_right_position": [0.0] * 6,
            }
            adapter._value_received_ns = {
                "revo2_left_position": now_ns,
                "revo2_right_position": now_ns,
            }
            blueprint = service.HostedBlueprint()
            blueprint.set_blueprint(service.build_revo2_blueprint())
            runtime_ready = asyncio.Event()
            runtime_ready.set()
            stopping = asyncio.Event()
            task = asyncio.create_task(
                service.run_revo2_blueprint(
                    blueprint,
                    adapter,
                    args,
                    runtime_ready,
                    stopping,
                )
            )
            blueprint._push_event(
                {
                    "schema": "operator.blueprint_event.v1",
                    "blueprint_id": service.REVO2_BLUEPRINT_ID,
                    "blueprint_revision": 1,
                    "sequence": 1,
                    "timestamp_ns": 1,
                    "component_id": service.REVO2_CONTROL_COMPONENT_ID,
                    "action": service.REVO2_CONTROL_ACTION,
                    "value": True,
                }
            )
            await asyncio.sleep(0.06)
            self.assertTrue(adapter.control_enabled)
            values = service.revo2_blueprint_values(
                adapter,
                allow_commands=False,
                command_side="both",
                runtime_ready=True,
            )
            self.assertTrue(values["control.enabled"])
            self.assertIn("read-only", values["service.status_text"])
            stopping.set()
            await asyncio.wait_for(task, timeout=0.2)
            blueprint.close()

        asyncio.run(exercise())

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

    def test_bridge_readiness_uses_a_real_loopback_connection(self) -> None:
        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        listener.bind(("127.0.0.1", 0))
        listener.listen()
        port = listener.getsockname()[1]
        try:
            self.assertTrue(service._tcp_port_listening(port))
        finally:
            listener.close()
        self.assertFalse(service._tcp_port_listening(port))

    def test_protocol_version_mismatch_fails_fast(self) -> None:
        service.validate_protocol_version(service.VERSION)
        with self.assertRaisesRegex(RuntimeError, "redeploy the complete"):
            service.validate_protocol_version(service.VERSION - 1)

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
            3,
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
        legacy = bytearray(payload)
        legacy[4] = 2
        self.assertIsNone(service.decode_packet(bytes(legacy)))

    def test_touch_payload_requires_complete_finite_samples(self) -> None:
        def item(index: int) -> SimpleNamespace:
            return SimpleNamespace(
                normal_force1=index + 1,
                normal_force2=(index + 1) * 10,
                normal_force3=0,
                tangential_force1=1,
                tangential_force2=(index + 1) * 5,
                tangential_force3=2,
                tangential_direction1=10,
                tangential_direction2=20 + index,
                tangential_direction3=30,
                self_proximity1=100,
                self_proximity2=200 + index,
                mutual_proximity=150,
                status=0,
            )

        items = [item(index) for index in range(5)]
        values = service.tactile_values(SimpleNamespace(items=items))
        self.assertEqual(values["touch_normal"], [10, 20, 30, 40, 50])
        self.assertEqual(values["touch_direction"], [20, 21, 22, 23, 24])
        del items[2].normal_force2
        with self.assertRaises(ValueError):
            service.tactile_values(SimpleNamespace(items=items))
        items[2].normal_force2 = math.inf
        with self.assertRaises(ValueError):
            service.tactile_values(SimpleNamespace(items=items))

    def test_touch_capability_uses_hardware_and_serial_hints(self) -> None:
        self.assertTrue(service._supports_touch(SimpleNamespace(hardware_type=6), "x"))
        self.assertTrue(service._supports_touch(SimpleNamespace(hardware_type=7), "x"))
        self.assertTrue(
            service._supports_touch(SimpleNamespace(hardware_type=5), "BCXTL-test")
        )
        self.assertFalse(
            service._supports_touch(SimpleNamespace(hardware_type=5), "BCXRL-test")
        )

    def test_background_touch_timeout_does_not_overlap_serial_io(self) -> None:
        class FakeContext:
            def __init__(self) -> None:
                self.active = 0
                self.max_active = 0
                self.motor_calls = 0
                self.touch_calls = 0

            async def get_motor_status(self, _slave_id):
                self.active += 1
                self.max_active = max(self.max_active, self.active)
                self.motor_calls += 1
                try:
                    await asyncio.sleep(0)
                    return SimpleNamespace(
                        positions=[0] * 6,
                        currents=[0] * 6,
                        states=[0] * 6,
                    )
                finally:
                    self.active -= 1

            async def get_touch_sensor_status(self, _slave_id):
                self.active += 1
                self.max_active = max(self.max_active, self.active)
                self.touch_calls += 1
                try:
                    await asyncio.sleep(1.0)
                finally:
                    self.active -= 1

        class FakeSocket:
            def __init__(self) -> None:
                self.payloads = []

            def sendto(self, payload, _address):
                self.payloads.append(json.loads(payload))

        async def exercise() -> tuple[FakeContext, FakeSocket]:
            context = FakeContext()
            output = FakeSocket()
            worker = service.HandWorker(
                sdk=SimpleNamespace(),
                config=service.HandConfig("left", 0, "/dev/null", 126, "BCXTL-test"),
                receiver=SimpleNamespace(commands={}),
                telemetry_socket=output,
                telemetry_address=("127.0.0.1", 19092),
                allow_commands=False,
                watchdog_ns=1_000_000_000,
                max_step=160.0,
                max_speed=1000,
                max_current_ma=500,
                protected_current_ma=400,
                command_channels=(True,) * 6,
                current_alpha=0.35,
                rate_hz=100.0,
                touch_rate_hz=50.0,
                touch_timeout_seconds=0.005,
            )
            worker.context = context
            worker.touch_supported = True
            stopping = asyncio.Event()
            task = asyncio.create_task(worker.run(stopping, connected=True))
            await asyncio.sleep(0.065)
            stopping.set()
            await asyncio.wait_for(task, timeout=0.1)
            return context, output

        context, output = asyncio.run(exercise())
        self.assertGreaterEqual(context.motor_calls, 4)
        self.assertGreaterEqual(context.touch_calls, 2)
        self.assertEqual(context.max_active, 1)
        self.assertTrue(output.payloads)
        self.assertNotIn(
            "revo2_left_touch_normal", output.payloads[-1]["values"]
        )

    def test_touch_cli_rate_and_timeout_are_bounded(self) -> None:
        parser = service.build_parser()
        with self.assertRaises(SystemExit):
            service.validate_args(
                parser,
                parser.parse_args(["--rate", "20", "--touch-rate", "21"]),
            )
        with self.assertRaises(SystemExit):
            service.validate_args(
                parser,
                parser.parse_args(["--rate", "100", "--touch-timeout-ms", "11"]),
            )

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
