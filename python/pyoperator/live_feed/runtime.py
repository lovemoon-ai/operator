"""Live Feed runtime: accept OLCP push connections and hand back typed samples.

This is the layer example code and algorithms build on.  It owns the sockets,
the reader thread, and the bounded drop-oldest queues, and exposes a plain
blocking iterator::

    with LiveFeedReceiver(ReceiverConfig()) as receiver:
        for session in receiver.sessions():
            for sample in session.samples():
                ...

The socket reader never blocks on the consumer: when the consumer falls behind,
high-rate samples (RGB packets, poses, depth frames) are dropped oldest-first so
the headset never stalls.  Session lifecycle and stream-configuration frames are
never dropped.
"""

from __future__ import annotations

import base64
import dataclasses
import json
import collections
import queue
import socket
import sys
import threading
import time
from pathlib import Path
from typing import Any, BinaryIO, Callable, Generic, Iterator, TypeVar

from . import qr
from .decoders import RgbHevcDecoder
from .models import (
    DepthCameraModel,
    DepthFrameSample,
    DepthMetadataSample,
    RgbConfigSample,
    RgbPacketSample,
    Sample,
    SessionEndSample,
    SessionStartSample,
    parse_sample,
)
from .protocol import (
    ACCEPTED_SESSION_PROTOCOL_PREFIXES,
    FLAG_COMPOSITE_JSON,
    JSON_FRAME_TYPES,
    TYPE_CAPTURE_REQUEST,
    TYPE_DEPTH_FRAME,
    TYPE_RGB_CSD,
    TYPE_RGB_PACKET,
    TYPE_SESSION_END,
    TYPE_SESSION_START,
    StreamEvent,
    decode_depth_frame_payload,
    encode_json,
    pack_frame,
    read_frame,
)
from .results import ResultChannel, ResultPublisher


T = TypeVar("T")

#: Sample kinds that must never be dropped under back-pressure.
CRITICAL_KINDS = frozenset({"session_start", "session_end", "rgb_csd", "depth_metadata"})


class DroppingQueue(Generic[T]):
    """Bounded queue that drops the oldest *droppable* item rather than block.

    ``protects`` marks items that must survive back-pressure. Without it,
    shedding the head of the queue would happily discard an already-queued
    ``session_start`` / ``rgb_csd`` as soon as high-rate poses filled the
    buffer -- admitting a critical item is worthless if the next flood evicts
    it again.
    """

    def __init__(self, name: str, maxsize: int, protects: Callable[[T], bool] | None = None) -> None:
        self.name = name
        self.maxsize = maxsize
        self._items: collections.deque[T] = collections.deque()
        self._cond = threading.Condition()
        self._protects = protects
        self.dropped = 0

    def _is_protected(self, item: T) -> bool:
        return self._protects is not None and self._protects(item)

    def put_drop_oldest(self, item: T) -> None:
        with self._cond:
            if len(self._items) >= self.maxsize:
                for index, existing in enumerate(self._items):
                    if not self._is_protected(existing):
                        del self._items[index]
                        self.dropped += 1
                        break
                else:
                    # Everything queued is protected. Accept the overflow: the
                    # alternative is discarding data we promised to keep, and
                    # protected kinds are inherently low-rate.
                    pass
            self._items.append(item)
            self._cond.notify()

    def put_blocking(self, item: T, stop: threading.Event | None = None, timeout: float = 0.25) -> bool:
        """Enqueue without ever discarding this item; never blocks forever.

        Parking on a full queue would strand the reader thread the moment a
        consumer stops draining (a ``break`` out of ``samples()`` is enough),
        and closing the socket does not wake a thread waiting on a queue.
        Returns False only if ``stop`` fired first.
        """
        with self._cond:
            while len(self._items) >= self.maxsize:
                if stop is not None and stop.is_set():
                    self.dropped += 1
                    return False
                # Shed a droppable item if one exists, else wait for a reader.
                for index, existing in enumerate(self._items):
                    if not self._is_protected(existing):
                        del self._items[index]
                        self.dropped += 1
                        break
                else:
                    if not self._cond.wait(timeout):
                        continue
            self._items.append(item)
            self._cond.notify()
            return True

    def get(self, timeout: float) -> T:
        with self._cond:
            if not self._items and not self._cond.wait_for(lambda: bool(self._items), timeout):
                raise queue.Empty
            self._cond.notify()
            return self._items.popleft()

    def get_nowait(self) -> T:
        with self._cond:
            if not self._items:
                raise queue.Empty
            self._cond.notify()
            return self._items.popleft()

    def qsize(self) -> int:
        return len(self._items)


