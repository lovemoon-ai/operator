"""Command-line interface for the pyoperator Live Feed server."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Iterable

from . import qr
from .protocol import (
    QUEST_CAPTURE_PROFILE,
    CapturePlan,
    build_capture_request,
    get_demand,
    validate_demand,
)
from .server import LiveFeedServer, run_self_test


def print_plan(plan: CapturePlan) -> None:
    print(json.dumps(build_capture_request(plan), indent=2, sort_keys=True))


def parse_args(argv: Iterable[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", "--push-port", dest="port", type=int, default=63910)
    parser.add_argument("--result-host", "--pull-host", dest="result_host", default="")
    parser.add_argument("--result-port", "--pull-port", dest="result_port", type=int, default=63912)
    parser.add_argument("--out", type=Path, default=Path("live_feed_out"))
    parser.add_argument("--algorithm", default="depth_fusion_pointcloud")
    parser.add_argument("--max-queue", type=int, default=256)
    parser.add_argument("--auth-token", default="")
    parser.add_argument("--max-events", type=int)
    parser.add_argument("--publish-interval-s", type=float, default=1.0)
    parser.add_argument("--point-stride", type=int, default=4)
    parser.add_argument("--min-depth-m", type=float, default=0.20)
    parser.add_argument("--max-depth-m", type=float, default=5.0)
    parser.add_argument("--max-points-per-update", type=int, default=80_000)
    parser.add_argument("--result-fragment-bytes", type=int, default=1024 * 1024)
    parser.add_argument("--rgb-colorize", dest="rgb_colorize", action="store_true", default=True)
    parser.add_argument("--no-rgb-colorize", dest="rgb_colorize", action="store_false")
    parser.add_argument("--ffmpeg-bin", default="ffmpeg")
    # On by default: the XR client consumes capture_request on the result
    # channel to decide which streams to send.
    parser.add_argument(
        "--send-capture-request-to-xr",
        dest="send_capture_request_to_xr",
        action="store_true",
        default=True,
    )
    parser.add_argument(
        "--no-send-capture-request-to-xr",
        dest="send_capture_request_to_xr",
        action="store_false",
    )
    parser.add_argument("--send-results-to-xr", dest="send_results_to_xr", action="store_true", default=True)
    parser.add_argument("--no-send-results-to-xr", dest="send_results_to_xr", action="store_false")
    parser.add_argument(
        "--no-qr",
        action="store_true",
        help="do not print the connection QR code on startup",
    )
    parser.add_argument("--print-plan", action="store_true")
    parser.add_argument("--self-test", action="store_true")
    return parser.parse_args(None if argv is None else list(argv))


def main(argv: Iterable[str] | None = None) -> int:
    args = parse_args(argv)
    if args.self_test:
        run_self_test()
        return 0

    demand = get_demand(args.algorithm)
    plan = validate_demand(QUEST_CAPTURE_PROFILE, demand)
    if args.print_plan:
        print_plan(plan)
        return 0

    server = LiveFeedServer(
        host=args.host,
        port=args.port,
        result_host=args.result_host or args.host,
        result_port=args.result_port,
        out_dir=args.out,
        plan=plan,
        max_queue=args.max_queue,
        auth_token=args.auth_token,
        send_capture_request_to_xr=args.send_capture_request_to_xr,
        send_results_to_xr=args.send_results_to_xr,
        max_events=args.max_events,
        publish_interval_s=args.publish_interval_s,
        point_stride=args.point_stride,
        min_depth_m=args.min_depth_m,
        max_depth_m=args.max_depth_m,
        max_points_per_update=args.max_points_per_update,
        result_fragment_bytes=args.result_fragment_bytes,
        rgb_colorize=args.rgb_colorize,
        ffmpeg_bin=args.ffmpeg_bin,
        show_qr=not args.no_qr,
    )
    server.serve_forever()
    return 0
