#!/usr/bin/env python3
"""Run the complete Revo2 hand-only Operator service on one Thor host.

This entry point combines the guarded serial runtime, the pyoperator hosted
adapter, and xr-bridge supervision. The headset connects directly to the Thor
address on the normal Operator ports.
"""

from __future__ import annotations

import argparse
import asyncio
from contextlib import suppress
from dataclasses import dataclass
import fcntl
import glob
import json
import math
import os
from pathlib import Path
import shutil
import signal
import socket
import struct
import sys
import time
from types import SimpleNamespace
from typing import Any, Dict, IO, Optional, Sequence, Tuple

SCRIPT_DIR = Path(__file__).resolve().parent
for dependency_dir in (
    SCRIPT_DIR / "lib",
    SCRIPT_DIR / "sdk",
    SCRIPT_DIR.parent / "python",
):
    if dependency_dir.is_dir():
        sys.path.insert(0, str(dependency_dir))

from pyoperator.hosted import create_server
from pyoperator.integrations.revo2_udp import (
    Revo2UdpHostedAdapter,
    make_revo2_descriptor,
)

DEFAULT_LEFT_SERIAL = "BCXRL2103J2600007"
DEFAULT_RIGHT_SERIAL = "BCXRR2100J2600007"
DEFAULT_PID_FILE = "revo2_thor_service.pid"
XR_POSE_PORT = 63901
XR_TELEMETRY_PORT = 63903
PACKET = struct.Struct("<4sBBHIQ12f")
MAGIC = b"BCH2"
VERSION = 2
FLAG_HOLD = 1 << 0
CHANNEL_NAMES = (
    "thumb_flex",
    "thumb_aux",
    "index",
    "middle",
    "ring",
    "pinky",
)
CHANNEL_MAX_POSITIONS = (500.0, 870.0, 1000.0, 1000.0, 1000.0, 1000.0)


def _sdk():
    try:
        from bc_stark_sdk import main_mod as sdk
    except ImportError as exc:
        raise SystemExit(
            "bc-stark-sdk is required; add the extracted official aarch64 wheel "
            "directory to PYTHONPATH"
        ) from exc
    return sdk


def decode_packet(payload: bytes) -> Optional[Dict[str, Any]]:
    if len(payload) != PACKET.size:
        return None
    magic, version, side, flags, sequence, sender_ns, *values = PACKET.unpack(payload)
    if magic != MAGIC or version != VERSION or side not in (0, 1):
        return None
    q = tuple(float(value) for value in values[:6])
    dq = tuple(float(value) for value in values[6:])
    if not all(math.isfinite(value) for value in q + dq):
        return None
    return {
        "side": int(side),
        "flags": int(flags),
        "sequence": int(sequence),
        "sender_ns": int(sender_ns),
        "q": tuple(max(0.0, min(1.0, value)) for value in q),
        "dq": tuple(max(0.0, min(1.0, value)) for value in dq),
    }


def slew_targets(
    previous: Sequence[float], desired: Sequence[float], max_step: float
) -> Tuple[int, ...]:
    return tuple(
        int(round(old + max(-max_step, min(max_step, new - old))))
        for old, new in zip(previous, desired)
    )


def parse_channel_mask(value: str) -> Tuple[bool, ...]:
    names = {item.strip() for item in value.split(",") if item.strip()}
    unknown = names.difference(CHANNEL_NAMES)
    if unknown:
        raise argparse.ArgumentTypeError(
            "unknown command channels: %s" % ", ".join(sorted(unknown))
        )
    if not names:
        raise argparse.ArgumentTypeError("at least one command channel is required")
    return tuple(name in names for name in CHANNEL_NAMES)


def masked_targets(
    actual: Sequence[float], desired: Sequence[float], enabled: Sequence[bool]
) -> Tuple[float, ...]:
    return tuple(
        min(target, maximum) if active else position
        for position, target, active, maximum in zip(
            actual, desired, enabled, CHANNEL_MAX_POSITIONS
        )
    )