@dataclasses.dataclass
class SessionQueues:
    """Per-stream queues used by the depth-fusion reference server."""

    session: DroppingQueue[StreamEvent]
    rgb_csd: DroppingQueue[StreamEvent]
    rgb_packet: DroppingQueue[StreamEvent]
    depth: DroppingQueue[StreamEvent]
    head_pose: DroppingQueue[StreamEvent]
    controller: DroppingQueue[StreamEvent]
    hands: DroppingQueue[StreamEvent]
    result: DroppingQueue[StreamEvent]

    @classmethod
    def create(cls, maxsize: int) -> "SessionQueues":
        return cls(
            session=DroppingQueue("session", maxsize),
            rgb_csd=DroppingQueue("rgb_csd", maxsize),
            rgb_packet=DroppingQueue("rgb_packet", maxsize),
            depth=DroppingQueue("depth", maxsize),
            head_pose=DroppingQueue("head_pose", maxsize),
            controller=DroppingQueue("controller", maxsize),
            hands=DroppingQueue("hands", maxsize),
            result=DroppingQueue("result", maxsize),
        )


@dataclasses.dataclass
class ReceiverConfig:
    """Configuration for :class:`LiveFeedReceiver`."""

    host: str = "0.0.0.0"
    push_port: int = 63910
    result_host: str = "0.0.0.0"
    result_port: int = 63912
    #: Accept the headset's live-pull connection. Keep this on even for one-way
    #: examples so the headset does not reconnect in a loop.
    accept_results: bool = True
    #: Create a :class:`ResultPublisher`. Off disables algorithm results; an
    #: explicitly configured capture request may still be sent.
    publish_results: bool = True
    #: Optional control-plane request sent as soon as the headset connects to
    #: the result channel. Examples use this to tell the headset which input
    #: data types they consume before live-push capture starts.
    capture_request: dict[str, Any] | None = None
    max_queue: int = 256
    auth_token: str = ""
    max_events: int | None = None
    #: Persist raw frames (events.ndjson, rgb.h265, depth/*.u16) under this dir.
    record_dir: Path | None = None
    #: Decode RGB to raw frames via ffmpeg (needs ffmpeg on PATH).
    decode_rgb: bool = False
    ffmpeg_bin: str = "ffmpeg"
    result_fragment_bytes: int = 1024 * 1024
    quiet: bool = False
    #: Print the address + QR banner when the listener starts, so every entry
    #: point advertises itself without having to remember to do it.
    #: ``None`` follows ``quiet`` (silent in tests, shown in normal runs); set
    #: it explicitly to show the banner even when runtime logging is quiet.
    show_connection_banner: bool | None = None
    #: Include the scannable QR in that banner (the address is always shown).
    show_qr: bool = True
    #: Overrides the banner heading, e.g. "Live Feed viewer".
    banner_label: str = "Live Feed server"


@dataclasses.dataclass
class SessionStats:
    """Live counters for a session; safe to read from the consumer thread."""

    counts: dict[str, int] = dataclasses.field(default_factory=dict)
    bytes_received: int = 0
    frames_received: int = 0
    dropped: int = 0
    #: ``None`` until the first sample; do not use 0 as the sentinel, a
    #: legitimate timestamp of 0 would then be mistaken for "unset".
    first_recv_ns: int | None = None
    last_recv_ns: int | None = None

    def record(self, sample: Sample, payload_size: int) -> None:
        self.counts[sample.kind] = self.counts.get(sample.kind, 0) + 1
        self.frames_received += 1
        self.bytes_received += payload_size
        if self.first_recv_ns is None:
            self.first_recv_ns = sample.recv_monotonic_ns
        self.last_recv_ns = sample.recv_monotonic_ns

    @property
    def elapsed_s(self) -> float:
        if self.first_recv_ns is None or self.last_recv_ns is None:
            return 0.0
        return max(0.0, (self.last_recv_ns - self.first_recv_ns) / 1e9)

    def rate_hz(self, kind: str) -> float:
        elapsed = self.elapsed_s
        if elapsed <= 0.0:
            return 0.0
        return self.counts.get(kind, 0) / elapsed

    def summary(self) -> str:
        parts = [f"{kind}={count}" for kind, count in sorted(self.counts.items())]
        parts.append(f"dropped={self.dropped}")
        parts.append(f"mib={self.bytes_received / (1024 * 1024):.1f}")
        return " ".join(parts)


