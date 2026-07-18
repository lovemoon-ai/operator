"""Teleop-loop latency instrumentation for the `vr_operator` plugin.

Phase-1 measurement harness (see the teleop latency optimization plan). This is
**pure logging**: it never changes control behavior, only observes it, so it is
safe to run on a live arm to capture a baseline.

It quantifies the segments the Rust-side `LatencyRecorder` cannot see -- the ones
downstream of the UDS handoff, which is where the real teleop lag lives:

* ``age_uds``   -- `Target` published by the adapter (host wall clock) until this
                   plugin actually *consumes* it in `get_action()`. Includes the
                   wait for the next teleop-loop tick, so it exposes the 72Hz
                   producer -> low-Hz consumer downsampling directly.
* ``ik``        -- placo solve + FK convergence loop time inside `_solve`.
* ``get_action``-- whole-call time (IK + our overhead). Compare against lerobot's
                   own printed ``Teleop loop time`` to infer the serial cost
                   (``loop - get_action`` = get_observation read + send_action
                   read/write on the Feetech bus).
* ``fresh_hz``  -- how many *distinct* target seqs actually reach the arm per
                   second. The headset sends ~72Hz; anything less is downsampling
                   at the 30Hz loop, and a big gap between calls/s and fresh/s is
                   the "not keeping up with my hand" signal.

Clock note: ``age_uds`` subtracts ``Target.ts_ns`` (stamped by the Rust adapter
with ``SystemTime::UNIX_EPOCH``) from Python's ``time.time_ns()``. Both are the
same wall clock on the same host, so no clock-sync is needed for this segment.
"""

from __future__ import annotations

import logging
import time
from dataclasses import dataclass, field

logger = logging.getLogger(__name__)


def _percentiles(samples: list[float], ps: tuple[float, ...]) -> list[float]:
    """Nearest-rank percentiles of ``samples`` (ms). Empty -> zeros.

    Deliberately dependency-free (no numpy import at module load) so this stays
    cheap and importable in isolation for tests.
    """
    if not samples:
        return [0.0] * len(ps)
    ordered = sorted(samples)
    n = len(ordered)
    out: list[float] = []
    for p in ps:
        idx = int(round((n - 1) * p))
        out.append(ordered[idx])
    return out


@dataclass
class LatencyMetrics:
    """Rolling 1Hz aggregator for the teleop consume path.

    Accumulate per call, then `maybe_flush()` once per `log_period_s` emits a
    single structured line and resets the window. All times are milliseconds.
    """

    log_period_s: float = 1.0
    _window_start: float = field(default_factory=time.monotonic)
    _age_uds_ms: list[float] = field(default_factory=list)
    _ik_ms: list[float] = field(default_factory=list)
    _get_action_ms: list[float] = field(default_factory=list)
    _ik_iters: list[int] = field(default_factory=list)
    _calls: int = 0
    _fresh: int = 0
    _holds: int = 0

    def record_call(self, get_action_ms: float) -> None:
        """One `get_action()` returned, whatever path it took."""
        self._calls += 1
        self._get_action_ms.append(get_action_ms)

    def record_hold(self) -> None:
        """This call held the last setpoint (disabled/stale/e-stop/no target)."""
        self._holds += 1

    def record_solve(self, *, age_uds_ms: float | None, ik_ms: float, ik_iters: int, fresh: bool) -> None:
        """This call consumed a target and ran IK.

        ``age_uds_ms`` is None when the adapter did not stamp ``ts_ns`` (older
        adapter) so the segment is simply not sampled rather than logged as zero.
        """
        if age_uds_ms is not None and age_uds_ms >= 0.0:
            self._age_uds_ms.append(age_uds_ms)
        self._ik_ms.append(ik_ms)
        self._ik_iters.append(ik_iters)
        if fresh:
            self._fresh += 1

    def maybe_flush(self, now: float | None = None) -> None:
        now = time.monotonic() if now is None else now
        elapsed = now - self._window_start
        if elapsed < self.log_period_s:
            return
        if self._calls == 0:
            self._reset(now)
            return

        a50, a95, a99, amax = _percentiles(self._age_uds_ms, (0.50, 0.95, 0.99, 1.0))
        i50, i95, imax = _percentiles(self._ik_ms, (0.50, 0.95, 1.0))
        g50, g95, gmax = _percentiles(self._get_action_ms, (0.50, 0.95, 1.0))
        call_hz = self._calls / elapsed
        fresh_hz = self._fresh / elapsed
        iters_max = max(self._ik_iters) if self._ik_iters else 0

        logger.info(
            "teleop-latency: calls/s=%.1f fresh/s=%.1f holds=%d "
            "age_uds(p50/p95/p99/max)=%.1f/%.1f/%.1f/%.1f ms "
            "ik(p50/p95/max)=%.2f/%.2f/%.2f ms ik_iters_max=%d "
            "get_action(p50/p95/max)=%.2f/%.2f/%.2f ms",
            call_hz,
            fresh_hz,
            self._holds,
            a50,
            a95,
            a99,
            amax,
            i50,
            i95,
            imax,
            iters_max,
            g50,
            g95,
            gmax,
        )
        self._reset(now)

    def _reset(self, now: float) -> None:
        self._window_start = now
        self._age_uds_ms.clear()
        self._ik_ms.clear()
        self._get_action_ms.clear()
        self._ik_iters.clear()
        self._calls = 0
        self._fresh = 0
        self._holds = 0
