"""Length-prefixed JSON and binary framing for an NV MemWorld stream worker."""

from __future__ import annotations

import json
import socket
import struct
from typing import Any


HEADER_PREFIX = struct.Struct(">I")
MAX_HEADER_BYTES = 16 * 1024 * 1024
MAX_PAYLOAD_BYTES = 256 * 1024 * 1024


class ProtocolError(RuntimeError):
    pass


def recv_exact(
    sock: socket.socket,
    size: int,
    *,
    allow_clean_eof: bool = False,
) -> bytes | None:
    data = bytearray()
    while len(data) < size:
        block = sock.recv(size - len(data))
        if not block:
            if allow_clean_eof and not data:
                return None
            raise EOFError(f"socket closed after {len(data)}/{size} bytes")
        data.extend(block)
    return bytes(data)


def send_message(
    sock: socket.socket,
    header: dict[str, Any],
    payload: bytes = b"",
) -> None:
    if len(payload) > MAX_PAYLOAD_BYTES:
        raise ProtocolError(f"payload too large: {len(payload)}")
    wire_header = dict(header)
    wire_header["payload_bytes"] = len(payload)
    encoded = json.dumps(
        wire_header,
        ensure_ascii=False,
        allow_nan=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")
    if len(encoded) > MAX_HEADER_BYTES:
        raise ProtocolError(f"header too large: {len(encoded)}")
    sock.sendall(HEADER_PREFIX.pack(len(encoded)) + encoded + payload)


def recv_message(
    sock: socket.socket,
) -> tuple[dict[str, Any], bytes] | None:
    prefix = recv_exact(sock, HEADER_PREFIX.size, allow_clean_eof=True)
    if prefix is None:
        return None
    (header_size,) = HEADER_PREFIX.unpack(prefix)
    if not 0 < header_size <= MAX_HEADER_BYTES:
        raise ProtocolError(f"invalid header size: {header_size}")
    raw_header = recv_exact(sock, header_size)
    assert raw_header is not None
    header = json.loads(raw_header.decode("utf-8"))
    if not isinstance(header, dict):
        raise ProtocolError("message header is not an object")
    payload_size = header.get("payload_bytes", 0)
    if (
        isinstance(payload_size, bool)
        or not isinstance(payload_size, int)
        or not 0 <= payload_size <= MAX_PAYLOAD_BYTES
    ):
        raise ProtocolError(f"invalid payload size: {payload_size!r}")
    payload = recv_exact(sock, payload_size)
    assert payload is not None
    return header, payload