def _stall(value: Any) -> float:
    name = getattr(value, "name", str(value)).upper()
    return 1.0 if name.endswith("STALL") or value == 2 else 0.0


@dataclass
class AcceptedCommand:
    q: Tuple[float, ...]
    dq: Tuple[float, ...]
    flags: int
    sequence: int
    sender_ns: int
    received_ns: int


class CommandReceiver(asyncio.DatagramProtocol):
    def __init__(self, allowed_source: str, reset_after_ns: int) -> None:
        self.allowed_source = allowed_source
        self.reset_after_ns = reset_after_ns
        self.commands: Dict[int, AcceptedCommand] = {}
        self.rejected = 0

    def datagram_received(self, payload: bytes, address: Tuple[str, int]) -> None:
        if self.allowed_source and address[0] != self.allowed_source:
            self.rejected += 1
            return
        decoded = decode_packet(payload)
        if decoded is None:
            self.rejected += 1
            return
        side = int(decoded["side"])
        now_ns = time.monotonic_ns()
        previous = self.commands.get(side)
        if previous is not None:
            delta = (int(decoded["sequence"]) - previous.sequence) & 0xFFFFFFFF
            newer = 0 < delta < 0x80000000
            stale = now_ns - previous.received_ns > self.reset_after_ns
            if not newer and not stale:
                self.rejected += 1
                return
        self.commands[side] = AcceptedCommand(
            q=decoded["q"],
            dq=decoded["dq"],
            flags=int(decoded["flags"]),
            sequence=int(decoded["sequence"]),
            sender_ns=int(decoded["sender_ns"]),
            received_ns=now_ns,
        )


@dataclass(frozen=True)
class HandConfig:
    side: str
    side_id: int
    port: str
    slave_id: int
    serial: str


