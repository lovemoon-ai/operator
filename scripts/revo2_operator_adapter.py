#!/usr/bin/env python3
"""Serve a hand-only Operator adapter backed by a remote Revo2 UDP runtime."""

from __future__ import annotations

import argparse

from pyoperator.hosted import serve
from pyoperator.integrations.revo2_udp import (
    Revo2UdpHostedAdapter,
    make_revo2_descriptor,
)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--runtime-host", required=True, help="robot computer running the hand runtime"
    )
    parser.add_argument("--command-port", type=int, default=19091)
    parser.add_argument("--telemetry-bind", default="0.0.0.0")
    parser.add_argument("--telemetry-port", type=int, default=19092)
    parser.add_argument("--adapter-bind", default="127.0.0.1")
    parser.add_argument("--adapter-port", type=int, default=63910)
    parser.add_argument("--telemetry-rate", type=float, default=50.0)
    parser.add_argument(
        "--command-speed",
        type=float,
        default=0.12,
        help="minimum normalized Revo2 speed used by adaptive tracking",
    )
    parser.add_argument("--max-command-speed", type=float, default=1.0)
    parser.add_argument("--command-catchup-ms", type=float, default=70.0)
    parser.add_argument("--command-speed-gain", type=float, default=1.0)
    parser.add_argument("--telemetry-timeout-ms", type=float, default=500.0)
    args = parser.parse_args()

    adapter = Revo2UdpHostedAdapter(
        command_host=args.runtime_host,
        command_port=args.command_port,
        telemetry_host=args.telemetry_bind,
        telemetry_port=args.telemetry_port,
        command_speed=args.command_speed,
        max_command_speed=args.max_command_speed,
        command_catchup_seconds=args.command_catchup_ms / 1000.0,
        command_speed_gain=args.command_speed_gain,
        telemetry_timeout_seconds=args.telemetry_timeout_ms / 1000.0,
    )
    serve(
        adapter,
        make_revo2_descriptor(),
        host=args.adapter_bind,
        port=args.adapter_port,
        telemetry_hz=args.telemetry_rate,
    )


if __name__ == "__main__":
    main()
