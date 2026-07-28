"""Optional media decoding for Live Feed streams.

RGB arrives as an HEVC (or H.264) Annex-B elementary stream, so decoding it
needs an external codec.  :class:`RgbHevcDecoder` pipes the stream through
``ffmpeg`` and hands back raw RGB24 frames.  When ``ffmpeg`` is unavailable the
decoder degrades gracefully: it stays disabled and reports why, so callers can
keep consuming pose/depth without RGB.
"""

from __future__ import annotations

import base64
import collections
import queue
import shutil
import subprocess
import threading
import time
from typing import Any

from .models import (
    RgbCameraModel,
    RgbFrame,
    as_finite_int,
    rgb_cameras_from_config,
)
from .protocol import StreamEvent, read_exact


class RgbHevcDecoder:
    """Decode the OLCP RGB stream to :class:`~pyoperator.live_feed.models.RgbFrame`.

    Feed it ``rgb_csd`` config via :meth:`configure` and ``rgb_packet`` frames
    via :meth:`submit_packet`; decoded frames land in a bounded ring buffer that
    :meth:`nearest_frame` searches by timestamp.
    """

    def __init__(self, ffmpeg_bin: str = "ffmpeg", enabled: bool = True, max_frames: int = 24) -> None:
        self.enabled = enabled
        self.ffmpeg_bin = shutil.which(ffmpeg_bin) if ffmpeg_bin else None
        self.max_frames = max(1, max_frames)
        self.codec = "hevc"
        self.width = 0
        self.height = 0
        self.stereo_layout = "mono"
        self.cameras: tuple[RgbCameraModel, ...] = ()
        self.frames: collections.deque[RgbFrame] = collections.deque(maxlen=self.max_frames)
        self.decoded_count = 0
        self.failed = False
        self.disabled_reason = "" if self.ffmpeg_bin else f"ffmpeg not found: {ffmpeg_bin}"
        self._proc: subprocess.Popen[bytes] | None = None
        self._reader: threading.Thread | None = None
        self._lock = threading.Lock()
        self._pending_pts: queue.Queue[int] = queue.Queue(maxsize=256)
        self._configured_signature: tuple[int, int, str, int, str] | None = None

    @property
    def available(self) -> bool:
        return self.enabled and not self.failed and self.ffmpeg_bin is not None

    def close(self) -> None:
        proc = self._proc
        self._proc = None
        if proc is not None:
            try:
                if proc.stdin:
                    proc.stdin.close()
            except OSError:
                pass
            try:
                proc.terminate()
            except OSError:
                pass
            try:
                proc.wait(timeout=1.0)
            except subprocess.TimeoutExpired:
                proc.kill()
        if self._reader is not None:
            self._reader.join(timeout=1.0)
            self._reader = None

    def configure(self, config: dict[str, Any]) -> None:
        if not self.enabled or self.failed:
            return
        if self.ffmpeg_bin is None:
            return
        width = as_finite_int(config.get("width"))
        height = as_finite_int(config.get("height"))
        if width is None or height is None or width <= 0 or height <= 0:
            self.disabled_reason = "missing RGB frame dimensions"
            return
        codec = self._codec_from_config(config)
        if codec not in {"hevc", "h264"}:
            self.disabled_reason = f"unsupported RGB codec: {codec or 'missing'}"
            return
        cameras = rgb_cameras_from_config(config)
        layout = str(config.get("stereo_layout", "mono"))
        signature = (width, height, layout, len(cameras), codec)
        if self._configured_signature != signature:
            self.close()
            self.codec = codec
            self.width = width
            self.height = height
            self.stereo_layout = layout
            self.cameras = cameras
            self._configured_signature = signature
            self._start_process()
        csd_base64 = str(config.get("csd_base64", ""))
        if csd_base64:
            try:
                self._write_bytes(base64.b64decode(csd_base64))
            except Exception as error:
                self.failed = True
                self.disabled_reason = f"bad rgb_csd: {error}"

    def submit_packet(self, event: StreamEvent) -> None:
        if self._proc is None or self.failed:
            return
        try:
            self._pending_pts.put_nowait(event.pts_ns)
        except queue.Full:
            try:
                self._pending_pts.get_nowait()
            except queue.Empty:
                pass
            try:
                self._pending_pts.put_nowait(event.pts_ns)
            except queue.Full:
                pass
        self._write_bytes(event.payload)

    def submit_payload(self, pts_ns: int, payload: bytes) -> None:
        """Packet variant for callers holding a typed sample instead of a raw event."""
        self.submit_packet(StreamEvent(0, 0, pts_ns, 0, payload))

    def nearest_frame(self, pts_ns: int, max_delta_ns: int = 500_000_000) -> RgbFrame | None:
        with self._lock:
            frames = list(self.frames)
        if not frames:
            return None
        best = min(frames, key=lambda frame: abs(frame.pts_ns - pts_ns))
        if pts_ns > 0 and best.pts_ns > 0 and abs(best.pts_ns - pts_ns) > max_delta_ns:
            return frames[-1]
        return best

    def latest_frame(self) -> RgbFrame | None:
        """Most recently decoded frame, or ``None`` if nothing decoded yet."""
        with self._lock:
            return self.frames[-1] if self.frames else None

    def _start_process(self) -> None:
        assert self.ffmpeg_bin is not None
        command = [
            self.ffmpeg_bin,
            "-hide_banner",
            "-loglevel",
            "error",
            "-f",
            self.codec,
            "-i",
            "pipe:0",
            "-an",
            "-f",
            "rawvideo",
            "-pix_fmt",
            "rgb24",
            "pipe:1",
        ]
        try:
            self._proc = subprocess.Popen(
                command,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                bufsize=0,
            )
        except OSError as error:
            self.failed = True
            self.disabled_reason = f"failed to start ffmpeg: {error}"
            return
        self._reader = threading.Thread(target=self._reader_loop, name=f"rgb-{self.codec}-decoder", daemon=True)
        self._reader.start()

    @staticmethod
    def _codec_from_config(config: dict[str, Any]) -> str:
        codec = str(config.get("codec", "")).strip().lower()
        bitstream = str(config.get("bitstream_format", "")).strip().lower()
        if codec in {"hevc", "h265", "h.265", "video/hevc"} or bitstream.startswith("hevc"):
            return "hevc"
        if codec in {"h264", "h.264", "avc", "video/avc"} or bitstream.startswith("h264"):
            return "h264"
        return codec

    def _write_bytes(self, payload: bytes) -> None:
        proc = self._proc
        if proc is None or proc.stdin is None or self.failed:
            return
        try:
            proc.stdin.write(payload)
            proc.stdin.flush()
        except (BrokenPipeError, OSError) as error:
            self.failed = True
            self.disabled_reason = f"ffmpeg stdin failed: {error}"

    def _reader_loop(self) -> None:
        proc = self._proc
        if proc is None or proc.stdout is None:
            return
        frame_size = self.width * self.height * 3
        while frame_size > 0:
            try:
                data = read_exact(proc.stdout, frame_size)
            except Exception as error:
                self.disabled_reason = f"ffmpeg stdout failed: {error}"
                return
            if not data:
                return
            try:
                pts_ns = self._pending_pts.get_nowait()
            except queue.Empty:
                pts_ns = time.monotonic_ns()
            frame = RgbFrame(
                pts_ns=pts_ns,
                width=self.width,
                height=self.height,
                stereo_layout=self.stereo_layout,
                cameras=self.cameras,
                data=data,
            )
            with self._lock:
                self.frames.append(frame)
                self.decoded_count += 1