class SessionRecorder:
    """Writes the raw OLCP stream to disk in the same layout as the reference server."""

    def __init__(self, session_dir: Path) -> None:
        self.session_dir = session_dir
        self.depth_dir = session_dir / "depth"
        session_dir.mkdir(parents=True, exist_ok=True)
        self.depth_dir.mkdir(exist_ok=True)
        self._events: Any = (session_dir / "events.ndjson").open("a", encoding="utf-8")
        self._rgb: BinaryIO = (session_dir / "rgb.h265").open("ab")

    def close(self) -> None:
        try:
            self._events.close()
        finally:
            self._rgb.close()

    def record(self, event: StreamEvent) -> None:
        log_payload: Any
        if event.frame_type in JSON_FRAME_TYPES:
            try:
                log_payload = event.payload_json()
            except Exception:
                log_payload = {"binary_size": len(event.payload)}
            if event.frame_type == TYPE_RGB_CSD and isinstance(log_payload, dict):
                csd_base64 = str(log_payload.get("csd_base64", ""))
                if csd_base64:
                    self._rgb.write(base64.b64decode(csd_base64))
                    self._rgb.flush()
        elif event.frame_type == TYPE_DEPTH_FRAME and (event.flags & FLAG_COMPOSITE_JSON):
            try:
                metadata, depth_bytes = decode_depth_frame_payload(event)
                depth_name = f"depth_{event.pts_ns:020d}.u16"
                (self.depth_dir / depth_name).write_bytes(depth_bytes)
                log_payload = {
                    "metadata": metadata,
                    "binary_uri": f"depth/{depth_name}",
                    "binary_size": len(depth_bytes),
                    "wire_size": len(event.payload),
                }
            except Exception as error:
                log_payload = {
                    "binary_size": len(event.payload),
                    "decode_error": str(error),
                }
        else:
            log_payload = {"binary_size": len(event.payload)}

        if event.frame_type == TYPE_RGB_PACKET:
            self._rgb.write(event.payload)
            self._rgb.flush()

        record = {
            "recv_monotonic_ns": event.recv_monotonic_ns,
            "frame_type": event.frame_type,
            "flags": event.flags,
            "pts_ns": event.pts_ns,
            "duration_ns": event.duration_ns,
            "payload": log_payload,
        }
        self._events.write(json.dumps(record, sort_keys=True) + "\n")
        self._events.flush()


class _EndOfSession:
    """Sentinel pushed by the reader thread when the stream ends."""

    __slots__ = ("error",)

    def __init__(self, error: BaseException | None = None) -> None:
        self.error = error


