"""Validation and decoding for MemWorld live JPEG frame sequences."""

from __future__ import annotations

import io
import zipfile


FRAME_COUNT = 17
LIVE_FRAME_MIME_TYPE = "application/vnd.operator.memworld-frames+zip"


def unpack_jpeg_sequence(payload: bytes) -> tuple[bytes, ...]:
    """Return exactly 17 deterministic JPEG entries from a live result ZIP."""
    expected = [f"frames/{index:03d}.jpg" for index in range(FRAME_COUNT)]
    try:
        with zipfile.ZipFile(io.BytesIO(payload)) as archive:
            if archive.namelist() != expected:
                raise ValueError(
                    "live frame ZIP must contain exactly 17 ordered JPEG frames"
                )
            frames = tuple(archive.read(name) for name in expected)
    except zipfile.BadZipFile as error:
        raise ValueError("worker returned an invalid live frame ZIP") from error

    for index, frame in enumerate(frames):
        if not frame.startswith(b"\xff\xd8") or not frame.endswith(b"\xff\xd9"):
            raise ValueError(f"live frame {index} is not a complete JPEG")
    return frames
