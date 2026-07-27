"""Retargeting service: the Operator wire protocol in front of a solver runtime.

This is a translation layer, deliberately thin. It owns the connection —
handshake, session lifetime, latest-only backpressure, error envelopes — and
delegates every numeric decision to the `retargeting` library:

    XR app --ws--> RetargetingConnection --solve()--> retargeting runtime

Used by Operator's Inside Robot "remote retargeting" backend: only the solve
runs here; the simulation and robot rendering stay in the headset.

:class:`RetargetingConnection` is transport-free so the protocol can be tested
without a socket; :func:`create_app` binds it to FastAPI/uvicorn.
"""

from __future__ import annotations

import argparse
import asyncio
import contextlib
import logging
from typing import Any, Mapping

from ..integrations.retargeting import (
    input_from_payload,
    require_retargeting,
    result_to_wire,
)
from ..protocol.retargeting import (
    FRAME_TYPE,
    HELLO_ACK_TYPE,
    PROTOCOL_VERSION,
    RESET_ACK_TYPE,
    RESET_TYPE,
    ProtocolError,
    error_message,
    frame_id_of,
    parse_frame_envelope,
    parse_hello,
    require_mapping,
)

LOGGER = logging.getLogger(__name__)

DEFAULT_PORT = 8000
HEALTH_PATH = "/healthz"
PROFILES_PATH = "/v1/profiles"
RETARGET_PATH = "/v1/retarget"


def default_runtime():
    """The retargeting runtime this host serves profiles from."""
    return require_retargeting().RetargetingRuntime()


class RetargetingConnection:
    """One client connection: negotiate a profile, then solve its frames.

    The caller drives it with decoded JSON messages and sends back whatever it
    returns. Nothing here touches a socket, so the whole protocol — including
    every rejection path — is exercisable in a unit test.
    """

    def __init__(self, runtime):
        self._runtime = runtime
        self._session = None
        self._profile = None

    @property
    def profile(self):
        return self._profile

    def hello(self, message: Any) -> dict[str, Any]:
        """Validate the handshake and open a session. Raises ProtocolError."""
        if self._session is not None:
            raise ProtocolError("invalid_message", "session is already established")
        hello = parse_hello(message)
        try:
            profile = self._runtime.describe_profile(hello.profile_id)
        except KeyError as exc:
            raise ProtocolError("unknown_profile", str(exc)) from exc
        if not profile.available:
            raise ProtocolError("profile_unavailable", profile.unavailable_reason)
        if hello.input_type != profile.input_type:
            raise ProtocolError(
                "input_type_mismatch",
                f"profile expects {profile.input_type}, got {hello.input_type}",
            )
        # An empty client hash means "I trust the host"; a mismatching one means
        # the two sides would be solving against different models.
        if hello.model_hash and hello.model_hash != profile.model_hash:
            raise ProtocolError(
                "model_mismatch", f"profile model hash is {profile.model_hash}"
            )
        self._session = self._runtime.create_session(profile.profile_id)
        self._profile = profile
        return {
            "type": HELLO_ACK_TYPE,
            "protocol_version": PROTOCOL_VERSION,
            "profile": profile.public_dict(),
        }

    def handle(self, message: Any) -> dict[str, Any] | None:
        """Handle one post-handshake message and return the reply, if any."""
        if self._session is None:
            raise ProtocolError("hello_required", "session has not been established")
        raw: Mapping[str, Any] = require_mapping(message)
        kind = raw.get("type")
        if kind == RESET_TYPE:
            self._session.reset()
            return {"type": RESET_ACK_TYPE}
        if kind != FRAME_TYPE:
            raise ProtocolError("invalid_message", f"unexpected message type '{kind}'")
        request = parse_frame_envelope(raw)
        source = input_from_payload(
            request.payload, self._profile.input_type, request.timestamp_ns
        )
        result = self._session.solve(source)
        return result_to_wire(result, request).to_wire()

    def is_healthy(self) -> bool:
        return self._session is None or self._session.is_healthy()

    def close(self) -> None:
        if self._session is not None:
            self._session.close()
            self._session = None


