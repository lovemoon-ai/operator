import asyncio
import json
import unittest
from unittest.mock import Mock, patch
import time

import server.pose_inference_ws as pose_inference_ws
from server.pose_inference_protocol import LatestPose, unpack_image_frame
from server.pose_inference_ws import (
    ConnectionStats,
    build_qr_payload,
    html_headers,
    is_websocket_path,
    process_request,
    run_inference,
    validate_client_message,
)


class PoseInferenceServiceTests(unittest.TestCase):
    def test_connection_stats_reports_one_second_rates_and_resets_window(self):
        stats = ConnectionStats(start_time=10.0)
        stats.record_pose(128, {
            "frame_id": 7,
            "head": {"tracked": True},
            "left": {"tracking": True},
            "right": {"tracking": False},
        })
        stats.record_pose(256, {
            "frame_id": 8,
            "head": {"tracked": False},
            "left": {"tracking": True},
            "right": {"tracking": True},
        })
        stats.record_image(512)
        stats.record_pose_to_image_latency(12_000_000)
        stats.record_pose_to_image_latency(18_000_000)

        snapshot = stats.snapshot_if_due(11.0)

        self.assertEqual(snapshot, {
            "pose_rx_fps": 2.0,
            "image_tx_fps": 1.0,
            "pose_rx_bytes": 384,
            "image_tx_bytes": 512,
            "latest_pose_frame_id": 8,
            "head_tracked_fps": 1.0,
            "left_hand_tracked_fps": 2.0,
            "right_hand_tracked_fps": 1.0,
            "pose_to_image_avg_ms": 15.0,
            "pose_to_image_max_ms": 18.0,
        })
        self.assertIsNone(stats.snapshot_if_due(11.5))
        self.assertEqual(
            stats.snapshot_if_due(12.0),
            {
                "pose_rx_fps": 0.0,
                "image_tx_fps": 0.0,
                "pose_rx_bytes": 0,
                "image_tx_bytes": 0,
                "latest_pose_frame_id": 8,
                "head_tracked_fps": 0.0,
                "left_hand_tracked_fps": 0.0,
                "right_hand_tracked_fps": 0.0,
                "pose_to_image_avg_ms": 0.0,
                "pose_to_image_max_ms": 0.0,
            },
        )

    def test_first_pose_logger_prints_one_compact_complete_sample(self):
        first_pose = {
            "type": "pose",
            "frame_id": 41,
            "capture_time_ns": 123,
            "head": {
                "tracked": True,
                "position": [0.1, 1.6, -0.2],
                "rotation": [0.0, 0.0, 0.0, 1.0],
            },
            "left": {"tracking": True, "wrist": {}, "joints": [{"tracked": True}]},
            "right": {"tracking": False, "wrist": {}, "joints": []},
            "_server_received_ns": 999,
        }
        logger_class = getattr(pose_inference_ws, "FirstPoseLogger", None)
        self.assertIsNotNone(logger_class)
        logger = logger_class()

        with patch("builtins.print") as print_mock:
            logger.log(first_pose)
            logger.log({"type": "pose", "frame_id": 42})

        print_mock.assert_called_once()
        rendered = print_mock.call_args.args[0]
        self.assertTrue(print_mock.call_args.kwargs["flush"])
        self.assertTrue(rendered.startswith("POSE_SAMPLE "))
        logged_pose = json.loads(rendered.removeprefix("POSE_SAMPLE "))
        self.assertEqual(logged_pose["frame_id"], 41)
        self.assertEqual(logged_pose["left"]["joints"], [{"tracked": True}])
        self.assertNotIn("_server_received_ns", logged_pose)

    def test_qr_payload_contains_connection_configuration(self):
        config = build_qr_payload("ws://10.10.99.72:63920/pose-inference", "secret")

        self.assertEqual(config["mode"], "pose_inference")
        self.assertEqual(config["url"], "ws://10.10.99.72:63920/pose-inference")
        self.assertEqual(config["token"], "secret")

    def test_hello_requires_matching_token(self):
        with self.assertRaises(ValueError):
            validate_client_message({"type": "hello", "token": "wrong"}, "secret")

    def test_pose_requires_a_frame_id_after_hello(self):
        self.assertEqual(
            validate_client_message({"type": "pose", "frame_id": 9, "capture_time_ns": 11}, "secret"),
            "pose",
        )
        with self.assertRaises(ValueError):
            validate_client_message({"type": "pose"}, "secret")

    def test_websocket_path_is_not_claimed_by_qr_page_route(self):
        self.assertTrue(is_websocket_path("/pose-inference"))
        self.assertFalse(is_websocket_path("/"))

    def test_qr_page_declares_html_content_type(self):
        self.assertEqual(html_headers()["Content-Type"], "text/html; charset=utf-8")

    def test_qr_page_replaces_default_plain_text_content_type(self):
        class Headers(dict):
            def __setitem__(self, key, value):
                self.setdefault(key, []).append(value)

            def __getitem__(self, key):
                return super().__getitem__(key)[0]

            def get_all(self, key):
                return super().get(key, [])

        response = Mock()
        response.headers = Headers({"Content-Type": ["text/plain; charset=utf-8"]})
        connection = Mock()
        connection.respond.return_value = response
        request = Mock(path="/")

        with patch("server.pose_inference_ws.qr_page", return_value=b"page"):
            result = __import__("asyncio").run(process_request(connection, request, {"mode": "pose_inference"}))

        self.assertIs(result, response)
        self.assertEqual(response.headers["Content-Type"], "text/html; charset=utf-8")
        self.assertEqual(response.headers.get_all("Content-Type"), ["text/html; charset=utf-8"])


if __name__ == "__main__":
    unittest.main()


class FakeStreamTests(unittest.IsolatedAsyncioTestCase):
    async def test_inference_sends_multiple_fixed_rate_images_for_latest_pose(self):
        class Connection:
            def __init__(self):
                self.sent: list[bytes] = []

            async def send(self, payload: bytes) -> None:
                self.sent.append(payload)

        class Renderer:
            def render(self, pose, image_sequence):
                return 2, 1, b"jpeg"

        connection = Connection()
        latest = LatestPose()
        latest.replace({"frame_id": 9, "capture_time_ns": 123, "_server_received_ns": time.perf_counter_ns()})
        task = asyncio.create_task(
            run_inference(
                connection,
                latest,
                ConnectionStats(),
                renderer=Renderer(),
            )
        )
        try:
            await asyncio.sleep(0.13)
        finally:
            task.cancel()
            await asyncio.gather(task, return_exceptions=True)

        frames = [unpack_image_frame(payload) for payload in connection.sent]
        self.assertGreaterEqual(len(frames), 2)
        self.assertTrue(all(frame.frame_id == 9 for frame in frames))
        self.assertTrue(all(frame.capture_time_ns == 123 for frame in frames))
