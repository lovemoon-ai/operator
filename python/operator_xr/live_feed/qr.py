"""Minimal QR encoder, enough to print a server address for the headset to scan.

Dependency-free on purpose: the Live Feed server is meant to run from a bare
checkout, and pulling in an imaging stack just to draw a code on a terminal is
a poor trade. Scope is deliberately narrow -- byte mode, error level M,
versions 1..10 -- which covers the connection payloads we emit (well under 200
bytes) and nothing more.

Correctness is cross-checked against `segno` in the test-suite when that
package happens to be installed; the encoder itself never imports it.
"""

from __future__ import annotations

import os
import re
import socket
import sys
import time
from typing import Iterable, Sequence


__all__ = [
    "QrError",
    "encode",
    "render_ascii",
    "local_ip",
    "connection_payload",
    "resolve_advertised_host",
    "print_connection_banner",
    "candidate_lan_ips",
]


class QrError(ValueError):
    """Raised when the payload does not fit the supported QR versions."""


# --- error correction level M tables (versions 1..10) ----------------------
# (ec_codewords_per_block, group1_blocks, group1_data, group2_blocks, group2_data)
_EC_M: dict[int, tuple[int, int, int, int, int]] = {
    1: (10, 1, 16, 0, 0),
    2: (16, 1, 28, 0, 0),
    3: (26, 1, 44, 0, 0),
    4: (18, 2, 32, 0, 0),
    5: (24, 2, 43, 0, 0),
    6: (16, 4, 27, 0, 0),
    7: (18, 4, 31, 0, 0),
    8: (22, 2, 38, 2, 39),
    9: (22, 3, 36, 2, 37),
    10: (26, 4, 43, 1, 44),
}

#: Row/column centres of the alignment patterns per version (empty for v1).
_ALIGNMENT: dict[int, list[int]] = {
    1: [],
    2: [6, 18],
    3: [6, 22],
    4: [6, 26],
    5: [6, 30],
    6: [6, 34],
    7: [6, 22, 38],
    8: [6, 24, 42],
    9: [6, 26, 46],
    10: [6, 28, 50],
}

_EC_LEVEL_M_BITS = 0b00  # format-info bits for level M


# --- GF(256) arithmetic ----------------------------------------------------

def _build_tables() -> tuple[list[int], list[int]]:
    exp = [0] * 512
    log = [0] * 256
    value = 1
    for i in range(255):
        exp[i] = value
        log[value] = i
        value <<= 1
        if value & 0x100:
            value ^= 0x11D  # QR's primitive polynomial
    for i in range(255, 512):
        exp[i] = exp[i - 255]
    return exp, log


_EXP, _LOG = _build_tables()


def _gf_mul(a: int, b: int) -> int:
    if a == 0 or b == 0:
        return 0
    return _EXP[_LOG[a] + _LOG[b]]


def _generator_poly(degree: int) -> list[int]:
    poly = [1]
    for i in range(degree):
        # multiply by (x - alpha^i)
        next_poly = [0] * (len(poly) + 1)
        for j, coeff in enumerate(poly):
            next_poly[j] ^= coeff
            next_poly[j + 1] ^= _gf_mul(coeff, _EXP[i])
        poly = next_poly
    return poly


def _ec_codewords(data: Sequence[int], count: int) -> list[int]:
    generator = _generator_poly(count)
    remainder = list(data) + [0] * count
    for i in range(len(data)):
        factor = remainder[i]
        if factor == 0:
            continue
        for j, coeff in enumerate(generator):
            remainder[i + j] ^= _gf_mul(coeff, factor)
    return remainder[len(data):]


# --- bit assembly ----------------------------------------------------------

def _char_count_bits(version: int) -> int:
    # Byte mode: 8 bits for versions 1..9, 16 for 10..26.
    return 8 if version <= 9 else 16


def _total_data_codewords(version: int) -> int:
    _, g1, g1d, g2, g2d = _EC_M[version]
    return g1 * g1d + g2 * g2d


def _pick_version(length: int) -> int:
    for version in sorted(_EC_M):
        capacity = _total_data_codewords(version)
        header_bits = 4 + _char_count_bits(version)
        if header_bits + length * 8 <= capacity * 8:
            return version
    raise QrError(f"payload of {length} bytes exceeds supported QR versions (max v10-M)")


