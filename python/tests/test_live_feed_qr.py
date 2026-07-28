"""Tests for the dependency-free QR encoder used to print the server address.

The encoder is hand-written, so the meaningful assertion is "a real decoder
reads it back". That runs whenever OpenCV happens to be installed; the
structural tests below always run.
"""

from __future__ import annotations

import ipaddress
import json
import re
import unittest
from unittest import mock

import pytest

from pyoperator.live_feed import qr


_TRUECOLOR = re.compile(
    r"\x1b\[38;2;(\d+);(\d+);(\d+);48;2;(\d+);(\d+);(\d+)m"
)


def _terminal_cells(text: str) -> list[list[tuple[int, int]]]:
    """Return the visible top/bottom pixels represented by terminal cells."""
    rows: list[list[tuple[int, int]]] = []
    for line in text.splitlines():
        foreground = background = 255
        cells: list[tuple[int, int]] = []
        offset = 0
        while offset < len(line):
            colour = _TRUECOLOR.match(line, offset)
            if colour:
                values = tuple(int(value) for value in colour.groups())
                assert values[:3] in ((0, 0, 0), (255, 255, 255))
                assert values[3:] in ((0, 0, 0), (255, 255, 255))
                foreground, background = values[0], values[3]
                offset = colour.end()
                continue
            if line.startswith("\x1b[0m", offset):
                offset += len("\x1b[0m")
                continue
            glyph = line[offset]
            if glyph == "▀":
                cells.append((int(foreground == 0), int(background == 0)))
            elif glyph == " ":
                # A space exposes its background across the complete cell.
                cells.append((int(background == 0), int(background == 0)))
            else:
                raise AssertionError(f"unexpected terminal QR glyph: {glyph!r}")
            offset += 1
        rows.append(cells)
    return rows


def _decoder():
    """Return an OpenCV QR decoder, or None when OpenCV is unavailable."""
    try:
        import cv2  # noqa: F401
        import numpy  # noqa: F401
    except ImportError:
        return None
    import cv2 as _cv2

    return _cv2.QRCodeDetector()


def _to_image(matrix, scale: int = 8, quiet: int = 4):
    import numpy as np

    n = len(matrix)
    size = (n + quiet * 2) * scale
    img = np.full((size, size), 255, dtype=np.uint8)
    for r in range(n):
        for c in range(n):
            if matrix[r][c]:
                y, x = (r + quiet) * scale, (c + quiet) * scale
                img[y:y + scale, x:x + scale] = 0
    return img


def _terminal_image(text: str, cell_width: int = 8, cell_height: int = 16):
    """Rasterize the actual ANSI/half-block output as a terminal would."""
    import numpy as np

    cells = _terminal_cells(text)
    image = np.full(
        (len(cells) * cell_height, len(cells[0]) * cell_width),
        255,
        dtype=np.uint8,
    )
    split = cell_height // 2
    for row_index, row in enumerate(cells):
        y = row_index * cell_height
        for column_index, (upper, lower) in enumerate(row):
            x = column_index * cell_width
            image[y:y + split, x:x + cell_width] = 0 if upper else 255
            image[y + split:y + cell_height, x:x + cell_width] = 0 if lower else 255
    return image


class ConnectionPayloadTests(unittest.TestCase):
    def test_compact_address_matches_the_headset_parser(self) -> None:
        # `_parse_live_server_address()` accepts this exact form. Keeping the
        # result port explicit avoids relying on its push-port+2 inference.
        self.assertEqual(
            qr.connection_payload("10.0.0.5", 63910, 63912),
            "10.0.0.5:63910?result_port=63912",
        )

    def test_token_is_included_only_when_set(self) -> None:
        payload = json.loads(qr.connection_payload("10.0.0.5", 1, 2, "tok"))
        self.assertEqual(payload["host"], "10.0.0.5")
        self.assertEqual(payload["port"], 1)
        self.assertEqual(payload["result_port"], 2)
        self.assertEqual(payload["token"], "tok")

    def test_non_default_result_port_survives(self) -> None:
        payload = qr.connection_payload("10.0.0.5", 63910, 7000)
        self.assertEqual(payload, "10.0.0.5:63910?result_port=7000")

    def test_absent_result_channel_is_not_advertised(self) -> None:
        self.assertEqual(
            qr.connection_payload("10.0.0.5", 63910, None),
            "10.0.0.5:63910",
        )

    def test_ipv6_address_is_bracketed(self) -> None:
        self.assertEqual(
            qr.connection_payload("fd00::42", 63910, 63912),
            "[fd00::42]:63910?result_port=63912",
        )


