#!/usr/bin/env python3
"""Own two Revo2 serial links, accept BCH2 commands, and stream telemetry.

The process is non-actuating unless ``--allow-commands`` is supplied. It is
intended for isolated hand tuning when no other BrainCo runtime owns the ports.
"""

from __future__ import annotations

import argparse
import asyncio
from dataclasses import dataclass
import json
import math
import signal
import socket
import struct
import sys
import time
from typing import Any, Dict, Optional, Sequence, Tuple


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
                print("%s final hold failed: %s" % (self.config.side, exc), file=sys.stderr)
        await self.sdk.close_device_handler(self.context)
        self.context = None

    async def run(self, stopping: asyncio.Event) -> None:
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
                    if self.allow_commands and self.last_written is not None and not self.hold_sent:
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
                        base = self.last_written if self.last_written is not None else self.actual
                        limited = slew_targets(base, desired, self.max_step)
                        await self._write(limited, command.dq)
                        self.last_written = tuple(float(value) for value in limited)
                        self.hold_sent = False
                elif self.allow_commands and self.last_written is not None and not self.hold_sent:
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
        position_values = [int(round(max(0.0, min(1000.0, value)))) for value in positions]
        speed_values = [
            max(1, min(self.max_speed, int(round(max(0.0, min(1.0, value)) * 1000.0))))
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


async def run(args: argparse.Namespace) -> None:
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
    stopping = asyncio.Event()
    for signal_name in (signal.SIGINT, signal.SIGTERM):
        try:
            loop.add_signal_handler(signal_name, stopping.set)
        except NotImplementedError:
            pass

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
    tasks = [asyncio.create_task(worker.run(stopping)) for worker in workers]
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
    try:
        await asyncio.gather(*tasks)
    finally:
        stopping.set()
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        for worker in workers:
            await worker.close()
        transport.close()
        telemetry_socket.close()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bind", default="0.0.0.0")
    parser.add_argument("--command-port", type=int, default=19091)
    parser.add_argument("--allowed-source", default="")
    parser.add_argument("--telemetry-host", required=True)
    parser.add_argument("--telemetry-port", type=int, default=19092)
    parser.add_argument("--left-port", required=True)
    parser.add_argument("--left-id", type=lambda value: int(value, 0), default=126)
    parser.add_argument("--left-serial", required=True)
    parser.add_argument("--right-port", required=True)
    parser.add_argument("--right-id", type=lambda value: int(value, 0), default=127)
    parser.add_argument("--right-serial", required=True)
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
        type=parse_channel_mask,
        default=(True,) * 6,
        help="comma-separated subset of: %s" % ",".join(CHANNEL_NAMES),
    )
    parser.add_argument("--current-alpha", type=float, default=0.35)
    parser.add_argument("--allow-commands", action="store_true")
    args = parser.parse_args()
    if args.rate <= 0.0:
        parser.error("--rate must be positive")
    if args.watchdog_ms <= 0.0:
        parser.error("--watchdog-ms must be positive")
    if args.max_step <= 0.0:
        parser.error("--max-step must be positive")
    if not 1 <= args.max_speed <= 1000:
        parser.error("--max-speed must be in 1..1000")
    if not 1 <= args.protected_current_ma <= args.max_current_ma:
        parser.error("--protected-current-ma must be in 1..--max-current-ma")
    if not 0.0 < args.current_alpha <= 1.0:
        parser.error("--current-alpha must be in (0, 1]")
    asyncio.run(run(args))


if __name__ == "__main__":
    main()
