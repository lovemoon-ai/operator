"""Persistent localhost client for the MemWorld GPU worker."""

from __future__ import annotations

import asyncio
from dataclasses import dataclass
import hashlib
import io
import json
import os
from pathlib import Path
import queue
import select
import socket
import subprocess
import threading
import time
from typing import Any, Callable
from urllib.parse import urlparse

from PIL import Image

from server.memworld_chunks import pack_live_chunk
from server.memworld_frame_sequence import (
    FRAME_COUNT,
    LIVE_FRAME_MIME_TYPE,
    unpack_jpeg_sequence,
)
from server.memworld_stream_protocol import recv_message, send_message


STREAM_PROTOCOL = "memworld-stream-v1"
STREAM_OUTPUT_FRAMES = 16
STREAM_MAX_INFLIGHT_CHUNKS = 3
# Zero means a live session continues until the Quest/gateway disconnects.
STREAM_DEFAULT_SESSION_CHUNKS = 0


@dataclass(frozen=True)
class WorkerResult:
    chunk_id: int
    metadata: dict[str, Any]
    frames: tuple[bytes, ...]


def accept_worker_output(
    expected_chunk_id: int,
    metadata: dict[str, Any],
    payload: bytes,
) -> WorkerResult:
    if not isinstance(metadata, dict) or metadata.get("type") != "chunk.output":
        raise ValueError("worker did not send chunk.output metadata")
    chunk_id = int(metadata.get("chunk_id", -1))
    if chunk_id != expected_chunk_id:
        raise ValueError(
            f"worker chunk_id {chunk_id} does not match running chunk_id {expected_chunk_id}"
        )
    if metadata.get("mime_type") != LIVE_FRAME_MIME_TYPE:
        raise ValueError("worker returned an unsupported live frame MIME type")
    if metadata.get("frame_format") != "jpeg":
        raise ValueError("worker live frame format must be jpeg")
    if int(metadata.get("frame_count", 0)) != FRAME_COUNT:
        raise ValueError(f"worker live output must contain {FRAME_COUNT} frames")
    byte_length = metadata.get("byte_length")
    if byte_length is not None and int(byte_length) != len(payload):
        raise ValueError("worker frame ZIP length does not match chunk.output")
    unpack_started = time.perf_counter()
    frames = unpack_jpeg_sequence(payload)
    metadata["frame_zip_bytes"] = len(payload)
    metadata["frame_zip_unpack_ms"] = round(
        (time.perf_counter() - unpack_started) * 1000.0,
        3,
    )
    return WorkerResult(chunk_id=chunk_id, metadata=metadata, frames=frames)


