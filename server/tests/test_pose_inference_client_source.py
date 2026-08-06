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
    def test_open_connection_sends_pose_every_process_frame_without_rate_limiter(self):
        source = CLIENT_SOURCE.read_text(encoding="utf-8")

        self.assertNotIn("SEND_INTERVAL_S", source)
        self.assertNotIn("_send_accum", source)
        self.assertRegex(
            source,
            r"if _state == WebSocketPeer\.STATE_OPEN:\s+"
            r"_drain_packets\(\)\s+_send_pose\(\)",
        )


if __name__ == "__main__":
    unittest.main()
