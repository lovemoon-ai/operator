import io
import json
import unittest
from unittest.mock import patch
import zipfile

from server import memworld_gateway
from server.memworld_frame_sequence import LIVE_FRAME_MIME_TYPE
from server.memworld_gateway import (
    DashboardState,
    build_qr_payload,
    dashboard_html,
    is_websocket_path,
    validate_client_message,
)
from server.memworld_worker_client import accept_worker_output


def calibration():
    return {
        "ok": True,
        "metadata_only": True,
        "calibration_id": "left:1280x960",
        "selected_yuv_size": {"width": 1280, "height": 960},
        "sensor_active_array_size": {
            "left": 0, "top": 0, "right": 1280, "bottom": 960,
            "width": 1280, "height": 960,
        },
        "lens_intrinsic_calibration": [1000.0, 1000.0, 640.0, 480.0, 0.0],
        "lens_distortion": [],
        "lens_pose_translation": [0.0, 0.0, 0.0],
        "lens_pose_rotation": [0.0, 0.0, 0.0, 1.0],
    }


def live_frame_zip() -> bytes:
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_STORED) as archive:
        for index in range(17):
            archive.writestr(
                f"frames/{index:03d}.jpg",
                b"\xff\xd8" + index.to_bytes(2, "big") + b"\xff\xd9",
            )
    return output.getvalue()