class HandWorker:
    def __init__(
        self,
        *,
        sdk: Any,
        config: HandConfig,
        receiver: CommandReceiver,
        telemetry_socket: socket.socket,
        telemetry_address: Tuple[str, int],
        allow_commands: bool,
        watchdog_ns: int,
        max_step: float,
        max_speed: int,
        max_current_ma: int,
        protected_current_ma: int,
        command_channels: Tuple[bool, ...],
        current_alpha: float,
        rate_hz: float,
    ) -> None:
        self.sdk = sdk
        self.config = config
        self.receiver = receiver
        self.telemetry_socket = telemetry_socket
        self.telemetry_address = telemetry_address
        self.allow_commands = allow_commands
        self.watchdog_ns = watchdog_ns
        self.max_step = max_step
        self.max_speed = max_speed
        self.max_current_ma = max_current_ma
        self.protected_current_ma = protected_current_ma
        self.command_channels = command_channels
        self.current_alpha = current_alpha
        self.interval = 1.0 / rate_hz
        self.context = None
        self.actual: Tuple[float, ...] = (0.0,) * 6
        self.target: Tuple[float, ...] = (0.0,) * 6
        self.filtered_current: Optional[Tuple[float, ...]] = None
        self.last_written: Optional[Tuple[float, ...]] = None
        self.hold_sent = False

    async def connect(self) -> None:
        detected = await self.sdk.auto_detect(
            scan_all=True,
            port=self.config.port,
            protocol="Modbus",
        )
        matches = [
            device
            for device in detected
            if int(device.slave_id) == self.config.slave_id
            and str(device.serial_number) == self.config.serial
        ]
        if len(matches) != 1:
            raise RuntimeError(
                "%s: expected one hand id=%d serial=%s on %s, found %d"
                % (
                    self.config.side,
                    self.config.slave_id,
                    self.config.serial,
                    self.config.port,
                    len(matches),
                )
            )
        self.context = await self.sdk.init_from_detected(matches[0])
        if self.allow_commands:
            await self._configure_current_limits()
        print(
            "%s connected port=%s id=%d serial=%s commands=%s"
            % (
                self.config.side,
                self.config.port,
                self.config.slave_id,
                self.config.serial,
                "enabled" if self.allow_commands else "disabled",
            ),
            flush=True,
        )

    async def _configure_current_limits(self) -> None:
        finger_ids = (
            self.sdk.FingerId.Thumb,
            self.sdk.FingerId.ThumbAux,
            self.sdk.FingerId.Index,
            self.sdk.FingerId.Middle,
            self.sdk.FingerId.Ring,
            self.sdk.FingerId.Pinky,
        )
        for finger_id in finger_ids:
            await self._set_and_verify_max_current(finger_id)

        protected = [self.protected_current_ma] * 6
        for _attempt in range(2):
            await self.context.set_finger_protected_currents(
                self.config.slave_id, protected
            )
            await asyncio.sleep(0.01)
            readback = list(
                await self.context.get_finger_protected_currents(
                    self.config.slave_id
                )
            )
            if readback == protected:
                break
        else:
            raise RuntimeError(
                "%s protected-current readback mismatch: %s"
                % (self.config.side, readback)
            )
        print(
            "%s current limits max=%dmA protected=%dmA"
            % (self.config.side, self.max_current_ma, self.protected_current_ma),
            flush=True,
        )

    async def _set_and_verify_max_current(self, finger_id: Any) -> None:
        for _attempt in range(2):
            await self.context.set_finger_max_current(
                self.config.slave_id, finger_id, self.max_current_ma
            )
            await asyncio.sleep(0.01)
            readback = int(
                await self.context.get_finger_max_current(
                    self.config.slave_id, finger_id
                )
            )
            if readback == self.max_current_ma:
                return
        raise RuntimeError(
            "%s max-current readback mismatch finger=%s value=%s"
            % (self.config.side, finger_id, readback)
        )

    async def close(self) -> None:
        if self.context is None:
            return
        if self.allow_commands and self.last_written is not None:
            try:
                await self._write(self.actual, (0.02,) * 6)
            except Exception as exc:
                print(
                    "%s final hold failed: %s" % (self.config.side, exc),
                    file=sys.stderr,
                )
        await self.sdk.close_device_handler(self.context)
        self.context = None

    async def run(self, stopping: asyncio.Event, *, connected: bool = False) -> None:
        if not connected:
            await self.connect()
        next_tick = time.monotonic()
        while not stopping.is_set():
            try:
                status = await self.context.get_motor_status(self.config.slave_id)
                self.actual = tuple(float(value) for value in status.positions)
                current = tuple(float(value) for value in status.currents)
                if self.filtered_current is None:
                    self.filtered_current = current
                else:
                    self.filtered_current = tuple(
                        old + self.current_alpha * (new - old)
                        for old, new in zip(self.filtered_current, current)
                    )
                command = self.receiver.commands.get(self.config.side_id)
                fresh = (
                    command is not None
                    and time.monotonic_ns() - command.received_ns <= self.watchdog_ns
                )
                hold_requested = fresh and bool(command.flags & FLAG_HOLD)
                if hold_requested:
                    self.target = self.actual
                    if (
                        self.allow_commands
                        and self.last_written is not None
                        and not self.hold_sent
                    ):
                        await self._write(self.actual, (0.02,) * 6)
                        self.last_written = self.actual
                        self.hold_sent = True
                elif fresh:
                    requested = tuple(value * 1000.0 for value in command.q)
                    desired = masked_targets(
                        self.actual, requested, self.command_channels
                    )
                    self.target = tuple(float(value) for value in desired)
                    if self.allow_commands:
                        base = (
                            self.last_written
                            if self.last_written is not None
                            else self.actual
                        )
                        limited = slew_targets(base, desired, self.max_step)
                        await self._write(limited, command.dq)
                        self.last_written = tuple(float(value) for value in limited)
                        self.hold_sent = False
                elif (
                    self.allow_commands
                    and self.last_written is not None
                    and not self.hold_sent
                ):
                    await self._write(self.actual, (0.02,) * 6)
                    self.last_written = self.actual
                    self.target = self.actual
                    self.hold_sent = True
                else:
                    self.target = self.actual
                self._publish(status.states)
            except Exception as exc:
                print("%s loop error: %s" % (self.config.side, exc), file=sys.stderr)
            next_tick += self.interval
            await asyncio.sleep(max(0.0, next_tick - time.monotonic()))

    async def _write(self, positions: Sequence[float], speed: Sequence[float]) -> None:
        position_values = [
            int(round(max(0.0, min(1000.0, value)))) for value in positions
        ]
        speed_values = [
            max(
                1,
                min(
                    self.max_speed,
                    int(round(max(0.0, min(1.0, value)) * 1000.0)),
                ),
            )
            for value in speed
        ]
        await self.context.set_finger_positions_and_speeds(
            self.config.slave_id,
            position_values,
            speed_values,
        )

    def _publish(self, states: Sequence[Any]) -> None:
        current = self.filtered_current or (0.0,) * 6
        prefix = "revo2_%s" % self.config.side
        payload = json.dumps(
            {
                "values": {
                    prefix + "_target": list(self.target),
                    prefix + "_position": list(self.actual),
                    prefix + "_current": list(current),
                    prefix + "_stall": [_stall(value) for value in states],
                },
                "timestamp_ns": time.time_ns(),
            },
            separators=(",", ":"),
        ).encode("utf-8")
        self.telemetry_socket.sendto(payload, self.telemetry_address)


