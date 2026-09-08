#!/usr/bin/env python3
"""Offline behavioral tests; no robot, network, movement, or camera hardware access."""
import argparse
import base64
import hashlib
import io
import json
import math
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import motion_math
import remote_probe

class GeometryTests(unittest.TestCase):
    def test_continue_original_target(self):
        result = motion_math.project((10, 20, 0), (10.33, 20), 1)
        self.assertAlmostEqual(result["remaining_m"], 0.67)
        self.assertFalse(result["motion_or_stationary_status_assessed"])

    def test_rotated_reference(self):
        result = motion_math.project((2, 3, math.pi / 2), (2, 3.3), .3)
        self.assertAlmostEqual(result["forward_m"], .3)
        self.assertAlmostEqual(result["lateral_m"], 0)

    def test_overshoot_and_backward_preserve_sign(self):
        self.assertAlmostEqual(motion_math.project((0, 0, 0), (.305, 0), .3)["remaining_m"], -.005)
        self.assertAlmostEqual(motion_math.project((0, 0, 0), (-.2, 0), -.3)["remaining_m"], -.1)

    def test_lateral_is_not_forward(self):
        result = motion_math.project((0, 0, 0), (0, .3), .3)
        self.assertAlmostEqual(result["forward_m"], 0)
        self.assertAlmostEqual(result["lateral_m"], .3)

    def test_nonfinite_rejected(self):
        for bad in (math.nan, math.inf, -math.inf):
            with self.assertRaises(ValueError):
                motion_math.project((0, 0, bad), (1, 0), 1)

class ProbeTests(unittest.TestCase):
    def test_raw_depth_alarm_overrides_false_flag_without_diagnosing_camera(self):
        result = remote_probe.summarize_health({
            "hasDepthCameraDisconnected": False,
            "baseError": [{"errorCode": 17041920, "componentErrorDeviceId": -1}],
        })
        self.assertTrue(result["depth_warning_reported"])
        self.assertEqual(result["depth_camera_identity"], "not_determined_by_this_helper")
        self.assertFalse(result["motion_clearance_assessed"])

    def test_hardware_interlocks_detected_by_raw_code(self):
        result = remote_probe.summarize_health({"baseError": [
            {"errorCode": "0x02010100"}, {"errorCode": 33621760}
        ]})
        self.assertTrue(result["emergency_stop_reported"])
        self.assertTrue(result["brake_released_reported"])

    def test_missing_health_is_not_clean_health(self):
        result = remote_probe.summarize_health(None)
        self.assertFalse(result["health_available"])
        self.assertFalse(result["motion_clearance_assessed"])

    def test_command_quoting_preserves_literal_path(self):
        path = "/home/unitree/ws/it's $(touch nope) " + chr(96) + "echo nope" + chr(96) + ".jpg"
        args = remote_probe.parser().parse_args(["image-chunk", "--path", path])
        command = remote_probe.build_command(args)
        self.assertEqual(command[0], "ssh")
        remote_tokens = shlex.split(command[-1])
        self.assertEqual(remote_tokens[:3], ["PYTHONDONTWRITEBYTECODE=1", "python3", "-c"])
        source = remote_tokens[3]
        compile(source, "<remote_payload>", "exec")
        observed = {}
        ns = {"__name__": "__test__"}
        prefix, invocation = source.split("\ntry:\n    result = perform(", 1)
        exec(prefix, ns)
        def fake(op, cfg):
            observed.update(op=op, cfg=cfg)
            return {"ok": True}
        ns["perform"] = fake
        with patch("sys.stdout", new=io.StringIO()):
            with self.assertRaises(SystemExit) as stopped:
                exec("\ntry:\n    result = perform(" + invocation, ns)
        self.assertEqual(stopped.exception.code, 0)
        self.assertEqual(observed["cfg"]["path"], path)

    def test_ssh_option_injection_rejected(self):
        args = remote_probe.parser().parse_args(["status"])
        args.host = "-oProxyCommand=anything"
        with self.assertRaises(ValueError):
            remote_probe.build_command(args)

    def test_transport_failure_is_structured_not_success(self):
        completed = subprocess.CompletedProcess([], 255, "", "Connection timed out")
        with patch("remote_probe.subprocess.run", return_value=completed):
            with patch("sys.stdout", new=io.StringIO()) as output:
                result = remote_probe.main(["status"])
        body = json.loads(output.getvalue())
        self.assertEqual(result, 2)
        self.assertFalse(body["ok"])
        self.assertFalse(body["motion_command_sent"])

    def test_history_duration_rejected_before_transport(self):
        with patch("remote_probe.subprocess.run") as run:
            with patch("sys.stdout", new=io.StringIO()):
                self.assertEqual(remote_probe.main(["health-history", "--seconds", "nan"]), 2)
        run.assert_not_called()

