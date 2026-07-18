"""Socket client, framing codec, and background reader for the `vr_operator` link.

Mirror image of the Rust `LinkCodec` in
`robot/crates/robot-adapter/src/control/drivers/lerobot_link.rs`.

Framing is ``[4B len LE][JSON]``. The Rust adapter listens; this module dials in
as a client and reconnects with backoff, so either process may restart without
taking the other down.

Threading model
---------------
`VRLink` owns a daemon reader thread. That thread is the only reader of the
socket; it writes the latest `Control` state and the latest `TargetSample` into
slots guarded by a lock. `Teleoperator.get_action()` reads those slots without
blocking, which matters because the stock `teleop_loop` is single-threaded and
sleeps `1/fps - dt` with no drift compensation -- any blocking read here would
directly stretch the control loop period.
"""

from __future__ import annotations

import json
import logging
import socket
import struct
import threading
import time
from dataclasses import dataclass, field
from typing import Any

logger = logging.getLogger(__name__)

# Must match `MAX_FRAME_LEN` in lerobot_link.rs. Frames are tiny; anything
# larger is protocol corruption.
MAX_FRAME_LEN = 1024 * 1024

# Reconnect backoff bounds.
_BACKOFF_INITIAL_S = 0.02
_BACKOFF_MAX_S = 1.0

# Reader poll granularity, so `stop()` is responsive without a self-pipe.
_RECV_TIMEOUT_S = 0.2
_RECV_CHUNK = 65536


# ---------------------------------------------------------------------------
# Codec
# ---------------------------------------------------------------------------


def encode_frame(obj: dict[str, Any]) -> bytes:
    """Encode a message as ``[4B len LE][JSON]``."""
    payload = json.dumps(obj, separators=(",", ":")).encode()
    if len(payload) > MAX_FRAME_LEN:
        raise ValueError(f"frame too large: {len(payload)} bytes")
    return struct.pack("<I", len(payload)) + payload


class FrameDecoder:
    """Incremental decoder for ``[4B len LE][JSON]`` streams.

    Tolerates frames split across arbitrary `recv()` boundaries, which a plain
    "read 4 then read n" loop only handles by blocking.
    """

    def __init__(self) -> None:
        self._buf = bytearray()

    def reset(self) -> None:
        """Drop buffered bytes. Called on reconnect so a truncated frame from a
        dead socket cannot corrupt the next connection's stream."""
        self._buf.clear()

    def feed(self, data: bytes) -> list[dict[str, Any]]:
        """Append bytes and return every complete message now decodable."""
        self._buf.extend(data)
        out: list[dict[str, Any]] = []
        while True:
            if len(self._buf) < 4:
                return out
            (length,) = struct.unpack("<I", self._buf[:4])
            if length > MAX_FRAME_LEN:
                raise ValueError(f"frame length {length} exceeds maximum {MAX_FRAME_LEN}")
            if len(self._buf) < 4 + length:
                return out
            body = bytes(self._buf[4 : 4 + length])
            del self._buf[: 4 + length]
            out.append(json.loads(body))


def parse_endpoint(endpoint: str) -> tuple[int, Any]:
    """Parse the Rust `Endpoint` string form into `(family, address)`.

    Accepts ``uds:<path>`` and ``tcp:<host>:<port>`` -- the exact strings the
    Rust `Endpoint::Display` impl produces.
    """
    if endpoint.startswith("uds:"):
        path = endpoint[len("uds:") :]
        if not path:
            raise ValueError("empty uds path")
        return socket.AF_UNIX, path
    if endpoint.startswith("tcp:"):
        rest = endpoint[len("tcp:") :]
        host, sep, port = rest.rpartition(":")
        if not sep or not host or not port:
            raise ValueError(f"invalid tcp address {rest!r}; expected tcp:<host>:<port>")
        try:
            port_num = int(port)
        except ValueError as e:
            raise ValueError(f"invalid tcp port {port!r}") from e
        return socket.AF_INET, (host, port_num)
    raise ValueError(f"unknown scheme in {endpoint!r}; expected 'uds:<path>' or 'tcp:<host>:<port>'")


