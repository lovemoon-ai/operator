"""Wire helpers shared by the pose-inference server and clients."""

from __future__ import annotations

from dataclasses import dataclass
import struct
from typing import Any


MAGIC = b"PINF"
VERSION = 1
HEADER = struct.Struct(">4sB3xQQHHI")
MAX_JPEG_BYTES = 8 * 1024 * 1024


class ProtocolError(ValueError):
    """Raised when an image frame does not satisfy the PINF contract."""


@dataclass(frozen=True)
class ImageFrame:
    frame_id: int
    capture_time_ns: int
    width: int
    height: int
    jpeg: bytes


class LatestPose:
    """A one-item queue that deliberately discards work the model has missed."""

    def __init__(self) -> None:
        self._pose: dict[str, Any] | None = None

    def replace(self, pose: dict[str, Any]) -> None:
        self._pose = pose

    def take(self) -> dict[str, Any] | None:
        pose, self._pose = self._pose, None
        return pose


def pack_image_frame(frame_id: int, capture_time_ns: int, width: int, height: int, jpeg: bytes) -> bytes:
    if not jpeg or len(jpeg) > MAX_JPEG_BYTES:
        raise ProtocolError("JPEG payload size is invalid")
    if not 0 < width <= 65535 or not 0 < height <= 65535:
        raise ProtocolError("image dimensions are invalid")
    return HEADER.pack(MAGIC, VERSION, frame_id, capture_time_ns, width, height, len(jpeg)) + jpeg


def unpack_image_frame(payload: bytes) -> ImageFrame:
    if len(payload) < HEADER.size:
        raise ProtocolError("image frame is shorter than its header")
    magic, version, frame_id, capture_time_ns, width, height, jpeg_size = HEADER.unpack_from(payload)
    if magic != MAGIC:
        raise ProtocolError("unexpected image frame magic")
    if version != VERSION:
        raise ProtocolError("unsupported image frame version")
    if not 0 < width <= 65535 or not 0 < height <= 65535:
        raise ProtocolError("image dimensions are invalid")
    if not 0 < jpeg_size <= MAX_JPEG_BYTES or len(payload) != HEADER.size + jpeg_size:
        raise ProtocolError("JPEG payload size is invalid")
    return ImageFrame(frame_id, capture_time_ns, width, height, payload[HEADER.size:])