async def run_hand_runtime(
    args: argparse.Namespace,
    *,
    stopping: Optional[asyncio.Event] = None,
    ready: Optional[asyncio.Event] = None,
) -> None:
    if args.allow_commands and not args.allowed_source:
        raise SystemExit("--allowed-source is required with --allow-commands")
    sdk = _sdk()
    telemetry_socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    loop = asyncio.get_running_loop()
    receiver = CommandReceiver(args.allowed_source, int(args.watchdog_ms * 1_000_000))
    transport, _protocol = await loop.create_datagram_endpoint(
        lambda: receiver,
        local_addr=(args.bind, args.command_port),
    )
    owns_stopping = stopping is None
    stopping = stopping or asyncio.Event()
    if owns_stopping:
        for signal_name in (signal.SIGINT, signal.SIGTERM):
            with suppress(NotImplementedError):
                loop.add_signal_handler(signal_name, stopping.set)

    configs = (
        HandConfig("left", 0, args.left_port, args.left_id, args.left_serial),
        HandConfig("right", 1, args.right_port, args.right_id, args.right_serial),
    )
    workers = [
        HandWorker(
            sdk=sdk,
            config=config,
            receiver=receiver,
            telemetry_socket=telemetry_socket,
            telemetry_address=(args.telemetry_host, args.telemetry_port),
            allow_commands=(
                args.allow_commands and args.command_side in ("both", config.side)
            ),
            watchdog_ns=int(args.watchdog_ms * 1_000_000),
            max_step=args.max_step,
            max_speed=args.max_speed,
            max_current_ma=args.max_current_ma,
            protected_current_ma=args.protected_current_ma,
            command_channels=args.command_channels,
            current_alpha=args.current_alpha,
            rate_hz=args.rate,
        )
        for config in configs
    ]
    connect_tasks = [asyncio.create_task(worker.connect()) for worker in workers]
    tasks: list[asyncio.Task[None]] = []
    try:
        await asyncio.gather(*connect_tasks)
        tasks = [
            asyncio.create_task(worker.run(stopping, connected=True))
            for worker in workers
        ]
        if ready is not None:
            ready.set()
        print(
            "BCH2 runtime listening udp=%s:%d telemetry=%s:%d mode=%s"
            % (
                args.bind,
                args.command_port,
                args.telemetry_host,
                args.telemetry_port,
                "CONTROL" if args.allow_commands else "READ_ONLY",
            ),
            flush=True,
        )
        await asyncio.gather(*tasks)
    finally:
        stopping.set()
        for task in connect_tasks + tasks:
            task.cancel()
        await asyncio.gather(*connect_tasks, *tasks, return_exceptions=True)
        for worker in workers:
            await worker.close()
        transport.close()
        telemetry_socket.close()