class RobotPayloadTests(unittest.TestCase):
    def setUp(self):
        self.ns = {"__name__": "__test__"}
        exec(remote_probe.REMOTE_PROGRAM, self.ns)

    def test_status_partial_failure_preserves_other_data_and_only_gets(self):
        seen = []
        class FakeOpener:
            def open(self, request, timeout):
                seen.append(request.get_method())
                if request.full_url.endswith("/speed"):
                    raise OSError("mock speed unavailable")
                return io.BytesIO(b"{}")
        with patch("urllib.request.build_opener", return_value=FakeOpener()):
            result = self.ns["perform"]("status", {"base_url": "http://example.invalid"})
        self.assertFalse(result["ok"])
        self.assertIn("speed", result["errors"])
        self.assertIn("health", result["data"])
        self.assertEqual(seen, ["GET"] * 4)

    def test_image_chunk_reassembly_and_hash(self):
        with tempfile.TemporaryDirectory(prefix="g1d-skill-test-") as temp:
            path = Path(temp) / "fixture.jpg"
            raw = b"\xff\xd8" + bytes(range(256)) * 400 + b"\xff\xd9"
            path.write_bytes(raw)
            self.ns["artifact_path"] = lambda value: path
            combined = ""
            total = None
            while total is None or len(combined) < total:
                result = self.ns["perform"]("image-chunk", {
                    "path": str(path), "offset": len(combined), "count": 30000
                })
                total = result["total_chars"]
                self.assertLessEqual(len(result["chunk"]), 30000)
                self.assertEqual(result["sha256"], hashlib.sha256(raw).hexdigest())
                combined += result["chunk"]
            self.assertEqual(base64.b64decode(combined), raw)
            with self.assertRaises(ValueError):
                self.ns["perform"]("image-chunk", {"path": str(path), "offset": total, "count": 30000})

    def test_artifact_path_restriction(self):
        for path in ("relative.jpg", "/etc/passwd", "/home/unitree/ws/../../../etc/passwd"):
            with self.assertRaises(ValueError):
                self.ns["artifact_path"](path)

    def test_capture_timeout_creates_no_directory(self):
        class FakeSocket:
            def setsockopt(self, *args): pass
            def connect(self, *args): pass
            def poll(self, *args): return False
            def close(self, *args): pass
        class FakeContext:
            def socket(self, *args): return FakeSocket()
            def term(self): pass
        fake_zmq = argparse.Namespace(Context=FakeContext, SUB=1, SUBSCRIBE=2, CONFLATE=3, LINGER=4)
        with tempfile.TemporaryDirectory(prefix="g1d-skill-test-") as temp:
            target = Path(temp) / "not-created"
            self.ns["artifact_path"] = lambda value: target
            with patch.dict("sys.modules", {"cv2": argparse.Namespace(), "numpy": argparse.Namespace(), "zmq": fake_zmq}):
                with self.assertRaisesRegex(RuntimeError, "No fresh head camera"):
                    self.ns["perform"]("capture-head", {"out_dir": str(target)})
            self.assertFalse(target.exists())

if __name__ == "__main__":
    unittest.main(verbosity=2)