def _encode_data(payload: bytes, version: int) -> list[int]:
    bits: list[int] = []

    def push(value: int, width: int) -> None:
        for shift in range(width - 1, -1, -1):
            bits.append((value >> shift) & 1)

    push(0b0100, 4)  # byte mode
    push(len(payload), _char_count_bits(version))
    for byte in payload:
        push(byte, 8)

    capacity_bits = _total_data_codewords(version) * 8
    # Terminator: up to four zero bits, truncated if we are near the limit.
    push(0, min(4, capacity_bits - len(bits)))
    # Pad to a byte boundary, then alternate the two specified pad bytes.
    while len(bits) % 8:
        bits.append(0)
    codewords = [int("".join(str(b) for b in bits[i:i + 8]), 2) for i in range(0, len(bits), 8)]
    for index in range(_total_data_codewords(version) - len(codewords)):
        codewords.append(0xEC if index % 2 == 0 else 0x11)
    return codewords


def _interleave(codewords: Sequence[int], version: int) -> list[int]:
    ec_per_block, g1, g1d, g2, g2d = _EC_M[version]
    blocks: list[list[int]] = []
    offset = 0
    for _ in range(g1):
        blocks.append(list(codewords[offset:offset + g1d]))
        offset += g1d
    for _ in range(g2):
        blocks.append(list(codewords[offset:offset + g2d]))
        offset += g2d

    ec_blocks = [_ec_codewords(block, ec_per_block) for block in blocks]

    out: list[int] = []
    for i in range(max(len(b) for b in blocks)):
        for block in blocks:
            if i < len(block):
                out.append(block[i])
    for i in range(ec_per_block):
        for block in ec_blocks:
            out.append(block[i])
    return out


# --- matrix construction ---------------------------------------------------

def _new_matrix(size: int) -> list[list[int | None]]:
    return [[None] * size for _ in range(size)]


def _place_finder(matrix: list[list[int | None]], row: int, col: int) -> None:
    for r in range(-1, 8):
        for c in range(-1, 8):
            rr, cc = row + r, col + c
            if not (0 <= rr < len(matrix) and 0 <= cc < len(matrix)):
                continue
            in_ring = (
                (0 <= r <= 6 and c in (0, 6))
                or (0 <= c <= 6 and r in (0, 6))
                or (2 <= r <= 4 and 2 <= c <= 4)
            )
            matrix[rr][cc] = 1 if in_ring else 0


def _place_function_patterns(matrix: list[list[int | None]], version: int) -> None:
    size = len(matrix)
    _place_finder(matrix, 0, 0)
    _place_finder(matrix, 0, size - 7)
    _place_finder(matrix, size - 7, 0)

    for i in range(8, size - 8):
        bit = 1 if i % 2 == 0 else 0
        if matrix[6][i] is None:
            matrix[6][i] = bit
        if matrix[i][6] is None:
            matrix[i][6] = bit

    centres = _ALIGNMENT[version]
    for r in centres:
        for c in centres:
            # Skip the three corners already occupied by finder patterns.
            if (r, c) in ((6, 6), (6, size - 7), (size - 7, 6)):
                continue
            for dr in range(-2, 3):
                for dc in range(-2, 3):
                    matrix[r + dr][c + dc] = 1 if max(abs(dr), abs(dc)) != 1 else 0

    matrix[size - 8][8] = 1  # dark module


def _reserve_format_areas(size: int) -> set[tuple[int, int]]:
    reserved: set[tuple[int, int]] = set()
    for i in range(9):
        reserved.add((8, i))
        reserved.add((i, 8))
    for i in range(8):
        reserved.add((8, size - 1 - i))
        reserved.add((size - 1 - i, 8))
    return reserved


def _place_data(matrix: list[list[int | None]], bits: Iterable[int], reserved: set[tuple[int, int]]) -> None:
    size = len(matrix)
    bit_iter = iter(bits)
    col = size - 1
    upward = True
    while col > 0:
        if col == 6:  # the vertical timing pattern column is skipped entirely
            col -= 1
        rows = range(size - 1, -1, -1) if upward else range(size)
        for row in rows:
            for c in (col, col - 1):
                if matrix[row][c] is not None or (row, c) in reserved:
                    continue
                try:
                    matrix[row][c] = next(bit_iter)
                except StopIteration:
                    matrix[row][c] = 0
        upward = not upward
        col -= 2