@dataclass(frozen=True)
class ServicePaths:
    xr_bridge: Path
    bridge_config: Path
    left_port: Path
    right_port: Path


def _resolve_executable(value: str) -> Path:
    candidate = Path(value).expanduser()
    if candidate.parent != Path(".") or candidate.is_absolute():
        resolved = candidate.resolve()
    else:
        found = shutil.which(value)
        if found is None:
            raise ValueError(f"executable not found: {value}")
        resolved = Path(found).resolve()
    if not resolved.is_file() or not os.access(resolved, os.X_OK):
        raise ValueError(f"not an executable file: {resolved}")
    return resolved


async def _discover_hand_ports(args: argparse.Namespace, sdk: object) -> tuple[Path, Path]:
    requested = {
        "left": Path(args.left_port).expanduser() if args.left_port else None,
        "right": Path(args.right_port).expanduser() if args.right_port else None,
    }
    if all(requested.values()):
        return requested["left"], requested["right"]

    expected = {
        (args.left_id, args.left_serial): "left",
        (args.right_id, args.right_serial): "right",
    }
    discovered: dict[str, list[Path]] = {"left": [], "right": []}
    candidates = [Path(value) for value in sorted(glob.glob("/dev/serial/by-id/*-port0"))]
    if not candidates:
        raise ValueError("no serial devices found under /dev/serial/by-id")
    for candidate in candidates:
        devices = await sdk.auto_detect(
            scan_all=True,
            port=str(candidate),
            protocol="Modbus",
        )
        for device in devices:
            side = expected.get((int(device.slave_id), str(device.serial_number)))
            if side is not None and requested[side] is None:
                discovered[side].append(candidate)

    for side in ("left", "right"):
        if requested[side] is not None:
            continue
        matches = discovered[side]
        if len(matches) != 1:
            found = ", ".join(str(path) for path in matches) if matches else "none"
            raise ValueError(
                f"expected one {side} hand serial port, found {found}; "
                f"pass --{side}-port explicitly"
            )
        requested[side] = matches[0]
    return requested["left"], requested["right"]


async def resolve_paths(args: argparse.Namespace, sdk: object) -> ServicePaths:
    left_port, right_port = await _discover_hand_ports(args, sdk)
    paths = ServicePaths(
        xr_bridge=_resolve_executable(args.xr_bridge),
        bridge_config=Path(args.bridge_config).expanduser().resolve(),
        left_port=Path(os.path.abspath(left_port)),
        right_port=Path(os.path.abspath(right_port)),
    )
    for label, path in (
        ("bridge config", paths.bridge_config),
        ("left hand serial port", paths.left_port),
        ("right hand serial port", paths.right_port),
    ):
        if not path.exists():
            raise ValueError(f"{label} does not exist: {path}")
    return paths


def _tcp_port_listening(port: int) -> bool:
    target = f"{port:04X}"
    for table in (Path("/proc/net/tcp"), Path("/proc/net/tcp6")):
        try:
            lines = table.read_text(encoding="utf-8").splitlines()[1:]
        except OSError:
            continue
        for line in lines:
            fields = line.split()
            if (
                len(fields) >= 4
                and fields[1].rsplit(":", 1)[-1] == target
                and fields[3] == "0A"
            ):
                return True
    return False


async def _wait_for_bridge(process: asyncio.subprocess.Process) -> None:
    deadline = asyncio.get_running_loop().time() + 5.0
    while asyncio.get_running_loop().time() < deadline:
        if process.returncode is not None:
            raise RuntimeError(f"xr-bridge exited with status {process.returncode}")
        if _tcp_port_listening(XR_POSE_PORT) and _tcp_port_listening(XR_TELEMETRY_PORT):
            return
        await asyncio.sleep(0.05)
    raise RuntimeError("xr-bridge did not open ports 63901 and 63903 within 5 seconds")