# ---------------------------------------------------------------------------
# Wire state
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class ControlState:
    """Latched control state from the adapter.

    Defaults are the safe state: an unseeded or freshly disconnected link is
    *disabled*, so `get_action()` holds the last setpoint until the adapter says
    otherwise.
    """

    enabled: bool = False
    stopped: bool = False
    reset_epoch: int = 0


@dataclass(frozen=True)
class TargetSample:
    """One `Target` frame, plus when we received it.

    Exactly one of `ee_position`/`positions` is normally set; both may be `None`
    for a gripper-only update.
    """

    ee_position: list[float] | None = None
    ee_rotation: list[float] | None = None  # quaternion, xyzw
    positions: list[float] | None = None  # 5 arm joints, degrees (direct mode)
    gripper: float | None = None  # normalized 0..1
    seq: int = 0
    # Local monotonic receipt time. Staleness is judged against this rather than
    # the wire `ts_ns`, which comes from another process's wall clock.
    recv_monotonic: float = field(default_factory=time.monotonic)
    # Adapter-side wall clock (ns, UNIX epoch) when this Target was published to
    # the UDS, stamped by `lerobot_link.rs::now_ns`. Same host + same clock base
    # as `time.time_ns()`, so `time.time_ns() - ts_ns` is the true
    # publish->consume latency. 0 means the adapter did not stamp it.
    ts_ns: int = 0


