"""Synchronous and asynchronous session APIs."""

from __future__ import annotations

import asyncio
from dataclasses import dataclass
import json
from typing import Any, Callable, Iterator

from .models import BridgeStats, XrFrame, frame_from_json

try:
    from ._native import NativeSession as _NativeSession
except ImportError as _native_import_error:  # pure-Python tools still import cleanly
    _NativeSession = None
else:
    _native_import_error = None


@dataclass(frozen=True)
class BridgeConfig:
    name: str = "pyoperator"
    pose_port: int = 63901
    discovery_port: int = 63900
    pose_udp_port: int = 63902
    telemetry_port: int = 63903
    discovery_unicast_targets: tuple[str, ...] = ()


class XrSession:
    def __init__(
        self,
        config: BridgeConfig | None = None,
        *,
        _native_factory: Callable[..., Any] | None = None,
    ) -> None:
        self.config = config or BridgeConfig()
        factory = _native_factory or _NativeSession
        if factory is None:
            raise RuntimeError(
                "pyoperator native extension is not installed; run "
                "`pip install -e ./python` from the Operator repository"
            ) from _native_import_error
        self._native = factory(
            name=self.config.name,
            pose_port=self.config.pose_port,
            discovery_port=self.config.discovery_port,
            pose_udp_port=self.config.pose_udp_port,
            telemetry_port=self.config.telemetry_port,
            discovery_unicast_targets=list(self.config.discovery_unicast_targets),
        )

    def start(self) -> "XrSession":
        self._native.start()
        return self

    def close(self) -> None:
        self._native.close()

    def __enter__(self) -> "XrSession":
        return self.start()

    def __exit__(self, *_: object) -> None:
        self.close()

    @property
    def is_running(self) -> bool:
        return bool(self._native.is_running())

    def latest(self) -> XrFrame | None:
        payload = self._native.latest_json()
        return frame_from_json(payload) if payload is not None else None

    def wait_next(
        self, after_frame_id: int = 0, timeout: float | None = None
    ) -> XrFrame | None:
        payload = self._native.wait_next_json(after_frame_id, timeout)
        return frame_from_json(payload) if payload is not None else None

    async def wait_next_async(
        self, after_frame_id: int = 0, timeout: float | None = None
    ) -> XrFrame | None:
        return await asyncio.to_thread(self.wait_next, after_frame_id, timeout)

    def frames(self, timeout: float | None = None) -> Iterator[XrFrame]:
        frame_id = 0
        while self.is_running:
            frame = self.wait_next(frame_id, timeout)
            if frame is None:
                continue
            frame_id = frame.frame_id
            yield frame

    def stats(self) -> BridgeStats:
        data = json.loads(self._native.stats_json())
        return BridgeStats(
            running=bool(data.get("running", False)),
            connected=bool(data.get("connected", False)),
            frames_received=int(data.get("frames_received", 0)),
            parse_errors=int(data.get("parse_errors", 0)),
            last_frame_id=int(data.get("last_frame_id", 0)),
            last_timestamp_ns=int(data.get("last_timestamp_ns", 0)),
            last_error=data.get("last_error"),
        )
