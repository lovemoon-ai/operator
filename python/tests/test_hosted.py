import asyncio
import json
import struct
import unittest
from types import MappingProxyType
from unittest.mock import patch

from pyoperator.hosted import (
    RobotHostedAdapter,
    _client,
    _read_frame,
    _write_frame,
    make_descriptor,
    serve,
    serve_async,
)
from pyoperator.robot import JointTarget, RobotState


class FakeAdapter:
    def __init__(self) -> None:
        self.commands = []
        self.stops = []
        self.connected = False

    def connect(self) -> None:
        self.connected = True

    def disconnect(self) -> None:
        self.connected = False

    def handle_command(self, command) -> None:
        self.commands.append(dict(command))

    def telemetry(self):
        return {"values": {"battery": 0.8}, "timestamp_ns": 10}

    def stop(self, reason) -> None:
        self.stops.append(reason)


class FakeRobot:
    def __init__(self) -> None:
        self.connected = False
        self.commands = []
        self.stops = []

    def connect(self) -> None:
        self.connected = True

    def disconnect(self) -> None:
        self.connected = False

    def read_state(self) -> RobotState:
        return RobotState(
            timestamp_ns=55,
            joint_positions=(0.1, 0.2),
            values=MappingProxyType({"battery": 0.8}),
        )

    def write(self, command) -> None:
        self.commands.append(command)

    def stop(self, reason) -> None:
        self.stops.append(reason)


class MemoryWriter:
    def __init__(self) -> None:
        self.data = bytearray()
        self.closed = False

    def write(self, data: bytes) -> None:
        self.data.extend(data)

    async def drain(self) -> None:
        pass

    def close(self) -> None:
        self.closed = True

    async def wait_closed(self) -> None:
        pass


def reader_with(payload: bytes) -> asyncio.StreamReader:
    reader = asyncio.StreamReader()
    reader.feed_data(payload)
    reader.feed_eof()
    return reader


class HostedTests(unittest.IsolatedAsyncioTestCase):
    async def test_existing_adapter_wire_protocol(self) -> None:
        adapter = FakeAdapter()
        descriptor = make_descriptor(name="Python Bot")
        server = await asyncio.start_server(
            lambda reader, writer: _client(reader, writer, adapter, descriptor, 100.0),
            "127.0.0.1",
            0,
        )
        address = server.sockets[0].getsockname()
        reader, writer = await asyncio.open_connection(*address)
        lock = asyncio.Lock()
        await _write_frame(writer, lock, {"type": "Hello"})
        response = await _read_frame(reader)
        self.assertEqual(response["type"], "Descriptor")
        self.assertEqual(response["device"]["name"], "Python Bot")

        await _write_frame(
            writer,
            lock,
            {"type": "Command", "axes": {"gripper": 0.4}, "buttons": {}, "poses": {}, "timestamp_ns": 1},
        )
        for _ in range(10):
            if adapter.commands:
                break
            await asyncio.sleep(0.01)
        self.assertEqual(adapter.commands[0]["axes"]["gripper"], 0.4)

        telemetry = await _read_frame(reader)
        self.assertEqual(telemetry["type"], "Telemetry")
        await _write_frame(writer, lock, {"type": "Shutdown"})
        await asyncio.sleep(0.02)
        server.close()
        await server.wait_closed()
        self.assertFalse(adapter.connected)

    async def test_stop_command_and_disconnect_cleanup(self) -> None:
        adapter = FakeAdapter()
        messages = (
            struct.pack("<I", len(b'{"type":"Hello"}'))
            + b'{"type":"Hello"}'
            + struct.pack("<I", len(b'{"type":"Stop","reason":"operator released"}'))
            + b'{"type":"Stop","reason":"operator released"}'
        )
        writer = MemoryWriter()
        await _client(reader_with(messages), writer, adapter, make_descriptor(name="Bot"), 100.0)
        self.assertIn("operator released", adapter.stops)
        self.assertIn("xr-bridge disconnected", adapter.stops)
        self.assertFalse(adapter.connected)
        self.assertTrue(writer.closed)

    async def test_framing_rejects_eof_oversize_and_non_object(self) -> None:
        self.assertIsNone(await _read_frame(reader_with(b"\x01\x00")))
        with patch("pyoperator.hosted.MAX_FRAME_BYTES", 4):
            with self.assertRaisesRegex(ValueError, "exceeds"):
                await _read_frame(reader_with(struct.pack("<I", 5) + b"12345"))
            with self.assertRaisesRegex(ValueError, "exceeds"):
                await _write_frame(MemoryWriter(), asyncio.Lock(), {"value": "large"})

        payload = json.dumps([1, 2, 3]).encode()
        with self.assertRaisesRegex(ValueError, "JSON object"):
            await _read_frame(reader_with(struct.pack("<I", len(payload)) + payload))

    async def test_client_requires_hello_and_always_disconnects(self) -> None:
        payload = b'{"type":"Command"}'
        adapter = FakeAdapter()
        writer = MemoryWriter()
        with self.assertRaisesRegex(ValueError, "expected adapter Hello"):
            await _client(
                reader_with(struct.pack("<I", len(payload)) + payload),
                writer,
                adapter,
                make_descriptor(name="Bot"),
                10.0,
            )
        self.assertFalse(adapter.connected)
        self.assertTrue(writer.closed)

    async def test_telemetry_failure_propagates_and_unblocks_client(self) -> None:
        class FailingTelemetryAdapter(FakeAdapter):
            def telemetry(self):
                raise RuntimeError("telemetry failed")

        hello = b'{"type":"Hello"}'
        reader = asyncio.StreamReader()
        reader.feed_data(struct.pack("<I", len(hello)) + hello)
        adapter = FailingTelemetryAdapter()
        writer = MemoryWriter()

        with self.assertRaisesRegex(RuntimeError, "telemetry failed"):
            await asyncio.wait_for(
                _client(reader, writer, adapter, make_descriptor(name="Bot"), 10.0),
                timeout=1.0,
            )
        self.assertFalse(adapter.connected)
        self.assertTrue(writer.closed)

    async def test_cleanup_disconnects_when_stop_raises(self) -> None:
        class StopFailingAdapter(FakeAdapter):
            def stop(self, reason) -> None:
                self.stops.append(reason)
                raise RuntimeError("stop failed")

        adapter = StopFailingAdapter()
        writer = MemoryWriter()
        hello = b'{"type":"Hello"}'
        with self.assertRaisesRegex(RuntimeError, "stop failed"):
            await _client(
                reader_with(struct.pack("<I", len(hello)) + hello),
                writer,
                adapter,
                make_descriptor(name="Bot"),
                10.0,
            )
        self.assertFalse(adapter.connected)
        self.assertTrue(writer.closed)

    async def test_serve_rejects_non_positive_telemetry_rate(self) -> None:
        with self.assertRaisesRegex(ValueError, "must be positive"):
            await serve_async(FakeAdapter(), make_descriptor(name="Bot"), telemetry_hz=0)