class VRLink:
    """Reconnecting client for the adapter's `lerobot_link` listener."""

    def __init__(self, endpoint: str, connect_timeout_s: float) -> None:
        self._endpoint = endpoint
        self._family, self._address = parse_endpoint(endpoint)
        self._connect_timeout_s = connect_timeout_s

        self._lock = threading.Lock()
        # Serializes all writes to the socket. Two threads send: the reader
        # thread emits `Hello` from `_connect_once` on every (re)connect, while
        # the teleop-loop thread emits `State`/`Error` via `send()`. Without this
        # their `sendall`s can interleave into a corrupt frame the adapter
        # rejects, or land State-before-Hello. Held across each whole frame, and
        # across "publish socket + send Hello" so Hello is always first. Never
        # held together with a blocking read, so it cannot stall the reader.
        self._send_lock = threading.Lock()
        self._sock: socket.socket | None = None
        self._decoder = FrameDecoder()

        self._control = ControlState()
        self._target: TargetSample | None = None
        self._hello: dict[str, Any] | None = None

        # Reset is an edge, but `reset_epoch` is only monotonic *within one
        # adapter process*: a robot-service restart sends it back to 0. Comparing
        # raw epochs across a reconnect would make every future reset look stale
        # (0 is never > the last-seen 3) and silently stop working. So we track a
        # per-connection baseline instead: the first Control of each connection
        # is adopted as the baseline without firing, and any later change bumps a
        # process-monotonic `reset_generation` the plugin watches.
        self._conn_has_reset_baseline = False
        self._reset_generation = 0

        self._stop = threading.Event()
        self._thread: threading.Thread | None = None

    # -- lifecycle ---------------------------------------------------------

    @property
    def endpoint(self) -> str:
        return self._endpoint

    @property
    def is_running(self) -> bool:
        return self._thread is not None and self._thread.is_alive()

    @property
    def is_socket_connected(self) -> bool:
        with self._lock:
            return self._sock is not None

    def set_hello(self, payload: dict[str, Any]) -> None:
        """Store the `Hello` payload sent on every (re)connect.

        The payload is precomputed by the caller rather than derived here: it
        needs forward kinematics, and placo must only ever be touched from the
        thread that owns the solver.
        """
        with self._lock:
            self._hello = payload

    def start(self) -> None:
        """Connect (blocking, with retry) and start the reader thread.

        Raises:
            ConnectionError: if the adapter does not accept within the timeout.
        """
        if self._hello is None:
            raise RuntimeError("set_hello() must be called before start()")

        deadline = time.monotonic() + self._connect_timeout_s
        backoff = _BACKOFF_INITIAL_S
        last_err: Exception | None = None
        announced = False
        while time.monotonic() < deadline:
            try:
                self._connect_once()
                break
            except OSError as e:  # adapter not listening yet
                last_err = e
                if not announced:
                    logger.info(
                        "Waiting for the Operator adapter to listen on %s "
                        "(start `robot-service` with a `lerobot_link` arm driver)...",
                        self._endpoint,
                    )
                    announced = True
                time.sleep(backoff)
                backoff = min(backoff * 2, _BACKOFF_MAX_S)
        else:
            raise ConnectionError(
                f"could not connect to the Operator adapter at {self._endpoint} within "
                f"{self._connect_timeout_s:.1f}s: {last_err}. Start the adapter first "
                f"(`robot-service --config configs/so101_lerobot.yaml`), or point "
                f"--teleop.endpoint at the right socket."
            )

        self._stop.clear()
        self._thread = threading.Thread(target=self._run, name="vr-operator-link", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        """Stop the reader thread and close the socket."""
        self._stop.set()
        self._close_socket()
        if self._thread is not None:
            self._thread.join(timeout=2.0)
            self._thread = None

    # -- reads / writes ----------------------------------------------------

    def control(self) -> ControlState:
        with self._lock:
            return self._control

    def reset_generation(self) -> int:
        """Process-monotonic counter, bumped once per reset the adapter requests.

        Survives adapter restarts (see `__init__`): the plugin compares this
        against its own last-seen value instead of comparing raw `reset_epoch`s.
        """
        with self._lock:
            return self._reset_generation

    def latest_target(self) -> TargetSample | None:
        """Latest target, or `None`. Non-blocking; latest-wins."""
        with self._lock:
            return self._target

    def send(self, obj: dict[str, Any]) -> None:
        """Best-effort write. Drops (and logs) if the socket is down.

        Deliberately never raises: a disconnected adapter must not take down the
        teleop loop, and the reader thread will reconnect on its own.
        """
        frame = encode_frame(obj)
        # Hold `_send_lock` across the whole write so it cannot interleave with
        # the reader thread's `Hello`. Re-read the socket under it, so a reconnect
        # that swapped the socket while we waited is respected.
        with self._send_lock:
            with self._lock:
                sock = self._sock
            if sock is None:
                return
            try:
                sock.sendall(frame)
            except OSError as e:
                logger.debug("link send failed (%s); reader thread will reconnect", e)
                self._close_socket()

    # -- internals ---------------------------------------------------------

    def _connect_once(self) -> None:
        sock = socket.socket(self._family, socket.SOCK_STREAM)
        try:
            sock.settimeout(max(_RECV_TIMEOUT_S, 1.0))
            sock.connect(self._address)
            if self._family == socket.AF_INET:
                # Targets are small and latency-critical; never coalesce them.
                sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            sock.settimeout(_RECV_TIMEOUT_S)
        except OSError:
            sock.close()
            raise

        # Hold `_send_lock` across publishing the socket AND sending Hello, so no
        # `send()` from the teleop thread can slip a State frame in before Hello.
        with self._send_lock:
            with self._lock:
                self._sock = sock
                self._decoder.reset()
                # Next Control frame is this connection's reset baseline, not an edge.
                self._conn_has_reset_baseline = False
                hello = self._hello

            # Hello must be the first frame: the adapter blocks its device
            # connect until it arrives, having no forward kinematics of its own.
            try:
                sock.sendall(encode_frame(dict(hello)))
            except OSError:
                self._close_socket()
                raise
        logger.info("Connected to the Operator adapter at %s; sent Hello", self._endpoint)

    def _close_socket(self) -> None:
        with self._lock:
            sock, self._sock = self._sock, None
            # A dropped link means the adapter's latched state is unknown to us.
            # Fall back to the safe state so a stale `enabled=True` cannot keep
            # driving the arm; the adapter re-sends `Control` on reconnect.
            self._control = ControlState(reset_epoch=self._control.reset_epoch)
            self._target = None
        if sock is not None:
            try:
                sock.close()
            except OSError:
                pass

    def _run(self) -> None:
        backoff = _BACKOFF_INITIAL_S
        while not self._stop.is_set():
            with self._lock:
                sock = self._sock

            if sock is None:
                try:
                    self._connect_once()
                    backoff = _BACKOFF_INITIAL_S
                except OSError as e:
                    logger.debug("reconnect to %s failed (%s)", self._endpoint, e)
                    self._stop.wait(backoff)
                    backoff = min(backoff * 2, _BACKOFF_MAX_S)
                continue

            try:
                data = sock.recv(_RECV_CHUNK)
            except TimeoutError:
                # Poll timeout, not a fault: loop so `stop()` stays responsive.
                continue
            except OSError as e:
                logger.warning("link read failed (%s); reconnecting to %s", e, self._endpoint)
                self._close_socket()
                continue

            if not data:
                logger.warning("adapter closed the link; reconnecting to %s", self._endpoint)
                self._close_socket()
                continue

            try:
                messages = self._decoder.feed(data)
            except (ValueError, json.JSONDecodeError) as e:
                logger.error("protocol error on %s (%s); reconnecting", self._endpoint, e)
                self._close_socket()
                continue

            self._apply_all(messages)

    def _apply_all(self, messages: list[dict[str, Any]]) -> None:
        """Apply each decoded message, guarding every one individually.

        A malformed frame (missing key, bad type) must not kill the daemon
        reader thread: that would flip `is_running` to False and surface at the
        next `get_action()` as a misleading DeviceNotConnectedError, hiding the
        real cause. Framing is already validated by the decoder, so a bad message
        is one message, not stream corruption -- log it and move on.
        """
        for msg in messages:
            try:
                self._apply(msg)
            except Exception:
                logger.exception("ignoring malformed frame from %s: %r", self._endpoint, msg)

    def _apply(self, msg: dict[str, Any]) -> None:
        kind = msg.get("type")
        if kind == "Control":
            epoch = int(msg.get("reset_epoch", 0))
            with self._lock:
                if not self._conn_has_reset_baseline:
                    # First Control of this connection: adopt as baseline. A
                    # reconnect (incl. a restarted adapter whose epoch reset to 0)
                    # must not read as a reset request.
                    self._conn_has_reset_baseline = True
                elif epoch != self._control.reset_epoch:
                    # Within a connection the adapter only ever increments, so any
                    # change is a genuine reset edge.
                    self._reset_generation += 1
                self._control = ControlState(
                    enabled=bool(msg.get("enabled", False)),
                    stopped=bool(msg.get("stopped", False)),
                    reset_epoch=epoch,
                )
            return

        if kind == "Target":
            ee = msg.get("ee_pose")
            positions = msg.get("positions")
            gripper = msg.get("gripper")
            sample = TargetSample(
                ee_position=[float(v) for v in ee["position"]] if ee else None,
                ee_rotation=[float(v) for v in ee["rotation"]] if ee else None,
                positions=[float(v) for v in positions] if positions is not None else None,
                gripper=float(gripper) if gripper is not None else None,
                seq=int(msg.get("seq", 0)),
                recv_monotonic=time.monotonic(),
                ts_ns=int(msg.get("ts_ns", 0)),
            )
            with self._lock:
                self._target = sample
            return

        logger.warning("ignoring unknown message type %r from the adapter", kind)
