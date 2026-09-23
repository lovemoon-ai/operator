"""Python adapters and Blueprint hosted behind standalone xr-bridge."""

from __future__ import annotations

import asyncio
from collections import deque
import json
import struct
import sys
import threading
import time
from typing import Any, Callable, Mapping, Protocol

from ._blueprint_spec import WIRE
from .blueprint import BlueprintClient
from .capture import CaptureStreamsConfig, StreamsControl, StreamsStatus
from .robot import Robot, RobotCommand

try:
    from ._native import NativeBlueprintPublisher as _NativeBlueprintPublisher
except ImportError as error:
    _NativeBlueprintPublisher = None
    _native_import_error = error
else:
    _native_import_error = None

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


def _signal_blueprint_update(queue: asyncio.Queue[None]) -> None:
    if not queue.full():
        queue.put_nowait(None)


class _HostedBlueprintBackend:
    def __init__(self) -> None:
        if _NativeBlueprintPublisher is None:
            raise RuntimeError(
                "operator_xr native extension is not installed; run "
                "`pip install -e ./python` from the Operator repository"
            ) from _native_import_error
        self._native = _NativeBlueprintPublisher()
        self._lock = threading.Lock()
        self._event_ready = threading.Condition(self._lock)
        self._running = True
        self._blueprint_version = 0
        self._has_blueprint = False
        self._state_version = 0
        self._has_state = False
        self._events: deque[str] = deque(maxlen=256)
        self._next_subscriber = 1
        self._subscribers: dict[
            int, tuple[asyncio.AbstractEventLoop, asyncio.Queue[None]]
        ] = {}

    def is_running(self) -> bool:
        with self._lock:
            return self._running

    def blueprint_spec_sha256(self) -> str:
        return str(self._native.blueprint_spec_sha256())

    def blueprint_spec_version(self) -> int:
        return int(self._native.blueprint_spec_version())

    def set_blueprint_json(self, payload: str) -> None:
        with self._lock:
            self._native.set_blueprint_json(payload)
            self._has_blueprint = True
            self._has_state = False
            self._events.clear()
            self._blueprint_version += 1
            self._state_version += 1
            self._notify_subscribers_locked()

    def clear_blueprint(self) -> None:
        with self._lock:
            self._native.clear_blueprint()
            self._has_blueprint = False
            self._has_state = False
            self._blueprint_version += 1
            self._state_version += 1
            self._events.clear()
            self._notify_subscribers_locked()

    def publish_blueprint_state_json(self, payload: str) -> None:
        with self._lock:
            self._native.publish_blueprint_state_json(payload)
            self._has_state = True
            self._state_version += 1
            self._notify_subscribers_locked()

    def update_blueprint_values_json(self, payload: str, timestamp_ns: int) -> int:
        with self._lock:
            sequence = int(
                self._native.update_blueprint_values_json(payload, timestamp_ns)
            )
            self._has_state = True
            self._state_version += 1
            self._notify_subscribers_locked()
            return sequence

    def poll_blueprint_event_json(self, timeout: float | None) -> str | None:
        if timeout is not None and (timeout < 0.0 or not float(timeout) < float("inf")):
            raise ValueError("timeout must be finite and non-negative")
        deadline = None if timeout is None else time.monotonic() + timeout
        with self._event_ready:
            while self._running and not self._events:
                remaining = None if deadline is None else deadline - time.monotonic()
                if remaining is not None and remaining <= 0.0:
                    return None
                self._event_ready.wait(remaining)
            return self._events.popleft() if self._events else None

    def push_event(self, event: Mapping[str, Any]) -> None:
        message = json.dumps(
            {"type": WIRE["commands"]["event"], "event": dict(event)},
            separators=(",", ":"),
            allow_nan=False,
        )
        with self._event_ready:
            if not self._running:
                return
            self._events.append(self._native.parse_event_message_json(message))
            self._event_ready.notify()

    def subscribe(self) -> tuple[int, asyncio.Queue[None]]:
        loop = asyncio.get_running_loop()
        queue: asyncio.Queue[None] = asyncio.Queue(maxsize=1)
        with self._lock:
            token = self._next_subscriber
            self._next_subscriber += 1
            self._subscribers[token] = (loop, queue)
        queue.put_nowait(None)
        return token, queue

    def unsubscribe(self, token: int) -> None:
        with self._lock:
            self._subscribers.pop(token, None)

    def snapshot(
        self,
    ) -> tuple[int, dict[str, Any] | None, int, dict[str, Any] | None, bool]:
        with self._lock:
            blueprint = None
            state = None
            if self._has_blueprint:
                message = json.loads(self._native.definition_message_json())
                blueprint = message["blueprint"]
            if self._has_state:
                message = json.loads(self._native.state_message_json())
                state = message["state"]
            return (
                self._blueprint_version,
                blueprint,
                self._state_version,
                state,
                self._running,
            )

    def descriptor_message(self, descriptor: Mapping[str, Any]) -> dict[str, Any]:
        payload = json.dumps(dict(descriptor), separators=(",", ":"), allow_nan=False)
        with self._lock:
            message = json.loads(self._native.descriptor_message_json(payload))
        if not isinstance(message, dict):
            raise RuntimeError("Rust Operator SDK returned a non-object descriptor")
        return message

    def close(self) -> None:
        with self._event_ready:
            if not self._running:
                return
            self._running = False
            self._events.clear()
            self._event_ready.notify_all()
            self._notify_subscribers_locked()

    def _notify_subscribers_locked(self) -> None:
        for loop, queue in self._subscribers.values():
            loop.call_soon_threadsafe(_signal_blueprint_update, queue)


