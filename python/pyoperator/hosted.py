"""Compatibility mode for Python backends hosted behind standalone xr-bridge."""

from __future__ import annotations

import asyncio
import json
import struct
import sys
import time
from typing import Any, Callable, Mapping, Protocol

from .robot import Robot, RobotCommand

MAX_FRAME_BYTES = 16 * 1024 * 1024


class HostedAdapter(Protocol):
    def connect(self) -> None: ...
    def disconnect(self) -> None: ...
    def handle_command(self, command: Mapping[str, Any]) -> None: ...
    def telemetry(self) -> Mapping[str, Any]: ...
    def stop(self, reason: str) -> None: ...


class RobotHostedAdapter:
    """Expose the common ``Robot`` API through the existing adapter protocol."""

    def __init__(
        self,
        robot: Robot,
        command_mapper: Callable[[Mapping[str, Any]], RobotCommand | None],
        telemetry_mapper: Callable[[Robot], Mapping[str, Any]] | None = None,
    ) -> None:
        self.robot = robot
        self.command_mapper = command_mapper
        self.telemetry_mapper = telemetry_mapper

    def connect(self) -> None:
        self.robot.connect()

    def disconnect(self) -> None:
        self.robot.disconnect()

    def handle_command(self, command: Mapping[str, Any]) -> None:
        mapped = self.command_mapper(command)
        if mapped is not None:
            self.robot.write(mapped)

    def telemetry(self) -> Mapping[str, Any]:
        if self.telemetry_mapper is not None:
            return self.telemetry_mapper(self.robot)
        state = self.robot.read_state()
        values: dict[str, Any] = {"joint_positions": list(state.joint_positions)}
        values.update(state.values)
        return {"values": values, "timestamp_ns": state.timestamp_ns}

    def stop(self, reason: str) -> None:
        self.robot.stop(reason)


def make_descriptor(
    *,
    name: str,
    device_type: str = "python_robot",
    axes: list[Mapping[str, Any]] | None = None,
    buttons: list[Mapping[str, Any]] | None = None,
    poses: list[Mapping[str, Any]] | None = None,
    telemetry: list[Mapping[str, Any]] | None = None,
    command_timeout_ms: int = 500,
) -> dict[str, Any]:
    return {
        "device": {"type": device_type, "name": name, "icon": "robot_arm"},
        "control_schema": {
            "axes": list(axes or ()),
            "buttons": list(buttons or ()),
            "poses": list(poses or ()),
        },
        "input_mapping": [],
        "telemetry_schema": {"values": list(telemetry or ())},
        "video_feeds": [],
        "safety": {"disconnect_action": "stop", "command_timeout_ms": command_timeout_ms},
    }


async def _read_frame(reader: asyncio.StreamReader) -> dict[str, Any] | None:
    try:
        prefix = await reader.readexactly(4)
    except asyncio.IncompleteReadError:
        return None
    length = struct.unpack("<I", prefix)[0]
    if length > MAX_FRAME_BYTES:
        raise ValueError(f"adapter frame exceeds {MAX_FRAME_BYTES} bytes")
    payload = await reader.readexactly(length)
    value = json.loads(payload)
    if not isinstance(value, dict):
        raise ValueError("adapter frame must be a JSON object")
    return value


async def _write_frame(
    writer: asyncio.StreamWriter, lock: asyncio.Lock, value: Mapping[str, Any]
) -> None:
    payload = json.dumps(value, separators=(",", ":")).encode()
    if len(payload) > MAX_FRAME_BYTES:
        raise ValueError(f"adapter frame exceeds {MAX_FRAME_BYTES} bytes")
    async with lock:
        writer.write(struct.pack("<I", len(payload)) + payload)
        await writer.drain()


