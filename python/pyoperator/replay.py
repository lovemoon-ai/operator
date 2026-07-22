"""Versioned JSONL recording/replay using the same immutable frame models."""

from __future__ import annotations

import json
from pathlib import Path
import time
from typing import IO, Iterator

from .models import BridgeStats, XrFrame, frame_from_dict, frame_to_dict


class FrameRecorder:
    def __init__(self, path: str | Path) -> None:
        self.path = Path(path)
        self._file: IO[str] | None = None

    def __enter__(self) -> "FrameRecorder":
        self._file = self.path.open("w", encoding="utf-8")
        self._file.write('{"type":"pyoperator_recording","schema_version":1}\n')
        return self

    def write(self, frame: XrFrame) -> None:
        if self._file is None:
            raise RuntimeError("FrameRecorder must be used as a context manager")
        self._file.write(json.dumps(frame_to_dict(frame), separators=(",", ":")) + "\n")

    def __exit__(self, *_: object) -> None:
        if self._file is not None:
            self._file.close()
            self._file = None


def load(path: str | Path) -> tuple[XrFrame, ...]:
    with Path(path).open("r", encoding="utf-8") as source:
        header = json.loads(source.readline())
        if header.get("type") != "pyoperator_recording" or header.get("schema_version") != 1:
            raise ValueError("not a pyoperator recording v1")
        return tuple(frame_from_dict(json.loads(line)) for line in source if line.strip())


class ReplaySession:
    def __init__(self, path: str | Path, *, realtime: bool = False) -> None:
        self._frames = load(path)
        self._realtime = realtime
        self._index = 0
        self._running = False
        self._wall_start = 0.0
        self._source_start = self._frames[0].timestamp_ns if self._frames else 0

    def start(self) -> "ReplaySession":
        self._index = 0
        self._running = True
        self._wall_start = time.monotonic()
        return self

    def close(self) -> None:
        self._running = False

    @property
    def is_running(self) -> bool:
        return self._running

    def latest(self) -> XrFrame | None:
        return self._frames[self._index - 1] if self._index > 0 else None

    def wait_next(self, after_frame_id: int = 0, timeout: float | None = None) -> XrFrame | None:
        del timeout
        while self._index < len(self._frames):
            frame = self._frames[self._index]
            self._index += 1
            if frame.frame_id <= after_frame_id:
                continue
            if self._realtime:
                due = self._wall_start + (frame.timestamp_ns - self._source_start) / 1e9
                delay = due - time.monotonic()
                if delay > 0:
                    time.sleep(delay)
            return frame
        self._running = False
        return None

    def frames(self, timeout: float | None = None) -> Iterator[XrFrame]:
        frame_id = 0
        while self._running:
            frame = self.wait_next(frame_id, timeout)
            if frame is None:
                break
            frame_id = frame.frame_id
            yield frame

    def stats(self) -> BridgeStats:
        latest = self.latest()
        return BridgeStats(
            running=self._running,
            connected=self._running,
            frames_received=self._index,
            last_frame_id=latest.frame_id if latest else 0,
            last_timestamp_ns=latest.timestamp_ns if latest else 0,
        )