_MASKS = [
    lambda r, c: (r + c) % 2 == 0,
    lambda r, c: r % 2 == 0,
    lambda r, c: c % 3 == 0,
    lambda r, c: (r + c) % 3 == 0,
    lambda r, c: (r // 2 + c // 3) % 2 == 0,
    lambda r, c: (r * c) % 2 + (r * c) % 3 == 0,
    lambda r, c: ((r * c) % 2 + (r * c) % 3) % 2 == 0,
    lambda r, c: ((r + c) % 2 + (r * c) % 3) % 2 == 0,
]


def _format_bits(mask: int) -> list[int]:
    value = (_EC_LEVEL_M_BITS << 3) | mask
    # Long division by the BCH(15,5) generator polynomial 0x537.
    remainder = value << 10
    while remainder.bit_length() > 10:
        remainder ^= 0x537 << (remainder.bit_length() - 11)
    bits_value = ((value << 10) | remainder) ^ 0x5412
    return [(bits_value >> i) & 1 for i in range(14, -1, -1)]


def _place_format(matrix: list[list[int | None]], mask: int) -> None:
    size = len(matrix)
    bits = _format_bits(mask)
    # Copy 1 (around the top-left finder).
    positions_a = [(8, 0), (8, 1), (8, 2), (8, 3), (8, 4), (8, 5), (8, 7), (8, 8),
                   (7, 8), (5, 8), (4, 8), (3, 8), (2, 8), (1, 8), (0, 8)]
    for bit, (r, c) in zip(bits, positions_a):
        matrix[r][c] = bit
    # Copy 2 (split between the other two finders).
    positions_b = [(size - 1 - i, 8) for i in range(7)] + [(8, size - 8 + i) for i in range(8)]
    for bit, (r, c) in zip(bits, positions_b):
        matrix[r][c] = bit


def _version_bits(version: int) -> list[int]:
    remainder = version << 12
    while remainder.bit_length() > 12:
        remainder ^= 0x1F25 << (remainder.bit_length() - 13)
    value = (version << 12) | remainder
    return [(value >> i) & 1 for i in range(17, -1, -1)]


def _place_version(matrix: list[list[int | None]], version: int) -> None:
    if version < 7:
        return
    size = len(matrix)
    bits = _version_bits(version)
    # Spec indexes these least-significant-bit first.
    ordered = list(reversed(bits))
    for i in range(18):
        r, c = i // 3, i % 3
        matrix[r][size - 11 + c] = ordered[i]
        matrix[size - 11 + c][r] = ordered[i]


def _penalty(matrix: list[list[int]]) -> int:
    size = len(matrix)
    score = 0

    # Rule 1: runs of five or more same-coloured modules in a row/column.
    for line in list(matrix) + [list(col) for col in zip(*matrix)]:
        run = 1
        for i in range(1, size):
            if line[i] == line[i - 1]:
                run += 1
            else:
                if run >= 5:
                    score += 3 + (run - 5)
                run = 1
        if run >= 5:
            score += 3 + (run - 5)

    # Rule 2: 2x2 blocks of one colour.
    for r in range(size - 1):
        for c in range(size - 1):
            block = matrix[r][c] + matrix[r][c + 1] + matrix[r + 1][c] + matrix[r + 1][c + 1]
            if block in (0, 4):
                score += 3

    # Rule 3: finder-like 1:1:3:1:1 patterns.
    pattern_a = [1, 0, 1, 1, 1, 0, 1, 0, 0, 0, 0]
    pattern_b = list(reversed(pattern_a))
    for line in list(matrix) + [list(col) for col in zip(*matrix)]:
        for i in range(size - 10):
            window = line[i:i + 11]
            if window == pattern_a or window == pattern_b:
                score += 40

    # Rule 4: deviation from a 50% dark ratio.
    dark = sum(sum(row) for row in matrix)
    percent = dark * 100 // (size * size)
    score += 10 * (abs(percent - 50) // 5)
    return score


def encode(payload: str | bytes) -> list[list[int]]:
    """Encode ``payload`` and return the QR matrix as rows of 0/1 ints."""
    data = payload.encode("utf-8") if isinstance(payload, str) else bytes(payload)
    version = _pick_version(len(data))
    size = version * 4 + 17

    codewords = _interleave(_encode_data(data, version), version)
    bits = [(byte >> shift) & 1 for byte in codewords for shift in range(7, -1, -1)]

    base = _new_matrix(size)
    _place_function_patterns(base, version)
    reserved = _reserve_format_areas(size)
    if version >= 7:
        for i in range(18):
            r, c = i // 3, i % 3
            reserved.add((r, size - 11 + c))
            reserved.add((size - 11 + c, r))
    _place_data(base, bits, reserved)

    best: list[list[int]] | None = None
    best_score = -1
    for mask_index, mask_fn in enumerate(_MASKS):
        candidate = [[0] * size for _ in range(size)]
        for r in range(size):
            for c in range(size):
                value = base[r][c]
                if value is None:
                    value = 0
                # Function patterns are never masked.
                is_function = (r, c) in reserved or _is_function_module(base, r, c, size, version)
                if not is_function and mask_fn(r, c):
                    value ^= 1
                candidate[r][c] = value
        _place_format(candidate, mask_index)
        _place_version(candidate, version)
        score = _penalty(candidate)
        if best is None or score < best_score:
            best, best_score = candidate, score
    assert best is not None
    return best


def _is_function_module(base: list[list[int | None]], r: int, c: int, size: int, version: int) -> bool:
    if r < 9 and c < 9:
        return True
    if r < 9 and c >= size - 8:
        return True
    if r >= size - 8 and c < 9:
        return True
    if r == 6 or c == 6:
        return True
    for ar in _ALIGNMENT[version]:
        for ac in _ALIGNMENT[version]:
            if (ar, ac) in ((6, 6), (6, size - 7), (size - 7, 6)):
                continue
            if abs(r - ar) <= 2 and abs(c - ac) <= 2:
                return True
    if version >= 7 and ((r < 6 and c >= size - 11) or (c < 6 and r >= size - 11)):
        return True
    return False


def render_ascii(
    matrix: Sequence[Sequence[int]],
    quiet_zone: int = 4,
    scale: float = 1.0,
    compact: bool | None = None,
    *,
    cell_width_px: float | None = None,
    cell_height_px: float | None = None,
) -> str:
    """Render a high-contrast QR directly in a terminal.

    ``scale`` controls the vertical sample count per QR module. ``cell_width_px``
    and ``cell_height_px`` describe the terminal's real character cell; the
    horizontal sample count is derived from those metrics so the complete
    rendered rectangle is physically square instead of assuming every font is
    exactly 1:2. A half-block packs two vertical samples into one text row:

    * ``scale=1.0`` -> 2 chars wide, one full text row per module row (largest,
      easiest for a camera to resolve).
    * ``scale=0.5`` -> 1 char wide, two module rows per text row (half the size
      each way; the grid cannot go smaller without distorting).

    In-between values round to whichever vertical resolution the character grid
    can represent. ``compact=True`` is kept as an alias for ``scale=0.5``.

    Colours are exact 24-bit black/white rather than ANSI palette entries.
    Palette colour 0 is theme-configurable (and is medium grey in several
    popular themes), which can leave too little camera contrast for a scanner.
    Solid pairs use only the cell background; ``▀`` is needed only where the
    upper and lower modules differ. This avoids font-glyph seams over most of
    the code while retaining the compact, square-module geometry.
    """
    if compact is not None:
        scale = 0.5 if compact else 1.0
    vertical_samples = max(1, round(2 * scale))
    has_cell_metrics = (
        cell_width_px is not None
        and cell_width_px > 0
        and cell_height_px is not None
        and cell_height_px > 0
    )
    resolved_width = (
        float(cell_width_px)
        if cell_width_px is not None and cell_width_px > 0
        else 1.0
    )
    resolved_height = (
        float(cell_height_px)
        if cell_height_px is not None and cell_height_px > 0
        else 2.0
    )

    size = len(matrix)
    padded = size + quiet_zone * 2
    horizontal_samples = vertical_samples
    left_padding = 0
    while True:
        source_half_rows = padded * vertical_samples
        text_rows = (source_half_rows + 1) // 2
        # A terminal paints complete cells, including the unused lower half of
        # an odd compact QR. Size the horizontal grid against that real painted
        # height so the outer white rectangle is square as well as the modules.
        if has_cell_metrics:
            horizontal_samples = max(
                1,
                round(vertical_samples * resolved_height / (2 * resolved_width)),
            )
            content_width = padded * horizontal_samples
            width = max(1, round(text_rows * resolved_height / resolved_width))
        else:
            content_width = padded * vertical_samples
            width = content_width
        if width >= content_width:
            left_padding = (width - content_width) // 2
            break
        vertical_samples += 1
    rendered_half_rows = text_rows * 2

    def dark(half_row: int, col: int) -> bool:
        if half_row >= source_half_rows:
            return False
        content_col = col - left_padding
        if content_col < 0 or content_col >= padded * horizontal_samples:
            return False
        padded_row = half_row // vertical_samples
        padded_col = content_col // horizontal_samples
        module_row = padded_row - quiet_zone
        module_col = padded_col - quiet_zone
        return bool(
            0 <= module_row < size
            and 0 <= module_col < size
            and matrix[module_row][module_col]
        )

    reset = "\033[0m"

    lines: list[str] = []
    for top in range(0, rendered_half_rows, 2):
        parts: list[str] = []
        active: tuple[bool, bool] | None = None
        for col in range(width):
            # Upper half-cell is the glyph foreground, lower half the background.
            upper = dark(top, col)
            lower = dark(top + 1, col)
            style = (upper, lower)
            if style != active:
                foreground = 0 if upper else 255
                background = 0 if lower else 255
                parts.append(
                    f"\033[38;2;{foreground};{foreground};{foreground};"
                    f"48;2;{background};{background};{background}m"
                )
                active = style
            # The background paints the full cell, including font line
            # spacing. A glyph is only needed to split unlike module pairs.
            parts.append(" " if upper == lower else "▀")
        lines.append("".join(parts) + reset)
    return "\n".join(lines)


def _terminal_cell_pixels(timeout_s: float = 0.15) -> tuple[float, float] | None:
    """Return the real terminal cell width/height in pixels when available."""
    try:
        override_width = float(os.environ.get("OPERATOR_TERM_CELL_WIDTH_PX", "0"))
        override_height = float(os.environ.get("OPERATOR_TERM_CELL_HEIGHT_PX", "0"))
    except ValueError:
        override_width = override_height = 0.0
    if override_width > 0 and override_height > 0:
        return override_width, override_height

    try:
        if not sys.stdout.isatty():
            return None
        import fcntl
        import struct
        import termios

        rows, columns, width_px, height_px = struct.unpack(
            "HHHH",
            fcntl.ioctl(
                sys.stdout.fileno(),
                termios.TIOCGWINSZ,
                struct.pack("HHHH", 0, 0, 0, 0),
            ),
        )
        if rows > 0 and columns > 0 and width_px > 0 and height_px > 0:
            return width_px / columns, height_px / rows
    except (AttributeError, ImportError, OSError, ValueError):
        pass

    # XTerm window operation 16 reports the character cell as
    # CSI 6 ; height ; width t. Query /dev/tty rather than stdin so callers that
    # pipe capture data into the process do not lose bytes.
    tty_fd: int | None = None
    old_settings = None
    try:
        import select
        import termios
        import tty

        tty_fd = os.open("/dev/tty", os.O_RDWR | os.O_NOCTTY)
        old_settings = termios.tcgetattr(tty_fd)
        tty.setcbreak(tty_fd)
        os.write(tty_fd, b"\x1b[16t")
        deadline = time.monotonic() + timeout_s
        response = bytearray()
        pattern = re.compile(rb"\x1b\[6;(\d+);(\d+)t")
        while time.monotonic() < deadline:
            remaining = max(0.0, deadline - time.monotonic())
            readable, _, _ = select.select([tty_fd], [], [], remaining)
            if not readable:
                break
            response.extend(os.read(tty_fd, 64))
            match = pattern.search(response)
            if match:
                height = float(match.group(1))
                width = float(match.group(2))
                if width > 0 and height > 0:
                    return width, height
    except (ImportError, OSError, ValueError):
        pass
    finally:
        if tty_fd is not None:
            if old_settings is not None:
                try:
                    import termios

                    termios.tcsetattr(tty_fd, termios.TCSADRAIN, old_settings)
                except (ImportError, OSError):
                    pass
            os.close(tty_fd)
    return None


def _terminal_row_count(
    matrix: Sequence[Sequence[int]],
    quiet_zone: int,
    scale: float,
) -> int:
    cell = max(1, round(2 * scale))
    half_rows = (len(matrix) + quiet_zone * 2) * cell
    return (half_rows + 1) // 2


def _qr_rgb(
    matrix: Sequence[Sequence[int]],
    *,
    quiet_zone: int = 4,
    module_pixels: int = 4,
) -> tuple[bytes, int]:
    """Return an exact square RGB raster without creating an image file."""
    size = len(matrix)
    side = (size + quiet_zone * 2) * module_pixels
    pixels = bytearray()
    for y in range(side):
        module_row = y // module_pixels - quiet_zone
        for x in range(side):
            module_col = x // module_pixels - quiet_zone
            dark = bool(
                0 <= module_row < size
                and 0 <= module_col < size
                and matrix[module_row][module_col]
            )
            pixels.extend(b"\x00\x00\x00" if dark else b"\xff\xff\xff")
    return bytes(pixels), side


def _kitty_graphics_commands(
    matrix: Sequence[Sequence[int]],
    *,
    rows: int,
    quiet_zone: int = 4,
) -> list[bytes]:
    """Encode a square QR for Kitty Graphics, preserving its physical aspect.

    Only ``r`` (display rows) is specified. Per the protocol, the terminal then
    computes the column count from its real cell dimensions and the square
    source image. Supplying both ``c`` and ``r`` would repeat the same faulty
    fixed-cell-aspect assumption as the Unicode renderer.
    """
    import base64
    import zlib

    rgb, side = _qr_rgb(matrix, quiet_zone=quiet_zone)
    encoded = base64.standard_b64encode(zlib.compress(rgb, 9))
    chunks = [encoded[offset:offset + 4096] for offset in range(0, len(encoded), 4096)]
    commands: list[bytes] = []
    for index, chunk in enumerate(chunks):
        more = int(index < len(chunks) - 1)
        if index == 0:
            control = (
                f"a=T,f=24,s={side},v={side},o=z,q=2,r={rows},C=1,m={more}"
            ).encode("ascii")
        else:
            control = f"q=2,m={more}".encode("ascii")
        commands.append(b"\x1b_G" + control + b";" + chunk + b"\x1b\\")
    return commands


def _tmux_passthrough(command: bytes) -> bytes:
    """Wrap one terminal command in tmux DCS passthrough."""
    return b"\x1bPtmux;" + command.replace(b"\x1b", b"\x1b\x1b") + b"\x1b\\"


def _kitty_graphics_supported() -> bool:
    try:
        if not sys.stdout.isatty() or getattr(sys.stdout, "buffer", None) is None:
            return False
    except (AttributeError, ValueError):
        return False

    # These terminals implement Kitty Graphics. Ghostty leaves its resource
    # variables in the environment even when TERM_PROGRAM becomes "tmux".
    markers = " ".join(
        os.environ.get(name, "")
        for name in (
            "TERM",
            "TERM_PROGRAM",
            "GHOSTTY_RESOURCES_DIR",
            "KITTY_WINDOW_ID",
            "WEZTERM_PANE",
        )
    ).lower()
    return any(name in markers for name in ("ghostty", "kitty", "wezterm"))


def _print_square_terminal_qr(
    matrix: Sequence[Sequence[int]],
    *,
    rows: int,
) -> bool:
    """Display a physically square QR through terminal-native graphics."""
    if not _kitty_graphics_supported():
        return False

    import subprocess
    import time

    commands = _kitty_graphics_commands(matrix, rows=rows)
    pane = os.environ.get("TMUX_PANE", "") if os.environ.get("TMUX") else ""
    original_local = ""
    changed_passthrough = False
    if pane:
        try:
            original_local = subprocess.run(
                ["tmux", "show-options", "-pv", "-t", pane, "allow-passthrough"],
                check=True,
                capture_output=True,
                text=True,
            ).stdout.strip()
            effective = original_local
            if not effective:
                effective = subprocess.run(
                    ["tmux", "show-options", "-gv", "allow-passthrough"],
                    check=True,
                    capture_output=True,
                    text=True,
                ).stdout.strip()
            if effective not in ("on", "all"):
                subprocess.run(
                    ["tmux", "set-option", "-p", "-t", pane, "allow-passthrough", "on"],
                    check=True,
                    capture_output=True,
                )
                changed_passthrough = True
            commands = [_tmux_passthrough(command) for command in commands]
        except (OSError, subprocess.SubprocessError):
            return False

    try:
        stream = sys.stdout.buffer
        for command in commands:
            stream.write(command)
        # C=1 keeps the graphics command from moving the real terminal cursor.
        # Move through normal text output instead so tmux and Ghostty retain the
        # same cursor position after the image.
        stream.write(b"\n" * rows)
        stream.flush()
        return True
    except (AttributeError, OSError, ValueError):
        return False
    finally:
        if changed_passthrough:
            # Give tmux's event loop time to forward the already-flushed APC
            # before restoring this pane-local option.
            time.sleep(0.05)
            try:
                if original_local:
                    subprocess.run(
                        [
                            "tmux",
                            "set-option",
                            "-p",
                            "-t",
                            pane,
                            "allow-passthrough",
                            original_local,
                        ],
                        check=False,
                        capture_output=True,
                    )
                else:
                    subprocess.run(
                        ["tmux", "set-option", "-pu", "-t", pane, "allow-passthrough"],
                        check=False,
                        capture_output=True,
                    )
            except OSError:
                pass


# POSIX interface flags (same values on Linux and the BSDs/macOS).
_IFF_UP = 0x1
_IFF_LOOPBACK = 0x8
_IFF_POINTOPOINT = 0x10


def _is_private_ipv4(ip: str) -> bool:
    if ip.startswith("192.168.") or ip.startswith("10."):
        return True
    if ip.startswith("172."):
        try:
            return 16 <= int(ip.split(".")[1]) <= 31
        except (IndexError, ValueError):
            return False
    return False


def _iter_interface_ipv4() -> Iterable[tuple[str, str, int]]:
    """Yield ``(name, ipv4, flags)`` for each interface via ``getifaddrs``.

    Pure ctypes so it stays dependency-free. Raises if ``getifaddrs`` is
    unavailable (non-POSIX), which callers treat as "fall back to probing".
    """
    import ctypes
    import ctypes.util

    class _ifaddrs(ctypes.Structure):
        pass

    # Only the leading fields matter; the rest of the struct is left off since
    # we never dereference past ifa_addr. Field order/alignment matches both
    # glibc and the macOS/BSD layout.
    _ifaddrs._fields_ = [
        ("ifa_next", ctypes.POINTER(_ifaddrs)),
        ("ifa_name", ctypes.c_char_p),
        ("ifa_flags", ctypes.c_uint),
        ("ifa_addr", ctypes.POINTER(ctypes.c_ubyte)),
    ]

    libc_name = ctypes.util.find_library("c")
    if libc_name is None:
        raise OSError("libc not found")
    libc = ctypes.CDLL(libc_name, use_errno=True)

    head = ctypes.POINTER(_ifaddrs)()
    if libc.getifaddrs(ctypes.byref(head)) != 0:
        raise OSError(ctypes.get_errno(), "getifaddrs failed")
    try:
        node = head
        while node:
            entry = node.contents
            node = entry.ifa_next
            if not entry.ifa_addr:
                continue
            raw = bytes(ctypes.cast(entry.ifa_addr, ctypes.POINTER(ctypes.c_ubyte * 8)).contents)
            # sockaddr: macOS has sa_len at byte 0 then sa_family; Linux has a
            # 2-byte little-endian sa_family. Either way the IPv4 address sits
            # at bytes 4..8 of a sockaddr_in.
            if sys.platform == "darwin":
                is_inet = raw[1] == socket.AF_INET
            else:
                is_inet = raw[0] == socket.AF_INET and raw[1] == 0
            if not is_inet:
                continue
            ip = socket.inet_ntoa(bytes(raw[4:8]))
            yield entry.ifa_name.decode("utf-8", "replace"), ip, entry.ifa_flags
    finally:
        libc.freeifaddrs(head)


def candidate_lan_ips() -> list[str]:
    """LAN IPv4 addresses a headset on the same network could dial.

    Excludes loopback, link-local, and point-to-point interfaces -- the last
    of which is what keeps a VPN tunnel (e.g. utun) from being advertised as
    the server address when it has stolen the default route. Private-range
    addresses are listed first.
    """
    seen: list[str] = []
    try:
        for _name, ip, flags in _iter_interface_ipv4():
            if not (flags & _IFF_UP):
                continue
            if flags & (_IFF_LOOPBACK | _IFF_POINTOPOINT):
                continue
            if ip == "127.0.0.1" or ip.startswith("169.254."):
                continue
            if ip not in seen:
                seen.append(ip)
    except Exception:
        return []
    seen.sort(key=lambda ip: 0 if _is_private_ipv4(ip) else 1)
    return seen


def local_ip(target: str = "8.8.8.8") -> str:
    """Best-effort LAN address of this host.

    Prefers a real (non-tunnel) LAN interface via ``getifaddrs``. Falls back to
    a routing probe -- opening a UDP socket toward ``target`` to see which
    interface the routing table picks -- only when enumeration is unavailable.
    The probe is what mis-selected a VPN address before, so it is last resort.
    """
    candidates = candidate_lan_ips()
    if candidates:
        return candidates[0]

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.connect((target, 80))
        return str(sock.getsockname()[0])
    except OSError:
        try:
            return socket.gethostbyname(socket.gethostname())
        except OSError:
            return "127.0.0.1"
    finally:
        sock.close()


def resolve_advertised_host(bind_host: str) -> str:
    """Turn a bind address into one the headset can actually dial.

    A wildcard bind says nothing about where to connect, so substitute this
    machine's LAN address.
    """
    if bind_host in ("", "0.0.0.0", "::", "*"):
        return local_ip()
    return bind_host


def print_connection_banner(
    bind_host: str,
    push_port: int,
    result_port: int | None,
    auth_token: str = "",
    *,
    show_qr: bool = True,
    label: str = "Live Feed server",
    qr_scale: float = 0.7,
) -> None:
    """Print the address the headset should connect to, plus a scannable QR.

    Saves the operator from typing an IP on a virtual keyboard inside a
    headset. Shared by the CLI server and the examples so every entry point
    advertises itself the same way. ``result_port=None`` means this process
    does not serve the result channel, so it is left out of the payload.

    ``qr_scale`` keeps the QR compact enough to fit a typical terminal. The QR
    is deliberately the final banner output: in a 24-row terminal, printing
    even one log line after it can scroll away its top quiet zone and make the
    otherwise-valid code impossible to detect.
    """
    host = resolve_advertised_host(bind_host)
    # Without a result channel the headset should not be told to expect one;
    # point it at the push port only and let it keep its configured default.
    payload = connection_payload(host, push_port, result_port, auth_token)

    print()
    print(f"  {label}:  {host}")
    # If more than one LAN address exists, the auto-pick may not be the one the
    # headset can reach. Show the others so the operator can retry with --host.
    if resolve_advertised_host(bind_host) == host:
        others = [ip for ip in candidate_lan_ips() if ip != host]
        if others:
            print(f"  other addresses:   {', '.join(others)}  (use --host if the QR will not connect)")
    if result_port is None:
        print(f"  push port:     {push_port}  (no result channel)")
    else:
        print(f"  push / result: {push_port} / {result_port}")
    if auth_token:
        print("  auth token:    (embedded in QR)")
    print()
    print("  Scan from the headset: Live Feed settings -> camera icon next to Server host.")
    print("  Same machine over USB instead:")
    reverse = f"    adb reverse tcp:{push_port} tcp:{push_port}"
    if result_port is not None:
        reverse += f" && adb reverse tcp:{result_port} tcp:{result_port}"
    print(reverse)
    print()
    if show_qr:
        try:
            matrix = encode(payload)
            rows = _terminal_row_count(matrix, quiet_zone=4, scale=qr_scale)
            if not _print_square_terminal_qr(matrix, rows=rows):
                cell_pixels = _terminal_cell_pixels()
                if cell_pixels is None:
                    print(render_ascii(matrix, scale=qr_scale))
                else:
                    print(
                        render_ascii(
                            matrix,
                            scale=qr_scale,
                            cell_width_px=cell_pixels[0],
                            cell_height_px=cell_pixels[1],
                        )
                    )
        except QrError as error:
            print(f"  (QR omitted: {error})\n")
    # stdout is block-buffered when redirected to a file or pipe, so without
    # this the banner can sit unseen until the buffer fills -- which for a
    # long-running server may be never.
    sys.stdout.flush()


def connection_payload(
    host: str,
    push_port: int,
    result_port: int | None,
    auth_token: str = "",
) -> str:
    """Build the compact endpoint the headset parses into server settings.

    `_parse_live_server_address` in
    `xr/scripts/ui/view_locked_capture_panel.gd` accepts
    ``host:port?result_port=...``. It is materially shorter than equivalent
    JSON, dropping a typical terminal QR from version 5 to version 3 while
    still preserving a non-default result port. Authenticated legacy callers
    keep JSON because the Godot query parser intentionally does not URL-decode
    token values.
    """
    import json

    endpoint_host = f"[{host}]" if ":" in host and not host.startswith("[") else host
    if not auth_token:
        if result_port is None:
            return f"{endpoint_host}:{int(push_port)}"
        return f"{endpoint_host}:{int(push_port)}?result_port={int(result_port)}"
    payload: dict[str, object] = {
        "host": host,
        "port": int(push_port),
        "token": auth_token,
    }
    if result_port is not None:
        payload["result_port"] = int(result_port)
    return json.dumps(payload, separators=(",", ":"), sort_keys=True)