async def _client(
    reader: asyncio.StreamReader,
    writer: asyncio.StreamWriter,
    adapter: HostedAdapter,
    descriptor: Mapping[str, Any],
    telemetry_hz: float,
) -> None:
    lock = asyncio.Lock()
    telemetry_task: asyncio.Task[None] | None = None
    inbound_task: asyncio.Task[None] | None = None
    connect_attempted = False
    try:
        connect_attempted = True
        adapter.connect()
        hello = await _read_frame(reader)
        if hello is None or hello.get("type") != "Hello":
            raise ValueError("expected adapter Hello")
        await _write_frame(writer, lock, {"type": "Descriptor", **descriptor})

        async def telemetry_loop() -> None:
            interval = 1.0 / telemetry_hz
            while True:
                telemetry = dict(adapter.telemetry())
                telemetry.setdefault("values", {})
                telemetry.setdefault("timestamp_ns", time.time_ns())
                await _write_frame(writer, lock, {"type": "Telemetry", **telemetry})
                await asyncio.sleep(interval)

        async def inbound_loop() -> None:
            while True:
                message = await _read_frame(reader)
                if message is None:
                    break
                kind = message.pop("type", None)
                if kind == "Command":
                    adapter.handle_command(message)
                elif kind == "Stop":
                    adapter.stop(str(message.get("reason", "xr-bridge stop")))
                elif kind == "Shutdown":
                    adapter.stop("xr-bridge shutdown")
                    break

        telemetry_task = asyncio.create_task(telemetry_loop())
        inbound_task = asyncio.create_task(inbound_loop())
        done, _pending = await asyncio.wait(
            (telemetry_task, inbound_task),
            return_when=asyncio.FIRST_COMPLETED,
        )
        # Await every completed task so telemetry/serialization/socket errors
        # propagate through _client instead of leaving the reader hung forever.
        for task in done:
            try:
                await task
            except (BrokenPipeError, ConnectionResetError, asyncio.IncompleteReadError):
                pass
    finally:
        primary_error = sys.exc_info()[1]
        cleanup_errors: list[BaseException] = []
        tasks = [task for task in (telemetry_task, inbound_task) if task is not None]
        for task in tasks:
            task.cancel()
        if tasks:
            await asyncio.gather(*tasks, return_exceptions=True)
        if connect_attempted:
            try:
                adapter.stop("xr-bridge disconnected")
            except BaseException as error:
                cleanup_errors.append(error)
            try:
                adapter.disconnect()
            except BaseException as error:
                cleanup_errors.append(error)
        try:
            writer.close()
            await writer.wait_closed()
        except (BrokenPipeError, ConnectionResetError):
            pass
        except BaseException as error:
            cleanup_errors.append(error)

        if primary_error is None and cleanup_errors:
            raise cleanup_errors[0]
        if primary_error is not None and cleanup_errors:
            add_note = getattr(primary_error, "add_note", None)
            if add_note is not None:
                for error in cleanup_errors:
                    add_note(f"pyoperator hosted cleanup also failed: {error!r}")


async def create_server(
    adapter: HostedAdapter,
    descriptor: Mapping[str, Any],
    *,
    host: str = "127.0.0.1",
    port: int = 63910,
    telemetry_hz: float = 10.0,
) -> asyncio.AbstractServer:
    if telemetry_hz <= 0:
        raise ValueError("telemetry_hz must be positive")
    return await asyncio.start_server(
        lambda reader, writer: _client(
            reader, writer, adapter, descriptor, telemetry_hz
        ),
        host,
        port,
    )


async def serve_async(
    adapter: HostedAdapter,
    descriptor: Mapping[str, Any],
    *,
    host: str = "127.0.0.1",
    port: int = 63910,
    telemetry_hz: float = 10.0,
) -> None:
    server = await create_server(
        adapter,
        descriptor,
        host=host,
        port=port,
        telemetry_hz=telemetry_hz,
    )
    async with server:
        await server.serve_forever()


def serve(
    adapter: HostedAdapter,
    descriptor: Mapping[str, Any],
    **options: Any,
) -> None:
    asyncio.run(serve_async(adapter, descriptor, **options))
