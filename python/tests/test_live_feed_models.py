"""Unit tests for the pure Live Feed layers: geometry, camera models, decoders.

These need no headset and no network. The RGB decoder is exercised through a
stub ``ffmpeg`` so the subprocess plumbing is covered on the host; real codec
behaviour is covered by ``cicd/04_live_feed_e2e.sh``.
"""

from __future__ import annotations

import io
import json
import tempfile
import time
import unittest
from pathlib import Path

import fake_headset

from pyoperator.live_feed import (
    DensePoint,
    LiveFeedReceiver,
    ReceiverConfig,
    RgbHevcDecoder,
    apply_transform,
    compose_transform,
    depth_model_from_metadata,
    identity_matrix,
    identity_transform,
    invert_transform,
    rgb_cameras_from_config,
    sample_kinds,
    transform_to_matrix,
)
from pyoperator.live_feed.models import (
    DepthCameraModel,
    RgbCameraModel,
    RgbFrame,
    as_finite_float,
    as_finite_int,
    parse_nested_metadata_json,
    quaternion_to_rotation,
    transform_from_extrinsics_3x4,
    transform_from_position_rotation,
    transform_from_record,
)
from pyoperator.live_feed.protocol import StreamEvent, encode_json, read_frame
from pyoperator.live_feed.results import monotonic_pts_ns, pack_dense_points
from pyoperator.live_feed.runtime import (
    DroppingQueue,
    SessionRecorder,
    connect_push_client,
)


class ScalarHelperTests(unittest.TestCase):
    def test_as_finite_float_rejects_nan_inf_and_junk(self) -> None:
        self.assertEqual(as_finite_float("1.5"), 1.5)
        self.assertIsNone(as_finite_float(float("nan")))
        self.assertIsNone(as_finite_float(float("inf")))
        self.assertIsNone(as_finite_float(None))
        self.assertIsNone(as_finite_float("abc"))

    def test_as_finite_int_rejects_junk(self) -> None:
        self.assertEqual(as_finite_int("7"), 7)
        self.assertEqual(as_finite_int(7.9), 7)
        self.assertIsNone(as_finite_int(None))
        self.assertIsNone(as_finite_int("x"))