class LiveFeedSession:
    """One headset push connection, exposed as an iterator of typed samples."""

    def __init__(
        self,
        conn: socket.socket,
        peer: tuple[str, int],
        config: ReceiverConfig,
        publisher: ResultPublisher | None,
        recorder: SessionRecorder | None = None,
        on_closed: Callable[["LiveFeedSession"], None] | None = None,
    ) -> None:
        self.conn = conn
        self.peer = peer
        self.config = config
        self.results = publisher
        self.recorder = recorder
        self._on_closed = on_closed
        self.stats = SessionStats()
        self.session_id = ""
        self.session_info: dict[str, Any] = {}
        self.depth_model: DepthCameraModel | None = None
        self.rgb_config: dict[str, Any] = {}

        self.rgb_decoder: RgbHevcDecoder | None = None
        self._decode_queue: DroppingQueue[Any] | None = None
        self._decode_thread: threading.Thread | None = None
        if config.decode_rgb:
            self.rgb_decoder = RgbHevcDecoder(ffmpeg_bin=config.ffmpeg_bin, enabled=True)
            self._decode_queue = DroppingQueue("rgb-decode", max(8, config.max_queue))

        self._queue: DroppingQueue[Any] = DroppingQueue(
            "samples",
            max(8, config.max_queue),
            # Critical frames must survive the flood, not merely enter it.
            protects=lambda item: isinstance(item, _EndOfSession) or getattr(item, "kind", "") in CRITICAL_KINDS,
        )
        #: Set when the stream has ended (consumers may stop iterating).
        self._stop = threading.Event()
        #: Set by close(); tells blocked producers to give up rather than wait
        #: for a consumer that is never coming back.
        self._closing = threading.Event()
        self._reader = threading.Thread(target=self._read_loop, name="live-feed-reader", daemon=True)
        self._closed = False
        self._error: BaseException | None = None

    # -- lifecycle ---------------------------------------------------------

    def start(self) -> None:
        self._reader.start()
        if self._decode_queue is not None:
            self._decode_thread = threading.Thread(
                target=self._decode_loop, name="live-feed-rgb-feed", daemon=True
            )
            self._decode_thread.start()

    def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        self._closing.set()
        self._stop.set()
        try:
            self.conn.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        try:
            self.conn.close()
        except OSError:
            pass
        # Free a reader parked in put_blocking: closing the socket does not
        # wake a thread waiting on a full queue, and the join below would then
        # time out silently, leaking the thread and everything it buffered.
        self._drain_queue()
        if self._reader.is_alive() or self._reader.ident is not None:
            self._reader.join(timeout=2.0)
        if self._decode_thread is not None:
            self._decode_queue.put_drop_oldest(_EndOfSession())  # type: ignore[union-attr]
            self._decode_thread.join(timeout=2.0)
        if self.rgb_decoder is not None:
            self.rgb_decoder.close()
        if self.recorder is not None:
            self.recorder.close()
        if self.results is not None:
            # Owns an open results.ndjson when recording; nothing else closes it.
            self.results.close()
        if self._on_closed is not None:
            self._on_closed(self)

    def _drain_queue(self) -> None:
        while True:
            try:
                self._queue.get_nowait()
            except queue.Empty:
                return

    def __enter__(self) -> "LiveFeedSession":
        return self

    def __exit__(self, *_exc: Any) -> None:
        self.close()

    @property
    def error(self) -> BaseException | None:
        """Exception that terminated the stream, if any."""
        return self._error

    # -- consumption -------------------------------------------------------

    def samples(self, timeout: float = 0.25) -> Iterator[Sample]:
        """Yield typed samples until the headset ends the session or disconnects.

        ``timeout`` only bounds how long an internal queue read blocks; the
        iterator itself blocks until the next sample or end of stream.
        """
        while True:
            try:
                item = self._queue.get(timeout=timeout)
            except queue.Empty:
                if self._stop.is_set():
                    return
                continue
            if isinstance(item, _EndOfSession):
                self._error = item.error
                return
            yield item

    def drain_latest(self, kind: str) -> Sample | None:
        """Non-blocking: newest queued sample of ``kind``, discarding older ones."""
        latest: Sample | None = None
        while True:
            try:
                item = self._queue.get_nowait()
            except queue.Empty:
                return latest
            if isinstance(item, _EndOfSession):
                self._error = item.error
                self._stop.set()
                return latest
            if item.kind == kind:
                latest = item

    # -- internals ---------------------------------------------------------

    def _log(self, message: str) -> None:
        if not self.config.quiet:
            print(message, flush=True)

    def _read_loop(self) -> None:
        error: BaseException | None = None
        count = 0
        saw_session_start = False
        try:
            while not self._stop.is_set():
                event = read_frame(self.conn)
                if event is None:
                    break
                count += 1
                if not saw_session_start:
                    if event.frame_type != TYPE_SESSION_START:
                        raise ValueError(
                            f"first OLCP frame must be session_start, got type={event.frame_type}"
                        )
                    self._validate_session_start(event)
                    saw_session_start = True
                if self.recorder is not None:
                    self.recorder.record(event)
                self._dispatch(event)
                if event.frame_type == TYPE_SESSION_END:
                    break
                if self.config.max_events is not None and count >= self.config.max_events:
                    self._log(f"max events reached: {self.config.max_events}")
                    break
        except EOFError as eof:
            self._log(f"push closed: {eof}")
        except (ValueError, PermissionError) as rejected:
            # Handshake rejections must be reported, not swallowed. PermissionError
            # subclasses OSError, so this has to come before the OSError branch.
            error = rejected
            print(f"live feed rejected session: {rejected}", file=sys.stderr, flush=True)
        except OSError:
            # Socket torn down (usually our own close()); not an error.
            pass
        except BaseException as unexpected:  # noqa: BLE001 - surfaced via session.error
            error = unexpected
            print(f"live feed reader failed: {unexpected}", file=sys.stderr, flush=True)
        finally:
            # _stop is set inside the sentinel push below, not before it: a
            # consumer that sees _stop while the queue is momentarily empty
            # would return without ever reading the sentinel, losing
            # session.error. Push first, then signal.
            self._queue.put_blocking(_EndOfSession(error), stop=self._closing)
            self._stop.set()

    def _dispatch(self, event: StreamEvent) -> None:
        sample = parse_sample(event, depth_model=self.depth_model)

        if isinstance(sample, SessionStartSample):
            self.session_id = sample.session_id
            self.session_info = sample.info
        elif isinstance(sample, RgbConfigSample):
            self.rgb_config = sample.config
            if self.rgb_decoder is not None:
                self.rgb_decoder.configure(sample.config)
        elif isinstance(sample, (DepthMetadataSample, DepthFrameSample)):
            if sample.model is not None:
                self.depth_model = sample.model
        elif isinstance(sample, RgbPacketSample) and self._decode_queue is not None:
            self._decode_queue.put_drop_oldest(sample)

        before = self._queue.dropped
        if sample.kind in CRITICAL_KINDS:
            self._queue.put_blocking(sample, stop=self._closing)
        else:
            self._queue.put_drop_oldest(sample)
        self.stats.dropped += self._queue.dropped - before
        self.stats.record(sample, len(event.payload))

        if isinstance(sample, SessionEndSample):
            self._log(f"session_end received for {self.session_id or '<unknown>'}")

    def _decode_loop(self) -> None:
        assert self._decode_queue is not None
        while True:
            try:
                item = self._decode_queue.get(timeout=0.25)
            except queue.Empty:
                if self._stop.is_set():
                    return
                continue
            if isinstance(item, _EndOfSession):
                return
            if self.rgb_decoder is not None:
                self.rgb_decoder.submit_payload(item.pts_ns, item.payload)

    def _validate_session_start(self, event: StreamEvent) -> None:
        payload = event.payload_json()
        protocol = str(payload.get("protocol", "operator.live_feed.v1"))
        if not protocol.startswith(ACCEPTED_SESSION_PROTOCOL_PREFIXES):
            raise ValueError(f"unsupported session protocol: {protocol}")
        if self.config.auth_token and payload.get("auth_token") != self.config.auth_token:
            raise PermissionError("session auth token mismatch")

    def send_control_json(self, frame_type: int, value: dict[str, Any]) -> None:
        """Send a control frame back over the *push* connection (e.g. capture_request)."""
        payload = encode_json(value)
        self.conn.sendall(pack_frame(frame_type, 0, 0, 0, payload))