class EncoderStructureTests(unittest.TestCase):
    def test_version_grows_with_payload_size(self) -> None:
        sizes = [len(qr.encode("A" * n)) for n in (1, 40, 90, 140)]
        self.assertEqual(sizes, sorted(sizes))
        for size in sizes:
            self.assertEqual((size - 17) % 4, 0, "size must be 4*version+17")

    def test_matrix_is_square_and_binary(self) -> None:
        matrix = qr.encode("hello")
        self.assertTrue(all(len(row) == len(matrix) for row in matrix))
        self.assertTrue(all(v in (0, 1) for row in matrix for v in row))

    def test_finder_patterns_are_present_in_three_corners(self) -> None:
        matrix = qr.encode("hello")
        size = len(matrix)
        for r0, c0 in ((0, 0), (0, size - 7), (size - 7, 0)):
            # Outer ring dark, inner ring light, 3x3 core dark.
            self.assertEqual(matrix[r0][c0], 1)
            self.assertEqual(matrix[r0 + 1][c0 + 1], 0)
            self.assertEqual(matrix[r0 + 3][c0 + 3], 1)

    def test_timing_patterns_alternate(self) -> None:
        matrix = qr.encode("hello")
        size = len(matrix)
        for i in range(8, size - 8):
            expected = 1 if i % 2 == 0 else 0
            self.assertEqual(matrix[6][i], expected, f"row-6 timing at {i}")
            self.assertEqual(matrix[i][6], expected, f"col-6 timing at {i}")

    def test_oversized_payload_is_rejected(self) -> None:
        with self.assertRaisesRegex(qr.QrError, "exceeds supported QR versions"):
            qr.encode("x" * 400)