def runtime_args(args: argparse.Namespace, paths: ServicePaths) -> SimpleNamespace:
    return SimpleNamespace(
        bind="127.0.0.1",
        command_port=args.command_port,
        allowed_source="127.0.0.1",
        telemetry_host="127.0.0.1",
        telemetry_port=args.telemetry_port,
        left_port=str(paths.left_port),
        left_id=args.left_id,
        left_serial=args.left_serial,
        right_port=str(paths.right_port),
        right_id=args.right_id,
        right_serial=args.right_serial,
        rate=args.rate,
        watchdog_ms=args.watchdog_ms,
        max_step=args.max_step,
        max_speed=args.max_speed,
        max_current_ma=args.max_current_ma,
        protected_current_ma=args.protected_current_ma,
        command_side=args.command_side,
        command_channels=parse_channel_mask(args.command_channels),
        current_alpha=args.current_alpha,
        allow_commands=args.allow_commands,
    )


def bridge_command(args: argparse.Namespace, paths: ServicePaths) -> list[str]:
    return [
        str(paths.xr_bridge),
        "--config",
        str(paths.bridge_config),
        "--adapter-endpoint",
        f"tcp:127.0.0.1:{args.adapter_port}",
    ]


def acquire_pid_lock(path: Path) -> IO[str]:
    path.parent.mkdir(parents=True, exist_ok=True)
    handle = path.open("a+", encoding="utf-8")
    try:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError as exc:
        handle.seek(0)
        owner = handle.read().strip() or "unknown"
        handle.close()
        raise RuntimeError(f"service is already running with pid {owner}") from exc
    handle.seek(0)
    handle.truncate()
    handle.write(f"{os.getpid()}\n")
    handle.flush()
    return handle


async def _stop_process(process: asyncio.subprocess.Process) -> None:
    if process.returncode is not None:
        return
    process.terminate()
    try:
        await asyncio.wait_for(process.wait(), timeout=3.0)
    except asyncio.TimeoutError:
        process.kill()
        await process.wait()