def create_app(runtime=None):
    """A FastAPI app exposing health, profile discovery, and the solve socket."""
    try:
        from fastapi import FastAPI, WebSocket, WebSocketDisconnect
    except ImportError as exc:  # pragma: no cover - exercised by deployments
        raise RuntimeError(
            "the retargeting service requires its extra: "
            "pip install 'pyoperator[retargeting]'"
        ) from exc

    # ``from __future__ import annotations`` stores the endpoint annotation as
    # the string "WebSocket"; FastAPI resolves it against module globals.
    globals()["WebSocket"] = WebSocket

    solver_runtime = runtime if runtime is not None else default_runtime()
    app = FastAPI(title="pyoperator-retargeting", version=str(PROTOCOL_VERSION))

    @app.get(HEALTH_PATH)
    async def healthz() -> dict[str, Any]:
        available = solver_runtime.list_profiles(include_unavailable=False)
        return {
            "status": "ok",
            "protocol_version": PROTOCOL_VERSION,
            "available_profiles": [profile.profile_id for profile in available],
        }

    @app.get(PROFILES_PATH)
    async def list_profiles() -> dict[str, Any]:
        return {
            "protocol_version": PROTOCOL_VERSION,
            "profiles": [
                profile.public_dict() for profile in solver_runtime.list_profiles()
            ],
        }

    @app.websocket(RETARGET_PATH)
    async def retarget(websocket: WebSocket) -> None:
        await websocket.accept()
        connection = RetargetingConnection(solver_runtime)
        receiver: asyncio.Task | None = None
        try:
            await websocket.send_json(connection.hello(await websocket.receive_json()))
            # Frames are coalesced by `_replace_latest`, while ordered control
            # messages such as reset must be allowed to wait beside one frame.
            queue: asyncio.Queue[dict[str, Any]] = asyncio.Queue(
                maxsize=MAX_PENDING_MESSAGES
            )
            receiver = asyncio.create_task(_receive_latest(websocket, queue))
            while True:
                message = await queue.get()
                kind = message.get("type")
                if kind == _DISCONNECT_TYPE:
                    break
                if kind == _PROTOCOL_ERROR_TYPE:
                    await websocket.send_json(
                        error_message(message["code"], message["message"])
                    )
                    await websocket.close(code=1008, reason="invalid client message")
                    break
                try:
                    # Solving is CPU-bound; keep the receive loop responsive so
                    # a slow frame is superseded rather than queued behind.
                    reply = await asyncio.to_thread(connection.handle, message)
                    if reply is not None:
                        await websocket.send_json(reply)
                except ProtocolError as exc:
                    await websocket.send_json(
                        error_message(exc.code, str(exc), frame_id_of(message))
                    )
                except Exception as exc:  # one bad solve must not kill the socket
                    LOGGER.warning("retargeting solve failed: %s", exc)
                    await websocket.send_json(
                        error_message("retargeting_failed", str(exc), frame_id_of(message))
                    )
                    if not connection.is_healthy():
                        await websocket.close(
                            code=1011, reason="retargeting session unavailable"
                        )
                        return
        except WebSocketDisconnect:
            pass
        except ProtocolError as exc:
            await websocket.send_json(error_message(exc.code, str(exc)))
            await websocket.close(code=_CLOSE_CODES.get(exc.code, 1008))
        except ValueError as exc:  # includes JSONDecodeError
            await websocket.send_json(error_message("invalid_json", str(exc)))
            await websocket.close(code=1008)
        finally:
            if receiver is not None:
                receiver.cancel()
                with contextlib.suppress(asyncio.CancelledError):
                    await receiver
            connection.close()

    return app


_DISCONNECT_TYPE = "_disconnect"
_PROTOCOL_ERROR_TYPE = "_protocol_error"
MAX_PENDING_CONTROL_MESSAGES = 8
MAX_PENDING_MESSAGES = MAX_PENDING_CONTROL_MESSAGES + 1

#: A host that simply cannot serve this profile right now is "try again later"
#: (1013), not a protocol violation (1008); the rest are the client's fault.
_CLOSE_CODES = {"profile_unavailable": 1013}