class TransformTests(unittest.TestCase):
    def test_identity_round_trips(self) -> None:
        rotation, translation = identity_transform()
        self.assertEqual(translation, (0.0, 0.0, 0.0))
        self.assertEqual(apply_transform(identity_transform(), (1.0, 2.0, 3.0)), (1.0, 2.0, 3.0))
        self.assertEqual(identity_matrix()[0], [1.0, 0.0, 0.0, 0.0])
        self.assertEqual(transform_to_matrix(identity_transform())[3], [0.0, 0.0, 0.0, 1.0])

    def test_quaternion_to_rotation_handles_degenerate_input(self) -> None:
        self.assertEqual(quaternion_to_rotation(0.0, 0.0, 0.0, 0.0), identity_transform()[0])
        # 180 degrees about Y
        rotation = quaternion_to_rotation(0.0, 1.0, 0.0, 0.0)
        transform = (rotation, (0.0, 0.0, 0.0))
        x, y, z = apply_transform(transform, (0.0, 0.0, 1.0))
        self.assertAlmostEqual(x, 0.0)
        self.assertAlmostEqual(y, 0.0)
        self.assertAlmostEqual(z, -1.0)

    def test_quaternion_normalises_unnormalised_input(self) -> None:
        scaled = quaternion_to_rotation(0.0, 0.0, 0.0, 5.0)
        self.assertEqual(scaled, identity_transform()[0])

    def test_invert_transform_undoes_apply(self) -> None:
        rotation = quaternion_to_rotation(0.0, 0.7071067811865476, 0.0, 0.7071067811865476)
        transform = (rotation, (1.0, 2.0, 3.0))
        point = (0.3, -0.4, 0.5)
        moved = apply_transform(transform, point)
        back = apply_transform(invert_transform(transform), moved)
        for original, restored in zip(point, back):
            self.assertAlmostEqual(original, restored, places=9)

    def test_compose_transform_matches_sequential_application(self) -> None:
        parent = (quaternion_to_rotation(0.0, 0.0, 0.3826834, 0.9238795), (1.0, 0.0, 0.0))
        child = (quaternion_to_rotation(0.2588190, 0.0, 0.0, 0.9659258), (0.0, 0.5, 0.0))
        point = (0.1, 0.2, 0.3)
        composed = apply_transform(compose_transform(parent, child), point)
        sequential = apply_transform(parent, apply_transform(child, point))
        for a, b in zip(composed, sequential):
            self.assertAlmostEqual(a, b, places=9)

    def test_transform_from_position_rotation_validates_input(self) -> None:
        self.assertIsNone(transform_from_position_rotation(None, None))
        self.assertIsNone(transform_from_position_rotation({"x": 1}, {"x": 0}))
        self.assertIsNone(transform_from_position_rotation("nope", {"x": 0, "y": 0, "z": 0, "w": 1}))
        self.assertIsNone(
            transform_from_position_rotation(
                {"x": float("nan"), "y": 0, "z": 0}, {"x": 0, "y": 0, "z": 0, "w": 1}
            )
        )
        valid = transform_from_position_rotation({"x": 1, "y": 2, "z": 3}, {"x": 0, "y": 0, "z": 0, "w": 1})
        self.assertIsNotNone(valid)
        assert valid is not None
        self.assertEqual(valid[1], (1.0, 2.0, 3.0))

    def test_transform_from_record_and_extrinsics(self) -> None:
        self.assertIsNone(transform_from_record("nope"))
        self.assertIsNone(transform_from_record({}))
        self.assertIsNone(transform_from_extrinsics_3x4(None))
        self.assertIsNone(transform_from_extrinsics_3x4([1.0, 2.0]))
        self.assertIsNone(transform_from_extrinsics_3x4(["a"] * 12))
        parsed = transform_from_extrinsics_3x4(
            [1.0, 0.0, 0.0, 7.0, 0.0, 1.0, 0.0, 8.0, 0.0, 0.0, 1.0, 9.0]
        )
        self.assertIsNotNone(parsed)
        assert parsed is not None
        self.assertEqual(parsed[1], (7.0, 8.0, 9.0))


class DepthCameraModelTests(unittest.TestCase):
    def test_has_projection_requires_size_and_intrinsics_or_fov(self) -> None:
        self.assertFalse(DepthCameraModel(width=0, height=0).has_projection())
        self.assertFalse(DepthCameraModel(width=4, height=4).has_projection())
        self.assertTrue(DepthCameraModel(width=4, height=4, fx=1, fy=1, cx=2, cy=2).has_projection())
        self.assertTrue(
            DepthCameraModel(
                width=4, height=4, fov_left=1, fov_right=1, fov_top=1, fov_bottom=1
            ).has_projection()
        )

    def test_unproject_via_intrinsics_and_fov(self) -> None:
        pinhole = DepthCameraModel(width=4, height=4, fx=2.0, fy=2.0, cx=2.0, cy=2.0)
        point = pinhole.unproject(2.0, 2.0, 3.0)
        self.assertEqual(point, (0.0, -0.0, -3.0))

        fov = DepthCameraModel(width=4, height=4, fov_left=1.0, fov_right=1.0, fov_top=1.0, fov_bottom=1.0)
        centre = fov.unproject(2.0, 2.0, 2.0)
        assert centre is not None
        self.assertAlmostEqual(centre[0], 0.0)
        self.assertAlmostEqual(centre[1], 0.0)
        self.assertEqual(centre[2], -2.0)

    def test_unproject_rejects_degenerate_focal_length(self) -> None:
        broken = DepthCameraModel(width=4, height=4, fx=0.0, fy=0.0, cx=2.0, cy=2.0)
        self.assertIsNone(broken.unproject(1.0, 1.0, 1.0))
        self.assertIsNone(DepthCameraModel(width=4, height=4).unproject(1.0, 1.0, 1.0))

    def test_with_fallback_fills_missing_fields(self) -> None:
        fallback = DepthCameraModel(
            width=8, height=4, fx=1.0, fy=1.0, cx=4.0, cy=2.0, depth_eye_to_local=identity_transform()
        )
        self.assertIs(DepthCameraModel(width=1, height=1).with_fallback(None).width, 1)
        merged = DepthCameraModel(width=0, height=0).with_fallback(fallback)
        self.assertEqual((merged.width, merged.height), (8, 4))
        self.assertEqual(merged.fx, 1.0)
        self.assertIsNotNone(merged.depth_eye_to_local)