async def run_service(args: argparse.Namespace, paths: ServicePaths) -> int:
    stopping = asyncio.Event()
    loop = asyncio.get_running_loop()
    for signal_name in (signal.SIGINT, signal.SIGTERM):
        with suppress(NotImplementedError):
            loop.add_signal_handler(signal_name, stopping.set)

    adapter = Revo2UdpHostedAdapter(
        command_host="127.0.0.1",
        command_port=args.command_port,
        telemetry_host="127.0.0.1",
        telemetry_port=args.telemetry_port,
        command_speed=args.command_speed,
        max_command_speed=args.max_command_speed,
        command_catchup_seconds=args.command_catchup_ms / 1000.0,
        command_speed_gain=args.command_speed_gain,
        telemetry_timeout_seconds=args.telemetry_timeout_ms / 1000.0,
    )
    failure: BaseException | None = None
    exit_code = 0
    server: asyncio.AbstractServer | None = None
    runtime_task: asyncio.Task[None] | None = None
    runtime_ready_task: asyncio.Task[bool] | None = None
    process: asyncio.subprocess.Process | None = None
    bridge_task: asyncio.Task[int] | None = None
    stop_task: asyncio.Task[bool] | None = None
    runtime_ready = asyncio.Event()
    try:
        server = await create_server(
            adapter,
            make_revo2_descriptor(),
            host="127.0.0.1",
            port=args.adapter_port,
            telemetry_hz=args.telemetry_rate,
        )
        runtime_task = asyncio.create_task(
            run_hand_runtime(
                runtime_args(args, paths),
                stopping=stopping,
                ready=runtime_ready,
            ),
            name="revo2-runtime",
        )
        runtime_ready_task = asyncio.create_task(
            runtime_ready.wait(), name="revo2-runtime-ready"
        )
        done, _pending = await asyncio.wait(
            (runtime_task, runtime_ready_task),
            return_when=asyncio.FIRST_COMPLETED,
        )
        if runtime_task in done:
            await runtime_task
            raise RuntimeError("Revo2 runtime stopped before becoming ready")
        runtime_ready_task.cancel()
        await asyncio.gather(runtime_ready_task, return_exceptions=True)

        process = await asyncio.create_subprocess_exec(*bridge_command(args, paths))
        await _wait_for_bridge(process)
        bridge_task = asyncio.create_task(process.wait(), name="xr-bridge")
        stop_task = asyncio.create_task(stopping.wait(), name="service-stop")

        mode = "CONTROL" if args.allow_commands else "READ_ONLY"
        print(
            "Revo2 Thor service ready mode=%s headset=%s:%d telemetry=%d"
            % (mode, args.advertise_host, XR_POSE_PORT, XR_TELEMETRY_PORT),
            flush=True,
        )
        print(
            "Headset: Teleop -> Outside -> connect to %s:%d"
            % (args.advertise_host, XR_POSE_PORT),
            flush=True,
        )

        done, _pending = await asyncio.wait(
            (runtime_task, bridge_task, stop_task),
            return_when=asyncio.FIRST_COMPLETED,
        )
        if runtime_task in done:
            failure = runtime_task.exception()
            if failure is None and not stopping.is_set():
                failure = RuntimeError("Revo2 runtime stopped unexpectedly")
        elif bridge_task in done:
            bridge_status = bridge_task.result()
            if not stopping.is_set():
                failure = RuntimeError(f"xr-bridge exited with status {bridge_status}")
        stopping.set()
    except BaseException as exc:
        failure = exc
        stopping.set()
    finally:
        if process is not None:
            await _stop_process(process)
        if server is not None:
            server.close()
            await server.wait_closed()
        if runtime_task is not None:
            if not runtime_task.done():
                try:
                    await asyncio.wait_for(runtime_task, timeout=3.0)
                except asyncio.TimeoutError:
                    runtime_task.cancel()
            runtime_result = await asyncio.gather(runtime_task, return_exceptions=True)
            if failure is None and runtime_result and isinstance(runtime_result[0], BaseException):
                failure = runtime_result[0]
        if runtime_ready_task is not None:
            runtime_ready_task.cancel()
            await asyncio.gather(runtime_ready_task, return_exceptions=True)
        if stop_task is not None:
            stop_task.cancel()
            await asyncio.gather(stop_task, return_exceptions=True)

    if failure is not None:
        print(f"Revo2 Thor service failed: {failure}", file=sys.stderr, flush=True)
        exit_code = 1
    else:
        print("Revo2 Thor service stopped safely", flush=True)
    return exit_code


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--xr-bridge", default=str(SCRIPT_DIR / "bin" / "xr-bridge"))
    parser.add_argument(
        "--bridge-config", default=str(SCRIPT_DIR / "config" / "revo2_tuning.yaml")
    )
    parser.add_argument("--advertise-host", default="192.168.124.64")
    parser.add_argument("--adapter-port", type=int, default=63910)
    parser.add_argument("--command-port", type=int, default=19091)
    parser.add_argument("--telemetry-port", type=int, default=19092)
    parser.add_argument("--left-port")
    parser.add_argument("--left-id", type=lambda value: int(value, 0), default=126)
    parser.add_argument("--left-serial", default=DEFAULT_LEFT_SERIAL)
    parser.add_argument("--right-port")
    parser.add_argument("--right-id", type=lambda value: int(value, 0), default=127)
    parser.add_argument("--right-serial", default=DEFAULT_RIGHT_SERIAL)
    parser.add_argument("--rate", type=float, default=50.0)
    parser.add_argument("--watchdog-ms", type=float, default=1000.0)
    parser.add_argument("--max-step", type=float, default=160.0)
    parser.add_argument("--max-speed", type=int, default=1000)
    parser.add_argument("--max-current-ma", type=int, default=500)
    parser.add_argument("--protected-current-ma", type=int, default=400)
    parser.add_argument(
        "--command-side", choices=("left", "right", "both"), default="both"
    )
    parser.add_argument(
        "--command-channels",
        default=",".join(CHANNEL_NAMES),
        help="comma-separated subset of: %s"
        % ",".join(CHANNEL_NAMES),
    )
    parser.add_argument("--current-alpha", type=float, default=0.35)
    parser.add_argument("--telemetry-rate", type=float, default=50.0)
    parser.add_argument("--command-speed", type=float, default=0.12)
    parser.add_argument("--max-command-speed", type=float, default=1.0)
    parser.add_argument("--command-catchup-ms", type=float, default=70.0)
    parser.add_argument("--command-speed-gain", type=float, default=1.0)
    parser.add_argument("--telemetry-timeout-ms", type=float, default=500.0)
    parser.add_argument(
        "--allow-commands",
        action="store_true",
        help="allow physical hand motion; without this flag the service is read-only",
    )
    parser.add_argument("--check", action="store_true", help="validate paths and exit")
    parser.add_argument("--pid-file", default=str(SCRIPT_DIR / DEFAULT_PID_FILE))
    return parser


