#!/usr/bin/env python3
"""Read two BrainCo Revo2 hands without sending motion commands."""

from __future__ import annotations

import argparse
import asyncio
import json
import sys
import time
from collections import defaultdict
from typing import Any


def _sdk():
    try:
        from bc_stark_sdk import main_mod as sdk
    except ImportError as exc:
        raise SystemExit(
            "bc-stark-sdk is required; install the official aarch64 wheel first"
        ) from exc
    return sdk


def _stall(state: Any) -> float:
    name = getattr(state, "name", str(state)).upper()
    return 1.0 if name.endswith("STALL") or state == 2 else 0.0


async def _detect(sdk: Any, ports: list[str], protocol: str | None) -> list[Any]:
    devices: list[Any] = []
    if ports:
        for port in ports:
            devices.extend(
                await sdk.auto_detect(scan_all=True, port=port, protocol=protocol)
            )
    else:
        devices = list(await sdk.auto_detect(scan_all=True, protocol=protocol))
    return [device for device in devices if int(device.slave_id) in (126, 127)]


async def run(args: argparse.Namespace) -> None:
    sdk = _sdk()
    devices = await _detect(sdk, args.port, args.protocol)
    if not devices:
        raise SystemExit("no Revo2 hand with slave ID 126/127 detected")
    for device in devices:
        print(
            "detected"
            f" port={device.port_name}"
            f" id={int(device.slave_id)}"
            f" protocol={device.protocol_type}"
            f" serial={device.serial_number}"
            f" firmware={device.firmware_version}"
            f" sku={device.sku_type}",
            file=sys.stderr,
        )

    by_port: dict[str, list[Any]] = defaultdict(list)
    for device in devices:
        by_port[str(device.port_name)].append(device)

    contexts: list[tuple[Any, list[Any]]] = []
    try:
        for port_devices in by_port.values():
            contexts.append((await sdk.init_from_detected(port_devices[0]), port_devices))

        deadline = time.monotonic() + args.duration if args.duration > 0 else None
        while deadline is None or time.monotonic() < deadline:
            values: dict[str, list[float]] = {}
            for context, port_devices in contexts:
                for device in port_devices:
                    side = "left" if int(device.slave_id) == 126 else "right"
                    status = await context.get_motor_status(int(device.slave_id))
                    values[f"revo2_{side}_position"] = [float(v) for v in status.positions]
                    values[f"revo2_{side}_current"] = [float(v) for v in status.currents]
                    values[f"revo2_{side}_stall"] = [_stall(v) for v in status.states]
            print(json.dumps({"values": values, "timestamp_ns": time.time_ns()}), flush=True)
            await asyncio.sleep(1.0 / args.rate)
    finally:
        for context, _devices in contexts:
            await sdk.close_device_handler(context)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", action="append", default=[], help="serial port to scan")
    parser.add_argument(
        "--protocol",
        choices=("Modbus", "Can", "CanFd"),
        help="force one protocol; default probes all supported protocols",
    )
    parser.add_argument("--rate", type=float, default=10.0, help="read rate in Hz")
    parser.add_argument("--duration", type=float, default=5.0, help="seconds; 0 runs forever")
    args = parser.parse_args()
    if args.rate <= 0:
        parser.error("--rate must be positive")
    asyncio.run(run(args))


if __name__ == "__main__":
    main()
