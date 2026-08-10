from pathlib import Path
import unittest


CLIENT_SOURCE = (
    Path(__file__).resolve().parents[2]
    / "xr"
    / "addons"
    / "pose-inference"
    / "pose_inference_client.gd"
)


class PoseInferenceClientSourceTests(unittest.TestCase):
    def test_open_connection_rate_limits_pose_and_bounds_backpressure(self):
        source = CLIENT_SOURCE.read_text(encoding="utf-8")

        self.assertIn("const TARGET_POSE_HZ := 20.0", source)
        self.assertIn("const POSE_INTERVAL_S := 1.0 / TARGET_POSE_HZ", source)
        self.assertIn("const MAX_OUTBOUND_BUFFER_BYTES := 256 * 1024", source)
        self.assertRegex(
            source,
            r"if _state == WebSocketPeer\.STATE_OPEN:\s+"
            r"_drain_packets\(\)\s+_pose_elapsed_s \+= delta\s+"
            r"if _pose_elapsed_s >= POSE_INTERVAL_S:",
        )
        self.assertIn("get_current_outbound_buffered_amount()", source)
        self.assertIn("next_state == WebSocketPeer.STATE_CLOSED and _want_connection", source)


if __name__ == "__main__":
    unittest.main()
