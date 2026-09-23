"""Host-declared headset capture streams.

``BridgeConfig(capture_streams=CaptureStreamsConfig(...))`` declares, in the
device descriptor, which headset streams this host wants and their upper
limits (the permission *envelope*). The user grants or denies the envelope
on the headset; the headset answers with :class:`StreamsStatus` and sends the
granted streams over the host session's own media channel (OLCP frames on
``BridgeConfig.media_up_port``, authenticated by the session), which
:class:`XrCapture` turns into :mod:`operator_xr.live_feed` samples.
:class:`StreamsControl` adjusts parameters inside the envelope during the
session.

Mirrors ``robot/crates/teleop-protocol/src/streams.rs``; see
``claw/architecture/wire-protocol.md``.
"""

from __future__ import annotations

from dataclasses import dataclass, field
import json
import math
from typing import TYPE_CHECKING, Any, Callable, Iterator, Mapping

if TYPE_CHECKING:  # pragma: no cover - imported lazily at runtime
    from .live_feed.models import DepthCameraModel, Sample
    from .live_feed.results import ResultPublisher


CAPTURE_STREAMS_CAPABILITY = "capture_streams_v1"
CAPTURE_STREAMS_SCHEMA_VERSION = 1
CAPTURE_STREAM_NAMES = (
    "rgb.hevc",
    "depth.u16",
    "head_pose.json",
    "controller_pose.json",
    "controller_input.json",
    "hand_joints.json",
)
CAPTURE_STREAM_EYES = ("left", "mono", "stereo")
LOCAL_TASK_KINDS = ("record", "upload")
RECORD_CONTAINERS = ("spatialmp4",)
STREAMS_STATUS_SCHEMA = "operator.streams_status.v1"
STREAMS_CONTROL_SCHEMA = "operator.streams_control.v1"
STREAM_STATES = ("pending", "active", "paused", "denied")
LOCAL_TASK_STATES = ("pending", "running", "idle", "denied", "failed")
STREAMS_REASONS = (
    "permission_denied",
    "revoked",
    "unsupported",
    "limit",
    "unknown_endpoint",
)


def stream_capability(name: str) -> str:
    """``Hello.capabilities`` entry a headset advertises for a stream it produces."""
    return f"stream.{name}"