class MetadataParsingTests(unittest.TestCase):
    def test_parse_nested_metadata_json_tolerates_bad_input(self) -> None:
        self.assertEqual(parse_nested_metadata_json({}), {})
        self.assertEqual(parse_nested_metadata_json({"metadata_json": ""}), {})
        self.assertEqual(parse_nested_metadata_json({"metadata_json": "{bad"}), {})
        self.assertEqual(parse_nested_metadata_json({"metadata_json": "[1,2]"}), {})
        self.assertEqual(parse_nested_metadata_json({"metadata_json": '{"a":1}'}), {"a": 1})

    def test_depth_model_prefers_outer_then_nested_dimensions(self) -> None:
        self.assertIsNone(depth_model_from_metadata({}))
        fallback = DepthCameraModel(width=2, height=2, fx=1, fy=1, cx=1, cy=1)
        # Missing dimensions inherit the fallback's, producing an equal model.
        self.assertEqual(depth_model_from_metadata({}, fallback), fallback)
        # Explicitly invalid dimensions short-circuit to the fallback itself.
        self.assertIs(depth_model_from_metadata({"width": 0, "height": 0}, fallback), fallback)

        from_intrinsics = depth_model_from_metadata(
            {"intrinsics": {"width": 6, "height": 3, "fx": 3.0, "fy": 3.0, "cx": 3.0, "cy": 1.5}}
        )
        assert from_intrinsics is not None
        self.assertEqual((from_intrinsics.width, from_intrinsics.height), (6, 3))
        self.assertTrue(from_intrinsics.has_projection())

    def test_depth_model_reads_fov_from_nested_metadata(self) -> None:
        model = depth_model_from_metadata(
            {
                "width": 4,
                "height": 4,
                "metadata_json": encode_json(
                    {
                        "fov_tangent": {"left": 1.0, "right": 1.0, "top": 0.5, "bottom": 0.5},
                        "local_from_depth_eye": {
                            "position": {"x": 0.0, "y": 1.5, "z": 0.0},
                            "rotation": {"x": 0.0, "y": 0.0, "z": 0.0, "w": 1.0},
                        },
                    }
                ).decode(),
            }
        )
        assert model is not None
        self.assertEqual(model.fov_top, 0.5)
        self.assertTrue(model.depth_eye_transform_is_absolute)
        self.assertIsNotNone(model.depth_eye_to_local)

    def test_depth_model_falls_back_to_extrinsics_when_pose_absent(self) -> None:
        model = depth_model_from_metadata(
            {
                "width": 4,
                "height": 4,
                "intrinsics": {
                    "fx": 4.0,
                    "fy": 4.0,
                    "cx": 2.0,
                    "cy": 2.0,
                    "extrinsics_3x4": [1.0, 0.0, 0.0, 0.5, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0],
                },
            }
        )
        assert model is not None
        self.assertFalse(model.depth_eye_transform_is_absolute)
        assert model.depth_eye_to_local is not None
        self.assertEqual(model.depth_eye_to_local[1], (0.5, 0.0, 0.0))