class MemWorldGatewayTests(unittest.TestCase):
    def test_qr_payload_uses_public_memworld_mode(self):
        config = build_qr_payload("ws://10.10.99.72:63920/memworld", "secret")
        self.assertEqual(config, {
            "mode": "memWorld",
            "url": "ws://10.10.99.72:63920/memworld",
            "token": "secret",
        })

    def test_model_contract_uses_17_frame_windows_at_20_hz(self):
        self.assertEqual(memworld_gateway.FRAMES_PER_CHUNK, 17)
        self.assertEqual(memworld_gateway.NEW_FRAMES_PER_CHUNK, 16)
        expected_hz = 20.0
        self.assertAlmostEqual(memworld_gateway.MODEL_FPS, expected_hz)
        self.assertAlmostEqual(memworld_gateway.PROJECTION_HZ, expected_hz)
        self.assertAlmostEqual(memworld_gateway.PREVIEW_HZ, expected_hz)
        self.assertAlmostEqual(memworld_gateway.PLAYBACK_FPS, expected_hz)
        self.assertAlmostEqual(
            memworld_gateway.CHUNK_DURATION_SECONDS,
            0.8,
        )

    def test_stats_separate_pose_receive_and_model_sample_rates(self):
        with patch.object(
            memworld_gateway.time,
            "monotonic",
            side_effect=[100.0, 101.0],
        ):
            state = memworld_gateway.SessionState()
            self.assertEqual(state.model_sample_count, 0)
            state.pose_count = 90
            state.model_sample_count = 10
            state.preview_count = 10
            rates = state.stats_if_due()
        self.assertEqual(rates, {
            "pose_rx_hz": 90.0,
            "model_sample_hz": 10.0,
            "preview_tx_hz": 10.0,
            "pose_to_projection_ms": 0.0,
        })
        self.assertEqual(state.model_sample_count, 0)

    def test_session_keeps_latest_head_and_hands(self):
        state = memworld_gateway.SessionState()
        first_head = {
            "tracked": True,
            "position": [1.0, 2.0, 3.0],
            "rotation": [0.0, 0.0, 0.0, 1.0],
        }
        state.accept_pose({
            "type": "pose",
            "frame_id": 1,
            "capture_time_ns": 10,
            "head": first_head,
            "left_hand": {"marker": "first"},
            "right_hand": {"marker": "first"},
        }, received_ns=100)
        first_head["position"][0] = 99.0

        state.accept_pose({
            "type": "pose",
            "frame_id": 2,
            "capture_time_ns": 20,
            "head": {
                "tracked": True,
                "position": [4.0, 5.0, 6.0],
                "rotation": [0.0, 1.0, 0.0, 0.0],
            },
            "left_hand": {"marker": "second"},
            "right_hand": {"marker": "second"},
        }, received_ns=200)

        self.assertEqual(state.latest_pose["head"], {
            "tracked": True,
            "position": [4.0, 5.0, 6.0],
            "rotation": [0.0, 1.0, 0.0, 0.0],
        })
        self.assertEqual(state.latest_pose["left_hand"]["marker"], "second")
        self.assertEqual(state.latest_pose["right_hand"]["marker"], "second")
        self.assertEqual(state.latest_pose["frame_id"], 2)
        self.assertEqual(state.latest_pose["_server_received_ns"], 200)
        self.assertEqual(state.pose_count, 2)

    def test_hello_requires_token_protocol_and_calibration(self):
        kind, parsed = validate_client_message({
            "type": "hello",
            "protocol": "operator.memworld.v1",
            "token": "secret",
            "calibration": calibration(),
        }, "secret")
        self.assertEqual(kind, "hello")
        self.assertEqual(parsed.calibration_id, "left:1280x960")
        with self.assertRaises(ValueError):
            validate_client_message({
                "type": "hello",
                "protocol": "operator.memworld.v1",
                "token": "wrong",
                "calibration": calibration(),
            }, "secret")

    def test_pose_requires_frame_and_capture_time(self):
        self.assertEqual(
            validate_client_message({
                "type": "pose",
                "frame_id": 1,
                "capture_time_ns": 2,
            }, "secret")[0],
            "pose",
        )
        with self.assertRaises(ValueError):
            validate_client_message({"type": "pose"}, "secret")

    def test_websocket_path_is_memworld_only(self):
        self.assertTrue(is_websocket_path("/memworld"))
        self.assertFalse(is_websocket_path("/pose-inference"))

    def test_dashboard_exposes_presentation_views_metrics_and_steady_model_clock(self):
        page = dashboard_html(build_qr_payload("ws://host/memworld", "token"))
        text = page.decode("utf-8")
        self.assertIn("MemWorld", text)
        self.assertIn("/status.json", text)
        self.assertIn("/skeleton.jpg", text)
        self.assertIn("/model.jpg", text)
        self.assertIn('id="model-view"', text)
        self.assertIn('id="pose-view"', text)
        self.assertIn('id="pose-rate"', text)
        self.assertIn('id="inference-fps"', text)
        self.assertIn('id="send-latency"', text)
        self.assertIn('id="pairing-qr"', text)
        self.assertIn(
            f"setInterval(refreshModel,1000/{memworld_gateway.PLAYBACK_FPS})",
            text,
        )
        self.assertIn("status.inference_ms", text)
        self.assertIn("status.pose_to_projection_ms", text)
        self.assertNotIn('id="action-progress"', text)
        self.assertNotIn('id="chunk-progress"', text)
        self.assertNotIn('id="raw-status"', text)
        self.assertNotIn(">ACTIONS<", text)
        self.assertNotIn(">CHUNKS<", text)
        self.assertNotIn("/model.mp4", text)
        self.assertNotIn("<video", text)

    def test_dashboard_state_serializes_status_without_binary_payloads(self):
        state = DashboardState()
        state.update_status(worker="ready", pose_rx_hz=72.0)
        state.update_skeleton(b"jpeg", frame_id=4)
        frames = tuple(f"frame-{index}".encode() for index in range(17))
        state.update_model_frames(
            frames,
            chunk_id=3,
            inference_ms=900.0,
            playback_fps=17.0,
            started_at=100.0,
        )
        status = json.loads(state.status_json(now=100.0))
        self.assertEqual(status["worker"], "ready")
        self.assertEqual(status["skeleton_frame_id"], 4)
        self.assertEqual(status["output_chunk_id"], 3)
        self.assertEqual(status["playing_chunk_id"], 3)
        self.assertEqual(status["model_frame_count"], 17)
        self.assertEqual(status["model_playback_fps"], 17.0)
        self.assertNotIn("jpeg", status)
        self.assertNotIn("frame-0", status)

    def test_dashboard_selects_model_frames_at_17_hz_and_freezes_last(self):
        state = DashboardState()
        frames = tuple(f"first-{index}".encode() for index in range(17))
        state.update_model_frames(
            frames,
            chunk_id=1,
            inference_ms=500.0,
            playback_fps=17.0,
            started_at=100.0,
        )

        self.assertEqual(state.model_frame(now=100.00), frames[0])
        self.assertEqual(state.model_frame(now=100.19), frames[3])
        self.assertEqual(state.model_frame(now=101.00), frames[16])
        self.assertEqual(state.model_frame(now=110.00), frames[16])

    def test_new_model_chunk_immediately_replaces_unfinished_playback(self):
        state = DashboardState()
        first = tuple(f"first-{index}".encode() for index in range(17))
        newest = tuple(f"newest-{index}".encode() for index in range(17))
        state.update_model_frames(
            first,
            chunk_id=1,
            inference_ms=500.0,
            playback_fps=17.0,
            started_at=100.0,
        )
        self.assertEqual(state.model_frame(now=101.0), first[16])

        state.update_model_frames(
            newest,
            chunk_id=2,
            inference_ms=450.0,
            playback_fps=memworld_gateway.PLAYBACK_FPS,
            started_at=101.0,
            drop_first_frame=True,
        )

        self.assertEqual(state.model_frame(now=101.0), newest[1])
        self.assertEqual(state.model_frame(now=102.8), newest[16])
        status = json.loads(state.status_json(now=101.0))
        self.assertEqual(status["output_chunk_id"], 2)
        self.assertEqual(status["playing_chunk_id"], 2)
        self.assertEqual(status["model_frame_index"], 0)

        self.assertEqual(status["model_frame_count"], 16)

    def test_worker_drop_first_frame_metadata_reaches_dashboard(self):
        state = DashboardState()
        frames = tuple(f"frame-{index}".encode() for index in range(17))
        result = memworld_gateway.WorkerResult(
            chunk_id=2,
            metadata={
                "inference_ms": 1800.0,
                "fps": memworld_gateway.PLAYBACK_FPS,
                "drop_first_frame": True,
            },
            frames=frames,
        )
        memworld_gateway._on_worker_result(result, state)
        self.assertEqual(state.model_frame(), frames[1])
        status = json.loads(state.status_json())
        self.assertEqual(status["model_frame_count"], 16)

    def test_dashboard_accepts_native_16_frame_nv_output(self):
        state = DashboardState()
        frames = tuple(f"frame-{index}".encode() for index in range(16))
        result = memworld_gateway.WorkerResult(
            chunk_id=2,
            metadata={
                "inference_ms": 640.0,
                "fps": 20.0,
                "transport": "nv-tcp",
                "mp4_bytes": 12345,
                "mp4_decode_ms": 18.0,
            },
            frames=frames,
        )
        memworld_gateway._on_worker_result(result, state)
        status = json.loads(state.status_json())
        self.assertEqual(status["model_frame_count"], 16)
        self.assertEqual(status["model_playback_fps"], 20.0)
        self.assertEqual(status["worker_transport"], "nv-tcp")
        self.assertEqual(status["mp4_bytes"], 12345)

    def test_worker_output_rejects_wrong_chunk(self):
        payload = live_frame_zip()
        result = accept_worker_output(
            3,
            {
                "type": "chunk.output",
                "chunk_id": 3,
                "frame_count": 17,
                "frame_format": "jpeg",
                "mime_type": LIVE_FRAME_MIME_TYPE,
                "byte_length": len(payload),
                "inference_ms": 10.0,
            },
            payload,
        )
        self.assertEqual(result.chunk_id, 3)
        self.assertEqual(len(result.frames), 17)
        self.assertEqual(result.metadata["frame_zip_bytes"], len(payload))
        self.assertGreaterEqual(result.metadata["frame_zip_unpack_ms"], 0.0)
        with self.assertRaisesRegex(ValueError, "chunk_id"):
            accept_worker_output(
                3,
                {
                    "type": "chunk.output",
                    "chunk_id": 4,
                    "frame_count": 17,
                    "frame_format": "jpeg",
                    "mime_type": LIVE_FRAME_MIME_TYPE,
                },
                payload,
            )
        with self.assertRaisesRegex(ValueError, "MIME"):
            accept_worker_output(
                3,
                {
                    "type": "chunk.output",
                    "chunk_id": 3,
                    "frame_count": 17,
                    "frame_format": "jpeg",
                    "mime_type": "video/mp4",
                },
                payload,
            )
        with self.assertRaisesRegex(ValueError, "length"):
            accept_worker_output(
                3,
                {
                    "type": "chunk.output",
                    "chunk_id": 3,
                    "frame_count": 17,
                    "frame_format": "jpeg",
                    "mime_type": LIVE_FRAME_MIME_TYPE,
                    "byte_length": len(payload) + 1,
                },
                payload,
            )

    def test_worker_connection_disables_redundant_zip_compression(self):
        import inspect
        from server.memworld_worker_client import MemWorldWorkerClient

        source = inspect.getsource(MemWorldWorkerClient.run)
        self.assertIn("compression=None", source)


if __name__ == "__main__":
    unittest.main()
