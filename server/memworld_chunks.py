"""Anchor-overlapped chunk buffering and binary live-chunk serialization."""

from __future__ import annotations

from collections import deque
from dataclasses import dataclass
import io
import json
from threading import Lock
import time
from typing import Any
import zipfile

import numpy as np


@dataclass(frozen=True)
class ProjectedSample:
    frame_id: int
    capture_time_ns: int
    server_received_ns: int
    calibration_id: str
    c2w: np.ndarray
    keypoint_png: bytes
    pose_debug: dict[str, Any] | None = None


@dataclass(frozen=True)
class LiveChunk:
    chunk_id: int
    samples: tuple[ProjectedSample, ...]
    created_ns: int

    @property
    def first_frame_id(self) -> int:
        return self.samples[0].frame_id

    @property
    def last_frame_id(self) -> int:
        return self.samples[-1].frame_id


class RollingChunkWindow:
    """Collect fixed-size batches, retaining the last sample as the next anchor."""

    def __init__(self, frames_per_chunk: int = 17) -> None:
        if frames_per_chunk <= 1:
            raise ValueError("frames_per_chunk must be greater than one")
        self.frames_per_chunk = frames_per_chunk
        self._samples: deque[ProjectedSample] = deque(maxlen=frames_per_chunk)
        self._next_chunk_id = 1

    @property
    def fill(self) -> int:
        return len(self._samples)

    def add(self, sample: ProjectedSample) -> LiveChunk | None:
        self._samples.append(sample)
        if len(self._samples) != self.frames_per_chunk:
            return None
        chunk = LiveChunk(
            chunk_id=self._next_chunk_id,
            samples=tuple(self._samples),
            created_ns=time.perf_counter_ns(),
        )
        self._next_chunk_id += 1
        self._samples.clear()
        self._samples.append(chunk.samples[-1])
        return chunk


class LatestChunkSlot:
    """One running chunk plus one replaceable pending chunk."""

    def __init__(self) -> None:
        self._lock = Lock()
        self.running: LiveChunk | None = None
        self.pending: LiveChunk | None = None
        self.skipped = 0

    def submit(self, chunk: LiveChunk) -> None:
        with self._lock:
            if self.pending is not None:
                self.skipped += 1
            self.pending = chunk

    def start_next(self) -> LiveChunk | None:
        with self._lock:
            if self.running is not None or self.pending is None:
                return None
            self.running, self.pending = self.pending, None
            return self.running

    def finish(self, chunk_id: int) -> None:
        with self._lock:
            if self.running is None or self.running.chunk_id != chunk_id:
                raise ValueError(f"chunk {chunk_id} is not running")
            self.running = None

    def snapshot(self) -> dict[str, int | None]:
        with self._lock:
            return {
                "running_chunk": self.running.chunk_id if self.running else None,
                "pending_chunk": self.pending.chunk_id if self.pending else None,
                "skipped_chunks": self.skipped,
            }


class LatestWindowQueue:
    """Bounded recent-sample window consumed only when inference is idle.

    Samples arrive continuously.  The queue never stores stale chunks: once
    the worker is ready and at least ``stride`` new samples are available, it
    snapshots the newest ``frames_per_chunk`` samples.  If inference falls
    behind, old samples age out of the fixed-size deque and the next dispatch
    catches up to the most recent action history.
    """

    def __init__(
        self,
        frames_per_chunk: int = 17,
        stride: int = 16,
    ) -> None:
        if frames_per_chunk <= 1:
            raise ValueError("frames_per_chunk must be greater than one")
        if not 0 < stride < frames_per_chunk:
            raise ValueError("stride must be in [1, frames_per_chunk)")
        self.frames_per_chunk = frames_per_chunk
        self.stride = stride
        self._lock = Lock()
        self._samples: deque[tuple[int, ProjectedSample]] = deque(
            maxlen=frames_per_chunk
        )
        self._sample_sequence = 0
        self._last_dispatched_sequence = 0
        self._next_chunk_id = 1
        self.running: LiveChunk | None = None
        self.skipped_samples = 0

    @property
    def fill(self) -> int:
        with self._lock:
            return len(self._samples)

    def add(self, sample: ProjectedSample) -> None:
        with self._lock:
            self._sample_sequence += 1
            self._samples.append((self._sample_sequence, sample))

    def _ready_locked(self) -> bool:
        if self.running is not None or len(self._samples) < self.frames_per_chunk:
            return False
        if self._last_dispatched_sequence == 0:
            return True
        return (
            self._sample_sequence - self._last_dispatched_sequence
            >= self.stride
        )

    def start_next(self) -> LiveChunk | None:
        with self._lock:
            if not self._ready_locked():
                return None
            newest_sequence = self._samples[-1][0]
            if self._last_dispatched_sequence:
                new_samples = newest_sequence - self._last_dispatched_sequence
                self.skipped_samples += max(0, new_samples - self.stride)
            chunk = LiveChunk(
                chunk_id=self._next_chunk_id,
                samples=tuple(item[1] for item in self._samples),
                created_ns=time.perf_counter_ns(),
            )
            self._next_chunk_id += 1
            self._last_dispatched_sequence = newest_sequence
            self.running = chunk
            return chunk

    def finish(self, chunk_id: int) -> None:
        with self._lock:
            if self.running is None or self.running.chunk_id != chunk_id:
                raise ValueError(f"chunk {chunk_id} is not running")
            self.running = None

    def snapshot(self) -> dict[str, int | None]:
        with self._lock:
            ready = self._ready_locked()
            return {
                "running_chunk": (
                    self.running.chunk_id if self.running else None
                ),
                "pending_chunk": self._next_chunk_id if ready else None,
                "skipped_chunks": self.skipped_samples // self.stride,
                "skipped_samples": self.skipped_samples,
                "window_fill": len(self._samples),
            }


def pack_live_chunk(chunk: LiveChunk) -> bytes:
    if len(chunk.samples) != 17:
        raise ValueError(f"live MemWorld chunks require 17 samples, got {len(chunk.samples)}")
    c2ws = np.stack(
        [np.asarray(sample.c2w, dtype=np.float32) for sample in chunk.samples],
        axis=0,
    )
    if c2ws.shape != (17, 4, 4) or not np.isfinite(c2ws).all():
        raise ValueError(f"c2ws must be finite with shape [17,4,4], got {c2ws.shape}")
    manifest = {
        "protocol_version": 1,
        "chunk_id": chunk.chunk_id,
        "frame_count": len(chunk.samples),
        "first_frame_id": chunk.first_frame_id,
        "last_frame_id": chunk.last_frame_id,
        "capture_time_ns": [sample.capture_time_ns for sample in chunk.samples],
        "calibration_id": chunk.samples[-1].calibration_id,
    }
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr(
            "manifest.json",
            json.dumps(manifest, separators=(",", ":"), ensure_ascii=False),
        )
        array_bytes = io.BytesIO()
        np.save(array_bytes, c2ws, allow_pickle=False)
        archive.writestr("c2ws.npy", array_bytes.getvalue())
        for index, sample in enumerate(chunk.samples):
            if not sample.keypoint_png:
                raise ValueError(f"sample {index} has no keypoint PNG")
            archive.writestr(f"keypoints/{index:03d}.png", sample.keypoint_png)
        debug = [sample.pose_debug for sample in chunk.samples]
        if any(item is not None for item in debug):
            archive.writestr(
                "pose_debug.json",
                json.dumps(debug, separators=(",", ":"), ensure_ascii=False),
            )
    return output.getvalue()
