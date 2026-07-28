"""Result channel: sending algorithm output back to the headset over OLCP.

The XR client opens a second TCP connection (default port 63912), optionally
authenticates with ``result_hello`` (type 100), waits for ``result_welcome``
(type 102), and consumes result frames 101/110-116. :class:`ResultChannel`
owns that socket;
:class:`ResultPublisher` owns the framing rules the headset expects, in
particular that a point-cloud update is always sent as
``manifest -> fragment... -> commit``.
"""

from __future__ import annotations

import dataclasses
import hmac
import json
import math
import socket
import sys
import threading
import time
import uuid
from collections import OrderedDict
from pathlib import Path
from typing import Any, Callable, Iterable, Sequence

from .models import identity_matrix
from .protocol import (
    DENSE_POINT,
    FRAME_HEADER,
    FLAG_COMPOSITE_JSON,
    MAGIC,
    PROTOCOL_VERSION,
    TYPE_ALGORITHM_STATUS,
    TYPE_CAMERA_TRAJECTORY,
    TYPE_DENSE_MAP_COMMIT,
    TYPE_DENSE_MAP_FRAGMENT,
    TYPE_DENSE_MAP_MANIFEST,
    TYPE_MAP_RESET,
    TYPE_MAP_TRANSFORM,
    TYPE_RESULT_HELLO,
    TYPE_RESULT_WELCOME,
    StreamEvent,
    encode_json,
    pack_composite_payload,
    pack_frame,
)


POINT_FORMAT = "f32xyz_u8rgba_f32conf"

#: Upper bound on a single result send. Generous enough for a multi-megabyte
#: point-cloud chunk over Wi-Fi, short enough that a dead client is dropped
#: instead of wedging the channel.
SEND_TIMEOUT_S = 15.0
RESULT_AUTH_TIMEOUT_S = 5.0
MAX_RESULT_HELLO_BYTES = 4096
MAX_PENDING_AUTH = 32
DEFAULT_SNAPSHOT_CHUNKS = 64
DEFAULT_SNAPSHOT_POINTS = 1_200_000

SendFrame = Callable[[int, int, int, int, bytes], None]


@dataclasses.dataclass(frozen=True)
class DensePoint:
    """One point in the ``f32xyz_u8rgba_f32conf`` wire format."""

    x: float
    y: float
    z: float
    r: int = 255
    g: int = 255
    b: int = 255
    a: int = 255
    confidence: float = 1.0

    def pack(self) -> bytes:
        return DENSE_POINT.pack(
            float(self.x),
            float(self.y),
            float(self.z),
            _clamp_u8(self.r),
            _clamp_u8(self.g),
            _clamp_u8(self.b),
            _clamp_u8(self.a),
            float(self.confidence),
        )


def _clamp_u8(value: int) -> int:
    return max(0, min(255, int(value)))


def pack_dense_points(points: Iterable[DensePoint]) -> bytes:
    """Pack ``DensePoint`` values into the binary payload the headset renders."""
    buffer = bytearray()
    for point in points:
        buffer.extend(point.pack())
    return bytes(buffer)


def make_dense_point_payload(
    map_id: str,
    map_version: int,
    submap_id: int,
    frame_ids: tuple[int, int],
    point_count: int = 512,
) -> tuple[dict[str, Any], bytes]:
    """Synthetic point grid used by the self-test and loopback fixtures."""
    points = bytearray()
    for index in range(point_count):
        col = index % 32
        row = index // 32
        x = (col - 16) * 0.035
        y = (row - 8) * 0.035
        z = 1.0 + 0.01 * ((index + submap_id) % 17)
        r = (40 + index * 3) % 256
        g = (120 + index * 5) % 256
        b = (200 + submap_id * 11) % 256
        points.extend(DENSE_POINT.pack(x, y, z, r, g, b, 255, 0.75))
    metadata = {
        "schema": "operator.dense_map_chunk.v1",
        "map_id": map_id,
        "map_version": map_version,
        "submap_id": submap_id,
        "chunk_id": f"submap_{submap_id:04d}_chunk_0000",
        "operation": "upsert",
        "frame_id_range": list(frame_ids),
        "coordinate_frame": "map",
        "T_openxr_map": identity_matrix(),
        "point_format": POINT_FORMAT,
        "point_stride_bytes": DENSE_POINT.size,
        "point_count": point_count,
    }
    return metadata, bytes(points)