class LiveFeedReceiver:
    """Accepts headset live-push connections and owns the shared result channel."""

    def __init__(self, config: ReceiverConfig | None = None) -> None:
        self.config = config or ReceiverConfig()
        self.result_channel = ResultChannel(
            self.config.result_host,
            self.config.result_port,
            self.config.accept_results,
            quiet=self.config.quiet,
            auth_token=self.config.auth_token,
            on_client_connected=self._on_result_client_connected,
        )
        self._publisher_lock = threading.Lock()
        self._active_publisher: ResultPublisher | None = None
        self._server: socket.socket | None = None
        self._started = False
        self._closed = False
        self.session_count = 0

    @property
    def push_port(self) -> int:
        """Bound push port; resolves ``0`` to the OS-assigned port after :meth:`start`."""
        if self._server is not None:
            return self._server.getsockname()[1]
        return self.config.push_port

    @property
    def result_port(self) -> int:
        """Bound live-pull port; call :meth:`wait_result_bound` first when using port 0."""
        return self.result_channel.port

    def wait_result_bound(self, timeout: float = 5.0) -> bool:
        return self.result_channel.wait_bound(timeout)

    def start(self) -> "LiveFeedReceiver":
        if self._started:
            return self
        self._started = True
        server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind((self.config.host, self.config.push_port))
        server.listen(1)
        server.settimeout(0.5)
        self._server = server
        self.result_channel.start()
        self._log(f"push listening on {self.config.host}:{self.push_port}")
        # Keep the QR as the final startup output. On a 24-row terminal the
        # compact code fits with its cursor row; a later log line would scroll
        # away the top quiet zone and make it unscannable.
        self._announce()
        return self

    def _announce(self) -> None:
        """Print how to reach this listener, once it is actually bound.

        Lives here rather than in each caller so any new example or embedding
        gets it for free -- forgetting to call it is how the examples ended up
        without a QR in the first place.
        """
        show = self.config.show_connection_banner
        if show is None:
            show = not self.config.quiet
        if not show:
            return
        result_port: int | None = None
        if self.config.accept_results:
            # Resolve port 0 to what the OS actually handed out.
            self.result_channel.wait_bound(2.0)
            # Never advertise a port that failed to bind -- the headset would
            # connect, get refused, and the operator would blame the QR.
            if self.result_channel.bind_error is None:
                result_port = self.result_port
        qr.print_connection_banner(
            self.config.host,
            self.push_port,
            result_port,
            self.config.auth_token,
            show_qr=self.config.show_qr,
            label=self.config.banner_label,
        )

    def _announce_capture_request(self) -> None:
        request = self.config.capture_request
        if request is None:
            return
        self.result_channel.send_frame(
            TYPE_CAPTURE_REQUEST,
            0,
            0,
            0,
            encode_json(request),
        )
        self._log(
            "capture request announced: "
            f"streams={list(request.get('selected_streams', []))}"
        )

    def _on_result_client_connected(self) -> None:
        self._announce_capture_request()
        with self._publisher_lock:
            publisher = self._active_publisher
        if publisher is not None:
            replayed = publisher.replay_snapshot()
            self._log(f"result snapshot replayed: chunks={replayed}")

    def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        if self._server is not None:
            try:
                self._server.close()
            except OSError:
                pass
            self._server = None
        self.result_channel.close()

    def __enter__(self) -> "LiveFeedReceiver":
        return self.start()

    def __exit__(self, *_exc: Any) -> None:
        self.close()

    def _log(self, message: str) -> None:
        if not self.config.quiet:
            print(message, flush=True)

    def accept(self, timeout: float | None = None) -> LiveFeedSession | None:
        """Accept one push connection, or return ``None`` on timeout/shutdown."""
        if not self._started:
            self.start()
        assert self._server is not None
        deadline = None if timeout is None else time.monotonic() + timeout
        while not self._closed:
            try:
                conn, peer = self._server.accept()
            except socket.timeout:
                if deadline is not None and time.monotonic() >= deadline:
                    return None
                continue
            except OSError:
                return None
            conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            self._log(f"push accepted {peer[0]}:{peer[1]}")
            self.session_count += 1
            return self._make_session(conn, peer)
        return None

    def sessions(self, timeout: float | None = None) -> Iterator[LiveFeedSession]:
        """Yield sessions as headsets connect; each is closed when the caller moves on."""
        while not self._closed:
            session = self.accept(timeout=timeout)
            if session is None:
                return
            try:
                yield session
            finally:
                session.close()

    def _make_session(self, conn: socket.socket, peer: tuple[str, int]) -> LiveFeedSession:
        recorder: SessionRecorder | None = None
        session_dir: Path | None = None
        if self.config.record_dir is not None:
            session_dir = self._make_session_dir(peer)
            recorder = SessionRecorder(session_dir)

        publisher: ResultPublisher | None = None
        if self.config.publish_results and self.config.accept_results:
            publisher = ResultPublisher(
                self.result_channel.send_frame,
                session_dir=session_dir,
                max_fragment_bytes=self.config.result_fragment_bytes,
            )

        session = LiveFeedSession(
            conn,
            peer,
            self.config,
            publisher,
            recorder,
            on_closed=self._on_session_closed,
        )
        with self._publisher_lock:
            self._active_publisher = publisher
        session.start()
        return session

    def _on_session_closed(self, session: LiveFeedSession) -> None:
        with self._publisher_lock:
            if self._active_publisher is session.results:
                self._active_publisher = None

    def _make_session_dir(self, peer: tuple[str, int]) -> Path:
        assert self.config.record_dir is not None
        timestamp = time.strftime("%Y%m%d_%H%M%S")
        safe_peer = f"{peer[0].replace('.', '_')}_{peer[1]}"
        return self.config.record_dir / f"session_{timestamp}_{safe_peer}_{time.monotonic_ns()}"


def connect_push_client(host: str, port: int, timeout: float = 5.0) -> socket.socket:
    """Open a client socket that speaks live-push; used by tests and fake headsets."""
    conn = socket.create_connection((host, port), timeout=timeout)
    conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    return conn


SendFrameFn = Callable[[int, int, int, int, bytes], None]