def _is_number(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def _positive_hz(value: Any, what: str) -> float:
    if not _is_number(value) or not math.isfinite(value) or value <= 0:
        raise ValueError(f"{what} must be a finite number > 0")
    return float(value)


def _positive_int(value: Any, what: str) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value <= 0:
        raise ValueError(f"{what} must be an integer > 0")
    return value


def _optional_bool(value: Any, what: str) -> None:
    if value is not None and not isinstance(value, bool):
        raise ValueError(f"{what} must be a bool")


def _check_eye(eye: Any) -> None:
    if eye is not None and eye not in CAPTURE_STREAM_EYES:
        raise ValueError(f"eye must be one of {list(CAPTURE_STREAM_EYES)}")


def _check_stream_name(name: Any) -> None:
    if name not in CAPTURE_STREAM_NAMES:
        raise ValueError(
            f"unknown capture stream {name!r}; expected one of {list(CAPTURE_STREAM_NAMES)}"
        )


def _is_endpoint_name(value: Any) -> bool:
    """A headset-local endpoint *name*; URLs and host[:port] are rejected."""
    return (
        isinstance(value, str)
        and bool(value.strip())
        and "/" not in value
        and ":" not in value
    )


def _without_none(values: Mapping[str, Any]) -> dict[str, Any]:
    return {key: value for key, value in values.items() if value is not None}


# ---------------------------------------------------------------------------
# descriptor declaration
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class CaptureStream:
    """One declared stream and its envelope (``max_*`` are upper limits)."""

    name: str
    #: Only affects status/prompt priority; a denial never blocks the session.
    required: bool = False
    max_hz: float | None = None
    max_bitrate_bps: int | None = None
    eye: str | None = None

    def __post_init__(self) -> None:
        _check_stream_name(self.name)
        if not isinstance(self.required, bool):
            raise ValueError("required must be a bool")
        if self.max_hz is not None:
            _positive_hz(self.max_hz, f"{self.name} max_hz")
        if self.max_bitrate_bps is not None:
            _positive_int(self.max_bitrate_bps, f"{self.name} max_bitrate_bps")
        _check_eye(self.eye)

    def to_dict(self) -> dict[str, Any]:
        return _without_none(
            {
                "name": self.name,
                "required": self.required,
                "max_hz": self.max_hz,
                "max_bitrate_bps": self.max_bitrate_bps,
                "eye": self.eye,
            }
        )


@dataclass(frozen=True)
class LocalTask:
    """A headset-local task: ``record`` streams, or ``upload`` to a named endpoint.

    ``endpoint_ref`` names an ingest endpoint already configured and verified
    on the headset; hosts can never supply a URL or address.
    """

    kind: str
    container: str | None = None
    streams: tuple[str, ...] = ()
    endpoint_ref: str | None = None

    def __post_init__(self) -> None:
        if self.kind not in LOCAL_TASK_KINDS:
            raise ValueError(f"local task kind must be one of {list(LOCAL_TASK_KINDS)}")
        if isinstance(self.streams, str) or not isinstance(self.streams, (tuple, list)):
            raise ValueError("local task streams must be a sequence of stream names")
        streams = tuple(self.streams)
        for name in streams:
            _check_stream_name(name)
        if len(set(streams)) != len(streams):
            raise ValueError("local task streams must not contain duplicates")
        object.__setattr__(self, "streams", streams)
        if self.kind == "record":
            if self.container is not None and self.container not in RECORD_CONTAINERS:
                raise ValueError(f"record container must be one of {list(RECORD_CONTAINERS)}")
            if self.endpoint_ref is not None:
                raise ValueError("record tasks take no endpoint_ref")
        else:
            if self.container is not None or streams:
                raise ValueError("upload tasks take only endpoint_ref")
            if not _is_endpoint_name(self.endpoint_ref):
                raise ValueError(
                    "upload endpoint_ref must name a headset-local endpoint, not a URL or host"
                )

    def to_dict(self) -> dict[str, Any]:
        return _without_none(
            {
                "kind": self.kind,
                "container": self.container,
                "streams": list(self.streams) or None,
                "endpoint_ref": self.endpoint_ref,
            }
        )


@dataclass(frozen=True)
class CaptureStreamsConfig:
    """The descriptor ``capture_streams`` block this host declares.

    It names streams and local tasks only; the media transport (ports and
    token) belongs to the session and is issued by the bridge.
    """

    streams: tuple[CaptureStream, ...]
    local_tasks: tuple[LocalTask, ...] = ()

    def __post_init__(self) -> None:
        for attribute, kind in (("streams", CaptureStream), ("local_tasks", LocalTask)):
            values = getattr(self, attribute)
            if not isinstance(values, (tuple, list)) or any(
                not isinstance(value, kind) for value in values
            ):
                raise ValueError(f"{attribute} must be a sequence of {kind.__name__}")
            object.__setattr__(self, attribute, tuple(values))
        if not self.streams and not self.local_tasks:
            raise ValueError("capture_streams must declare at least one stream or local task")
        names = [stream.name for stream in self.streams]
        if len(set(names)) != len(names):
            raise ValueError("capture stream names must not contain duplicates")
        kinds = [task.kind for task in self.local_tasks]
        if len(set(kinds)) != len(kinds):
            raise ValueError("local task kinds must not contain duplicates")

    def stream(self, name: str) -> CaptureStream | None:
        return next((stream for stream in self.streams if stream.name == name), None)

    def to_descriptor_dict(self) -> dict[str, Any]:
        """The ``DeviceDescriptor.capture_streams`` JSON object."""
        return {
            "schema_version": CAPTURE_STREAMS_SCHEMA_VERSION,
            "streams": [stream.to_dict() for stream in self.streams],
            "local_tasks": [task.to_dict() for task in self.local_tasks],
        }


# ---------------------------------------------------------------------------
# StreamsStatus (headset -> host)
# ---------------------------------------------------------------------------


def _check_reason(reason: Any) -> None:
    if reason is not None and reason not in STREAMS_REASONS:
        raise ValueError(f"reason must be one of {list(STREAMS_REASONS)}")


@dataclass(frozen=True)
class StreamStatus:
    """Effective state of one stream; ``reason="limit"`` means it was clipped."""

    state: str
    reason: str | None = None
    hz: float | None = None
    bitrate_bps: int | None = None
    eye: str | None = None

    def __post_init__(self) -> None:
        if self.state not in STREAM_STATES:
            raise ValueError(f"stream state must be one of {list(STREAM_STATES)}")
        _check_reason(self.reason)
        if self.hz is not None and (
            not _is_number(self.hz) or not math.isfinite(self.hz) or self.hz < 0
        ):
            raise ValueError("stream hz must be a finite number >= 0")
        if self.bitrate_bps is not None and (
            not isinstance(self.bitrate_bps, int)
            or isinstance(self.bitrate_bps, bool)
            or self.bitrate_bps < 0
        ):
            raise ValueError("stream bitrate_bps must be an integer >= 0")
        _check_eye(self.eye)

    def to_dict(self) -> dict[str, Any]:
        return _without_none(
            {
                "state": self.state,
                "reason": self.reason,
                "hz": self.hz,
                "bitrate_bps": self.bitrate_bps,
                "eye": self.eye,
            }
        )


@dataclass(frozen=True)
class LocalTaskStatus:
    state: str
    reason: str | None = None

    def __post_init__(self) -> None:
        if self.state not in LOCAL_TASK_STATES:
            raise ValueError(f"local task state must be one of {list(LOCAL_TASK_STATES)}")
        _check_reason(self.reason)

    def to_dict(self) -> dict[str, Any]:
        return _without_none({"state": self.state, "reason": self.reason})


@dataclass(frozen=True)
class StreamsStatus:
    """The headset's answer to ``capture_streams`` (``operator.streams_status.v1``)."""

    streams: Mapping[str, StreamStatus] = field(default_factory=dict)
    local_tasks: Mapping[str, LocalTaskStatus] = field(default_factory=dict)

    @classmethod
    def from_dict(cls, value: Mapping[str, Any]) -> "StreamsStatus":
        if not isinstance(value, Mapping) or value.get("schema") != STREAMS_STATUS_SCHEMA:
            raise ValueError(f"StreamsStatus schema must be {STREAMS_STATUS_SCHEMA}")
        streams = value.get("streams")
        tasks = value.get("local_tasks")
        streams = {} if streams is None else streams
        tasks = {} if tasks is None else tasks
        if not isinstance(streams, Mapping) or not isinstance(tasks, Mapping):
            raise ValueError("StreamsStatus streams and local_tasks must be objects")
        return cls(
            streams={str(name): _status_from(StreamStatus, item) for name, item in streams.items()},
            local_tasks={str(kind): _status_from(LocalTaskStatus, item) for kind, item in tasks.items()},
        )

    @classmethod
    def from_json(cls, payload: str | bytes) -> "StreamsStatus":
        return cls.from_dict(json.loads(payload))

    @classmethod
    def unsupported(cls, config: CaptureStreamsConfig) -> "StreamsStatus":
        """What an old headset (no ``capture_streams_v1``) effectively answers."""
        return cls(
            streams={
                stream.name: StreamStatus("denied", "unsupported") for stream in config.streams
            },
            local_tasks={
                task.kind: LocalTaskStatus("denied", "unsupported") for task in config.local_tasks
            },
        )

    def stream(self, name: str) -> StreamStatus | None:
        return self.streams.get(name)

    def local_task(self, kind: str) -> LocalTaskStatus | None:
        return self.local_tasks.get(kind)

    def is_active(self, name: str) -> bool:
        status = self.streams.get(name)
        return status is not None and status.state == "active"

    def to_dict(self) -> dict[str, Any]:
        return {
            "schema": STREAMS_STATUS_SCHEMA,
            "streams": {name: status.to_dict() for name, status in self.streams.items()},
            "local_tasks": {kind: status.to_dict() for kind, status in self.local_tasks.items()},
        }


def _status_from(kind: type, item: Any) -> Any:
    if not isinstance(item, Mapping):
        raise ValueError(f"{kind.__name__} entries must be objects")
    names = set(kind.__dataclass_fields__)
    return kind(**{key: value for key, value in item.items() if key in names})


# ---------------------------------------------------------------------------
# StreamsControl (host -> headset)
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class StreamControl:
    """In-envelope adjustment; ``None`` fields keep their current value."""

    hz: float | None = None
    bitrate_bps: int | None = None
    paused: bool | None = None

    def __post_init__(self) -> None:
        if self.hz is not None:
            _positive_hz(self.hz, "hz")
        if self.bitrate_bps is not None:
            _positive_int(self.bitrate_bps, "bitrate_bps")
        _optional_bool(self.paused, "paused")

    def to_dict(self) -> dict[str, Any]:
        return _without_none(
            {"hz": self.hz, "bitrate_bps": self.bitrate_bps, "paused": self.paused}
        )


@dataclass(frozen=True)
class LocalTaskControl:
    """Start (``running=True``) or stop a declared local task."""

    running: bool | None = None

    def __post_init__(self) -> None:
        _optional_bool(self.running, "running")

    def to_dict(self) -> dict[str, Any]:
        return _without_none({"running": self.running})


@dataclass(frozen=True)
class StreamsControl:
    """``operator.streams_control.v1``; values may be given as plain dicts.

    The headset clips values outside the granted envelope and reports
    ``reason="limit"`` in its next :class:`StreamsStatus`.
    """

    streams: Mapping[str, StreamControl | Mapping[str, Any]] = field(default_factory=dict)
    local_tasks: Mapping[str, LocalTaskControl | Mapping[str, Any]] = field(
        default_factory=dict
    )

    def __post_init__(self) -> None:
        object.__setattr__(self, "streams", _controls(self.streams, StreamControl))
        object.__setattr__(self, "local_tasks", _controls(self.local_tasks, LocalTaskControl))
        for name in self.streams:
            _check_stream_name(name)
        for kind in self.local_tasks:
            if kind not in LOCAL_TASK_KINDS:
                raise ValueError(f"local task kind must be one of {list(LOCAL_TASK_KINDS)}")
        if not self.streams and not self.local_tasks:
            raise ValueError("StreamsControl must adjust at least one stream or local task")

    def validate_for(self, config: CaptureStreamsConfig) -> None:
        """Only streams and local tasks declared in ``config`` may be adjusted."""
        undeclared = [name for name in self.streams if config.stream(name) is None]
        if undeclared:
            raise ValueError(f"streams not declared in capture_streams: {undeclared}")
        declared_tasks = {task.kind for task in config.local_tasks}
        undeclared = [kind for kind in self.local_tasks if kind not in declared_tasks]
        if undeclared:
            raise ValueError(f"local tasks not declared in capture_streams: {undeclared}")

    def to_dict(self) -> dict[str, Any]:
        value: dict[str, Any] = {"schema": STREAMS_CONTROL_SCHEMA}
        if self.streams:
            value["streams"] = {name: item.to_dict() for name, item in self.streams.items()}
        if self.local_tasks:
            value["local_tasks"] = {kind: item.to_dict() for kind, item in self.local_tasks.items()}
        return value

    def to_json(self) -> str:
        return json.dumps(self.to_dict(), separators=(",", ":"), allow_nan=False)


def _controls(values: Any, kind: type) -> dict[str, Any]:
    if not isinstance(values, Mapping):
        raise ValueError(f"{kind.__name__} entries must be given as a mapping")
    result: dict[str, Any] = {}
    for name, item in values.items():
        if isinstance(item, Mapping):
            try:
                item = kind(**item)
            except TypeError as error:
                raise ValueError(f"invalid {kind.__name__} for {name!r}: {error}") from None
        elif not isinstance(item, kind):
            raise ValueError(f"{name!r} must be a {kind.__name__} or a mapping")
        result[str(name)] = item
    return result


# ---------------------------------------------------------------------------
# host-side media
# ---------------------------------------------------------------------------


class XrCapture:
    """Granted headset media for ``BridgeConfig.capture_streams`` (``xr.capture``).

    The host session carries media itself: the headset pushes OLCP frames to
    ``BridgeConfig.media_up_port`` with the session-issued token and pulls
    results from ``media_down_port``. :meth:`frames` turns the relayed frames
    into :mod:`operator_xr.live_feed` samples; :attr:`results` sends results
    back to the headset.
    """

    def __init__(
        self,
        config: CaptureStreamsConfig,
        native: Any,
        is_running: Callable[[], bool],
    ) -> None:
        from .live_feed.results import ResultPublisher

        self.config = config
        self._native = native
        self._is_running = is_running
        self._depth_model: DepthCameraModel | None = None
        #: Publishes to the headset's media_down connection. Frames published
        #: while no headset result client is connected are dropped, not
        #: replayed; call ``results.replay_snapshot()`` once
        #: ``xr.stats().media_down_connected`` turns true to restore the map.
        self.results: ResultPublisher = ResultPublisher(self._send_result_frame)

    def frames(self, timeout: float = 0.25) -> Iterator[Sample]:
        """Samples from successive headset media sessions, in arrival order;
        stops when the XrSession closes. ``pts_ns`` is headset ``godot_ticks_ns``."""
        if not self._is_running():
            raise RuntimeError("capture is not running; start the XrSession first")
        return self._frames(timeout)

    def _frames(self, timeout: float) -> Iterator[Sample]:
        from .live_feed.protocol import StreamEvent

        while True:
            frame = self._native.poll_media_frame(timeout)
            if frame is not None:
                yield self._sample(StreamEvent(*frame))
            elif not self._is_running():
                return

    def _sample(self, event: Any) -> Sample:
        from .live_feed.models import DepthFrameSample, DepthMetadataSample, parse_sample
        from .live_feed.protocol import TYPE_SESSION_START

        if event.frame_type == TYPE_SESSION_START:
            self._depth_model = None
        sample = parse_sample(event, depth_model=self._depth_model)
        if isinstance(sample, (DepthMetadataSample, DepthFrameSample)) and sample.model is not None:
            self._depth_model = sample.model
        return sample

    def _send_result_frame(
        self, frame_type: int, flags: int, pts_ns: int, duration_ns: int, payload: bytes
    ) -> None:
        try:
            self._native.send_media_down_frame(frame_type, flags, pts_ns, duration_ns, payload)
        except RuntimeError:
            # As with ResultChannel: no headset result client, frame dropped.
            pass