class HostedBlueprint(BlueprintClient):
    """Blueprint publisher for Python adapters behind standalone xr-bridge."""

    def __init__(self) -> None:
        self._hosted_backend = _HostedBlueprintBackend()
        super().__init__(self._hosted_backend, self._hosted_backend.is_running)

    def close(self) -> None:
        self._hosted_backend.close()

    def _subscribe(self) -> tuple[int, asyncio.Queue[None]]:
        return self._hosted_backend.subscribe()

    def _unsubscribe(self, token: int) -> None:
        self._hosted_backend.unsubscribe(token)

    def _snapshot(
        self,
    ) -> tuple[int, dict[str, Any] | None, int, dict[str, Any] | None, bool]:
        return self._hosted_backend.snapshot()

    def _push_event(self, event: Mapping[str, Any]) -> None:
        self._hosted_backend.push_event(event)

    def _descriptor_message(self, descriptor: Mapping[str, Any]) -> dict[str, Any]:
        return self._hosted_backend.descriptor_message(descriptor)


class HostedStreams:
    """Capture-stream ctrl for a Python adapter behind standalone xr-bridge.

    Declare the streams with ``make_descriptor(capture_streams=...)`` and pass
    this object to :func:`create_server`. xr-bridge forwards the headset's
    ``StreamsStatus`` here (:meth:`status`, ``on_status``) and :meth:`control`
    to the headset when it advertises ``capture_streams_v1``. The standalone
    bridge serves no media, so the headset reports declared streams
    ``unsupported``; capture media requires the embedded ``XrSession``.
    """

    #: ``on_status`` fires for each report; a cleared status (the reporting
    #: headset disconnected) only resets :meth:`status` to ``None``.
    def __init__(self, on_status: Callable[[StreamsStatus], None] | None = None) -> None:
        self._on_status = on_status
        self._lock = threading.Lock()
        self._status: StreamsStatus | None = None
        self._next_subscriber = 1
        self._subscribers: dict[
            int, tuple[asyncio.AbstractEventLoop, asyncio.Queue[dict[str, Any]]]
        ] = {}

    def status(self) -> StreamsStatus | None:
        """Latest headset status; ``None`` until reported, after the reporting
        headset disconnected, or once no xr-bridge is connected."""
        with self._lock:
            return self._status

    def control(
        self,
        streams: StreamsControl | Mapping[str, Any] | None = None,
        *,
        local_tasks: Mapping[str, Any] | None = None,
    ) -> None:
        """Queue a ``StreamsControl`` for every connected xr-bridge, in order."""
        control = (
            streams
            if isinstance(streams, StreamsControl)
            else StreamsControl(streams=streams or {}, local_tasks=local_tasks or {})
        )
        message = {"type": "StreamsControl", "control": control.to_dict()}
        with self._lock:
            subscribers = list(self._subscribers.values())
        if not subscribers:
            raise RuntimeError("no xr-bridge is connected")
        for loop, queue in subscribers:
            loop.call_soon_threadsafe(queue.put_nowait, message)

    def _subscribe(self) -> tuple[int, asyncio.Queue[dict[str, Any]]]:
        loop = asyncio.get_running_loop()
        queue: asyncio.Queue[dict[str, Any]] = asyncio.Queue()
        with self._lock:
            token = self._next_subscriber
            self._next_subscriber += 1
            self._subscribers[token] = (loop, queue)
        return token, queue

    def _unsubscribe(self, token: int) -> None:
        with self._lock:
            self._subscribers.pop(token, None)
            if not self._subscribers:
                self._status = None

    def _push_status(self, value: Any) -> None:
        if value is None:
            # The reporting headset disconnected: drop the stale report
            # instead of leaving the adapter believing capture still runs.
            with self._lock:
                self._status = None
            return
        try:
            status = StreamsStatus.from_dict(value)
        except (TypeError, ValueError):
            return
        with self._lock:
            self._status = status
        if self._on_status is not None:
            self._on_status(status)