class ResultChannel:
    """TCP listener that streams OLCP result frames to one XR client at a time."""

    def __init__(
        self,
        host: str,
        port: int,
        enabled: bool,
        *,
        quiet: bool = False,
        auth_token: str = "",
        on_client_connected: Callable[[], None] | None = None,
    ) -> None:
        self.host = host
        self.port = port
        self.enabled = enabled
        self.quiet = quiet
        self.auth_token = auth_token
        #: Called right after an XR client attaches. Used to push the capture
        #: request as soon as the headset's settings page connects, before any
        #: capture has started.
        self.on_client_connected = on_client_connected
        self.accepted_count = 0
        #: Set when the listener could not bind; callers should not advertise
        #: this port. None while healthy.
        self.bind_error: OSError | None = None
        self.server_instance_id = uuid.uuid4().hex
        self._stop = threading.Event()
        self._connected = threading.Event()
        self._bound = threading.Event()
        self._lock = threading.Lock()
        self._promotion_lock = threading.Lock()
        self._server: socket.socket | None = None
        self._conn: socket.socket | None = None
        self._pending_conns: set[socket.socket] = set()
        self._auth_threads: set[threading.Thread] = set()
        self._thread: threading.Thread | None = None

    @property
    def connected(self) -> bool:
        return self._connected.is_set()

    def start(self) -> None:
        if not self.enabled:
            self._log("result return disabled")
            return
        self._thread = threading.Thread(target=self._serve, name="live-feed-result-channel", daemon=True)
        self._thread.start()

    def wait_bound(self, timeout: float = 5.0) -> bool:
        """Block until the listener socket is bound, so :attr:`port` is resolved."""
        if not self.enabled:
            return False
        return self._bound.wait(timeout)

    def wait_for_client(self, timeout: float) -> bool:
        """Block until an XR client connects, or ``timeout`` elapses."""
        if not self.enabled:
            return False
        return self._connected.wait(timeout)

    def close(self) -> None:
        self._stop.set()
        # Break any in-flight sendall *before* contending for the lock:
        # send_frame holds it for the whole blocking send, so a headset that
        # stopped reading (full TCP window) would otherwise make close() --
        # and process exit -- wait forever. Reading the attribute without the
        # lock is safe; shutdown() on an already-closed socket just raises.
        with self._lock:
            sockets = [candidate for candidate in (self._conn, *self._pending_conns) if candidate is not None]
            server = self._server
        for conn in sockets:
            try:
                conn.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
        if server is not None:
            try:
                server.close()
            except OSError:
                pass
        with self._lock:
            self._close_conn_locked()
            for pending in tuple(self._pending_conns):
                try:
                    pending.close()
                except OSError:
                    pass
            self._pending_conns.clear()
            if self._server is not None:
                try:
                    self._server.close()
                except OSError:
                    pass
                self._server = None
        if self._thread is not None:
            self._thread.join(timeout=2.0)
        deadline = time.monotonic() + 2.0
        while True:
            with self._lock:
                auth_threads = tuple(self._auth_threads)
            if not auth_threads:
                break
            remaining = deadline - time.monotonic()
            if remaining <= 0.0:
                break
            for thread in auth_threads:
                thread.join(timeout=max(0.0, remaining))

    def send_frame(self, frame_type: int, flags: int, pts_ns: int, duration_ns: int, payload: bytes) -> None:
        if not self.enabled:
            return
        frame = pack_frame(frame_type, flags, pts_ns, duration_ns, payload)
        with self._lock:
            if self._conn is None:
                return
            try:
                self._conn.sendall(frame)
            except OSError as error:
                print(f"result send failed: {error}", file=sys.stderr, flush=True)
                self._close_conn_locked()

    def _log(self, message: str) -> None:
        if not self.quiet:
            print(message, flush=True)

    def _serve(self) -> None:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as server:
            server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            try:
                server.bind((self.host, self.port))
                server.listen(MAX_PENDING_AUTH)
            except OSError as error:
                # Without this the thread dies with a bare traceback, _bound
                # never fires, and the banner/QR go on advertising a port
                # nothing is listening on -- results silently vanish.
                self.bind_error = error
                print(
                    f"result channel cannot listen on {self.host}:{self.port}: {error}",
                    file=sys.stderr,
                    flush=True,
                )
                self._bound.set()
                return
            if self.port == 0:
                self.port = server.getsockname()[1]
            server.settimeout(0.5)
            with self._lock:
                self._server = server
            self._bound.set()
            self._log(f"result listening on {self.host}:{self.port}")
            while not self._stop.is_set():
                try:
                    conn, peer = server.accept()
                except socket.timeout:
                    continue
                except OSError:
                    break
                # Authenticate candidates independently. A silent or malicious
                # peer must not monopolize the accept loop and prevent the real
                # headset from reconnecting.
                conn.settimeout(SEND_TIMEOUT_S)
                conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                conn.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
                with self._lock:
                    if self._stop.is_set() or len(self._pending_conns) >= MAX_PENDING_AUTH:
                        rejected = True
                    else:
                        rejected = False
                        self._pending_conns.add(conn)
                if rejected:
                    try:
                        conn.close()
                    except OSError:
                        pass
                    continue
                thread = threading.Thread(
                    target=self._authenticate_and_install,
                    args=(conn, peer),
                    name=f"live-feed-result-auth-{peer[0]}:{peer[1]}",
                    daemon=True,
                )
                with self._lock:
                    self._auth_threads.add(thread)
                    # Publish the thread to close() only after it is startable;
                    # otherwise close could observe it in the tiny add/start
                    # gap and `join()` would raise "cannot join before start".
                    thread.start()
        with self._lock:
            if self._server is server:
                self._server = None

    def _authenticate_and_install(
        self,
        conn: socket.socket,
        peer: tuple[str, int],
    ) -> None:
        current = threading.current_thread()
        installed = False
        try:
            if not self._authenticate(conn, peer):
                return
            # Serialize promotion and its replay callback so a second valid
            # client cannot replace `_conn` halfway through the first client's
            # welcome/snapshot sequence.
            with self._promotion_lock:
                if self._stop.is_set():
                    return
                welcome = encode_json(
                    {
                        "schema": "operator.result_welcome.v1",
                        "protocol": "operator.live_feed.v2",
                        "server_instance_id": self.server_instance_id,
                    }
                )
                try:
                    conn.sendall(pack_frame(TYPE_RESULT_WELCOME, 0, 0, 0, welcome))
                except OSError as error:
                    self._log(
                        f"result welcome failed {peer[0]}:{peer[1]}: {error}"
                    )
                    return
                with self._lock:
                    if self._stop.is_set() or conn not in self._pending_conns:
                        return
                    self._pending_conns.remove(conn)
                    self._close_conn_locked()
                    self._conn = conn
                    self.accepted_count += 1
                    installed = True
                self._connected.set()
                self._log(f"result accepted {peer[0]}:{peer[1]}")
                if self.on_client_connected is not None:
                    try:
                        self.on_client_connected()
                    except Exception as error:  # noqa: BLE001
                        print(
                            f"result on-connect hook failed: {error}",
                            file=sys.stderr,
                            flush=True,
                        )
        finally:
            with self._lock:
                self._pending_conns.discard(conn)
                self._auth_threads.discard(current)
            if not installed:
                try:
                    conn.close()
                except OSError:
                    pass

    def _authenticate(self, conn: socket.socket, peer: tuple[str, int]) -> bool:
        """Validate client-first OLCP authentication before exposing results.

        Every client must send the hello, even when no token is configured, so
        the server can return an unambiguous welcome acknowledgement. When a
        token is configured, a new connection cannot replace the current
        headset or receive data until it proves possession of that token.
        """
        rejection: str | None = None
        try:
            frame = self._read_auth_frame(conn)
            if frame is None:
                rejection = "connection closed before result_hello"
                return False
            if frame.frame_type != TYPE_RESULT_HELLO:
                rejection = (
                    f"expected result_hello, got frame type {frame.frame_type}"
                )
                return False
            payload = frame.payload_json()
            if not isinstance(payload, dict):
                rejection = "result_hello payload must be a JSON object"
                return False
            if payload.get("schema") != "operator.result_hello.v1":
                rejection = "unsupported result_hello schema"
                return False
            supplied = payload.get("auth_token", "")
            if not isinstance(supplied, str):
                rejection = "result_hello auth_token must be a string"
                return False
            if self.auth_token and not hmac.compare_digest(supplied, self.auth_token):
                rejection = "token mismatch"
                return False
            return True
        except (EOFError, OSError, ValueError, json.JSONDecodeError) as error:
            rejection = str(error) or error.__class__.__name__
            return False
        finally:
            try:
                conn.settimeout(SEND_TIMEOUT_S)
            except OSError:
                pass
            if rejection is not None:
                self._log(
                    f"result authentication rejected "
                    f"{peer[0]}:{peer[1]}: {rejection}"
                )

    def _read_auth_frame(self, conn: socket.socket) -> StreamEvent | None:
        """Read one small hello while remaining promptly cancellable by close()."""
        deadline = time.monotonic() + RESULT_AUTH_TIMEOUT_S
        buffer = bytearray()
        frame_size: int | None = None
        conn.settimeout(0.1)
        while not self._stop.is_set() and time.monotonic() < deadline:
            try:
                chunk = conn.recv(MAX_RESULT_HELLO_BYTES + FRAME_HEADER.size - len(buffer))
            except socket.timeout:
                continue
            if not chunk:
                return None
            buffer.extend(chunk)
            if frame_size is None and len(buffer) >= FRAME_HEADER.size:
                (
                    magic,
                    version,
                    _frame_type,
                    _flags,
                    _pts_ns,
                    _duration_ns,
                    payload_size,
                ) = FRAME_HEADER.unpack(buffer[: FRAME_HEADER.size])
                if magic != MAGIC:
                    raise ValueError(f"invalid magic {magic!r}")
                if version != PROTOCOL_VERSION:
                    raise ValueError(f"unsupported OLCP version {version}")
                if payload_size > MAX_RESULT_HELLO_BYTES:
                    raise ValueError(
                        f"OLCP payload too large: {payload_size} bytes "
                        f"(maximum {MAX_RESULT_HELLO_BYTES})"
                    )
                frame_size = FRAME_HEADER.size + payload_size
            if frame_size is not None and len(buffer) >= frame_size:
                (
                    _magic,
                    _version,
                    frame_type,
                    flags,
                    pts_ns,
                    duration_ns,
                    payload_size,
                ) = FRAME_HEADER.unpack(buffer[: FRAME_HEADER.size])
                payload = bytes(
                    buffer[FRAME_HEADER.size: FRAME_HEADER.size + payload_size]
                )
                return StreamEvent(
                    frame_type,
                    flags,
                    pts_ns,
                    duration_ns,
                    payload,
                )
        return None

    def _close_conn_locked(self) -> None:
        self._connected.clear()
        if self._conn is None:
            return
        try:
            self._conn.close()
        except OSError:
            pass
        self._conn = None