class RobotHostedAdapterTests(unittest.TestCase):
    def test_robot_adapter_maps_commands_and_default_telemetry(self) -> None:
        robot = FakeRobot()
        expected = JointTarget((0.5,), gripper=0.2, timestamp_ns=8)
        adapter = RobotHostedAdapter(robot, lambda command: expected if command.get("drive") else None)
        adapter.connect()
        adapter.handle_command({"drive": False})
        adapter.handle_command({"drive": True})
        self.assertEqual(robot.commands, [expected])
        self.assertEqual(
            adapter.telemetry(),
            {
                "values": {"joint_positions": [0.1, 0.2], "battery": 0.8},
                "timestamp_ns": 55,
            },
        )
        adapter.stop("test stop")
        adapter.disconnect()
        self.assertFalse(robot.connected)
        self.assertEqual(robot.stops, ["test stop"])

    def test_custom_telemetry_mapper_and_descriptor_shape(self) -> None:
        robot = FakeRobot()
        adapter = RobotHostedAdapter(robot, lambda _command: None, lambda _robot: {"custom": 1})
        self.assertEqual(adapter.telemetry(), {"custom": 1})
        descriptor = make_descriptor(
            name="Python Bot",
            device_type="arm",
            axes=[{"name": "gripper"}],
            buttons=[{"name": "home"}],
            poses=[{"name": "ee"}],
            telemetry=[{"name": "battery"}],
            command_timeout_ms=250,
        )
        self.assertEqual(descriptor["device"]["type"], "arm")
        self.assertEqual(descriptor["control_schema"]["axes"][0]["name"], "gripper")
        self.assertEqual(descriptor["safety"]["command_timeout_ms"], 250)

    def test_sync_serve_delegates_to_async_entrypoint(self) -> None:
        adapter = FakeAdapter()
        descriptor = make_descriptor(name="Bot")
        with patch("pyoperator.hosted.asyncio.run") as run_async:
            serve(adapter, descriptor, port=1234)
        coroutine = run_async.call_args.args[0]
        self.assertEqual(coroutine.cr_frame.f_locals["port"], 1234)
        coroutine.close()
