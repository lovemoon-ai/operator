"""Unix datagram receiver and per-channel latest-only sample store."""

from __future__ import annotations

import os
import socket
import threading
import time
from collections.abc import Callable
from pathlib import Path

from .clock import MonotonicOffsetEstimator
from .coordinates import godot_to_isaac
from .model import ControlSample, ExternalInputBundle, TimedSample
from .protocol import MAX_PAYLOAD_SIZE, Kind, ProtocolError, decode_datagram, decode_payload


class LatestSampleStore:
    def __init__(
        self,
        *,
        expected_token: int | None = None,
        max_age_ns: int = 100_000_000,
        clock: MonotonicOffsetEstimator | None = None,
        transform_coordinates: bool = False,
        accepted_descriptor_versions: frozenset[int] = frozenset({1}),
    ) -> None:
        self.expected_token = expected_token
        self.max_age_ns = max_age_ns
        self.clock = clock or MonotonicOffsetEstimator()
        self.transform_coordinates = transform_coordinates
        self.accepted_descriptor_versions = accepted_descriptor_versions
        self._samples: dict[Kind, TimedSample] = {}
        # CTRL run/reset are edge events carried alongside level signals. A
        # faster XR heartbeat may replace the pulse before a slower simulation
        # tick snapshots the store, so retain each edge until one snapshot
        # consumes it. Kill/deadman always come from the newest CTRL sample.
        self._latched_run_toggle = False
        self._latched_reset = False
        self._lock = threading.Lock()
        self.dropped_out_of_order = 0
        self.dropped_wrong_token = 0

    def ingest(
        self, datagram: bytes, *, available_time_ns: int | None = None
    ) -> TimedSample | None:
        packet = decode_datagram(datagram)
        if packet.descriptor_version not in self.accepted_descriptor_versions:
            supported = sorted(self.accepted_descriptor_versions)
            raise ProtocolError(
                f"unsupported descriptor_version {packet.descriptor_version}; "
                f"supported versions are {supported}"
            )
        if self.expected_token is not None and packet.token != self.expected_token:
            self.dropped_wrong_token += 1
            return None
        available = time.monotonic_ns() if available_time_ns is None else available_time_ns
        self.clock.bootstrap_from_arrival(packet.timestamp_ns, available)
        common = self.clock.to_common(packet.timestamp_ns)
        value = decode_payload(packet.kind, packet.payload)
        if self.transform_coordinates and not isinstance(value, ControlSample):
            value = godot_to_isaac(value)
        sample = TimedSample(
            packet.kind,
            value,
            packet.timestamp_ns,
            common,
            available,
            packet.sequence,
            packet.token,
            packet.descriptor_version,
        )
        with self._lock:
            previous = self._samples.get(packet.kind)
            if (
                previous is not None
                and packet.token == previous.token
                and packet.sequence <= previous.sequence
            ):
                self.dropped_out_of_order += 1
                return None
            self._samples[packet.kind] = sample
            if packet.kind is Kind.CONTROL:
                assert isinstance(value, ControlSample)
                self._latched_run_toggle = self._latched_run_toggle or value.run_toggle
                self._latched_reset = self._latched_reset or value.reset
        return sample

    def snapshot(self, *, now_ns: int | None = None) -> ExternalInputBundle:
        now = time.monotonic_ns() if now_ns is None else now_ns
        with self._lock:
            samples = {
                kind: sample
                for kind, sample in self._samples.items()
                if sample.age_ns(now) <= self.max_age_ns
            }
            control_sample = samples.get(Kind.CONTROL)
            if control_sample is not None:
                control = control_sample.value
                assert isinstance(control, ControlSample)
                samples[Kind.CONTROL] = TimedSample(
                    kind=control_sample.kind,
                    value=ControlSample(
                        kill=control.kill,
                        run_toggle=self._latched_run_toggle,
                        reset=self._latched_reset,
                        deadman=control.deadman,
                    ),
                    raw_sample_time_ns=control_sample.raw_sample_time_ns,
                    common_sample_time_ns=control_sample.common_sample_time_ns,
                    available_time_ns=control_sample.available_time_ns,
                    sequence=control_sample.sequence,
                    token=control_sample.token,
                    descriptor_version=control_sample.descriptor_version,
                )
            # Do not replay edges. If CTRL has expired, dropping a stale edge
            # is safer than applying it after controls recover.
            self._latched_run_toggle = False
            self._latched_reset = False
        graph_time = max((sample.common_sample_time_ns for sample in samples.values()), default=now)
        return ExternalInputBundle(samples, graph_time)

    def clear(self) -> None:
        with self._lock:
            self._samples.clear()
            self._latched_run_toggle = False
            self._latched_reset = False


class UnixDatagramReceiver:
    """Background UDS datagram receiver.

    The bridge sends one canonical packet per datagram.  Malformed packets are
    counted and discarded without terminating the receive loop.
    """

    def __init__(
        self,
        path: str | os.PathLike[str],
        *,
        store: LatestSampleStore | None = None,
        on_error: Callable[[Exception], None] | None = None,
    ) -> None:
        self.path = Path(path)
        self.store = store or LatestSampleStore()
        self.on_error = on_error
        self.invalid_datagrams = 0
        self._socket: socket.socket | None = None
        self._thread: threading.Thread | None = None
        self._stop = threading.Event()

    def start(self, *, background: bool = True) -> UnixDatagramReceiver:
        if self._socket is not None:
            return self
        self.path.parent.mkdir(parents=True, exist_ok=True)
        try:
            self.path.unlink()
        except FileNotFoundError:
            pass
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        sock.bind(str(self.path))
        sock.settimeout(0.1)
        self._socket = sock
        self._stop.clear()
        if background:
            self._thread = threading.Thread(
                target=self._receive_loop, name="operator-isaacteleop", daemon=True
            )
            self._thread.start()
        return self

    def receive_once(self, *, timeout: float | None = None) -> TimedSample | None:
        if self._socket is None:
            raise RuntimeError("receiver is not started")
        previous_timeout = self._socket.gettimeout()
        if timeout is not None:
            self._socket.settimeout(timeout)
        try:
            datagram = self._socket.recv(MAX_PAYLOAD_SIZE + 32)
        except (TimeoutError, BlockingIOError):
            return None
        finally:
            if timeout is not None and self._socket is not None:
                self._socket.settimeout(previous_timeout)
        try:
            return self.store.ingest(datagram)
        except (ProtocolError, TypeError, ValueError) as exc:
            self.invalid_datagrams += 1
            if self.on_error is not None:
                self.on_error(exc)
            return None

    def _receive_loop(self) -> None:
        while not self._stop.is_set():
            try:
                self.receive_once()
            except OSError as exc:
                if not self._stop.is_set() and self.on_error is not None:
                    self.on_error(exc)
                break

    def snapshot(self, *, now_ns: int | None = None) -> ExternalInputBundle:
        return self.store.snapshot(now_ns=now_ns)

    def close(self) -> None:
        self._stop.set()
        sock, self._socket = self._socket, None
        if sock is not None:
            sock.close()
        if self._thread is not None:
            self._thread.join(timeout=1.0)
            self._thread = None
        try:
            self.path.unlink()
        except FileNotFoundError:
            pass

    def __enter__(self) -> UnixDatagramReceiver:
        return self.start()

    def __exit__(self, exc_type, exc_value, traceback) -> None:
        self.close()
