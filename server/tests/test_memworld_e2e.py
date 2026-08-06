import asyncio
import io
import json
import unittest
import zipfile
from unittest.mock import patch

from PIL import Image

from server.memworld_gateway import DashboardState, PLAYBACK_FPS, parse_args, websocket_handler
from server.memworld_frame_sequence import LIVE_FRAME_MIME_TYPE
from server.pose_inference_protocol import unpack_image_frame


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


def pose(frame_id):
    joints = [
        {
            "tracked": True,
            "position": [-0.08 + index * 0.006, 0.25, 1.0],
            "rotation": [0.0, 0.0, 0.0, 1.0],
        }
        for index in range(26)
    ]
    return {
        "type": "pose",
        "frame_id": frame_id,
        "capture_time_ns": frame_id * 1_000_000,
        "head": {
            "tracked": True,
            "position": [0.0, 0.0, 0.0],
            "rotation": [0.0, 0.0, 0.0, 1.0],
        },
        "left": {"tracking": True, "joints": joints},
        "right": {"tracking": False, "joints": []},
    }


def model_frame_zip() -> tuple[bytes, tuple[bytes, ...]]:
    output = io.BytesIO()
    frames = []
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_STORED) as archive:
        for index in range(17):
            encoded = io.BytesIO()
            Image.new(
                "RGB",
                (640, 352),
                (index * 7 % 256, 40, 80),
            ).save(encoded, format="JPEG", quality=88)
            frame = encoded.getvalue()
            frames.append(frame)
            archive.writestr(f"frames/{index:03d}.jpg", frame)
    return output.getvalue(), tuple(frames)