class RgbCameraConfigTests(unittest.TestCase):
    def test_explicit_camera_list_is_used(self) -> None:
        cameras = rgb_cameras_from_config(
            {
                "cameras": [
                    {"width": 4, "height": 2, "fx": 2.0, "fy": 2.0, "cx": 2.0, "cy": 1.0},
                    "not-a-dict",
                    {"width": 0, "height": 2, "fx": 1.0, "fy": 1.0, "cx": 1.0, "cy": 1.0},
                    {"width": 4, "height": 2, "fx": None, "fy": 1.0, "cx": 1.0, "cy": 1.0},
                ]
            }
        )
        self.assertEqual(len(cameras), 1)
        self.assertEqual(cameras[0].index, 0)

    def test_side_by_side_fallback_splits_the_frame(self) -> None:
        cameras = rgb_cameras_from_config(
            {"width": 1280, "height": 960, "camera_count": 2, "stereo_layout": "side_by_side"}
        )
        self.assertEqual(len(cameras), 2)
        self.assertEqual(cameras[0].width, 640)
        self.assertEqual(cameras[0].cx, 320.0)

    def test_mono_fallback_and_empty_config(self) -> None:
        self.assertEqual(rgb_cameras_from_config({}), ())
        self.assertEqual(rgb_cameras_from_config({"width": 0, "height": 5}), ())
        self.assertEqual(rgb_cameras_from_config({"cameras": "junk", "width": 64, "height": 32})[0].width, 64)

    def test_rgb_frame_reports_eye_width(self) -> None:
        cameras = (
            RgbCameraModel(0, 4, 2, 2.0, 2.0, 2.0, 1.0),
            RgbCameraModel(1, 4, 2, 2.0, 2.0, 2.0, 1.0),
        )
        stereo = RgbFrame(0, 8, 2, "side_by_side", cameras, b"\x00" * 48)
        self.assertEqual(stereo.eye_width(), 4)
        self.assertEqual(stereo.camera_count, 2)
        mono = RgbFrame(0, 8, 2, "mono", (), b"")
        self.assertEqual(mono.eye_width(), 8)
        self.assertEqual(mono.camera_count, 1)


class SampleKindTests(unittest.TestCase):
    def test_sample_kinds_are_stable(self) -> None:
        kinds = sample_kinds()
        self.assertIn("head_pose", kinds)
        self.assertIn("unknown", kinds)
        self.assertEqual(len(set(kinds)), len(kinds))