class RenderTests(unittest.TestCase):
    @staticmethod
    def _matrix_from_ascii(text: str, scale: float, quiet: int = 4):
        """Reconstruct the module matrix from the rendered half-block cells.

        Lets the tests assert the render is lossless -- shrinking must change
        only the character resolution, never the encoded content.
        """
        cell = max(1, round(2 * scale))
        half_rows: list[list[int]] = []
        for row in _terminal_cells(text):
            half_rows.append([upper for upper, _ in row])
            half_rows.append([lower for _, lower in row])
        padded = len(half_rows[0]) // cell
        n = padded - 2 * quiet
        return [
            [half_rows[(mr + quiet) * cell][(mc + quiet) * cell] for mc in range(n)]
            for mr in range(n)
        ]

    def test_render_is_lossless_at_every_scale(self) -> None:
        matrix = qr.encode("192.168.1.10:63910")
        for scale in (1.0, 0.7, 0.5):
            rebuilt = self._matrix_from_ascii(qr.render_ascii(matrix, scale=scale), scale)
            self.assertEqual(rebuilt, [list(r) for r in matrix], f"scale={scale} altered the matrix")

    def test_full_scale_is_one_text_row_per_module(self) -> None:
        matrix = qr.encode("hello")
        quiet = 4
        lines = qr.render_ascii(matrix, quiet_zone=quiet, scale=1.0).split("\n")
        self.assertEqual(len(lines), len(matrix) + quiet * 2)

    def test_smaller_scale_uses_fewer_lines(self) -> None:
        matrix = qr.encode("hello")
        big = qr.render_ascii(matrix, scale=1.0).split("\n")
        small = qr.render_ascii(matrix, scale=0.7).split("\n")
        self.assertLess(len(small), len(big))
        # 0.7 rounds to the smallest square cell, same as compact.
        self.assertEqual(
            qr.render_ascii(matrix, scale=0.7), qr.render_ascii(matrix, compact=True)
        )

    def test_render_includes_a_quiet_zone(self) -> None:
        matrix = qr.encode("hello")
        text = qr.render_ascii(matrix, quiet_zone=4)
        first = _terminal_cells(text)[0]
        self.assertTrue(all(pair == (0, 0) for pair in first))

    def test_render_uses_exact_black_and_white_not_theme_palette(self) -> None:
        text = qr.render_ascii(qr.encode("hello"), scale=0.7)
        self.assertIn("\x1b[38;2;0;0;0;", text)
        self.assertIn(";48;2;255;255;255m", text)
        self.assertNotIn("\x1b[30m", text)
        self.assertNotIn("\x1b[40m", text)

    def test_typical_connection_fits_an_80_by_24_terminal(self) -> None:
        payload = qr.connection_payload("10.79.150.91", 63910, 63912)
        cells = _terminal_cells(qr.render_ascii(qr.encode(payload), scale=0.7))
        self.assertLessEqual(len(cells), 23)  # one row remains for the cursor
        self.assertLessEqual(max(map(len, cells)), 80)

    def test_ansi_fallback_uses_real_cell_metrics_for_a_square_canvas(self) -> None:
        matrix = qr.encode(qr.connection_payload("10.79.150.91", 63910, 63912))
        terminal = qr.render_ascii(
            matrix,
            scale=0.7,
            cell_width_px=9,
            cell_height_px=19,
        )
        image = _terminal_image(terminal, cell_width=9, cell_height=19)
        height, width = image.shape
        self.assertLessEqual(abs(height - width), 1)

    def test_terminal_cell_metric_override_is_explicit_and_testable(self) -> None:
        with mock.patch.dict(
            qr.os.environ,
            {
                "OPERATOR_TERM_CELL_WIDTH_PX": "9",
                "OPERATOR_TERM_CELL_HEIGHT_PX": "19",
            },
            clear=True,
        ):
            self.assertEqual(qr._terminal_cell_pixels(), (9.0, 19.0))

    def test_terminal_graphics_source_and_placement_are_square(self) -> None:
        import base64
        import zlib

        matrix = qr.encode(qr.connection_payload("10.79.150.91", 63910, 63912))
        rows = qr._terminal_row_count(matrix, quiet_zone=4, scale=0.7)
        commands = qr._kitty_graphics_commands(matrix, rows=rows)
        bodies = [command[len(b"\x1b_G"):-len(b"\x1b\\")] for command in commands]
        controls_and_payloads = [body.split(b";", 1) for body in bodies]
        controls = dict(
            field.split(b"=", 1)
            for field in controls_and_payloads[0][0].split(b",")
        )

        # Square source pixels plus only one requested grid dimension makes the
        # terminal compute columns from its real cell metrics without distortion.
        self.assertEqual(controls[b"s"], controls[b"v"])
        self.assertEqual(int(controls[b"r"]), rows)
        self.assertNotIn(b"c", controls)
        rgb = zlib.decompress(
            base64.standard_b64decode(
                b"".join(payload for _, payload in controls_and_payloads)
            )
        )
        side = int(controls[b"s"])
        self.assertEqual(len(rgb), side * side * 3)

    def test_tmux_passthrough_preserves_the_graphics_command(self) -> None:
        command = b"\x1b_Ga=q;\x1b\\"
        wrapped = qr._tmux_passthrough(command)
        self.assertTrue(wrapped.startswith(b"\x1bPtmux;"))
        self.assertTrue(wrapped.endswith(b"\x1b\\"))
        self.assertEqual(wrapped[7:-2].replace(b"\x1b\x1b", b"\x1b"), command)

    def test_square_terminal_graphics_write_advances_exactly_its_rows(self) -> None:
        import io

        class FakeTty:
            def __init__(self) -> None:
                self.buffer = io.BytesIO()

            def isatty(self) -> bool:
                return True

        matrix = qr.encode("hello")
        output = FakeTty()
        with (
            mock.patch.object(qr.sys, "stdout", output),
            mock.patch.dict(
                qr.os.environ,
                {"TERM_PROGRAM": "ghostty"},
                clear=True,
            ),
        ):
            self.assertTrue(qr._print_square_terminal_qr(matrix, rows=17))
        self.assertTrue(output.buffer.getvalue().endswith(b"\n" * 17))

    def test_terminal_output_matches_the_zxing_fixture(self) -> None:
        from pathlib import Path

        fixture_path = (
            Path(__file__).parents[2]
            / "xr/android_plugin/qrscanner/src/test/resources/terminal-live-feed-qr.txt"
        )
        lines = fixture_path.read_text().splitlines()
        payload = lines[0]
        cells = _terminal_cells(qr.render_ascii(qr.encode(payload), scale=0.7))
        actual = [
            "".join("#" if cell[half] else "." for cell in row)
            for row in cells
            for half in (0, 1)
        ]
        self.assertEqual(actual, lines[1:])