async def _receive_latest(websocket, queue: "asyncio.Queue[dict[str, Any]]") -> None:
    """Receive messages, coalescing frames without reordering control messages."""
    try:
        while True:
            try:
                message = await websocket.receive_json()
            except ValueError as exc:
                _replace_latest(
                    queue,
                    {
                        "type": _PROTOCOL_ERROR_TYPE,
                        "code": "invalid_json",
                        "message": str(exc),
                    },
                )
                return
            if not isinstance(message, dict):
                _replace_latest(
                    queue,
                    {
                        "type": _PROTOCOL_ERROR_TYPE,
                        "code": "invalid_message",
                        "message": "message must be an object",
                    },
                )
                return
            if message.get("type") not in {FRAME_TYPE, RESET_TYPE}:
                _replace_latest(
                    queue,
                    {
                        "type": _PROTOCOL_ERROR_TYPE,
                        "code": "invalid_message",
                        "message": f"unexpected message type '{message.get('type')}'",
                    },
                )
                return
            if not _replace_latest(queue, message):
                return
    except asyncio.CancelledError:
        raise
    except Exception as exc:
        # Wake the processing loop on disconnect or receive failure; the socket
        # layer already recorded the reason. No stale frame may outlive the peer.
        _replace_latest(queue, {"type": _DISCONNECT_TYPE, "reason": str(exc)})


def _replace_latest(
    queue: "asyncio.Queue[dict[str, Any]]", message: dict[str, Any]
) -> bool:
    """Enqueue one message while keeping only the newest pending frame.

    `reset` is an ordering barrier: dropping one silently preserves stale solver
    state. At most ``MAX_PENDING_CONTROL_MESSAGES`` barriers may wait beside
    one frame. A terminal message clears all queued work and returns ``False``
    so the receiver stops reading from a peer that has violated the protocol.
    """
    kind = message.get("type")
    if kind in {_DISCONNECT_TYPE, _PROTOCOL_ERROR_TYPE}:
        _clear_queue(queue)
        queue.put_nowait(message)
        return False

    pending: list[dict[str, Any]] = []
    while True:
        try:
            pending.append(queue.get_nowait())
        except asyncio.QueueEmpty:
            break
    if kind == FRAME_TYPE:
        pending = [item for item in pending if item.get("type") != FRAME_TYPE]
    elif sum(item.get("type") == RESET_TYPE for item in pending) >= (
        MAX_PENDING_CONTROL_MESSAGES
    ):
        queue.put_nowait(
            {
                "type": _PROTOCOL_ERROR_TYPE,
                "code": "too_many_pending_messages",
                "message": (
                    "too many reset messages are waiting for the retargeting solver"
                ),
            }
        )
        return False

    needed = len(pending) + 1
    if queue.maxsize > 0 and needed > queue.maxsize:
        queue.put_nowait(
            {
                "type": _PROTOCOL_ERROR_TYPE,
                "code": "too_many_pending_messages",
                "message": "the retargeting message queue is full",
            }
        )
        return False
    for item in pending:
        queue.put_nowait(item)
    queue.put_nowait(message)
    return True


def _clear_queue(queue: "asyncio.Queue[dict[str, Any]]") -> None:
    while True:
        try:
            queue.get_nowait()
        except asyncio.QueueEmpty:
            return


def serve(host: str = "0.0.0.0", port: int = DEFAULT_PORT, log_level: str = "info") -> None:
    """Run the service until interrupted."""
    try:
        import uvicorn
    except ImportError as exc:
        raise SystemExit(
            "the retargeting service requires its extra: "
            "pip install 'pyoperator[retargeting]'"
        ) from exc
    uvicorn.run(create_app(), host=host, port=port, log_level=log_level)


def add_arguments(parser: argparse.ArgumentParser) -> argparse.ArgumentParser:
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--log-level", default="info")
    return parser


def main(argv: list[str] | None = None) -> None:
    """`retargeting-service` entry point (kept for existing deployments)."""
    parser = add_arguments(
        argparse.ArgumentParser(description="Serve Operator retargeting over WebSocket")
    )
    args = parser.parse_args(argv)
    serve(host=args.host, port=args.port, log_level=args.log_level)