class MemWorldWorkerClient:
    def __init__(
        self,
        *,
        url: str,
        session_start: dict[str, Any],
        slot: Any,
        on_result: Callable[[WorkerResult], None],
        on_status: Callable[[str, str], None],
    ) -> None:
        self.url = url
        self.session_start = session_start
        self.slot = slot
        self.on_result = on_result
        self.on_status = on_status
        self._stopping = False

    def stop(self) -> None:
        self._stopping = True

    async def run(self) -> None:
        from websockets.asyncio.client import connect

        backoff = 0.5
        while not self._stopping:
            try:
                self.on_status("connecting", "")
                async with connect(
                    self.url,
                    max_size=512 * 1024 * 1024,
                    ping_interval=20,
                    ping_timeout=120,
                    compression=None,
                ) as websocket:
                    await websocket.send(json.dumps(self.session_start, separators=(",", ":")))
                    ready_raw = await websocket.recv()
                    if not isinstance(ready_raw, str):
                        raise ValueError("worker session.ready must be JSON")
                    ready = json.loads(ready_raw)
                    if ready.get("type") != "session.ready":
                        raise ValueError(f"worker rejected session: {ready}")
                    self.on_status("ready", "")
                    backoff = 0.5
                    while not self._stopping:
                        chunk = self.slot.start_next()
                        if chunk is None:
                            await asyncio.sleep(0.01)
                            continue
                        try:
                            payload = await asyncio.to_thread(pack_live_chunk, chunk)
                            await websocket.send(json.dumps({
                                "type": "chunk.input",
                                "session_id": self.session_start["session_id"],
                                "chunk_id": chunk.chunk_id,
                                "first_frame_id": chunk.first_frame_id,
                                "last_frame_id": chunk.last_frame_id,
                            }, separators=(",", ":")))
                            await websocket.send(payload)
                            started_raw = await websocket.recv()
                            if not isinstance(started_raw, str):
                                raise ValueError("worker chunk.started must be JSON")
                            started = json.loads(started_raw)
                            if (
                                started.get("type") != "chunk.started"
                                or int(started.get("chunk_id", -1)) != chunk.chunk_id
                            ):
                                raise ValueError(f"unexpected worker start event: {started}")
                            output_raw = await websocket.recv()
                            if not isinstance(output_raw, str):
                                raise ValueError("worker chunk.output must be JSON")
                            output = json.loads(output_raw)
                            receive_started = time.perf_counter()
                            frame_zip = await websocket.recv()
                            if not isinstance(frame_zip, bytes):
                                raise ValueError("worker frame ZIP must be binary")
                            output["frame_zip_receive_ms"] = round(
                                (time.perf_counter() - receive_started) * 1000.0,
                                3,
                            )
                            output["_source_server_received_ns"] = chunk.samples[-1].server_received_ns
                            output["_source_capture_time_ns"] = chunk.samples[-1].capture_time_ns
                            output["_source_frame_id"] = chunk.samples[-1].frame_id
                            result = accept_worker_output(
                                chunk.chunk_id,
                                output,
                                frame_zip,
                            )
                            self.on_result(result)
                        finally:
                            self.slot.finish(chunk.chunk_id)
            except asyncio.CancelledError:
                raise
            except Exception as error:
                running = self.slot.running
                if running is not None:
                    try:
                        self.slot.finish(running.chunk_id)
                    except ValueError:
                        pass
                self.on_status("offline", str(error))
                if self._stopping:
                    return
                await asyncio.sleep(backoff)
                backoff = min(backoff * 2.0, 5.0)


def _jpeg_from_rgb(rgb: bytes, width: int, height: int) -> bytes:
    output = io.BytesIO()
    Image.frombytes("RGB", (width, height), rgb).save(
        output,
        format="JPEG",
        quality=95,
        subsampling=0,
        optimize=False,
    )
    return output.getvalue()