class RgbHevcDecoderTests(unittest.TestCase):
    def make_fake_ffmpeg(self, frame_bytes: int, frames: int) -> str:
        import shutil as _shutil

        temp_dir = tempfile.mkdtemp()
        self.addCleanup(lambda: _shutil.rmtree(temp_dir, ignore_errors=True))
        self.addCleanup(fake_headset.clear_fake_ffmpeg_env)
        return fake_headset.make_fake_ffmpeg(Path(temp_dir), frame_bytes, frames)

    def test_missing_ffmpeg_disables_the_decoder_gracefully(self) -> None:
        decoder = RgbHevcDecoder(ffmpeg_bin="definitely-not-a-real-binary")
        self.addCleanup(decoder.close)
        self.assertFalse(decoder.available)
        self.assertIn("ffmpeg not found", decoder.disabled_reason)
        # No crash: configure and submit are no-ops without a process.
        decoder.configure({"width": 8, "height": 8, "codec": "hevc"})
        decoder.submit_payload(1, b"data")
        self.assertIsNone(decoder.nearest_frame(1))
        self.assertIsNone(decoder.latest_frame())
        self.assertEqual(decoder.decoded_count, 0)

    def test_disabled_decoder_ignores_configuration(self) -> None:
        decoder = RgbHevcDecoder(ffmpeg_bin=self.make_fake_ffmpeg(3, 0), enabled=False)
        self.addCleanup(decoder.close)
        decoder.configure({"width": 1, "height": 1, "codec": "hevc"})
        self.assertFalse(decoder.available)
        self.assertEqual(decoder.decoded_count, 0)

    def test_codec_detection_from_config(self) -> None:
        detect = RgbHevcDecoder._codec_from_config
        self.assertEqual(detect({"codec": "h265"}), "hevc")
        self.assertEqual(detect({"codec": "video/hevc"}), "hevc")
        self.assertEqual(detect({"bitstream_format": "hevc_annexb"}), "hevc")
        self.assertEqual(detect({"codec": "avc"}), "h264")
        self.assertEqual(detect({"bitstream_format": "h264_annexb"}), "h264")
        self.assertEqual(detect({"codec": "vp9"}), "vp9")
        self.assertEqual(detect({}), "")

    def test_bad_configuration_is_reported_not_raised(self) -> None:
        decoder = RgbHevcDecoder(ffmpeg_bin=self.make_fake_ffmpeg(3, 0))
        self.addCleanup(decoder.close)
        decoder.configure({"codec": "hevc"})
        self.assertIn("missing RGB frame dimensions", decoder.disabled_reason)
        decoder.configure({"width": 4, "height": 4, "codec": "vp9"})
        self.assertIn("unsupported RGB codec", decoder.disabled_reason)

    def test_decodes_frames_and_pairs_them_with_timestamps(self) -> None:
        width, height = 2, 2
        decoder = RgbHevcDecoder(ffmpeg_bin=self.make_fake_ffmpeg(width * height * 3, 3))
        self.addCleanup(decoder.close)
        decoder.configure({"width": width, "height": height, "codec": "hevc", "stereo_layout": "mono"})
        self.assertTrue(decoder.available)

        for pts in (100, 200, 300):
            decoder.submit_packet(StreamEvent(3, 0, pts, 0, b"\x00\x00\x00\x01"))

        deadline = time.monotonic() + 5.0
        while decoder.decoded_count < 3 and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertEqual(decoder.decoded_count, 3)

        latest = decoder.latest_frame()
        assert latest is not None
        self.assertEqual((latest.width, latest.height), (width, height))
        self.assertEqual(len(latest.data), width * height * 3)

        nearest = decoder.nearest_frame(205)
        assert nearest is not None
        self.assertEqual(nearest.pts_ns, 200)
        # Far outside the tolerance window: fall back to the newest frame.
        far = decoder.nearest_frame(999_999_999_999)
        assert far is not None
        self.assertEqual(far.pts_ns, 300)

    def test_invalid_csd_marks_the_decoder_failed(self) -> None:
        decoder = RgbHevcDecoder(ffmpeg_bin=self.make_fake_ffmpeg(12, 0))
        self.addCleanup(decoder.close)
        decoder.configure(
            {"width": 2, "height": 2, "codec": "hevc", "csd_base64": "!!!not base64!!!"}
        )
        self.assertTrue(decoder.failed)
        self.assertIn("bad rgb_csd", decoder.disabled_reason)
        self.assertFalse(decoder.available)

    def test_reconfiguring_with_the_same_signature_reuses_the_process(self) -> None:
        decoder = RgbHevcDecoder(ffmpeg_bin=self.make_fake_ffmpeg(12, 0))
        self.addCleanup(decoder.close)
        config = {"width": 2, "height": 2, "codec": "hevc", "stereo_layout": "mono"}
        decoder.configure(dict(config))
        first = decoder._proc
        decoder.configure(dict(config))
        self.assertIs(decoder._proc, first)