class InterfaceSelectionTests(unittest.TestCase):
    def test_private_range_classification(self) -> None:
        for ip in ("192.168.1.1", "10.79.150.91", "172.16.0.1", "172.31.255.1"):
            self.assertTrue(qr._is_private_ipv4(ip), ip)
        for ip in ("172.15.0.1", "172.32.0.1", "8.8.8.8", "100.64.0.1"):
            self.assertFalse(qr._is_private_ipv4(ip), ip)

    def test_candidate_ips_exclude_loopback_and_tunnels(self) -> None:
        # Simulate a host with a real LAN nic and a VPN tunnel that grabbed the
        # default route -- the exact shape that mis-advertised a utun address.
        fake = [
            ("lo0", "127.0.0.1", qr._IFF_UP | qr._IFF_LOOPBACK),
            ("en0", "10.79.150.91", qr._IFF_UP),
            ("utun5", "10.100.250.150", qr._IFF_UP | qr._IFF_POINTOPOINT),
            ("en5", "169.254.10.2", qr._IFF_UP),          # link-local, no DHCP
            ("en9", "10.0.0.5", 0),                        # down
        ]
        with mock.patch.object(qr, "_iter_interface_ipv4", return_value=iter(fake)):
            ips = qr.candidate_lan_ips()
        self.assertEqual(ips, ["10.79.150.91"])
        self.assertNotIn("10.100.250.150", ips)  # the VPN tunnel

    def test_public_addresses_sort_after_private(self) -> None:
        fake = [
            ("eth0", "203.0.113.5", qr._IFF_UP),
            ("eth1", "192.168.1.20", qr._IFF_UP),
        ]
        with mock.patch.object(qr, "_iter_interface_ipv4", return_value=iter(fake)):
            self.assertEqual(qr.candidate_lan_ips(), ["192.168.1.20", "203.0.113.5"])

    def test_local_ip_falls_back_when_enumeration_is_empty(self) -> None:
        with mock.patch.object(qr, "candidate_lan_ips", return_value=[]):
            ipaddress.IPv4Address(qr.local_ip())  # probe path still yields a valid address