def make_descriptor(
    *,
    name: str,
    device_type: str = "python_robot",
    axes: list[Mapping[str, Any]] | None = None,
    buttons: list[Mapping[str, Any]] | None = None,
    poses: list[Mapping[str, Any]] | None = None,
    telemetry: list[Mapping[str, Any]] | None = None,
    command_timeout_ms: int = 500,
    capture_streams: CaptureStreamsConfig | None = None,
) -> dict[str, Any]:
    """Build an adapter descriptor, optionally declaring ``capture_streams``."""
    descriptor: dict[str, Any] = {
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
        "capabilities": {},
    }
    if capture_streams is not None:
        descriptor["capture_streams"] = capture_streams.to_descriptor_dict()
    return descriptor


def _descriptor_without_blueprint(descriptor: Mapping[str, Any]) -> dict[str, Any]:
    result = dict(descriptor)
    capabilities = dict(result.get("capabilities", {}))
    capabilities.pop(WIRE["capability"], None)
    capabilities.pop(WIRE["spec_hash_capability"], None)
    result["capabilities"] = capabilities
    return result


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


async def _blueprint_loop(
    writer: asyncio.StreamWriter,
    lock: asyncio.Lock,
    publisher: HostedBlueprint,
) -> None:
    token, updates = publisher._subscribe()
    blueprint_version = -1
    state_version = -1
    try:
        while True:
            await updates.get()
            (
                next_blueprint_version,
                definition,
                next_state_version,
                state,
                running,
            ) = publisher._snapshot()
            if next_blueprint_version != blueprint_version:
                await _write_frame(
                    writer,
                    lock,
                    {"type": WIRE["commands"]["blueprint"], "blueprint": definition},
                )
                blueprint_version = next_blueprint_version
            if (
                definition is not None
                and state is not None
                and next_state_version != state_version
            ):
                await _write_frame(
                    writer,
                    lock,
                    {"type": WIRE["commands"]["state"], "state": state},
                )
                state_version = next_state_version
            if not running:
                return
    finally:
        publisher._unsubscribe(token)


