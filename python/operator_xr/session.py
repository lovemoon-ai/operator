"""Synchronous and asynchronous session APIs."""

from __future__ import annotations

import asyncio
from dataclasses import dataclass
import json
from typing import Any, Callable, Iterator

from .models import BridgeStats, XrFrame, frame_from_json
from .blueprint import BlueprintClient

try:
    from ._native import NativeSession as _NativeSession
except ImportError as error:  # pure-Python tools still import cleanly
    _NativeSession = None
    _native_import_error = error
else:
    _native_import_error = None


DEFAULT_XR_STREAMS = ("head", "controllers", "hands")
XR_STREAMS = frozenset((*DEFAULT_XR_STREAMS, "body", "motion_trackers"))
VIDEO_TRANSPORTS = frozenset(("tcp", "udp", "auto"))
VIDEO_CODECS = frozenset(("h264", "hevc"))


@dataclass(frozen=True)
class VideoFeedConfig:
    """One host video source advertised and relayed to Operator XR.

    Exactly one of ``rtsp_url`` and ``command`` must be configured. Command
    sources write an Annex-B elementary stream to stdout.
    """

    name: str
    tcp_port: int
    rtsp_url: str | None = None
    command: tuple[str, ...] = ()
    udp_port: int | None = None
    width: int = 1280
    height: int = 720
    fps: int = 30
    transport: str = "tcp"
    codec: str = "h264"
    stereo: bool = False

    def __post_init__(self) -> None:
        if not isinstance(self.name, str) or not self.name.strip():
            raise ValueError("video feed name must not be empty")
        has_rtsp = isinstance(self.rtsp_url, str) and bool(self.rtsp_url.strip())
        if not isinstance(self.command, (tuple, list)):
            raise ValueError("video feed command must be a sequence")
        command = tuple(self.command)
        has_command = bool(command) and all(
            isinstance(part, str) and part for part in command
        )
        if has_rtsp == has_command:
            raise ValueError(
                "video feed must configure exactly one of rtsp_url or command"
            )
        if not 1 <= int(self.tcp_port) <= 65535:
            raise ValueError("video feed tcp_port must be in 1..65535")
        if self.udp_port is not None and not 1 <= int(self.udp_port) <= 65535:
            raise ValueError("video feed udp_port must be in 1..65535")
        if min(int(self.width), int(self.height), int(self.fps)) <= 0:
            raise ValueError("video feed width, height, and fps must be positive")
        if self.transport not in VIDEO_TRANSPORTS:
            raise ValueError(
                f"video feed transport must be one of {sorted(VIDEO_TRANSPORTS)}"
            )
        if self.codec not in VIDEO_CODECS:
            raise ValueError(
                f"video feed codec must be one of {sorted(VIDEO_CODECS)}"
            )
        object.__setattr__(self, "command", command)

    def to_dict(self) -> dict[str, Any]:
        return {
            "name": self.name,
            "rtsp_url": self.rtsp_url,
            "command": list(self.command),
            "tcp_port": int(self.tcp_port),
            "udp_port": self.udp_port,
            "width": int(self.width),
            "height": int(self.height),
            "fps": int(self.fps),
            "transport": self.transport,
            "codec": self.codec,
            "stereo": bool(self.stereo),
        }


@dataclass(frozen=True)
class BridgeConfig:
    """Requested XR data; body/motion tracking (and its calibration) is opt-in.

    Empty requests are rejected because legacy XR interprets them as all streams.
    """
    name: str = "pyoperator"
    pose_port: int = 63901
    discovery_port: int = 63900
    pose_udp_port: int = 63902
    telemetry_port: int = 63903
    discovery_unicast_targets: tuple[str, ...] = ()
    streams: tuple[str, ...] = DEFAULT_XR_STREAMS
    video_feeds: tuple[VideoFeedConfig, ...] = ()

    def __post_init__(self) -> None:
        if not isinstance(self.streams, (tuple, list)) or not self.streams:
            raise ValueError("streams must be a non-empty sequence of explicit XR stream names")
        if any(not isinstance(s, str) or s not in XR_STREAMS for s in self.streams):
            raise ValueError(f"streams must contain only {sorted(XR_STREAMS)}")
        if len(set(self.streams)) != len(self.streams):
            raise ValueError("streams must not contain duplicates")
        object.__setattr__(self, "streams", tuple(self.streams))
        if not isinstance(self.video_feeds, (tuple, list)):
            raise ValueError("video_feeds must be a sequence")
        feeds = tuple(self.video_feeds)
        if any(not isinstance(feed, VideoFeedConfig) for feed in feeds):
            raise ValueError("video_feeds must contain VideoFeedConfig values")
        if len({feed.name for feed in feeds}) != len(feeds):
            raise ValueError("video feed names must not contain duplicates")
        if len({feed.tcp_port for feed in feeds}) != len(feeds):
            raise ValueError("video feed tcp ports must not contain duplicates")
        object.__setattr__(self, "video_feeds", feeds)


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
                "operator_xr native extension is not installed; run "
                "`pip install -e ./python` from the Operator repository"
            ) from _native_import_error
        self._native = factory(
            name=self.config.name,
            pose_port=self.config.pose_port,
            discovery_port=self.config.discovery_port,
            pose_udp_port=self.config.pose_udp_port,
            telemetry_port=self.config.telemetry_port,
            discovery_unicast_targets=list(self.config.discovery_unicast_targets),
            streams=list(self.config.streams),
            video_feeds_json=json.dumps(
                [feed.to_dict() for feed in self.config.video_feeds],
                separators=(",", ":"),
            ),
        )
        self.blueprint = BlueprintClient(self._native, lambda: self.is_running)

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