class BannerTests(unittest.TestCase):
    def test_wildcard_bind_advertises_a_reachable_address(self) -> None:
        for wildcard in ("0.0.0.0", "", "::"):
            self.assertNotEqual(qr.resolve_advertised_host(wildcard), wildcard)
        self.assertEqual(qr.resolve_advertised_host("10.1.2.3"), "10.1.2.3")

    def test_banner_lists_other_addresses_for_wildcard_bind(self) -> None:
        import io
        from contextlib import redirect_stdout

        with mock.patch.object(qr, "candidate_lan_ips", return_value=["10.79.150.91", "192.168.64.1"]):
            out = io.StringIO()
            with redirect_stdout(out):
                qr.print_connection_banner("0.0.0.0", 63910, 63912, show_qr=False)
            text = out.getvalue()
        # First candidate is advertised; the rest are offered as alternatives.
        self.assertIn("10.79.150.91", text)
        self.assertIn("other addresses", text)
        self.assertIn("192.168.64.1", text)

    def test_banner_reports_ports_and_scan_hint(self) -> None:
        import io
        from contextlib import redirect_stdout

        out = io.StringIO()
        with redirect_stdout(out):
            qr.print_connection_banner("10.1.2.3", 63910, 63912, show_qr=False)
        text = out.getvalue()
        self.assertIn("10.1.2.3", text)
        self.assertIn("63910 / 63912", text)
        self.assertIn("adb reverse tcp:63910", text)
        self.assertIn("adb reverse tcp:63912", text)

    def test_banner_without_a_result_channel(self) -> None:
        import io
        from contextlib import redirect_stdout

        out = io.StringIO()
        with redirect_stdout(out):
            qr.print_connection_banner("10.1.2.3", 63910, None, show_qr=False)
        text = out.getvalue()
        self.assertIn("no result channel", text)
        # Must not advertise a result port the process will never serve.
        self.assertNotIn("adb reverse tcp:63912", text)

    def test_terminal_qr_is_the_final_banner_output(self) -> None:
        import io
        from contextlib import redirect_stdout

        payload = qr.connection_payload("10.1.2.3", 63910, 63912)
        rendered = qr.render_ascii(qr.encode(payload), scale=0.7)
        out = io.StringIO()
        with redirect_stdout(out):
            qr.print_connection_banner("10.1.2.3", 63910, 63912)
        self.assertTrue(out.getvalue().endswith(rendered + "\n"))
        self.assertNotIn(".png", out.getvalue())


class LocalIpTests(unittest.TestCase):
    def test_returns_a_valid_ipv4_address(self) -> None:
        ip = qr.local_ip()
        ipaddress.IPv4Address(ip)  # raises if malformed

    def test_falls_back_when_the_probe_fails(self) -> None:
        # Unroutable target: must still yield something usable, not raise.
        ip = qr.local_ip(target="203.0.113.255")
        ipaddress.IPv4Address(ip)


@pytest.mark.skipif(_decoder() is None, reason="OpenCV not installed; decode check skipped")
class DecodeRoundTripTests(unittest.TestCase):
    """The real proof: a standard decoder reads back exactly what we encoded."""

    def assert_round_trip(self, payload: str) -> None:
        decoded, _, _ = _decoder().detectAndDecode(_to_image(qr.encode(payload)))
        self.assertEqual(decoded, payload)

    def test_bare_host_port(self) -> None:
        self.assert_round_trip("192.168.1.10:63910")

    def test_connection_json(self) -> None:
        self.assert_round_trip(qr.connection_payload("192.168.1.10", 63910, 63912))

    def test_terminal_render_round_trip(self) -> None:
        payload = qr.connection_payload("10.79.150.91", 63910, 63912)
        terminal = qr.render_ascii(qr.encode(payload), scale=0.7)
        decoded, _, _ = _decoder().detectAndDecode(_terminal_image(terminal))
        self.assertEqual(decoded, payload)

    def test_terminal_render_round_trip_with_non_two_to_one_cells(self) -> None:
        payload = qr.connection_payload("10.79.150.91", 63910, 63912)
        terminal = qr.render_ascii(
            qr.encode(payload),
            scale=0.7,
            cell_width_px=9,
            cell_height_px=19,
        )
        decoded, _, _ = _decoder().detectAndDecode(
            _terminal_image(terminal, cell_width=9, cell_height=19)
        )
        self.assertEqual(decoded, payload)

    def test_terminal_graphics_raster_round_trip(self) -> None:
        import numpy as np

        payload = qr.connection_payload("10.79.150.91", 63910, 63912)
        rgb, side = qr._qr_rgb(qr.encode(payload))
        image = np.frombuffer(rgb, dtype=np.uint8).reshape(side, side, 3)
        decoded, _, _ = _decoder().detectAndDecode(image)
        self.assertEqual(decoded, payload)

    def test_connection_json_with_token(self) -> None:
        self.assert_round_trip(qr.connection_payload("10.79.150.91", 63910, 63912, "secret-token-123"))

    def test_single_character(self) -> None:
        self.assert_round_trip("x")

    def test_near_capacity_payload(self) -> None:
        self.assert_round_trip(qr.connection_payload("192.168.100.200", 63910, 63912, "a" * 40))


if __name__ == "__main__":
    unittest.main()