class MemWorldEndToEndTests(unittest.IsolatedAsyncioTestCase):
    def test_gateway_uses_high_speed_inference_defaults(self):
        with patch(
            "sys.argv",
            [
                "memworld_gateway",
                "--public-host",
                "10.10.99.72",
            ],
        ):
            args = parse_args()

        self.assertEqual(args.num_inference_steps, 4)
        self.assertEqual(args.cfg_scale, 1.0)
        expected_asset = "/home/evophys/code/MemWorld-direct-dmd1000/anchor.jpg"
        self.assertEqual(args.initial_rgb, expected_asset)
        self.assertEqual(args.static_memory, expected_asset)

    async def test_pose_to_pinf_chunk_worker_and_dashboard(self):
        from websockets.asyncio.client import connect
        from websockets.asyncio.server import serve

        worker_received = asyncio.Event()
        chunk_started = asyncio.Event()
        allow_worker_output = asyncio.Event()
        output_zip, output_frames = model_frame_zip()

        async def fake_worker(connection):
            start = json.loads(await connection.recv())
            self.assertAlmostEqual(start["fps"], PLAYBACK_FPS)
            self.assertAlmostEqual(start["playback_fps"], PLAYBACK_FPS)
            self.assertEqual(start["frames_per_chunk"], 17)
            self.assertEqual(start["num_inference_steps"], 4)
            self.assertEqual(start["cfg_scale"], 1.0)
            await connection.send(json.dumps({
                "type": "session.ready",
                "session_id": start["session_id"],
            }))
            control = json.loads(await connection.recv())
            bundle = await connection.recv()
            with zipfile.ZipFile(io.BytesIO(bundle)) as archive:
                self.assertEqual(len([
                    name for name in archive.namelist()
                    if name.startswith("keypoints/")
                ]), 17)
            await connection.send(json.dumps({
                "type": "chunk.started",
                "session_id": start["session_id"],
                "chunk_id": control["chunk_id"],
            }))
            chunk_started.set()
            try:
                await asyncio.wait_for(allow_worker_output.wait(), timeout=3.0)
            except asyncio.TimeoutError:
                return
            await connection.send(json.dumps({
                "type": "chunk.output",
                "session_id": start["session_id"],
                "chunk_id": control["chunk_id"],
                "first_frame_id": control["first_frame_id"],
                "last_frame_id": control["last_frame_id"],
                "frame_count": 17,
                "frame_format": "jpeg",
                "mime_type": LIVE_FRAME_MIME_TYPE,
                "fps": PLAYBACK_FPS,
                "inference_ms": 12.5,
                "jpeg_encode_ms": 4.2,
                "byte_length": len(output_zip),
            }))
            await connection.send(output_zip)
            worker_received.set()
            await asyncio.sleep(0.2)

        dashboard = DashboardState()
        async with serve(fake_worker, "127.0.0.1", 0) as worker_server:
            worker_port = worker_server.sockets[0].getsockname()[1]
            async with serve(
                lambda connection: websocket_handler(
                    connection,
                    token="secret",
                    worker_url=f"ws://127.0.0.1:{worker_port}",
                    initial_rgb="/tmp/not-read-by-fake-worker.png",
                    static_memory="/tmp/not-read-by-fake-worker.png",
                    dashboard=dashboard,
                    inference_options={
                        "num_inference_steps": 4,
                        "cfg_scale": 1.0,
                    },
                ),
                "127.0.0.1",
                0,
                max_size=256 * 1024,
            ) as gateway_server:
                gateway_port = gateway_server.sockets[0].getsockname()[1]
                async with connect(
                    f"ws://127.0.0.1:{gateway_port}/memworld",
                    max_size=8 * 1024 * 1024,
                ) as quest:
                    await quest.send(json.dumps({
                        "type": "hello",
                        "protocol": "operator.memworld.v1",
                        "token": "secret",
                        "calibration": calibration(),
                    }))
                    ready = json.loads(await quest.recv())
                    self.assertEqual(ready["type"], "ready")
                    self.assertAlmostEqual(ready["projection_hz"], PLAYBACK_FPS)
                    self.assertAlmostEqual(ready["playback_fps"], PLAYBACK_FPS)
                    loop = asyncio.get_running_loop()
                    deadline = loop.time() + 5.0
                    frame_id = 0
                    while not chunk_started.is_set():
                        if loop.time() >= deadline:
                            self.fail("worker did not receive the first chunk")
                        frame_id += 1
                        await quest.send(json.dumps(pose(frame_id)))
                        await asyncio.sleep(0.005)
                    await asyncio.wait_for(chunk_started.wait(), timeout=1.0)
                    with self.assertRaises(asyncio.TimeoutError):
                        await asyncio.wait_for(quest.recv(), timeout=0.15)

                    frame_id += 1
                    latest_pose = pose(frame_id)
                    await quest.send(json.dumps(latest_pose))
                    await asyncio.sleep(0.02)
                    allow_worker_output.set()
                    await asyncio.wait_for(worker_received.wait(), timeout=5.0)
                    packet = await asyncio.wait_for(quest.recv(), timeout=1.0)
                    self.assertIsInstance(packet, bytes)
                    pinf = unpack_image_frame(packet)
        self.assertEqual((pinf.width, pinf.height), (640, 352))
        self.assertIn(pinf.jpeg, output_frames)
        self.assertEqual(pinf.frame_id, latest_pose["frame_id"])
        self.assertEqual(pinf.capture_time_ns, latest_pose["capture_time_ns"])
        self.assertIn(dashboard.model_frame(), output_frames)
        status = json.loads(dashboard.status_json())
        self.assertIsNotNone(status["output_chunk_id"])
        self.assertEqual(status["playing_chunk_id"], status["output_chunk_id"])
        self.assertEqual(status["model_frame_count"], 17)
        self.assertAlmostEqual(status["model_playback_fps"], PLAYBACK_FPS)
        self.assertEqual(status["inference_ms"], 12.5)
        self.assertEqual(status["jpeg_encode_ms"], 4.2)
        self.assertEqual(status["frame_zip_bytes"], len(output_zip))
        self.assertGreaterEqual(status["frame_zip_receive_ms"], 0.0)
        self.assertGreaterEqual(status["frame_zip_unpack_ms"], 0.0)


if __name__ == "__main__":
    unittest.main()
