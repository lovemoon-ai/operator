"""Executable UDS receiver for telemetry and injected external sessions."""

from __future__ import annotations

import argparse
import dataclasses
import importlib
import importlib.util
import json
import sys
import time
from collections.abc import Callable, Sequence
from pathlib import Path
from typing import Any

from .receiver import LatestSampleStore, UnixDatagramReceiver
from .session import ExternalTeleopSession


def _load_factory(spec: str) -> Callable[[], Any]:
    location, separator, attribute = spec.rpartition(":")
    if not separator or not location or not attribute:
        raise ValueError("session factory must be MODULE:CALLABLE or /path/file.py:CALLABLE")
    if location.endswith(".py") or "/" in location:
        path = Path(location).expanduser().resolve()
        module_spec = importlib.util.spec_from_file_location(
            "operator_isaacteleop_user_factory", path
        )
        if module_spec is None or module_spec.loader is None:
            raise ImportError(f"cannot load session factory file {path}")
        module = importlib.util.module_from_spec(module_spec)
        module_spec.loader.exec_module(module)
    else:
        module = importlib.import_module(location)
    factory = getattr(module, attribute)
    if not callable(factory):
        raise TypeError(f"{spec} does not resolve to a callable")
    return factory


def _json_default(value: Any) -> Any:
    if dataclasses.is_dataclass(value):
        return dataclasses.asdict(value)
    if isinstance(value, bytes):
        return value.decode("ascii", errors="replace")
    if hasattr(value, "value"):
        return value.value
    return repr(value)


def _sample_telemetry(sample, *, now_ns: int | None = None) -> dict[str, Any]:
    now = time.monotonic_ns() if now_ns is None else now_ns
    return {
        "event": "sample",
        "kind": sample.kind.value.decode("ascii"),
        "sequence": sample.sequence,
        "token": sample.token,
        "descriptor_version": sample.descriptor_version,
        "sample_time_raw_device_ns": sample.raw_sample_time_ns,
        "sample_time_local_common_ns": sample.common_sample_time_ns,
        "available_time_local_common_ns": sample.available_time_ns,
        "age_ns": sample.age_ns(now),
        "value": sample.value,
    }


def _result_telemetry(result: Any) -> dict[str, Any]:
    if isinstance(result, dict):
        outputs = sorted(str(key) for key in result)
    else:
        outputs = [type(result).__name__]
    return {"event": "session_step", "outputs": outputs}


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--socket", default="/tmp/operator-isaacteleop.sock", help="UDS datagram path"
    )
    parser.add_argument("--token", type=lambda value: int(value, 0), help="required session token")
    parser.add_argument("--max-age-ms", type=float, default=100.0, help="latest sample expiry")
    parser.add_argument(
        "--step-hz",
        type=float,
        default=60.0,
        help="session-factory tick rate; independent of packet arrival",
    )
    parser.add_argument(
        "--once",
        action="store_true",
        help="exit after one valid datagram (telemetry) or one tick (session)",
    )
    parser.add_argument(
        "--session-factory",
        help=(
            "MODULE:CALLABLE or /path/file.py:CALLABLE returning an "
            "ExternalTeleopSession; omitted for telemetry-only mode"
        ),
    )
    return parser


def _print_sample(sample) -> None:
    print(
        json.dumps(_sample_telemetry(sample), default=_json_default, sort_keys=True),
        flush=True,
    )


def _run_telemetry_loop(receiver: UnixDatagramReceiver, *, once: bool) -> int:
    while True:
        sample = receiver.receive_once()
        if sample is None:
            continue
        _print_sample(sample)
        if once:
            return 0


def _run_session_loop(
    receiver: UnixDatagramReceiver,
    external: ExternalTeleopSession,
    *,
    step_hz: float,
    once: bool,
) -> int:
    """Tick even with no packets so expired CTRL reaches the safety pipeline."""

    period_ns = max(1, round(1_000_000_000 / step_hz))
    next_tick_ns = time.monotonic_ns()
    while True:
        now_ns = time.monotonic_ns()
        wait_s = max(0.0, (next_tick_ns - now_ns) / 1_000_000_000)
        sample = receiver.receive_once(timeout=min(wait_s, 0.1))
        if sample is not None:
            _print_sample(sample)

        now_ns = time.monotonic_ns()
        if now_ns < next_tick_ns:
            continue
        result = external.step(receiver.snapshot(now_ns=now_ns))
        print(json.dumps(_result_telemetry(result), sort_keys=True), flush=True)
        if once:
            return 0
        elapsed_periods = max(1, (now_ns - next_tick_ns) // period_ns + 1)
        next_tick_ns += elapsed_periods * period_ns


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if args.max_age_ms <= 0:
        raise SystemExit("--max-age-ms must be positive")
    if args.step_hz <= 0:
        raise SystemExit("--step-hz must be positive")
    store = LatestSampleStore(
        expected_token=args.token,
        max_age_ns=round(args.max_age_ms * 1_000_000),
    )
    receiver = UnixDatagramReceiver(args.socket, store=store).start(background=False)
    external: ExternalTeleopSession | None = None
    if args.session_factory:
        created = _load_factory(args.session_factory)()
        if not isinstance(created, ExternalTeleopSession):
            raise TypeError("session factory must return ExternalTeleopSession")
        external = created
        external.__enter__()

    print(json.dumps({"event": "listening", "socket": str(receiver.path)}), flush=True)
    try:
        if external is None:
            return _run_telemetry_loop(receiver, once=args.once)
        return _run_session_loop(
            receiver,
            external,
            step_hz=args.step_hz,
            once=args.once,
        )
    except KeyboardInterrupt:
        return 130
    finally:
        if external is not None:
            external.__exit__(*sys.exc_info())
        receiver.close()


if __name__ == "__main__":
    raise SystemExit(main())