async def _streams_control_loop(
    writer: asyncio.StreamWriter,
    lock: asyncio.Lock,
    controls: asyncio.Queue[dict[str, Any]],
) -> None:
    while True:
        await _write_frame(writer, lock, await controls.get())


async def _client(
    reader: asyncio.StreamReader,
    writer: asyncio.StreamWriter,
    adapter: HostedAdapter,
    descriptor: Mapping[str, Any],
    telemetry_hz: float,
    blueprint: HostedBlueprint | None = None,
    streams: HostedStreams | None = None,
) -> None:
    lock = asyncio.Lock()
    telemetry_task: asyncio.Task[None] | None = None
    inbound_task: asyncio.Task[None] | None = None
    blueprint_task: asyncio.Task[None] | None = None
    streams_task: asyncio.Task[None] | None = None
    streams_token: int | None = None
    connect_attempted = False
    try:
        connect_attempted = True
        adapter.connect()
        hello = await _read_frame(reader)
        if hello is None or hello.get("type") != "Hello":
            raise ValueError("expected adapter Hello")
        if blueprint is None:
            advertised_descriptor = {
                "type": "Descriptor",
                **_descriptor_without_blueprint(descriptor),
            }
        else:
            advertised_descriptor = blueprint._descriptor_message(descriptor)
        await _write_frame(writer, lock, advertised_descriptor)
        if blueprint is not None:
            blueprint_task = asyncio.create_task(
                _blueprint_loop(writer, lock, blueprint),
                name="hosted-blueprint",
            )
        if streams is not None:
            streams_token, controls = streams._subscribe()
            streams_task = asyncio.create_task(
                _streams_control_loop(writer, lock, controls),
                name="hosted-streams-control",
            )

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
                elif kind == WIRE["commands"]["event"] and blueprint is not None:
                    event = message.get("event")
                    if isinstance(event, Mapping):
                        blueprint._push_event(event)
                elif kind == "StreamsStatus" and streams is not None:
                    streams._push_status(message.get("status"))
                elif kind == "Shutdown":
                    adapter.stop("xr-bridge shutdown")
                    break

        telemetry_task = asyncio.create_task(telemetry_loop())
        inbound_task = asyncio.create_task(inbound_loop())
        tasks = [telemetry_task, inbound_task]
        tasks.extend(task for task in (blueprint_task, streams_task) if task is not None)
        done, _pending = await asyncio.wait(
            tasks,
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
        tasks = [
            task
            for task in (telemetry_task, inbound_task, blueprint_task, streams_task)
            if task is not None
        ]
        for task in tasks:
            task.cancel()
        if tasks:
            await asyncio.gather(*tasks, return_exceptions=True)
        if streams is not None and streams_token is not None:
            streams._unsubscribe(streams_token)
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
                    add_note(f"operator_xr hosted cleanup also failed: {error!r}")


async def create_server(
    adapter: HostedAdapter,
    descriptor: Mapping[str, Any],
    *,
    host: str = "127.0.0.1",
    port: int = 63910,
    telemetry_hz: float = 10.0,
    blueprint: HostedBlueprint | None = None,
    streams: HostedStreams | None = None,
) -> asyncio.AbstractServer:
    if telemetry_hz <= 0:
        raise ValueError("telemetry_hz must be positive")
    return await asyncio.start_server(
        lambda reader, writer: _client(
            reader, writer, adapter, descriptor, telemetry_hz, blueprint, streams
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
    blueprint: HostedBlueprint | None = None,
    streams: HostedStreams | None = None,
) -> None:
    server = await create_server(
        adapter,
        descriptor,
        host=host,
        port=port,
        telemetry_hz=telemetry_hz,
        blueprint=blueprint,
        streams=streams,
    )
    async with server:
        await server.serve_forever()


def serve(
    adapter: HostedAdapter,
    descriptor: Mapping[str, Any],
    **options: Any,
) -> None:
    asyncio.run(serve_async(adapter, descriptor, **options))