def validate_args(parser: argparse.ArgumentParser, args: argparse.Namespace) -> None:
    positive = (
        "rate",
        "watchdog_ms",
        "max_step",
        "telemetry_rate",
        "command_catchup_ms",
        "command_speed_gain",
        "telemetry_timeout_ms",
    )
    for name in positive:
        if getattr(args, name) <= 0:
            parser.error(f"--{name.replace('_', '-')} must be positive")
    if not 1 <= args.max_speed <= 1000:
        parser.error("--max-speed must be in 1..1000")
    if not 1 <= args.protected_current_ma <= args.max_current_ma:
        parser.error("--protected-current-ma must be in 1..--max-current-ma")
    if not 0.0 < args.current_alpha <= 1.0:
        parser.error("--current-alpha must be in (0, 1]")
    if not 0.0 < args.command_speed <= args.max_command_speed <= 1.0:
        parser.error("command speeds must satisfy 0 < minimum <= maximum <= 1")
    for name in (
        "adapter_port",
        "command_port",
        "telemetry_port",
    ):
        if not 1 <= getattr(args, name) <= 65535:
            parser.error(f"--{name.replace('_', '-')} must be in 1..65535")


async def _main_async(args: argparse.Namespace, parser: argparse.ArgumentParser) -> int:
    try:
        sdk = _sdk()
        paths = await resolve_paths(args, sdk)
        runtime_args(args, paths)
    except (argparse.ArgumentTypeError, RuntimeError, ValueError) as exc:
        parser.error(str(exc))
    print(f"xr-bridge: {paths.xr_bridge}")
    print(f"left hand: {paths.left_port} id={args.left_id} serial={args.left_serial}")
    print(f"right hand: {paths.right_port} id={args.right_id} serial={args.right_serial}")
    print(
        "safety: watchdog=%.0fms max_step=%.0f max_speed=%d current=%d/%dmA"
        % (
            args.watchdog_ms,
            args.max_step,
            args.max_speed,
            args.max_current_ma,
            args.protected_current_ma,
        )
    )
    if args.check:
        print("configuration check passed")
        return 0

    pid_path = Path(args.pid_file).expanduser().resolve()
    try:
        lock = acquire_pid_lock(pid_path)
    except RuntimeError as exc:
        parser.error(str(exc))
    try:
        return await run_service(args, paths)
    finally:
        lock.close()
        with suppress(FileNotFoundError):
            pid_path.unlink()


def main(argv: Sequence[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    validate_args(parser, args)
    return asyncio.run(_main_async(args, parser))


if __name__ == "__main__":
    raise SystemExit(main())