class RuntimeHelperTests(unittest.TestCase):
    def test_dropping_queue_blocking_put(self) -> None:
        queue = DroppingQueue[str]("q", 2)
        queue.put_blocking("a")
        self.assertEqual(queue.get(timeout=1.0), "a")

    def test_session_recorder_handles_malformed_frames(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            recorder = SessionRecorder(Path(temp_dir))
            try:
                # session_start declared JSON but is not parseable
                recorder.record(StreamEvent(1, 0, 0, 0, b"{bad"))
                # composite flag set but payload is not composite
                recorder.record(StreamEvent(5, 2, 1, 0, b"\x00"))
                # binary frame
                recorder.record(StreamEvent(3, 0, 2, 0, b"\x01\x02"))
            finally:
                recorder.close()
            events = (Path(temp_dir) / "events.ndjson").read_text().splitlines()
            self.assertEqual(len(events), 3)
            self.assertEqual((Path(temp_dir) / "rgb.h265").read_bytes(), b"\x01\x02")

    def test_session_recorder_writes_csd_into_the_elementary_stream(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            recorder = SessionRecorder(Path(temp_dir))
            try:
                recorder.record(StreamEvent(2, 0, 0, 0, encode_json({"csd_base64": "AAAAAQ=="})))
            finally:
                recorder.close()
            self.assertEqual((Path(temp_dir) / "rgb.h265").read_bytes(), b"\x00\x00\x00\x01")

    def test_session_recorder_persists_compressed_depth_as_raw_u16(self) -> None:
        wire_frame = fake_headset.depth_frame_frame(
            123,
            width=64,
            height=64,
            depth_mm=1500,
        )
        event = read_frame(io.BytesIO(wire_frame))
        self.assertIsNotNone(event)
        assert event is not None

        with tempfile.TemporaryDirectory() as temp_dir:
            recorder = SessionRecorder(Path(temp_dir))
            try:
                recorder.record(event)
            finally:
                recorder.close()

            depth_files = list((Path(temp_dir) / "depth").glob("*.u16"))
            self.assertEqual(len(depth_files), 1)
            raw_depth = depth_files[0].read_bytes()
            self.assertEqual(len(raw_depth), 64 * 64 * 2)
            self.assertEqual(raw_depth[:2], (1500).to_bytes(2, "little"))

            records = [
                json.loads(line)
                for line in (Path(temp_dir) / "events.ndjson").read_text().splitlines()
            ]
            payload = records[0]["payload"]
            self.assertEqual(payload["binary_size"], len(raw_depth))
            self.assertLess(payload["wire_size"], payload["binary_size"])

    def test_connect_push_client_reaches_a_receiver(self) -> None:
        receiver = LiveFeedReceiver(
            ReceiverConfig(host="127.0.0.1", push_port=0, accept_results=False, quiet=True)
        )
        self.addCleanup(receiver.close)
        receiver.start()
        # start() is idempotent
        receiver.start()
        conn = connect_push_client("127.0.0.1", receiver.push_port)
        self.addCleanup(conn.close)
        session = receiver.accept(timeout=5.0)
        self.assertIsNotNone(session)
        assert session is not None
        session.close()
        # close() is idempotent
        session.close()

    def test_result_helpers_when_the_channel_is_disabled(self) -> None:
        receiver = LiveFeedReceiver(
            ReceiverConfig(host="127.0.0.1", push_port=0, accept_results=False, quiet=True)
        )
        self.addCleanup(receiver.close)
        receiver.start()
        self.assertFalse(receiver.wait_result_bound(0.1))
        self.assertFalse(receiver.result_channel.wait_for_client(0.1))
        # Sending on a disabled channel is a no-op rather than an error.
        receiver.result_channel.send_frame(110, 0, 0, 0, b"{}")
        receiver.close()
        receiver.close()

    def test_push_port_before_start_reports_the_configured_value(self) -> None:
        receiver = LiveFeedReceiver(ReceiverConfig(push_port=64321, accept_results=False, quiet=True))
        self.assertEqual(receiver.push_port, 64321)

    def test_monotonic_pts_and_point_packing(self) -> None:
        self.assertGreater(monotonic_pts_ns(), 0)
        self.assertEqual(pack_dense_points([]), b"")
        self.assertEqual(len(pack_dense_points([DensePoint(0.0, 0.0, 0.0)])), 20)


if __name__ == "__main__":
    unittest.main()