def decode_mp4_frames(
    payload: bytes,
    *,
    ffmpeg_bin: str,
    width: int,
    height: int,
    frame_count: int = STREAM_OUTPUT_FRAMES,
) -> tuple[bytes, ...]:
    completed = subprocess.run(
        [
            ffmpeg_bin,
            "-hide_banner",
            "-loglevel",
            "error",
            "-i",
            "pipe:0",
            "-an",
            "-f",
            "rawvideo",
            "-pix_fmt",
            "rgb24",
            "pipe:1",
        ],
        input=payload,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if completed.returncode != 0:
        raise RuntimeError(
            "ffmpeg decode failed: "
            + completed.stderr.decode("utf-8", errors="replace")[-2000:]
        )
    frame_bytes = width * height * 3
    expected = frame_count * frame_bytes
    if len(completed.stdout) != expected:
        raise RuntimeError(
            f"decoded stream has {len(completed.stdout)} bytes, "
            f"expected {expected}"
        )
    return tuple(
        _jpeg_from_rgb(
            completed.stdout[index * frame_bytes : (index + 1) * frame_bytes],
            width,
            height,
        )
        for index in range(frame_count)
    )


class FragmentedMP4Decoder:
    """Unwrap fMP4 media fragments into one persistent H.264 decoder."""

    def __init__(self, *, ffmpeg_bin: str, width: int, height: int) -> None:
        self.width = int(width)
        self.height = int(height)
        self.ffmpeg_bin = ffmpeg_bin
        self._closed = False
        self._has_pending_tail = False
        self._init_segment: bytes | None = None
        self._persistent_usable = True
        self.process = subprocess.Popen(
            [
                ffmpeg_bin,
                "-hide_banner",
                "-loglevel",
                "error",
                "-threads",
                "1",
                "-flags",
                "low_delay",
                "-flags2",
                "showall",
                "-f",
                "h264",
                "-i",
                "pipe:0",
                "-an",
                "-vsync",
                "0",
                "-flush_packets",
                "1",
                "-f",
                "rawvideo",
                "-pix_fmt",
                "rgb24",
                "pipe:1",
            ],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=0,
        )
        if self.process.stdin is None or self.process.stdout is None:
            self.abort()
            raise RuntimeError("cannot open persistent H.264 decoder pipes")

    def _write(self, payload: bytes) -> None:
        if self._closed or self.process.poll() is not None:
            raise RuntimeError("persistent H.264 decoder is not running")
        assert self.process.stdin is not None
        self.process.stdin.write(payload)
        self.process.stdin.flush()

    def feed_init(self, payload: bytes) -> None:
        if not payload:
            raise RuntimeError("empty fMP4 init segment")
        marker = payload.find(b"avcC")
        if marker < 4:
            raise RuntimeError("fMP4 init segment has no avcC codec record")
        box_start = marker - 4
        box_size = int.from_bytes(payload[box_start:marker], "big")
        box_end = box_start + box_size
        if box_size < 15 or box_end > len(payload):
            raise RuntimeError("invalid fMP4 avcC box")
        avcc = payload[marker + 4 : box_end]
        nal_length_size = (avcc[4] & 0x03) + 1
        offset = 5
        sps_count = avcc[offset] & 0x1F
        offset += 1
        nals: list[bytes] = []
        for _ in range(sps_count):
            if offset + 2 > len(avcc):
                raise RuntimeError("truncated avcC SPS length")
            size = int.from_bytes(avcc[offset : offset + 2], "big")
            offset += 2
            if size <= 0 or offset + size > len(avcc):
                raise RuntimeError("truncated avcC SPS payload")
            nals.append(avcc[offset : offset + size])
            offset += size
        if offset >= len(avcc):
            raise RuntimeError("truncated avcC PPS count")
        pps_count = avcc[offset]
        offset += 1
        for _ in range(pps_count):
            if offset + 2 > len(avcc):
                raise RuntimeError("truncated avcC PPS length")
            size = int.from_bytes(avcc[offset : offset + 2], "big")
            offset += 2
            if size <= 0 or offset + size > len(avcc):
                raise RuntimeError("truncated avcC PPS payload")
            nals.append(avcc[offset : offset + size])
            offset += size
        if not nals:
            raise RuntimeError("fMP4 avcC has no SPS/PPS NAL units")
        self._init_segment = bytes(payload)
        self._nal_length_size = nal_length_size
        self._write(b"".join(b"\x00\x00\x00\x01" + nal for nal in nals))

    def _annexb_from_fragment(self, payload: bytes) -> tuple[bytes, bytes]:
        offset = 0
        output = bytearray()
        media_units = 0
        last_unit = b""
        while offset < len(payload):
            if offset + 8 > len(payload):
                raise RuntimeError("truncated fMP4 box")
            box_size = int.from_bytes(payload[offset : offset + 4], "big")
            box_type = payload[offset + 4 : offset + 8]
            if box_size == 1:
                if offset + 16 > len(payload):
                    raise RuntimeError("truncated extended fMP4 box")
                box_size = int.from_bytes(payload[offset + 8 : offset + 16], "big")
                header_size = 16
            else:
                header_size = 8
            if box_size < header_size or offset + box_size > len(payload):
                raise RuntimeError("invalid fMP4 box size")
            if box_type == b"mdat":
                data = payload[offset + header_size : offset + box_size]
                cursor = 0
                access_unit = bytearray()
                while cursor < len(data):
                    end = cursor + self._nal_length_size
                    if end > len(data):
                        raise RuntimeError("truncated H.264 NAL length in fMP4")
                    nal_size = int.from_bytes(data[cursor:end], "big")
                    cursor = end
                    if nal_size <= 0 or cursor + nal_size > len(data):
                        raise RuntimeError("invalid H.264 NAL payload in fMP4")
                    access_unit.extend(b"\x00\x00\x00\x01")
                    access_unit.extend(data[cursor : cursor + nal_size])
                    cursor += nal_size
                output.extend(access_unit)
                last_unit = bytes(access_unit)
                media_units += 1
            offset += box_size
        if media_units == 0:
            raise RuntimeError("fMP4 fragment has no media payload")
        return bytes(output), last_unit

    def decode_fragment(self, payload: bytes, *, frame_count: int) -> tuple[bytes, ...]:
        if frame_count <= 0:
            raise ValueError("fragment frame_count must be positive")
        if not self._persistent_usable:
            if self._init_segment is None:
                raise RuntimeError("fMP4 init segment was not supplied")
            return decode_mp4_frames(
                self._init_segment + payload,
                ffmpeg_bin=self.ffmpeg_bin,
                width=self.width,
                height=self.height,
                frame_count=frame_count,
            )
        annexb, tail_unit = self._annexb_from_fragment(payload)
        # Keep the H.264 decoder live without waiting for a later model chunk:
        # one duplicated access unit closes the current decode interval.  On
        # later fragments the prior duplicate and the fMP4 encoder's retained
        # tail are both reported as leading duplicates and dropped by caller.
        self._write(annexb + tail_unit)
        decoded_count = frame_count + (1 if self._has_pending_tail else 0)
        self._has_pending_tail = True
        assert self.process.stdout is not None
        expected = decoded_count * self.width * self.height * 3
        output = bytearray()
        while len(output) < expected:
            readable, _, _ = select.select([self.process.stdout], [], [], 0.25)
            if not readable:
                # Some FFmpeg builds defer a pipe-backed H.264 stream until a
                # later fragment despite zero-latency flags.  Preserve the
                # fMP4 contract and fall back to isolated fragment decode
                # instead of silently adding one whole K4 block of latency.
                self._persistent_usable = False
                self.abort()
                if self._init_segment is None:
                    raise RuntimeError("fMP4 init segment was not supplied")
                return decode_mp4_frames(
                    self._init_segment + payload,
                    ffmpeg_bin=self.ffmpeg_bin,
                    width=self.width,
                    height=self.height,
                    frame_count=frame_count,
                )
            block = os.read(
                self.process.stdout.fileno(), expected - len(output)
            )
            if not block:
                detail = b""
                if self.process.stderr is not None:
                    try:
                        detail = self.process.stderr.read() or b""
                    except OSError:
                        pass
                raise RuntimeError(
                    "persistent H.264 decoder ended early: "
                    + detail.decode("utf-8", errors="replace")[-2000:]
                )
            output.extend(block)
        frame_bytes = self.width * self.height * 3
        return tuple(
            _jpeg_from_rgb(
                bytes(output[index * frame_bytes : (index + 1) * frame_bytes]),
                self.width,
                self.height,
            )
            for index in range(decoded_count)
        )

    @property
    def persistent_decoder(self) -> bool:
        return self._persistent_usable

    def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        if self.process.stdin is not None:
            try:
                self.process.stdin.close()
            except OSError:
                pass
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            try:
                self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.process.kill()

    def abort(self) -> None:
        if self._closed:
            return
        self._closed = True
        if self.process.stdin is not None:
            try:
                self.process.stdin.close()
            except OSError:
                pass
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.process.kill()


class MemWorldNVStreamClient:
    """Adapter from Operator's latest-window scheduler to an NV TCP worker."""

    def __init__(
        self,
        *,
        url: str,
        session_start: dict[str, Any],
        slot: Any,
        on_result: Callable[[WorkerResult], None],
        on_status: Callable[[str, str], None],
    ) -> None:
        parsed = urlparse(url)
        if parsed.scheme != "tcp" or not parsed.hostname or not parsed.port:
            raise ValueError(f"invalid NV stream URL: {url!r}")
        self.host = parsed.hostname
        self.port = parsed.port
        self.session_start = dict(session_start)
        self.slot = slot
        self.on_result = on_result
        self.on_status = on_status
        self._stopping = threading.Event()
        self._socket_lock = threading.Lock()
        self._socket: socket.socket | None = None

    def stop(self) -> None:
        self._stopping.set()
        with self._socket_lock:
            sock = self._socket
        if sock is not None:
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass

    async def run(self) -> None:
        backoff = 0.5
        attempt = 0
        while not self._stopping.is_set():
            try:
                await asyncio.to_thread(self._run_blocking, attempt)
                return
            except asyncio.CancelledError:
                self.stop()
                raise
            except Exception as error:
                running = self.slot.running
                if running is not None:
                    try:
                        self.slot.finish(running.chunk_id)
                    except ValueError:
                        pass
                self.on_status(
                    "offline",
                    f"{error}; reconnecting attempt={attempt + 1}",
                )
                if self._stopping.is_set():
                    return
                attempt += 1
                await asyncio.sleep(backoff)
                backoff = min(backoff * 2.0, 5.0)

    def _connect(self) -> socket.socket:
        sock = socket.create_connection((self.host, self.port), timeout=20)
        sock.settimeout(180)
        with self._socket_lock:
            self._socket = sock
        return sock

    @staticmethod
    def _session_id_for_attempt(base_session_id: str, attempt: int) -> str:
        if attempt < 0:
            raise ValueError("reconnect attempt must be non-negative")
        if attempt == 0:
            return base_session_id
        return f"{base_session_id}-r{attempt}"

    def _run_blocking(self, attempt: int = 0) -> None:
        self.on_status("connecting", "")
        sock = self._connect()
        try:
            session_id = self._session_id_for_attempt(
                str(self.session_start["session_id"]),
                attempt,
            )
            width = int(self.session_start["width"])
            height = int(self.session_start["height"])
            playback_fps = float(self.session_start["playback_fps"])
            session_chunks = int(
                self.session_start.get(
                    "worker_session_chunks",
                    STREAM_DEFAULT_SESSION_CHUNKS,
                )
            )
            if session_chunks < 0:
                raise ValueError("worker_session_chunks must be zero or positive")
            max_chunks = None if session_chunks == 0 else session_chunks
            initial_path = Path(self.session_start["initial_rgb"])
            initial_rgb = initial_path.read_bytes()
            expected_actions = (
                None
                if max_chunks is None
                else 1 + max_chunks * STREAM_OUTPUT_FRAMES
            )
            init_header = {
                "type": "session.init",
                "protocol": STREAM_PROTOCOL,
                "session_id": session_id,
                "hand_mode": "skeleton_frame",
                "live_capture": True,
                "continuous_session": max_chunks is None,
                "width": width,
                "height": height,
                "fps": playback_fps,
                "expected_chunks": max_chunks,
                "payload_kind": (
                    "image/png"
                    if initial_path.suffix.lower() == ".png"
                    else "image/jpeg"
                ),
                "initial_rgb_sha256": hashlib.sha256(initial_rgb).hexdigest(),
            }
            if expected_actions is not None:
                init_header["expected_action_frames"] = expected_actions
            send_message(
                sock,
                init_header,
                initial_rgb,
            )
            accepted_message = recv_message(sock)
            if accepted_message is None:
                raise EOFError("NV worker closed before session.accepted")
            accepted, accepted_payload = accepted_message
            if accepted_payload or accepted.get("type") != "session.accepted":
                raise RuntimeError(f"NV worker rejected session: {accepted}")
            if accepted.get("container") != "fmp4" or not accepted.get(
                "continuous_decoder"
            ):
                raise RuntimeError(
                    "NV worker does not support the required persistent fMP4 stream"
                )
            if not accepted.get("duplex_action_upload"):
                raise RuntimeError(
                    "NV worker does not support duplex action/media flow"
                )
            server_fps = float(accepted.get("output_fps", 0.0))
            if abs(server_fps - playback_fps) > 1e-6:
                raise RuntimeError(
                    f"NV worker FPS={server_fps} != requested FPS={playback_fps}"
                )
            self.on_status("ready", "")
            max_inflight = int(
                self.session_start.get(
                    "worker_max_inflight_chunks",
                    STREAM_MAX_INFLIGHT_CHUNKS,
                )
            )
            if max_inflight < 2 or max_inflight > 8:
                raise ValueError(
                    "worker_max_inflight_chunks must be in [2,8]"
                )
            pending: "queue.Queue[tuple[int, Any]]" = queue.Queue(
                maxsize=max_inflight
            )
            sender_errors: "queue.Queue[BaseException]" = queue.Queue(
                maxsize=1
            )
            sender_stop = threading.Event()
            sender_done = threading.Event()
            action_index = 0
            chunks_sent = 0
            chunks_completed = 0

            def send_loop() -> None:
                nonlocal action_index, chunks_sent
                try:
                    while (
                        not self._stopping.is_set()
                        and not sender_stop.is_set()
                        and (
                            max_chunks is None
                            or chunks_sent < max_chunks
                        )
                    ):
                        chunk = self.slot.start_next()
                        if chunk is None:
                            time.sleep(0.002)
                            continue
                        try:
                            while not sender_stop.is_set():
                                try:
                                    pending.put(
                                        (chunks_sent, chunk),
                                        timeout=0.1,
                                    )
                                    break
                                except queue.Full:
                                    continue
                            else:
                                return
                            samples = (
                                chunk.samples
                                if chunks_sent == 0
                                else chunk.samples[1:]
                            )
                            for sample in samples:
                                send_message(
                                    sock,
                                    {
                                        "type": "action.frame",
                                        "protocol": STREAM_PROTOCOL,
                                        "session_id": session_id,
                                        "hand_mode": "skeleton_frame",
                                        "frame_index": action_index,
                                        "source_time_s": (
                                            action_index / playback_fps
                                        ),
                                        "capture_monotonic_ns": (
                                            sample.server_received_ns
                                        ),
                                        "quest_frame_id": sample.frame_id,
                                        "quest_capture_time_ns": (
                                            sample.capture_time_ns
                                        ),
                                        "head_pose": {
                                            "c2w": sample.c2w.tolist()
                                        },
                                        "payload_kind": "image/png",
                                        "skeleton_sha256": hashlib.sha256(
                                            sample.keypoint_png
                                        ).hexdigest(),
                                    },
                                    sample.keypoint_png,
                                )
                                action_index += 1
                            chunks_sent += 1
                        finally:
                            self.slot.finish(chunk.chunk_id)
                    if (
                        not self._stopping.is_set()
                        and not sender_stop.is_set()
                        and max_chunks is not None
                        and chunks_sent == max_chunks
                    ):
                        send_message(
                            sock,
                            {
                                "type": "session.end",
                                "protocol": STREAM_PROTOCOL,
                                "session_id": session_id,
                                "action_frames_sent": action_index,
                                "last_frame_index": action_index - 1,
                            },
                        )
                except BaseException as exc:
                    try:
                        sender_errors.put_nowait(exc)
                    except queue.Full:
                        pass
                    try:
                        sock.shutdown(socket.SHUT_RDWR)
                    except OSError:
                        pass
                finally:
                    sender_done.set()

            sender = threading.Thread(
                target=send_loop,
                name="memworld-action-uploader",
                daemon=True,
            )
            sender.start()
            decoder = FragmentedMP4Decoder(
                ffmpeg_bin=self.session_start["ffmpeg_bin"],
                width=width,
                height=height,
            )
            saw_video_init = False
            completion: dict[str, Any] | None = None
            while not self._stopping.is_set():
                if not sender_errors.empty():
                    raise sender_errors.get_nowait()
                received = recv_message(sock)
                if received is None:
                    raise EOFError("NV worker closed during media receive")
                header, video_payload = received
                kind = header.get("type")
                if kind == "video.init":
                    if saw_video_init:
                        raise RuntimeError("NV worker sent duplicate video.init")
                    decoder.feed_init(video_payload)
                    saw_video_init = True
                    continue
                if kind == "session.failed":
                    raise RuntimeError(f"NV worker failed session: {header}")
                if kind == "session.completed":
                    completion = header
                    break
                if kind != "video.fragment" or not saw_video_init:
                    raise RuntimeError(f"unexpected NV worker output: {header}")
                try:
                    expected_index, chunk = pending.get(timeout=1.0)
                except queue.Empty as exc:
                    raise RuntimeError(
                        "NV worker returned output with no uploaded chunk"
                    ) from exc
                if int(header.get("chunk_index", -1)) != expected_index:
                    raise RuntimeError(
                        f"unexpected NV worker output: {header}"
                    )
                audit = header.get("audit") or {}
                for field in (
                    "future_rgb_frames",
                    "unknown_rgb_frames",
                    "teacher_forced_rgb_frames",
                ):
                    if audit.get(field, 0) != 0:
                        raise RuntimeError(
                            f"NV worker {field}={audit.get(field)}"
                        )
                decode_started = time.perf_counter()
                decoded_frames = decoder.decode_fragment(
                    video_payload,
                    frame_count=int(header.get("encoded_frame_count", 0)),
                )
                drop_leading = int(
                    header.get("drop_leading_frames", 0)
                    if decoder.persistent_decoder
                    else header.get("fmp4_leading_frames", 0)
                )
                if drop_leading < 0 or drop_leading > len(decoded_frames):
                    raise RuntimeError(
                        f"invalid NV leading-frame drop: {drop_leading}"
                    )
                frames = decoded_frames[drop_leading:]
                if len(frames) != STREAM_OUTPUT_FRAMES:
                    raise RuntimeError(
                        "NV fMP4 decoder produced "
                        f"{len(frames)} visible frames, expected "
                        f"{STREAM_OUTPUT_FRAMES}"
                    )
                decode_ms = (
                    time.perf_counter() - decode_started
                ) * 1000.0
                timing = header.get("server_timing") or {}
                metadata = {
                    "type": "chunk.output",
                    "transport": "nv-tcp-duplex",
                    "chunk_id": chunk.chunk_id,
                    "server_chunk_index": expected_index,
                    "inflight_chunks": pending.qsize() + 1,
                    "frame_count": len(frames),
                    "frame_format": "jpeg",
                    "fps": playback_fps,
                    "drop_first_frame": False,
                    "inference_ms": 1000.0
                    * float(
                        timing.get(
                            "action_ready_to_chunk_complete_seconds",
                            0.0,
                        )
                    ),
                    "server_timing": timing,
                    "mp4_bytes": len(video_payload),
                    "mp4_decode_ms": round(decode_ms, 3),
                    "decoder_mode": (
                        "persistent_h264"
                        if decoder.persistent_decoder
                        else "fmp4_fragment_fallback"
                    ),
                    "checkpoint_sha256": accepted.get(
                        "checkpoint_sha256"
                    ),
                    "temporal_kv": accepted.get("temporal_kv"),
                    "_source_server_received_ns": (
                        chunk.samples[-1].server_received_ns
                    ),
                    "_source_capture_time_ns": (
                        chunk.samples[-1].capture_time_ns
                    ),
                    "_source_frame_id": chunk.samples[-1].frame_id,
                }
                self.on_result(
                    WorkerResult(
                        chunk_id=chunk.chunk_id,
                        metadata=metadata,
                        frames=frames,
                    )
                )
                pending.task_done()
                chunks_completed += 1
                if (
                    max_chunks is None
                    and self._stopping.is_set()
                ):
                    break
            if (
                not self._stopping.is_set()
                and max_chunks is not None
            ):
                if completion is None:
                    raise RuntimeError("NV worker omitted session.completed")
                if chunks_completed != max_chunks:
                    raise RuntimeError(
                        "NV worker completed with "
                        f"{chunks_completed}/{max_chunks} decoded chunks"
                    )
                self.on_status("completed", "")
            sender_stop.set()
            sender.join(timeout=5)
            if sender.is_alive():
                raise RuntimeError("NV action uploader did not stop")
            if not sender_errors.empty():
                raise sender_errors.get_nowait()
        finally:
            if "sender_stop" in locals():
                sender_stop.set()
            if "decoder" in locals():
                decoder.close()
            if "sender" in locals() and sender.is_alive():
                try:
                    sock.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
                sender.join(timeout=2)
            with self._socket_lock:
                self._socket = None
            sock.close()


def build_worker_client(
    *,
    url: str,
    session_start: dict[str, Any],
    slot: Any,
    on_result: Callable[[WorkerResult], None],
    on_status: Callable[[str, str], None],
) -> MemWorldWorkerClient | MemWorldNVStreamClient:
    client_type = (
        MemWorldNVStreamClient
        if urlparse(url).scheme == "tcp"
        else MemWorldWorkerClient
    )
    return client_type(
        url=url,
        session_start=session_start,
        slot=slot,
        on_result=on_result,
        on_status=on_status,
    )