class ResultPublisher:
    """Frames algorithm output as OLCP result messages.

    ``send_frame`` is the transport (normally :meth:`ResultChannel.send_frame`).
    ``session_dir`` is optional: pass it to persist results to disk, omit it for
    in-memory example code.  ``event_sink`` receives every published event so a
    server can also fan results into its own queues.
    """

    def __init__(
        self,
        send_frame: SendFrame,
        *,
        session_dir: Path | None = None,
        event_sink: Callable[[StreamEvent], None] | None = None,
        max_fragment_bytes: int = 1024 * 1024,
        max_snapshot_chunks: int = DEFAULT_SNAPSHOT_CHUNKS,
        max_snapshot_points: int = DEFAULT_SNAPSHOT_POINTS,
    ) -> None:
        self.send_frame = send_frame
        self.session_dir = session_dir
        self.event_sink = event_sink
        self.max_fragment_bytes = max(64 * 1024, max_fragment_bytes)
        self.max_snapshot_chunks = max_snapshot_chunks
        self.max_snapshot_points = max_snapshot_points
        self.published_frames = 0
        self.published_points = 0
        self._map_versions: dict[str, int] = {}
        self._submap_ids: dict[str, int] = {}
        self._state_lock = threading.RLock()
        self._snapshot_chunks: OrderedDict[
            tuple[str, str],
            tuple[dict[str, Any], bytes, int, int],
        ] = OrderedDict()
        self._snapshot_point_count = 0
        self._latest_reset: tuple[dict[str, Any], int] | None = None
        self._latest_json: dict[int, tuple[dict[str, Any], int]] = {}

        self.results_dir: Path | None = None
        self.chunk_dir: Path | None = None
        self._log = None
        if session_dir is not None:
            self.results_dir = session_dir / "results"
            self.chunk_dir = self.results_dir / "map_chunks"
            self.results_dir.mkdir(parents=True, exist_ok=True)
            self.chunk_dir.mkdir(parents=True, exist_ok=True)
            self._log = (self.results_dir / "results.ndjson").open("a", encoding="utf-8")

    def close(self) -> None:
        with self._state_lock:
            if self._log is not None:
                self._log.close()
                self._log = None

    def __enter__(self) -> "ResultPublisher":
        return self

    def __exit__(self, *_exc: Any) -> None:
        self.close()

    # -- low level ---------------------------------------------------------

    def publish_json(self, frame_type: int, value: dict[str, Any], pts_ns: int = 0) -> None:
        with self._state_lock:
            snapshot_value = dict(value)
            if frame_type == TYPE_MAP_RESET:
                self._snapshot_chunks.clear()
                self._snapshot_point_count = 0
                self._latest_reset = (snapshot_value, pts_ns)
                self._latest_json.pop(TYPE_CAMERA_TRAJECTORY, None)
                self._latest_json.pop(TYPE_MAP_TRANSFORM, None)
            elif frame_type in (
                TYPE_ALGORITHM_STATUS,
                TYPE_CAMERA_TRAJECTORY,
                TYPE_MAP_TRANSFORM,
            ):
                self._latest_json[frame_type] = (snapshot_value, pts_ns)
            self._publish_json_locked(frame_type, value, pts_ns)

    def _publish_json_locked(
        self,
        frame_type: int,
        value: dict[str, Any],
        pts_ns: int,
    ) -> None:
        payload = encode_json(value)
        event = StreamEvent(frame_type, 0, pts_ns, 0, payload)
        if self.event_sink is not None:
            self.event_sink(event)
        self._write_log(event, value)
        self.send_frame(frame_type, 0, pts_ns, 0, payload)
        self.published_frames += 1

    def publish_dense_chunk(self, metadata: dict[str, Any], points: bytes, pts_ns: int = 0) -> None:
        """Send one chunk as manifest -> fragments -> commit.

        The headset only renders a chunk after the commit, so this ordering is
        mandatory; splitting into fragments keeps each OLCP frame bounded.
        """
        with self._state_lock:
            self._publish_dense_chunk_locked(metadata, points, pts_ns, record=True)
            self._remember_chunk_locked(metadata, points, pts_ns)

    def _publish_dense_chunk_locked(
        self,
        metadata: dict[str, Any],
        points: bytes,
        pts_ns: int,
        *,
        record: bool,
    ) -> None:
        chunk_path: Path | None = None
        if record and self.chunk_dir is not None:
            chunk_path = self.chunk_dir / f"{metadata['chunk_id']}.bin"
            chunk_path.write_bytes(points)
        stride = max(1, int(metadata.get("point_stride_bytes", DENSE_POINT.size)))
        fragment_bytes = self.max_fragment_bytes - (self.max_fragment_bytes % stride)
        fragment_bytes = max(stride, fragment_bytes)
        fragment_count = max(1, math.ceil(len(points) / fragment_bytes)) if points else 1
        manifest = {
            "schema": "operator.dense_map_manifest.v1",
            "map_id": metadata.get("map_id", ""),
            "map_version": int(metadata.get("map_version", 0)),
            "submap_id": int(metadata.get("submap_id", 0)),
            "chunks": [
                {
                    "chunk_id": metadata["chunk_id"],
                    "operation": metadata.get("operation", "upsert"),
                    "encoding": metadata.get("encoding", metadata.get("point_format", "")),
                    "point_format": metadata.get("point_format", ""),
                    "point_stride_bytes": int(metadata.get("point_stride_bytes", 0)),
                    "point_count": int(metadata.get("point_count", 0)),
                    "fragment_count": fragment_count,
                    "coordinate_frame": metadata.get("coordinate_frame", "map"),
                    "payload_size_bytes": len(points),
                }
            ],
            "T_openxr_map": metadata.get("T_openxr_map", identity_matrix()),
        }
        if record:
            self._publish_json_locked(TYPE_DENSE_MAP_MANIFEST, manifest, pts_ns)
        else:
            self.send_frame(
                TYPE_DENSE_MAP_MANIFEST,
                0,
                pts_ns,
                0,
                encode_json(manifest),
            )

        for fragment_index in range(fragment_count):
            start = fragment_index * fragment_bytes
            end = min(len(points), start + fragment_bytes)
            fragment = points[start:end]
            fragment_metadata = dict(metadata)
            fragment_metadata.update(
                {
                    "schema": "operator.dense_map_fragment.v1",
                    "fragment_index": fragment_index,
                    "fragment_count": fragment_count,
                    "payload_size_bytes": len(fragment),
                    "total_payload_size_bytes": len(points),
                }
            )
            payload = pack_composite_payload(fragment_metadata, fragment)
            if record:
                event = StreamEvent(
                    TYPE_DENSE_MAP_FRAGMENT,
                    FLAG_COMPOSITE_JSON,
                    pts_ns,
                    0,
                    payload,
                )
                if self.event_sink is not None:
                    self.event_sink(event)
                log_value = dict(fragment_metadata)
                if chunk_path is not None and self.session_dir is not None:
                    log_value["binary_uri"] = str(
                        chunk_path.relative_to(self.session_dir)
                    )
                self._write_log(event, log_value)
            self.send_frame(TYPE_DENSE_MAP_FRAGMENT, FLAG_COMPOSITE_JSON, pts_ns, 0, payload)
            if record:
                self.published_frames += 1

        commit = {
            "schema": "operator.dense_map_commit.v1",
            "map_id": metadata.get("map_id", ""),
            "map_version": int(metadata.get("map_version", 0)),
            "committed_chunks": [metadata["chunk_id"]],
        }
        if record:
            self._publish_json_locked(TYPE_DENSE_MAP_COMMIT, commit, pts_ns)
            self.published_points += int(metadata.get("point_count", 0))
        else:
            self.send_frame(
                TYPE_DENSE_MAP_COMMIT,
                0,
                pts_ns,
                0,
                encode_json(commit),
            )

    def _remember_chunk_locked(
        self,
        metadata: dict[str, Any],
        points: bytes,
        pts_ns: int,
    ) -> None:
        map_id = str(metadata.get("map_id", ""))
        chunk_id = str(metadata.get("chunk_id", ""))
        if not chunk_id:
            return
        key = (map_id, chunk_id)
        previous = self._snapshot_chunks.pop(key, None)
        if previous is not None:
            self._snapshot_point_count -= previous[2]
        if str(metadata.get("operation", "upsert")) == "delete":
            return
        point_count = max(0, int(metadata.get("point_count", 0)))
        self._snapshot_chunks[key] = (
            dict(metadata),
            bytes(points),
            point_count,
            pts_ns,
        )
        self._snapshot_point_count += point_count
        while self._snapshot_chunks and (
            (
                self.max_snapshot_chunks > 0
                and len(self._snapshot_chunks) > self.max_snapshot_chunks
            )
            or (
                self.max_snapshot_points > 0
                and self._snapshot_point_count > self.max_snapshot_points
                # Keep the newest chunk even when it alone exceeds the normal
                # budget; replaying a capped/large current chunk is better than
                # resetting the headset to an empty map.
                and len(self._snapshot_chunks) > 1
            )
        ):
            _, (_, _, removed_points, _) = self._snapshot_chunks.popitem(last=False)
            self._snapshot_point_count -= removed_points

    def replay_snapshot(self) -> int:
        """Reset and rebuild the current headset-visible result state.

        The cache follows the XR renderer's chunk/point budgets, so reconnecting
        never depends on TCP frames that may have been published while the
        headset was absent or on unacknowledged tail bytes from the old socket.
        Returns the number of dense chunks replayed.
        """
        with self._state_lock:
            if self._latest_reset is not None:
                reset, reset_pts_ns = self._latest_reset
                reset = dict(reset)
            else:
                versions = [
                    int(metadata.get("map_version", 0))
                    for metadata, _, _, _ in self._snapshot_chunks.values()
                ]
                first_map_id = (
                    next(iter(self._snapshot_chunks))[0]
                    if self._snapshot_chunks
                    else ""
                )
                reset = {
                    "schema": "operator.map_reset.v1",
                    "map_id": first_map_id,
                    "map_version": max(0, min(versions) - 1) if versions else 0,
                    "reason": "result client snapshot replay",
                }
                reset_pts_ns = 0
            reset["reason"] = "result client snapshot replay"
            self.send_frame(
                TYPE_MAP_RESET,
                0,
                reset_pts_ns,
                0,
                encode_json(reset),
            )
            for metadata, points, _point_count, pts_ns in self._snapshot_chunks.values():
                self._publish_dense_chunk_locked(
                    metadata,
                    points,
                    pts_ns,
                    record=False,
                )
            for frame_type in (
                TYPE_CAMERA_TRAJECTORY,
                TYPE_MAP_TRANSFORM,
                TYPE_ALGORITHM_STATUS,
            ):
                latest = self._latest_json.get(frame_type)
                if latest is None:
                    continue
                value, pts_ns = latest
                self.send_frame(
                    frame_type,
                    0,
                    pts_ns,
                    0,
                    encode_json(value),
                )
            return len(self._snapshot_chunks)

    # -- high level --------------------------------------------------------

    def publish_status(
        self,
        state: str,
        *,
        algorithm: str = "",
        message: str = "",
        pts_ns: int = 0,
        **fields: Any,
    ) -> None:
        """Send an ``algorithm_status`` frame (type 110)."""
        value: dict[str, Any] = {
            "schema": "operator.algorithm_status.v1",
            "algorithm": algorithm,
            "state": state,
        }
        if message:
            value["message"] = message
        value.update(fields)
        self.publish_json(TYPE_ALGORITHM_STATUS, value, pts_ns=pts_ns)

    def reset_map(self, map_id: str, *, reason: str = "new live session", pts_ns: int = 0) -> None:
        """Clear whatever the headset currently renders for ``map_id``."""
        self._map_versions[map_id] = 0
        self._submap_ids[map_id] = 0
        self.publish_json(
            TYPE_MAP_RESET,
            {
                "schema": "operator.map_reset.v1",
                "map_id": map_id,
                "map_version": 0,
                "reason": reason,
            },
            pts_ns=pts_ns,
        )

    def publish_points(
        self,
        *,
        map_id: str,
        points: Sequence[DensePoint] | bytes,
        chunk_id: str | None = None,
        operation: str = "upsert",
        pts_ns: int = 0,
        point_count: int | None = None,
        extra_metadata: dict[str, Any] | None = None,
    ) -> str:
        """Publish a point cloud chunk and return the ``chunk_id`` used.

        ``operation="upsert"`` with a stable ``chunk_id`` replaces the chunk in
        place, which keeps headset memory bounded for a continuously updated
        result such as a trajectory.  Pass a fresh ``chunk_id`` per call to
        accumulate instead.
        """
        if isinstance(points, (bytes, bytearray)):
            payload = bytes(points)
            resolved_count = point_count if point_count is not None else len(payload) // DENSE_POINT.size
        else:
            payload = pack_dense_points(points)
            resolved_count = point_count if point_count is not None else len(points)

        version = self._map_versions.get(map_id, 0) + 1
        submap = self._submap_ids.get(map_id, 0) + 1
        self._map_versions[map_id] = version
        self._submap_ids[map_id] = submap
        resolved_chunk_id = chunk_id or f"{map_id}_chunk_{submap:06d}"

        metadata: dict[str, Any] = {
            "schema": "operator.dense_map_chunk.v1",
            "map_id": map_id,
            "map_version": version,
            "submap_id": submap,
            "chunk_id": resolved_chunk_id,
            "operation": operation,
            "coordinate_frame": "map",
            "T_openxr_map": identity_matrix(),
            "point_format": POINT_FORMAT,
            "encoding": POINT_FORMAT,
            "point_stride_bytes": DENSE_POINT.size,
            "point_count": resolved_count,
        }
        if extra_metadata:
            metadata.update(extra_metadata)
        self.publish_dense_chunk(metadata, payload, pts_ns=pts_ns)
        return resolved_chunk_id

    def publish_trajectory(
        self,
        map_id: str,
        poses: Sequence[Any],
        *,
        pts_ns: int = 0,
        max_poses: int = 60,
    ) -> None:
        """Send a ``camera_trajectory`` frame from an iterable of ``PoseSample``."""
        from .models import transform_to_matrix

        selected = list(poses)[-max_poses:]
        self.publish_json(
            TYPE_CAMERA_TRAJECTORY,
            {
                "schema": "operator.camera_trajectory.v1",
                "map_id": map_id,
                "map_version": self._map_versions.get(map_id, 0),
                "coordinate_frame": "map",
                "poses": [
                    {
                        "frame_id": index,
                        "pts_ns": pose.pts_ns,
                        "T_map_camera": transform_to_matrix(pose.transform),
                    }
                    for index, pose in enumerate(selected)
                ],
            },
            pts_ns=pts_ns,
        )

    def publish_map_transform(self, map_id: str, matrix: list[list[float]] | None = None, *, pts_ns: int = 0) -> None:
        self.publish_json(
            TYPE_MAP_TRANSFORM,
            {
                "schema": "operator.map_transform.v1",
                "map_id": map_id,
                "map_version": self._map_versions.get(map_id, 0),
                "T_openxr_map": matrix or identity_matrix(),
            },
            pts_ns=pts_ns,
        )

    def map_version(self, map_id: str) -> int:
        return self._map_versions.get(map_id, 0)

    def _write_log(self, event: StreamEvent, value: dict[str, Any]) -> None:
        if self._log is None:
            return
        record = {
            "recv_monotonic_ns": event.recv_monotonic_ns,
            "frame_type": event.frame_type,
            "flags": event.flags,
            "pts_ns": event.pts_ns,
            "payload": value,
        }
        self._log.write(json.dumps(record, sort_keys=True) + "\n")
        self._log.flush()


def monotonic_pts_ns() -> int:
    """Timestamp in the same domain the headset uses for OLCP ``pts_ns``."""
    return time.monotonic_ns()
