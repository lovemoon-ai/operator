"""Clock-domain mapping for headset monotonic time to host monotonic time."""

from __future__ import annotations

import threading
from dataclasses import dataclass


@dataclass(frozen=True, slots=True)
class ClockExchange:
    offset_ns: int
    round_trip_ns: int


class MonotonicOffsetEstimator:
    """NTP-style raw-device to host-common monotonic clock estimator.

    ``observe_exchange`` accepts four timestamps: device send ``t0``, host
    receive ``t1``, host send ``t2`` and device receive ``t3``.  A fixed offset
    can instead be injected for deterministic replay and tests.
    """

    def __init__(self, *, offset_ns: int | None = None, smoothing: float = 0.125) -> None:
        if not 0.0 < smoothing <= 1.0:
            raise ValueError("smoothing must be in (0, 1]")
        self._offset_ns = offset_ns
        self._smoothing = smoothing
        self._best_rtt_ns: int | None = None
        self._lock = threading.Lock()

    @property
    def offset_ns(self) -> int | None:
        with self._lock:
            return self._offset_ns

    def set_offset(self, offset_ns: int) -> None:
        with self._lock:
            self._offset_ns = int(offset_ns)

    def bootstrap_from_arrival(self, raw_time_ns: int, host_arrival_ns: int) -> int:
        """Initialize only when no control-channel four-timestamp sample exists."""

        with self._lock:
            if self._offset_ns is None:
                self._offset_ns = host_arrival_ns - raw_time_ns
            return self._offset_ns

    def observe_exchange(
        self, t0_device: int, t1_host: int, t2_host: int, t3_device: int
    ) -> ClockExchange:
        rtt = (t3_device - t0_device) - (t2_host - t1_host)
        if rtt < 0:
            raise ValueError("invalid clock exchange: negative round trip")
        sample_offset = ((t1_host - t0_device) + (t2_host - t3_device)) // 2
        with self._lock:
            # Prefer the least-delayed samples.  Higher-delay samples still
            # update slowly once the baseline has been established.
            if self._offset_ns is None:
                self._offset_ns = sample_offset
            else:
                weight = self._smoothing
                if self._best_rtt_ns is not None and rtt > 2 * max(1, self._best_rtt_ns):
                    weight *= 0.25
                self._offset_ns = round((1.0 - weight) * self._offset_ns + weight * sample_offset)
            self._best_rtt_ns = rtt if self._best_rtt_ns is None else min(self._best_rtt_ns, rtt)
            offset = self._offset_ns
        return ClockExchange(offset, rtt)

    def to_common(self, raw_time_ns: int) -> int:
        with self._lock:
            if self._offset_ns is None:
                raise RuntimeError("clock offset has not been initialized")
            return raw_time_ns + self._offset_ns
