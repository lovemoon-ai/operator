"""Convenience singleton API: ``xr_bridge.start()`` then read whole frames."""

from __future__ import annotations

from typing import Iterator

from .models import BridgeStats, XrFrame
from .session import BridgeConfig, XrSession

_default_session: XrSession | None = None


def start(**config: object) -> XrSession:
    global _default_session
    if _default_session is not None and _default_session.is_running:
        return _default_session
    _default_session = XrSession(BridgeConfig(**config)).start()
    return _default_session


def stop() -> None:
    global _default_session
    if _default_session is not None:
        _default_session.close()
        _default_session = None


def session() -> XrSession:
    if _default_session is None:
        raise RuntimeError("xr_bridge.start() must be called first")
    return _default_session


def latest() -> XrFrame | None:
    return session().latest()


def wait_next(after_frame_id: int = 0, timeout: float | None = None) -> XrFrame | None:
    return session().wait_next(after_frame_id, timeout)


def frames(timeout: float | None = None) -> Iterator[XrFrame]:
    return session().frames(timeout)


def stats() -> BridgeStats:
    return session().stats()
