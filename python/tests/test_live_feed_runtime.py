"""Tests for the Live Feed runtime, typed models, result publishing, and examples."""

from __future__ import annotations

import importlib.util
import io
import json
import socket
import sys
import threading
import time
import unittest
import zlib
from contextlib import redirect_stdout
from pathlib import Path
from typing import Any

import pytest

from pyoperator.live_feed import (
    CONTROLLER_BUTTON_BITS,
    ControllerInputSample,
    ControllerPoseSample,
    DensePoint,
    DepthFrameSample,
    HandJointsSample,
    HeadPoseSample,
    LiveFeedReceiver,
    ReceiverConfig,
    ResultPublisher,
    RgbConfigSample,
    RgbPacketSample,
    SessionEndSample,
    SessionStartSample,
    UnknownSample,
    apply_transform,
    decode_button_mask,
    pack_dense_points,
    parse_sample,
    read_frame,
)
from pyoperator.live_feed.protocol import (
    DENSE_POINT,
    FLAG_COMPRESSED_ZLIB,
    FLAG_COMPOSITE_JSON,
    TYPE_ALGORITHM_STATUS,
    TYPE_CAMERA_TRAJECTORY,
    TYPE_CAPTURE_REQUEST,
    TYPE_DENSE_MAP_COMMIT,
    TYPE_DENSE_MAP_FRAGMENT,
    TYPE_DENSE_MAP_MANIFEST,
    TYPE_HEAD_POSE,
    TYPE_MAP_RESET,
    TYPE_RGB_PACKET,
    TYPE_RESULT_HELLO,
    TYPE_RESULT_WELCOME,
    StreamEvent,
    encode_json,
    pack_frame,
    parse_composite_payload,
    pack_composite_payload,
)
from pyoperator.live_feed.runtime import CRITICAL_KINDS, DroppingQueue, SessionStats

import fake_headset


EXAMPLES_DIR = Path(__file__).resolve().parents[1] / "examples"


def load_example(name: str) -> Any:
    """Import an example script as a module so its logic can be unit tested."""
    path = EXAMPLES_DIR / f"{name}.py"
    spec = importlib.util.spec_from_file_location(f"_example_{name}", path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def connect_result_socket(
    host: str,
    port: int,
    *,
    token: str = "",
) -> tuple[socket.socket, dict[str, Any]]:
    conn = socket.create_connection((host, port), timeout=5.0)
    conn.settimeout(5.0)
    conn.sendall(
        pack_frame(
            TYPE_RESULT_HELLO,
            0,
            0,
            0,
            encode_json(
                {
                    "schema": "operator.result_hello.v1",
                    "auth_token": token,
                }
            ),
        )
    )
    frame = read_frame(conn)
    assert frame is not None
    assert frame.frame_type == TYPE_RESULT_WELCOME
    welcome = frame.payload_json()
    assert welcome["schema"] == "operator.result_welcome.v1"
    assert welcome["server_instance_id"]
    return conn, welcome


# ---------------------------------------------------------------------------
# typed sample parsing
# ---------------------------------------------------------------------------


class SampleParsingTests(unittest.TestCase):
    def _event(self, frame_type: int, payload: dict[str, Any], pts_ns: int = 42, flags: int = 0) -> StreamEvent:
        return StreamEvent(frame_type, flags, pts_ns, 0, encode_json(payload))

    def test_session_start_uses_stream_name_and_expected_flags(self) -> None:
        sample = parse_sample(self._event(1, fake_headset.session_start_payload("live_a")))
        assert isinstance(sample, SessionStartSample)
        self.assertEqual(sample.kind, "session_start")
        # The headset field is stream_name, not session_id.
        self.assertEqual(sample.session_id, "live_a")
        self.assertEqual(sample.contract_version, 6)
        self.assertEqual(sample.rgb_size, (1280, 960))
        self.assertIn("head_pose", sample.expected_streams())
        self.assertIn("depth", sample.expected_streams())

    def test_session_end_exposes_reason(self) -> None:
        sample = parse_sample(self._event(10, {"stream_name": "live_a", "reason": "finish"}))
        assert isinstance(sample, SessionEndSample)
        self.assertEqual(sample.session_id, "live_a")
        self.assertEqual(sample.reason, "finish")

    def test_rgb_config_parses_stereo_cameras_and_csd(self) -> None:
        payload = fake_headset.rgb_csd_payload()
        payload["csd_base64"] = "AAAAAQ=="
        sample = parse_sample(self._event(2, payload))
        assert isinstance(sample, RgbConfigSample)
        self.assertEqual(sample.stereo_layout, "side_by_side")
        self.assertEqual(len(sample.cameras), 2)
        self.assertEqual(sample.cameras[1].fx, 320.0)
        self.assertEqual(sample.csd_bytes(), b"\x00\x00\x00\x01")

    def test_rgb_packet_reports_keyframe_flag(self) -> None:
        event = StreamEvent(TYPE_RGB_PACKET, 1, 7, 0, b"\x00\x00\x00\x01\x26")
        sample = parse_sample(event)
        assert isinstance(sample, RgbPacketSample)
        self.assertTrue(sample.keyframe)
        self.assertEqual(sample.size_bytes, 5)
        self.assertFalse(parse_sample(StreamEvent(TYPE_RGB_PACKET, 0, 7, 0, b"x")).keyframe)

    def test_head_pose_transform_and_invalid_tracking(self) -> None:
        sample = parse_sample(self._event(6, fake_headset.head_pose_payload(1.0, 2.0, 3.0)))
        assert isinstance(sample, HeadPoseSample)
        self.assertEqual(sample.position, (1.0, 2.0, 3.0))
        self.assertTrue(sample.tracking_valid)
        # identity rotation: local -Z maps straight to world -Z
        self.assertEqual(apply_transform(sample.transform, (0.0, 0.0, -1.0)), (1.0, 2.0, 2.0))

        invalid = parse_sample(self._event(6, fake_headset.head_pose_payload(tracking_valid=False)))
        assert isinstance(invalid, HeadPoseSample)
        self.assertFalse(invalid.tracking_valid)

    def test_controller_pose_hand_comes_from_source_field(self) -> None:
        for hand in ("left", "right"):
            sample = parse_sample(self._event(7, fake_headset.controller_pose_payload(hand)))
            assert isinstance(sample, ControllerPoseSample)
            self.assertEqual(sample.hand, hand)

    def test_controller_input_decodes_bitmasks_and_axes(self) -> None:
        mask = CONTROLLER_BUTTON_BITS["trigger_click"] | CONTROLLER_BUTTON_BITS["a"]
        sample = parse_sample(
            self._event(9, fake_headset.controller_input_payload("right", pressed_mask=mask, trigger=0.75))
        )
        assert isinstance(sample, ControllerInputSample)
        self.assertEqual(sample.hand, "right")
        self.assertTrue(sample.is_snapshot)
        self.assertAlmostEqual(sample.trigger, 0.75)
        self.assertAlmostEqual(sample.grip, 0.25)
        self.assertEqual(sample.thumbstick, (0.5, -0.25))
        self.assertEqual(sample.pressed_buttons(), ("a", "trigger_click"))
        self.assertTrue(sample.is_pressed("a"))
        self.assertFalse(sample.is_pressed("menu"))
        self.assertFalse(sample.is_pressed("not_a_button"))
        self.assertEqual(sample.numeric_axes()["thumbstick.x"], 0.5)

    def test_decode_button_mask_covers_every_bit(self) -> None:
        every = 0
        for bit in CONTROLLER_BUTTON_BITS.values():
            every |= bit
        self.assertEqual(set(decode_button_mask(every)), set(CONTROLLER_BUTTON_BITS))
        self.assertEqual(decode_button_mask(0), ())

    def test_hand_joints_parses_nested_json_string(self) -> None:
        sample = parse_sample(self._event(8, fake_headset.hand_joints_payload("left", joint_count=26)))
        assert isinstance(sample, HandJointsSample)
        self.assertEqual(sample.hand, "left")
        self.assertEqual(sample.joint_count, 26)
        self.assertEqual(sample.joints[0].index, 0)
        self.assertAlmostEqual(sample.joints[3].position[0], 0.03)
        self.assertAlmostEqual(sample.joints[0].radius_m, 0.008)
        self.assertEqual(len(sample.positions()), 26)

    def test_hand_joints_tolerates_bad_payloads(self) -> None:
        self.assertEqual(parse_sample(self._event(8, {"hand": "left", "joints_json": "not json"})).joints, ())
        self.assertEqual(parse_sample(self._event(8, {"hand": "left", "joints_json": ""})).joints, ())
        self.assertEqual(parse_sample(self._event(8, {"hand": "left"})).joints, ())
        partial = parse_sample(
            self._event(8, {"hand": "right", "joints_json": json.dumps([{"joint": 0}, "junk"])})
        )
        self.assertEqual(partial.joints, ())
        self.assertEqual(partial.hand, "right")

    def test_depth_frame_unprojects_into_world(self) -> None:
        frame = fake_headset.depth_frame_frame(pts_ns=99, width=8, height=4, depth_mm=2000)
        event = read_frame(io.BytesIO(frame))
        assert event is not None
        sample = parse_sample(event)
        assert isinstance(sample, DepthFrameSample)
        self.assertEqual((sample.width, sample.height), (8, 4))
        self.assertTrue(sample.has_pixels())
        self.assertEqual(sample.depth_mm_at(0, 0), 2000)

        points = list(sample.iter_points(stride=1, min_depth_m=0.1, max_depth_m=10.0))
        self.assertEqual(len(points), 32)
        # -Z forward in the depth-eye frame
        self.assertTrue(all(point[2] < 0 for point in points))

        capped = list(sample.iter_points(stride=1, max_points=5))
        self.assertEqual(len(capped), 5)
        # depth range filtering drops everything out of band
        self.assertEqual(list(sample.iter_points(min_depth_m=5.0, max_depth_m=6.0)), [])

    def test_compressed_depth_frame_is_transparently_decoded(self) -> None:
        frame = fake_headset.depth_frame_frame(
            pts_ns=99,
            width=64,
            height=64,
            depth_mm=2000,
        )
        event = read_frame(io.BytesIO(frame))
        assert event is not None
        self.assertTrue(event.flags & FLAG_COMPRESSED_ZLIB)

        sample = parse_sample(event)

        assert isinstance(sample, DepthFrameSample)
        self.assertEqual((sample.width, sample.height), (64, 64))
        self.assertEqual(len(sample.depth_bytes), 64 * 64 * 2)
        self.assertEqual(sample.depth_mm_at(0, 0), 2000)
        self.assertEqual(sample.metadata["wire_compression"], "zlib")

    def test_legacy_uncompressed_depth_frame_remains_supported(self) -> None:
        frame = fake_headset.depth_frame_frame(
            pts_ns=99,
            width=64,
            height=64,
            depth_mm=1750,
            compress=False,
        )
        event = read_frame(io.BytesIO(frame))
        assert event is not None
        self.assertFalse(event.flags & FLAG_COMPRESSED_ZLIB)

        sample = parse_sample(event)

        assert isinstance(sample, DepthFrameSample)
        self.assertEqual(sample.depth_mm_at(0, 0), 1750)

    def test_compressed_depth_without_composite_uses_previous_model(self) -> None:
        metadata_sample = parse_sample(
            self._event(
                4,
                {
                    "width": 4,
                    "height": 2,
                    "intrinsics": {
                        "fx": 4.0,
                        "fy": 4.0,
                        "cx": 2.0,
                        "cy": 1.0,
                    },
                },
            )
        )
        raw = b"\xd0\x07" * 8
        event = StreamEvent(5, FLAG_COMPRESSED_ZLIB, 5, 0, zlib.compress(raw, level=1))

        sample = parse_sample(event, depth_model=metadata_sample.model)

        assert isinstance(sample, DepthFrameSample)
        self.assertEqual(sample.depth_bytes, raw)
        self.assertEqual(sample.depth_mm_at(3, 1), 2000)

    def test_bad_or_wrong_sized_compressed_depth_degrades_to_unknown(self) -> None:
        bad_payload = pack_composite_payload(
            {"width": 4, "height": 2},
            b"not-zlib",
        )
        self.assertIsInstance(
            parse_sample(
                StreamEvent(
                    5,
                    FLAG_COMPOSITE_JSON | FLAG_COMPRESSED_ZLIB,
                    0,
                    0,
                    bad_payload,
                )
            ),
            UnknownSample,
        )

        wrong_size = pack_composite_payload(
            {"width": 4, "height": 2},
            zlib.compress(b"\x00\x01" * 7),
        )
        self.assertIsInstance(
            parse_sample(
                StreamEvent(
                    5,
                    FLAG_COMPOSITE_JSON | FLAG_COMPRESSED_ZLIB,
                    0,
                    0,
                    wrong_size,
                )
            ),
            UnknownSample,
        )

    def test_depth_frame_with_zero_pixels_yields_nothing(self) -> None:
        frame = fake_headset.depth_frame_frame(pts_ns=1, width=4, height=2, depth_mm=0)
        event = read_frame(io.BytesIO(frame))
        assert event is not None
        sample = parse_sample(event)
        assert isinstance(sample, DepthFrameSample)
        self.assertEqual(list(sample.iter_points()), [])

    def test_depth_frame_inherits_model_from_earlier_metadata(self) -> None:
        # A composite frame whose metadata lacks projection info still unprojects
        # when a previous depth_metadata frame supplied the model.
        metadata_sample = parse_sample(
            self._event(4, {"width": 4, "height": 2, "intrinsics": {"fx": 4.0, "fy": 4.0, "cx": 2.0, "cy": 1.0}})
        )
        self.assertIsNotNone(metadata_sample.model)

        bare = StreamEvent(5, 0, 5, 0, b"\x00\x01" * 8)
        inherited = parse_sample(bare, depth_model=metadata_sample.model)
        assert isinstance(inherited, DepthFrameSample)
        self.assertEqual(inherited.width, 4)
        self.assertTrue(inherited.has_pixels())

    def test_malformed_frames_degrade_to_unknown_instead_of_raising(self) -> None:
        self.assertIsInstance(parse_sample(StreamEvent(1, 0, 0, 0, b"{bad json")), UnknownSample)
        self.assertIsInstance(parse_sample(StreamEvent(6, 0, 0, 0, b"{}")), UnknownSample)
        self.assertIsInstance(parse_sample(StreamEvent(9, 0, 0, 0, b"nope")), UnknownSample)
        # composite flag set but payload is not a valid composite
        self.assertIsInstance(
            parse_sample(StreamEvent(5, FLAG_COMPOSITE_JSON, 0, 0, b"\x00")), UnknownSample
        )
        self.assertIsInstance(parse_sample(StreamEvent(999, 0, 0, 0, b"?")), UnknownSample)


# ---------------------------------------------------------------------------
# queues and stats
# ---------------------------------------------------------------------------


class QueueAndStatsTests(unittest.TestCase):
    def test_dropping_queue_drops_oldest_and_counts(self) -> None:
        queue = DroppingQueue[int]("test", 2)
        queue.put_drop_oldest(1)
        queue.put_drop_oldest(2)
        queue.put_drop_oldest(3)
        self.assertEqual(queue.dropped, 1)
        self.assertEqual(queue.qsize(), 2)
        self.assertEqual(queue.get_nowait(), 2)
        self.assertEqual(queue.get_nowait(), 3)

    def test_session_stats_rates_and_summary(self) -> None:
        stats = SessionStats()
        self.assertEqual(stats.elapsed_s, 0.0)
        self.assertEqual(stats.rate_hz("head_pose"), 0.0)
        for index in range(3):
            sample = parse_sample(
                StreamEvent(TYPE_HEAD_POSE, 0, index, 0, encode_json(fake_headset.head_pose_payload()))
            )
            object.__setattr__(sample, "recv_monotonic_ns", index * 1_000_000_000)
            stats.record(sample, 10)
        self.assertEqual(stats.counts["head_pose"], 3)
        self.assertEqual(stats.bytes_received, 30)
        self.assertAlmostEqual(stats.elapsed_s, 2.0)
        self.assertAlmostEqual(stats.rate_hz("head_pose"), 1.5)
        self.assertIn("head_pose=3", stats.summary())

    def test_critical_kinds_are_declared(self) -> None:
        self.assertIn("session_start", CRITICAL_KINDS)
        self.assertIn("session_end", CRITICAL_KINDS)
        self.assertIn("rgb_csd", CRITICAL_KINDS)


# ---------------------------------------------------------------------------
# result publishing
# ---------------------------------------------------------------------------


class ResultPublisherTests(unittest.TestCase):
    def setUp(self) -> None:
        self.sent: list[tuple[int, int, int, int, bytes]] = []
        self.publisher = ResultPublisher(
            lambda *args: self.sent.append(args), max_fragment_bytes=64 * 1024
        )

    def frame_types(self) -> list[int]:
        return [frame[0] for frame in self.sent]

    def test_publish_points_emits_manifest_fragments_then_commit(self) -> None:
        points = [DensePoint(x=float(index), y=0.0, z=0.0) for index in range(4)]
        chunk_id = self.publisher.publish_points(map_id="m", points=points, chunk_id="fixed")

        self.assertEqual(chunk_id, "fixed")
        self.assertEqual(
            self.frame_types(),
            [TYPE_DENSE_MAP_MANIFEST, TYPE_DENSE_MAP_FRAGMENT, TYPE_DENSE_MAP_COMMIT],
        )
        manifest = json.loads(self.sent[0][4])
        self.assertEqual(manifest["chunks"][0]["chunk_id"], "fixed")
        self.assertEqual(manifest["chunks"][0]["point_count"], 4)
        self.assertEqual(manifest["chunks"][0]["point_format"], "f32xyz_u8rgba_f32conf")
        self.assertEqual(manifest["chunks"][0]["point_stride_bytes"], DENSE_POINT.size)

        self.assertEqual(self.sent[1][1], FLAG_COMPOSITE_JSON)
        metadata, binary = parse_composite_payload(self.sent[1][4])
        self.assertEqual(metadata["fragment_index"], 0)
        self.assertEqual(metadata["fragment_count"], 1)
        self.assertEqual(len(binary), 4 * DENSE_POINT.size)

        commit = json.loads(self.sent[2][4])
        self.assertEqual(commit["committed_chunks"], ["fixed"])

    def test_map_version_increases_so_the_headset_never_drops_updates(self) -> None:
        # live_pull_client.gd discards manifests whose map_version is lower than
        # the newest one it has seen, so versions must be strictly increasing.
        versions = []
        for _ in range(4):
            self.publisher.publish_points(map_id="m", points=[DensePoint(0.0, 0.0, 0.0)], chunk_id="fixed")
            versions.append(self.publisher.map_version("m"))
        self.assertEqual(versions, [1, 2, 3, 4])
        manifests = [json.loads(frame[4]) for frame in self.sent if frame[0] == TYPE_DENSE_MAP_MANIFEST]
        self.assertEqual([manifest["map_version"] for manifest in manifests], [1, 2, 3, 4])

    def test_reset_map_restarts_versioning(self) -> None:
        self.publisher.publish_points(map_id="m", points=[DensePoint(0.0, 0.0, 0.0)])
        self.assertEqual(self.publisher.map_version("m"), 1)
        self.publisher.reset_map("m")
        self.assertEqual(self.frame_types()[-1], TYPE_MAP_RESET)
        self.assertEqual(self.publisher.map_version("m"), 0)
        self.publisher.publish_points(map_id="m", points=[DensePoint(0.0, 0.0, 0.0)])
        self.assertEqual(self.publisher.map_version("m"), 1)

    def test_large_payload_is_split_across_fragments_on_point_boundaries(self) -> None:
        publisher = ResultPublisher(lambda *args: self.sent.append(args), max_fragment_bytes=64 * 1024)
        count = 8000  # 8000 * 20B = 160000B > 64KiB fragment budget
        publisher.publish_points(
            map_id="m", points=[DensePoint(float(i), 0.0, 0.0) for i in range(count)]
        )
        fragments = [frame for frame in self.sent if frame[0] == TYPE_DENSE_MAP_FRAGMENT]
        self.assertGreater(len(fragments), 1)
        total = 0
        for index, frame in enumerate(fragments):
            metadata, binary = parse_composite_payload(frame[4])
            self.assertEqual(metadata["fragment_index"], index)
            self.assertEqual(metadata["fragment_count"], len(fragments))
            # Fragments must never split a point in half.
            self.assertEqual(len(binary) % DENSE_POINT.size, 0)
            total += len(binary)
        self.assertEqual(total, count * DENSE_POINT.size)
        self.assertEqual(self.frame_types()[-1], TYPE_DENSE_MAP_COMMIT)

    def test_publish_points_accepts_prepacked_bytes(self) -> None:
        payload = pack_dense_points([DensePoint(1.0, 2.0, 3.0), DensePoint(4.0, 5.0, 6.0)])
        self.assertEqual(len(payload), 2 * DENSE_POINT.size)
        self.publisher.publish_points(map_id="m", points=payload)
        manifest = json.loads(self.sent[0][4])
        self.assertEqual(manifest["chunks"][0]["point_count"], 2)

    def test_dense_point_clamps_colour_channels(self) -> None:
        packed = DensePoint(0.0, 0.0, 0.0, r=999, g=-5, b=128).pack()
        values = DENSE_POINT.unpack(packed)
        self.assertEqual(values[3], 255)
        self.assertEqual(values[4], 0)
        self.assertEqual(values[5], 128)

    def test_status_and_trajectory_frames(self) -> None:
        self.publisher.publish_status("running", algorithm="demo", message="hi", extra=1)
        status = json.loads(self.sent[-1][4])
        self.assertEqual(self.frame_types()[-1], TYPE_ALGORITHM_STATUS)
        self.assertEqual(status["state"], "running")
        self.assertEqual(status["message"], "hi")
        self.assertEqual(status["extra"], 1)

        sample = parse_sample(
            StreamEvent(TYPE_HEAD_POSE, 0, 5, 0, encode_json(fake_headset.head_pose_payload(1.0, 2.0, 3.0)))
        )
        self.publisher.publish_trajectory("m", [sample.pose])
        trajectory = json.loads(self.sent[-1][4])
        self.assertEqual(self.frame_types()[-1], TYPE_CAMERA_TRAJECTORY)
        self.assertEqual(len(trajectory["poses"]), 1)
        self.assertEqual(trajectory["poses"][0]["T_map_camera"][0][3], 1.0)

    def test_session_dir_persists_results(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            with ResultPublisher(lambda *_a: None, session_dir=Path(temp_dir)) as publisher:
                publisher.publish_points(map_id="m", points=[DensePoint(0.0, 0.0, 0.0)], chunk_id="c")
            results_dir = Path(temp_dir) / "results"
            self.assertTrue((results_dir / "results.ndjson").exists())
            self.assertTrue((results_dir / "map_chunks" / "c.bin").exists())
            records = [json.loads(line) for line in (results_dir / "results.ndjson").read_text().splitlines()]
            self.assertEqual([record["frame_type"] for record in records][0], TYPE_DENSE_MAP_MANIFEST)


# ---------------------------------------------------------------------------
# end-to-end loopback over real sockets
# ---------------------------------------------------------------------------


@pytest.mark.loopback
@pytest.mark.fake_headset
class ReceiverLoopbackTests(unittest.TestCase):
    def make_receiver(self, **overrides: Any) -> LiveFeedReceiver:
        config = ReceiverConfig(
            host="127.0.0.1",
            push_port=0,
            result_host="127.0.0.1",
            result_port=0,
            quiet=True,
            **overrides,
        )
        receiver = LiveFeedReceiver(config)
        self.addCleanup(receiver.close)
        receiver.start()
        return receiver

    def test_one_way_stream_yields_typed_samples_in_order(self) -> None:
        receiver = self.make_receiver(publish_results=False)
        kinds: list[str] = []

        def headset() -> None:
            with fake_headset.FakeHeadset("127.0.0.1", receiver.push_port) as device:
                device.session_start(stream_name="live_test_0001")
                device.rgb_csd()
                device.rgb_packet(1_000)
                device.depth_metadata(2_000)
                device.depth_frame(3_000)
                device.head_pose(4_000, x=0.1)
                device.controller_pose(5_000, hand="right")
                device.controller_input(6_000, hand="right", trigger=1.0)
                device.hand_joints(7_000, hand="left")
                device.session_end()

        thread = threading.Thread(target=headset, daemon=True)
        thread.start()

        session = receiver.accept(timeout=5.0)
        self.assertIsNotNone(session)
        assert session is not None
        try:
            for sample in session.samples():
                kinds.append(sample.kind)
        finally:
            session.close()
        thread.join(timeout=5.0)

        self.assertEqual(kinds[0], "session_start")
        self.assertEqual(kinds[-1], "session_end")
        for expected in (
            "rgb_csd",
            "rgb_packet",
            "depth_metadata",
            "depth_frame",
            "head_pose",
            "controller_pose",
            "controller_input",
            "hand_joints",
        ):
            self.assertIn(expected, kinds)
        self.assertEqual(session.session_id, "live_test_0001")
        self.assertEqual(session.stats.counts["head_pose"], 1)
        self.assertIsNone(session.error)
        # publish_results=False means strictly one-way.
        self.assertIsNone(session.results)

    def test_result_frames_reach_a_connected_pull_client(self) -> None:
        receiver = self.make_receiver()
        self.assertTrue(receiver.wait_result_bound(5.0))

        pull, _welcome = connect_result_socket("127.0.0.1", receiver.result_port)
        self.addCleanup(pull.close)
        self.assertTrue(receiver.result_channel.wait_for_client(5.0))

        device = fake_headset.FakeHeadset("127.0.0.1", receiver.push_port)
        self.addCleanup(device.close)
        device.session_start()

        session = receiver.accept(timeout=5.0)
        assert session is not None
        self.addCleanup(session.close)
        assert session.results is not None

        session.results.reset_map("m", reason="test")
        session.results.publish_points(
            map_id="m", points=[DensePoint(1.0, 2.0, 3.0)], chunk_id="c", pts_ns=123
        )

        received = [read_frame(pull) for _ in range(4)]
        self.assertEqual(
            [frame.frame_type for frame in received],
            [TYPE_MAP_RESET, TYPE_DENSE_MAP_MANIFEST, TYPE_DENSE_MAP_FRAGMENT, TYPE_DENSE_MAP_COMMIT],
        )
        metadata, binary = parse_composite_payload(received[2].payload)
        self.assertEqual(metadata["chunk_id"], "c")
        self.assertEqual(DENSE_POINT.unpack(binary)[:3], (1.0, 2.0, 3.0))
        self.assertEqual(received[2].pts_ns, 123)

    def test_first_frame_must_be_session_start(self) -> None:
        receiver = self.make_receiver(publish_results=False)
        device = fake_headset.FakeHeadset("127.0.0.1", receiver.push_port)
        self.addCleanup(device.close)
        device.head_pose(1)

        session = receiver.accept(timeout=5.0)
        assert session is not None
        self.addCleanup(session.close)
        self.assertEqual(list(session.samples()), [])
        self.assertIsInstance(session.error, ValueError)
        self.assertIn("must be session_start", str(session.error))

    def test_auth_token_mismatch_terminates_the_session(self) -> None:
        receiver = self.make_receiver(publish_results=False, auth_token="secret")
        device = fake_headset.FakeHeadset("127.0.0.1", receiver.push_port)
        self.addCleanup(device.close)
        device.session_start(auth_token="wrong")

        session = receiver.accept(timeout=5.0)
        assert session is not None
        self.addCleanup(session.close)
        self.assertEqual(list(session.samples()), [])
        self.assertIsInstance(session.error, PermissionError)

    def test_unsupported_session_protocol_is_rejected(self) -> None:
        receiver = self.make_receiver(publish_results=False)
        device = fake_headset.FakeHeadset("127.0.0.1", receiver.push_port)
        self.addCleanup(device.close)
        device.session_start(protocol="some.other.protocol")

        session = receiver.accept(timeout=5.0)
        assert session is not None
        self.addCleanup(session.close)
        self.assertEqual(list(session.samples()), [])
        self.assertIn("unsupported session protocol", str(session.error))

    def test_max_events_stops_the_reader(self) -> None:
        receiver = self.make_receiver(publish_results=False, max_events=3)
        device = fake_headset.FakeHeadset("127.0.0.1", receiver.push_port)
        self.addCleanup(device.close)
        device.session_start()
        for index in range(10):
            device.head_pose(index)

        session = receiver.accept(timeout=5.0)
        assert session is not None
        self.addCleanup(session.close)
        self.assertEqual(len(list(session.samples())), 3)

    def test_record_dir_persists_the_raw_stream(self) -> None:
        import tempfile

        temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(temp_dir.cleanup)
        receiver = self.make_receiver(publish_results=False, record_dir=Path(temp_dir.name))

        device = fake_headset.FakeHeadset("127.0.0.1", receiver.push_port)
        self.addCleanup(device.close)
        device.session_start()
        device.rgb_packet(1, payload=b"\x00\x00\x00\x01\x26")
        device.depth_frame(2)
        device.session_end()

        session = receiver.accept(timeout=5.0)
        assert session is not None
        list(session.samples())
        session.close()

        sessions = list(Path(temp_dir.name).iterdir())
        self.assertEqual(len(sessions), 1)
        session_dir = sessions[0]
        self.assertTrue((session_dir / "events.ndjson").exists())
        self.assertEqual((session_dir / "rgb.h265").read_bytes(), b"\x00\x00\x00\x01\x26")
        self.assertEqual(len(list((session_dir / "depth").iterdir())), 1)

    @pytest.mark.loopback
    def test_back_pressure_drops_high_rate_samples_but_never_critical_ones(self) -> None:
        """The actual back-pressure guarantee, not just the constant's contents.

        Deleting the put_blocking branch in _dispatch used to leave the whole
        suite green; this fails if a critical frame is ever dropped.
        """
        config = ReceiverConfig(
            host="127.0.0.1",
            push_port=0,
            accept_results=False,
            publish_results=False,
            max_queue=8,          # tiny, so the flood overruns it immediately
            quiet=True,
        )
        receiver = LiveFeedReceiver(config)
        self.addCleanup(receiver.close)
        receiver.start()

        device = fake_headset.FakeHeadset("127.0.0.1", receiver.push_port)
        self.addCleanup(device.close)
        device.session_start(stream_name="backpressure")
        # Far more high-rate samples than the queue can hold, with a critical
        # rgb_csd buried in the middle and session_end at the very end.
        for index in range(200):
            device.head_pose(index)
        device.rgb_csd()
        for index in range(200):
            device.head_pose(1000 + index)
        device.session_end()

        session = receiver.accept(timeout=5.0)
        assert session is not None
        self.addCleanup(session.close)

        # Consume slowly enough that the reader genuinely hits a full queue.
        kinds: list[str] = []
        for sample in session.samples():
            kinds.append(sample.kind)
            if len(kinds) < 5:
                time.sleep(0.05)

        self.assertGreater(session.stats.dropped, 0, "expected head poses to be dropped")
        self.assertLess(kinds.count("head_pose"), 400, "queue should not have held everything")
        # The point of CRITICAL_KINDS: these survive the flood.
        self.assertEqual(kinds.count("session_start"), 1)
        self.assertEqual(kinds.count("rgb_csd"), 1)
        self.assertEqual(kinds.count("session_end"), 1)
        self.assertEqual(kinds[0], "session_start")
        self.assertEqual(kinds[-1], "session_end")

    def test_drain_latest_returns_the_newest_sample_of_a_kind(self) -> None:
        receiver = self.make_receiver(publish_results=False)
        device = fake_headset.FakeHeadset("127.0.0.1", receiver.push_port)
        self.addCleanup(device.close)
        device.session_start()
        for index in range(5):
            device.head_pose(index, x=float(index))
        device.session_end()

        session = receiver.accept(timeout=5.0)
        assert session is not None
        self.addCleanup(session.close)

        # Wait until the reader thread has queued the whole stream. Draining
        # earlier would race it and could legitimately return an older pose.
        deadline = time.monotonic() + 5.0
        while session.stats.counts.get("head_pose", 0) < 5 and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertEqual(session.stats.counts.get("head_pose"), 5)

        latest = session.drain_latest("head_pose")
        assert latest is not None
        # Older queued poses are discarded; only the freshest survives.
        self.assertEqual(latest.position[0], 4.0)
        # The queue was drained, so a second call has nothing left to return.
        self.assertIsNone(session.drain_latest("head_pose"))

    def test_send_control_json_reaches_the_headset(self) -> None:
        receiver = self.make_receiver(publish_results=False)
        device = fake_headset.FakeHeadset("127.0.0.1", receiver.push_port)
        self.addCleanup(device.close)
        device.session_start()

        session = receiver.accept(timeout=5.0)
        assert session is not None
        self.addCleanup(session.close)
        session.send_control_json(101, {"schema": "operator.capture_request.v1"})

        device.conn.settimeout(5.0)
        frame = read_frame(device.conn)
        assert frame is not None
        self.assertEqual(frame.frame_type, 101)
        self.assertEqual(json.loads(frame.payload)["schema"], "operator.capture_request.v1")

    def test_rgb_packets_are_fed_to_the_decoder_thread(self) -> None:
        import tempfile

        temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(temp_dir.cleanup)
        self.addCleanup(fake_headset.clear_fake_ffmpeg_env)
        # 2x2 RGB24 = 12 bytes per frame; the stub emits two frames.
        ffmpeg = fake_headset.make_fake_ffmpeg(Path(temp_dir.name), 12, 2)

        receiver = self.make_receiver(publish_results=False, decode_rgb=True, ffmpeg_bin=ffmpeg)
        device = fake_headset.FakeHeadset("127.0.0.1", receiver.push_port)
        self.addCleanup(device.close)
        device.session_start()
        device.send_json(
            2, {"width": 2, "height": 2, "codec": "hevc", "stereo_layout": "mono", "csd_base64": ""}
        )
        device.rgb_packet(1_000)
        device.rgb_packet(2_000)
        device.session_end()

        session = receiver.accept(timeout=5.0)
        assert session is not None
        kinds = [sample.kind for sample in session.samples()]
        self.assertIn("rgb_packet", kinds)
        assert session.rgb_decoder is not None

        deadline = time.monotonic() + 5.0
        while session.rgb_decoder.decoded_count < 2 and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertEqual(session.rgb_decoder.decoded_count, 2)
        session.close()

    def test_closing_the_receiver_ends_the_sessions_iterator(self) -> None:
        receiver = self.make_receiver(publish_results=False)
        receiver.close()
        self.assertEqual(list(receiver.sessions(timeout=0.1)), [])

    def test_accept_times_out_without_a_client(self) -> None:
        receiver = self.make_receiver(accept_results=False)
        self.assertIsNone(receiver.accept(timeout=0.2))

    def test_sessions_iterator_closes_each_session(self) -> None:
        receiver = self.make_receiver(publish_results=False)

        def headset() -> None:
            with fake_headset.FakeHeadset("127.0.0.1", receiver.push_port) as device:
                device.session_start()
                device.session_end()

        thread = threading.Thread(target=headset, daemon=True)
        thread.start()
        for session in receiver.sessions(timeout=5.0):
            kinds = [sample.kind for sample in session.samples()]
            self.assertEqual(kinds, ["session_start", "session_end"])
            break
        thread.join(timeout=5.0)


# ---------------------------------------------------------------------------
# example 1: viewer
# ---------------------------------------------------------------------------


class ViewerExampleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.viewer = load_example("live_feed_viewer")

    def make_state(self) -> Any:
        return self.viewer.StreamState()

    def make_rerun_recorder(self) -> Any:
        calls: list[tuple[str, tuple[Any, ...], dict[str, Any]]] = []
        blueprints: list[Any] = []

        def archetype(name: str, *args: Any, **kwargs: Any) -> dict[str, Any]:
            return {"type": name, "args": args, "kwargs": kwargs}

        class ViewCoordinates:
            RUB = "RUB"
            RDF = "RDF"

        class RecordingRerun:
            @staticmethod
            def log(path: str, *entities: Any, **kwargs: Any) -> None:
                calls.append((path, entities, kwargs))

            @staticmethod
            def set_time(timeline: str, *, duration: float) -> None:
                calls.append(("$time", (timeline, duration), {}))

            @staticmethod
            def send_blueprint(blueprint: Any) -> None:
                blueprints.append(blueprint)

            @staticmethod
            def Scalars(value: float) -> dict[str, Any]:
                return archetype("Scalars", value)

            @staticmethod
            def TextLog(value: str) -> dict[str, Any]:
                return archetype("TextLog", value)

            @staticmethod
            def Quaternion(**kwargs: Any) -> dict[str, Any]:
                return archetype("Quaternion", **kwargs)

            @staticmethod
            def Transform3D(**kwargs: Any) -> dict[str, Any]:
                return archetype("Transform3D", **kwargs)

            @staticmethod
            def TransformAxes3D(axis_length: float) -> dict[str, Any]:
                return archetype("TransformAxes3D", axis_length)

            @staticmethod
            def Arrows3D(*args: Any, **kwargs: Any) -> dict[str, Any]:
                return archetype("Arrows3D", *args, **kwargs)

            @staticmethod
            def Clear(*args: Any, **kwargs: Any) -> dict[str, Any]:
                return archetype("Clear", *args, **kwargs)

            @staticmethod
            def Points3D(*args: Any, **kwargs: Any) -> dict[str, Any]:
                return archetype("Points3D", *args, **kwargs)

            @staticmethod
            def LineStrips3D(*args: Any, **kwargs: Any) -> dict[str, Any]:
                return archetype("LineStrips3D", *args, **kwargs)

            @staticmethod
            def Pinhole(*args: Any, **kwargs: Any) -> dict[str, Any]:
                return archetype("Pinhole", *args, **kwargs)

            @staticmethod
            def DepthImage(*args: Any, **kwargs: Any) -> dict[str, Any]:
                return archetype("DepthImage", *args, **kwargs)

            @staticmethod
            def Image(*args: Any, **kwargs: Any) -> dict[str, Any]:
                return archetype("Image", *args, **kwargs)

        RecordingRerun.ViewCoordinates = ViewCoordinates
        RecordingRerun.calls = calls
        RecordingRerun.blueprints = blueprints
        return RecordingRerun

    def make_rerun_visualizer(self, recorder: Any) -> Any:
        def blueprint(kind: str, *args: Any, **kwargs: Any) -> dict[str, Any]:
            return {"type": kind, "args": args, "kwargs": kwargs}

        class RecordingBlueprint:
            @staticmethod
            def Horizontal(*args: Any, **kwargs: Any) -> dict[str, Any]:
                return blueprint("Horizontal", *args, **kwargs)

            @staticmethod
            def Vertical(*args: Any, **kwargs: Any) -> dict[str, Any]:
                return blueprint("Vertical", *args, **kwargs)

            @staticmethod
            def Tabs(*args: Any, **kwargs: Any) -> dict[str, Any]:
                return blueprint("Tabs", *args, **kwargs)

            @staticmethod
            def Spatial3DView(*args: Any, **kwargs: Any) -> dict[str, Any]:
                return blueprint("Spatial3DView", *args, **kwargs)

            @staticmethod
            def Spatial2DView(*args: Any, **kwargs: Any) -> dict[str, Any]:
                return blueprint("Spatial2DView", *args, **kwargs)

            @staticmethod
            def TimeSeriesView(*args: Any, **kwargs: Any) -> dict[str, Any]:
                return blueprint("TimeSeriesView", *args, **kwargs)

            @staticmethod
            def TextLogView(*args: Any, **kwargs: Any) -> dict[str, Any]:
                return blueprint("TextLogView", *args, **kwargs)

        visualizer = self.viewer.RerunVisualizer.__new__(self.viewer.RerunVisualizer)
        visualizer.rr = recorder
        visualizer.rrb = RecordingBlueprint
        visualizer._reset_session_state()
        return visualizer

    def test_rerun_time_uses_current_duration_api(self) -> None:
        calls: list[tuple[str, float]] = []

        class CurrentRerun:
            @staticmethod
            def set_time(timeline: str, *, duration: float) -> None:
                calls.append((timeline, duration))

        self.viewer.set_rerun_time_nanos(CurrentRerun, "headset_pts", 1_234_567_890)
        self.assertEqual(calls, [("headset_pts", 1.23456789)])

    def test_rerun_time_supports_legacy_nanoseconds_api(self) -> None:
        calls: list[tuple[str, int]] = []

        class LegacyRerun:
            @staticmethod
            def set_time_nanos(timeline: str, nanos: int) -> None:
                calls.append((timeline, nanos))

        self.viewer.set_rerun_time_nanos(LegacyRerun, "headset_pts", 1_234_567_890)
        self.assertEqual(calls, [("headset_pts", 1_234_567_890)])

    def test_rerun_scalar_uses_current_plural_archetype(self) -> None:
        calls: list[float] = []

        class CurrentRerun:
            @staticmethod
            def Scalars(value: float) -> tuple[str, float]:
                calls.append(value)
                return ("scalars", value)

        archetype = self.viewer.rerun_scalar(CurrentRerun, 2.5)
        self.assertEqual(archetype, ("scalars", 2.5))
        self.assertEqual(calls, [2.5])

    def test_rerun_transform_uses_separate_current_axes_archetype(self) -> None:
        calls: list[tuple[Any, ...]] = []

        class CurrentRerun:
            @staticmethod
            def Quaternion(**kwargs: Any) -> tuple[str, dict[str, Any]]:
                return ("quaternion", kwargs)

            @staticmethod
            def Transform3D(**kwargs: Any) -> tuple[str, dict[str, Any]]:
                return ("transform", kwargs)

            @staticmethod
            def TransformAxes3D(axis_length: float) -> tuple[str, float]:
                return ("axes", axis_length)

            @staticmethod
            def log(*args: Any) -> None:
                calls.append(args)

        self.viewer.log_rerun_transform(
            CurrentRerun,
            "world/head",
            [1.0, 2.0, 3.0],
            [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
            0.15,
        )
        self.assertEqual(calls[0][0], "world/head")
        self.assertEqual(calls[0][1][0], "transform")
        self.assertEqual(calls[0][2], ("axes", 0.15))
        self.assertNotIn("axis_length", calls[0][1][1])
        self.assertEqual(calls[0][1][1]["rotation"], ("quaternion", {"xyzw": (0.0, 0.0, 0.0, 1.0)}))

    def test_rotation_matrix_conversion_preserves_openxr_orientation(self) -> None:
        identity = self.viewer.rotation_matrix_to_quaternion_xyzw(
            [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]
        )
        half_turn_x = self.viewer.rotation_matrix_to_quaternion_xyzw(
            [1.0, 0.0, 0.0, 0.0, -1.0, 0.0, 0.0, 0.0, -1.0]
        )
        self.assertEqual(identity, (0.0, 0.0, 0.0, 1.0))
        self.assertEqual(tuple(abs(value) for value in half_turn_x), (1.0, 0.0, 0.0, 0.0))

    def test_rerun_hand_logs_reference_joint_topology(self) -> None:
        recorder = self.make_rerun_recorder()
        visualizer = self.make_rerun_visualizer(recorder)
        sample = parse_sample(
            StreamEvent(
                8,
                0,
                1,
                0,
                encode_json(fake_headset.hand_joints_payload("left", joint_count=26)),
            )
        )
        visualizer._log_hand(sample)
        calls = {path: entities[0] for path, entities, _ in recorder.calls}
        joints = calls["world/hands/left/joints"]
        bones = calls["world/hands/left/bones"]
        self.assertEqual(joints["kwargs"]["labels"][0:2], ["PALM", "WRIST"])
        self.assertEqual(len(bones["args"][0]), 24)
        self.assertEqual(bones["args"][0][0], [[0.01, 1.0, -0.4], [0.02, 1.0, -0.4]])

    def test_rerun_depth_points_are_logged_in_world_space(self) -> None:
        recorder = self.make_rerun_recorder()
        visualizer = self.make_rerun_visualizer(recorder)
        state = self.make_state()
        event = read_frame(
            io.BytesIO(
                fake_headset.depth_frame_frame(
                    1,
                    width=8,
                    height=8,
                    depth_mm=1500,
                )
            )
        )
        assert event is not None
        sample = parse_sample(event)
        visualizer.on_sample(sample, state)
        calls = {path: entities[0] for path, entities, _ in recorder.calls}
        points = calls["world/depth_pointcloud"]["args"][0]
        depth = calls["depth2d/depth"]
        self.assertGreater(len(points), 0)
        self.assertGreater(points[0][1], 1.0)
        self.assertLess(points[0][2], -1.0)
        self.assertIn("world/depth_camera/image", calls)
        self.assertIn("depth2d/depth", calls)
        self.assertEqual(depth["kwargs"]["meter"], 1.0)
        self.assertEqual(depth["kwargs"]["depth_range"], (0.15, 6.0))
        self.assertAlmostEqual(float(depth["args"][0][0, 0]), 1.5)
        self.assertIn("depth_frame", visualizer._observed_streams)

    def test_rerun_does_not_create_depth_view_for_incomplete_frame(self) -> None:
        recorder = self.make_rerun_recorder()
        visualizer = self.make_rerun_visualizer(recorder)
        state = self.make_state()
        visualizer._update_blueprint(force=True)
        sample = self.viewer.DepthFrameSample(
            kind="depth_frame",
            frame_type=5,
            pts_ns=1,
            recv_monotonic_ns=1,
            metadata={},
            depth_bytes=b"",
            model=None,
        )

        visualizer.on_sample(sample, state)

        self.assertNotIn("depth_frame", visualizer._observed_streams)
        self.assertFalse(
            any(path == "depth2d/depth" for path, _, _ in recorder.calls)
        )
        self.assertNotIn("Depth", repr(recorder.blueprints))

    def test_rerun_rgb_uses_calibrated_camera_hierarchy(self) -> None:
        recorder = self.make_rerun_recorder()
        visualizer = self.make_rerun_visualizer(recorder)
        visualizer._head_history.append(
            (
                100,
                (
                    (1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0),
                    (0.0, 1.6, 0.0),
                ),
            )
        )
        config = parse_sample(
            StreamEvent(2, 0, 90, 0, encode_json(fake_headset.rgb_csd_payload()))
        )
        frame = self.viewer.RgbFrame(
            pts_ns=100,
            width=1280,
            height=960,
            stereo_layout="side_by_side",
            cameras=config.cameras,
            data=b"\x00" * (1280 * 960 * 3),
        )
        visualizer.log_rgb_frame(frame)
        paths = [path for path, _, _ in recorder.calls]
        self.assertIn("world/camera/left/image", paths)
        self.assertIn("world/camera/right/image", paths)
        self.assertIn("world/camera/left", paths)
        self.assertIn("world/camera/right", paths)
        right_transform = next(
            entities[0]
            for path, entities, _ in recorder.calls
            if path == "world/camera/right"
        )
        self.assertEqual(
            right_transform["kwargs"]["translation"],
            [0.064, 1.6, 0.0],
        )
        blueprint_text = repr(recorder.blueprints[-1])
        self.assertIn("RGB Left", blueprint_text)
        self.assertIn("RGB Right", blueprint_text)

    def test_rerun_layout_uses_observed_not_announced_streams(self) -> None:
        recorder = self.make_rerun_recorder()
        visualizer = self.make_rerun_visualizer(recorder)
        state = self.make_state()
        announced = parse_sample(
            StreamEvent(
                1,
                0,
                1,
                0,
                encode_json(fake_headset.session_start_payload()),
            )
        )
        visualizer.on_sample(announced, state)
        announced_layout = repr(recorder.blueprints[-1])
        self.assertEqual(visualizer._observed_streams, set())
        self.assertNotIn("Controller Input", announced_layout)
        self.assertNotIn("RGB Left", announced_layout)
        self.assertNotIn("Depth", announced_layout)

        head = parse_sample(
            StreamEvent(
                6,
                0,
                2,
                0,
                encode_json(fake_headset.head_pose_payload()),
            )
        )
        visualizer.on_sample(head, state)
        head_layout = repr(recorder.blueprints[-1])
        self.assertIn("head_pose", visualizer._observed_streams)
        self.assertNotIn("Controller Input", head_layout)
        self.assertFalse(
            any("controller" in path for path, _, _ in recorder.calls)
        )

        controller_input = parse_sample(
            StreamEvent(
                9,
                0,
                3,
                0,
                encode_json(fake_headset.controller_input_payload("left")),
            )
        )
        visualizer.on_sample(controller_input, state)
        controller_layout = repr(recorder.blueprints[-1])
        self.assertIn("controller_input", visualizer._observed_streams)
        self.assertIn("Controller Input", controller_layout)

    def test_rerun_new_session_clears_previous_visual_state(self) -> None:
        recorder = self.make_rerun_recorder()
        visualizer = self.make_rerun_visualizer(recorder)
        visualizer._trail.append((1.0, 2.0, 3.0))
        visualizer._head_history.append(
            (
                1,
                (
                    (1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0),
                    (1.0, 2.0, 3.0),
                ),
            )
        )
        visualizer._floor_logged = True
        visualizer._begin_session()
        self.assertEqual(len(visualizer._trail), 0)
        self.assertEqual(len(visualizer._head_history), 0)
        self.assertEqual(visualizer._observed_streams, set())
        self.assertFalse(visualizer._floor_logged)
        clear_call = next(call for call in recorder.calls if call[0] == "/")
        self.assertEqual(clear_call[1][0]["type"], "Clear")
        self.assertTrue(clear_call[2]["static"])

    def test_rate_tracker_measures_hz_over_the_window(self) -> None:
        tracker = self.viewer.RateTracker(window_s=10.0)
        self.assertEqual(tracker.hz(now=0.0), 0.0)
        for index in range(11):
            tracker.tick(now=float(index))
        self.assertEqual(tracker.total, 11)
        self.assertAlmostEqual(tracker.hz(now=10.0), 1.0)

    def test_rate_tracker_forgets_samples_outside_the_window(self) -> None:
        tracker = self.viewer.RateTracker(window_s=2.0)
        for index in range(5):
            tracker.tick(now=float(index))
        self.assertEqual(tracker.hz(now=100.0), 0.0)
        self.assertEqual(tracker.total, 5)

    def test_state_tracks_every_stream(self) -> None:
        state = self.make_state()

        def feed(frame_type: int, payload: dict[str, Any], pts_ns: int = 0) -> None:
            state.update(parse_sample(StreamEvent(frame_type, 0, pts_ns, 0, encode_json(payload))))

        feed(1, fake_headset.session_start_payload("live_x"))
        self.assertEqual(state.session_id, "live_x")
        self.assertIn("head_pose", state.expected_streams)

        feed(6, fake_headset.head_pose_payload(0.0, 1.6, 0.0), pts_ns=1)
        feed(6, fake_headset.head_pose_payload(1.0, 1.6, 0.0), pts_ns=2)
        self.assertAlmostEqual(state.head_path_m, 1.0)
        self.assertTrue(state.head_valid)

        feed(7, fake_headset.controller_pose_payload("left"))
        feed(9, fake_headset.controller_input_payload("left", trigger=0.5))
        feed(8, fake_headset.hand_joints_payload("right", joint_count=26))
        feed(2, fake_headset.rgb_csd_payload())
        self.assertIn("left", state.controllers)
        self.assertIn("left", state.controller_input)
        self.assertEqual(state.hands["right"], 26)
        self.assertEqual(state.rgb_config["codec"], "hevc")

        state.update(parse_sample(StreamEvent(TYPE_RGB_PACKET, 1, 3, 0, b"abcd")))
        self.assertEqual(state.rgb_bytes, 4)
        self.assertEqual(state.rgb_keyframes, 1)
        self.assertEqual(state.newest_pts_ns, 3)

    def test_state_summarises_depth_frames(self) -> None:
        state = self.make_state()
        event = read_frame(io.BytesIO(fake_headset.depth_frame_frame(1, width=64, height=64, depth_mm=1500)))
        assert event is not None
        state.update(parse_sample(event))
        self.assertEqual(state.depth_size, (64, 64))
        self.assertAlmostEqual(state.depth_valid_ratio, 1.0)
        self.assertAlmostEqual(state.depth_mean_m, 1.5, places=3)

    def test_state_reports_invalid_depth_pixels(self) -> None:
        state = self.make_state()
        event = read_frame(io.BytesIO(fake_headset.depth_frame_frame(1, width=64, height=64, depth_mm=0)))
        assert event is not None
        state.update(parse_sample(event))
        self.assertEqual(state.depth_valid_ratio, 0.0)
        self.assertEqual(state.depth_mean_m, 0.0)

    def test_head_tracking_loss_is_visible(self) -> None:
        state = self.make_state()
        state.update(
            parse_sample(
                StreamEvent(6, 0, 1, 0, encode_json(fake_headset.head_pose_payload(tracking_valid=False)))
            )
        )
        self.assertFalse(state.head_valid)

    def test_terminal_visualizer_renders_without_crashing(self) -> None:
        state = self.make_state()
        state.update(parse_sample(StreamEvent(1, 0, 0, 0, encode_json(fake_headset.session_start_payload()))))
        state.update(parse_sample(StreamEvent(6, 0, 1, 0, encode_json(fake_headset.head_pose_payload()))))
        state.update(parse_sample(StreamEvent(9, 0, 2, 0, encode_json(fake_headset.controller_input_payload()))))
        state.update(parse_sample(StreamEvent(8, 0, 3, 0, encode_json(fake_headset.hand_joints_payload()))))
        state.update(parse_sample(StreamEvent(2, 0, 4, 0, encode_json(fake_headset.rgb_csd_payload()))))

        class StubSession:
            stats = SessionStats()

        visualizer = self.viewer.TerminalVisualizer()
        output = io.StringIO()
        with redirect_stdout(output):
            visualizer.setup()
            visualizer.render(state, StubSession(), force=True)
            visualizer.render(state, StubSession(), force=True)
            visualizer.teardown(state)
        text = output.getvalue()
        self.assertIn("head", text)
        self.assertIn("rgb", text)

    def test_auto_backend_falls_back_to_terminal_without_rerun(self) -> None:
        real_import = __import__

        def blocked(name: str, *args: Any, **kwargs: Any) -> Any:
            if name == "rerun":
                raise ImportError("no rerun")
            return real_import(name, *args, **kwargs)

        import builtins

        original = builtins.__import__
        builtins.__import__ = blocked
        try:
            visualizer = self.viewer.build_visualizer("auto")
        finally:
            builtins.__import__ = original
        self.assertEqual(visualizer.name, "terminal")
        self.assertEqual(self.viewer.build_visualizer("terminal").name, "terminal")

    def test_cli_defaults_are_one_way(self) -> None:
        args = self.viewer.parse_args([])
        self.assertEqual(args.push_port, 63910)
        self.assertEqual(args.result_port, 63912)
        self.assertIsNone(args.decode_rgb)
        self.assertEqual(self.viewer.VIEWER_CAPTURE_REQUEST["algorithm"], "live_feed_viewer")
        self.assertEqual(
            self.viewer.VIEWER_CAPTURE_REQUEST["selected_streams"],
            [
                "session.json",
                "rgb.hevc",
                "depth.u16",
                "head_pose.json",
                "hand_joints.json",
            ],
        )
        self.assertEqual(
            self.viewer.VIEWER_CAPTURE_REQUEST["limits"],
            {
                "rgb_eye": "left",
                "rgb_max_hz": 15,
                "rgb_bitrate_bps": 4_000_000,
            },
        )
        self.assertNotIn(
            "controller_pose.json",
            self.viewer.VIEWER_CAPTURE_REQUEST["selected_streams"],
        )
        self.assertNotIn(
            "controller_input.json",
            self.viewer.VIEWER_CAPTURE_REQUEST["selected_streams"],
        )
        self.assertEqual(self.viewer.VIEWER_CAPTURE_REQUEST["result_streams"], [])
        custom = self.viewer.parse_args(["--push-port", "1234", "--viewer", "terminal", "--decode-rgb"])
        self.assertEqual(custom.push_port, 1234)
        self.assertTrue(custom.decode_rgb)
        self.assertFalse(self.viewer.parse_args(["--no-decode-rgb"]).decode_rgb)


@pytest.mark.loopback
@pytest.mark.fake_headset
class ViewerExampleLoopbackTests(unittest.TestCase):
    def test_viewer_main_consumes_a_full_session(self) -> None:
        viewer = load_example("live_feed_viewer")
        listener = socket.socket()
        listener.bind(("127.0.0.1", 0))
        push_port = listener.getsockname()[1]
        listener.close()

        def headset() -> None:
            import time

            deadline = time.monotonic() + 5.0
            while time.monotonic() < deadline:
                try:
                    device = fake_headset.FakeHeadset("127.0.0.1", push_port, timeout=0.5)
                except OSError:
                    time.sleep(0.05)
                    continue
                with device:
                    device.session_start()
                    device.head_pose(1_000, x=0.0)
                    device.head_pose(2_000, x=0.5)
                    device.session_end()
                return

        thread = threading.Thread(target=headset, daemon=True)
        thread.start()
        output = io.StringIO()
        with redirect_stdout(output):
            code = viewer.main(
                [
                    "--host", "127.0.0.1",
                    "--push-port", str(push_port),
                    "--result-port", "0",
                    "--viewer", "terminal",
                    "--once",
                ]
            )
        thread.join(timeout=5.0)
        self.assertEqual(code, 0)
        self.assertIn("session ended", output.getvalue())


# ---------------------------------------------------------------------------
# example 2: roundtrip
# ---------------------------------------------------------------------------


class HeadTrailProcessorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.roundtrip = load_example("live_feed_roundtrip")

    def head_sample(self, x: float, y: float = 1.6, z: float = 0.0, valid: bool = True, pts: int = 0) -> Any:
        return parse_sample(
            StreamEvent(6, 0, pts, 0, encode_json(fake_headset.head_pose_payload(x, y, z, valid)))
        )

    def test_accepts_moving_poses_and_rejects_invalid_ones(self) -> None:
        processor = self.roundtrip.HeadTrailProcessor(min_step_m=0.05)
        self.assertTrue(processor.add(self.head_sample(0.0)))
        self.assertFalse(processor.add(self.head_sample(0.0, valid=False)))
        self.assertTrue(processor.add(self.head_sample(1.0)))
        self.assertEqual(processor.accepted, 2)
        self.assertEqual(processor.rejected, 1)

    def test_thins_poses_closer_than_the_minimum_step(self) -> None:
        processor = self.roundtrip.HeadTrailProcessor(min_step_m=0.10)
        processor.add(self.head_sample(0.0))
        # 5 cm apart: below the 10 cm threshold, so discarded.
        self.assertFalse(processor.add(self.head_sample(0.05)))
        self.assertTrue(processor.add(self.head_sample(0.20)))
        self.assertEqual(len(processor.poses), 2)

    def test_trail_length_is_bounded_by_max_poses(self) -> None:
        processor = self.roundtrip.HeadTrailProcessor(max_poses=5, min_step_m=0.0)
        for index in range(50):
            processor.add(self.head_sample(float(index)))
        self.assertEqual(len(processor.poses), 5)
        # oldest evicted: the buffer holds the most recent five positions
        self.assertAlmostEqual(processor.poses[0].transform[1][0], 45.0)

    def test_points_form_a_cross_per_pose_with_a_colour_gradient(self) -> None:
        processor = self.roundtrip.HeadTrailProcessor(min_step_m=0.0, marker_size_m=0.02)
        processor.add(self.head_sample(0.0))
        processor.add(self.head_sample(1.0))
        points = processor.points()

        self.assertEqual(len(points), 2 * 7)
        centres = [point for point in points if (point.x, point.y, point.z) == (0.0, 1.6, 0.0)]
        self.assertEqual(len(centres), 1)
        # oldest is blue-ish, newest orange-ish
        self.assertGreater(points[0].b, points[0].r)
        self.assertGreater(points[-1].r, points[-1].b)
        self.assertLess(points[0].confidence, points[-1].confidence)
        for point in points:
            self.assertTrue(0 <= point.r <= 255 and 0 <= point.g <= 255 and 0 <= point.b <= 255)

    def test_single_pose_still_produces_points(self) -> None:
        processor = self.roundtrip.HeadTrailProcessor(min_step_m=0.0)
        processor.add(self.head_sample(0.0))
        points = processor.points()
        self.assertEqual(len(points), 7)
        self.assertEqual(points[0].confidence, 1.0)

    def test_empty_processor_publishes_nothing(self) -> None:
        processor = self.roundtrip.HeadTrailProcessor()
        self.assertEqual(processor.points(), [])
        self.assertFalse(processor.should_publish(now=1e9))

    def test_point_budget_stays_under_the_headset_chunk_limit(self) -> None:
        processor = self.roundtrip.HeadTrailProcessor(max_poses=100_000, min_step_m=0.0)
        for index in range(20_000):
            processor.add(self.head_sample(float(index)))
        points = processor.points()
        self.assertLessEqual(len(points), self.roundtrip.MAX_TRAIL_POINTS)
        # headset truncates a chunk at 120k points
        self.assertLess(len(points), 120_000)

    def test_publish_interval_gates_updates(self) -> None:
        processor = self.roundtrip.HeadTrailProcessor(min_step_m=0.0, publish_interval_s=1.0)
        processor.add(self.head_sample(0.0))
        processor.mark_published(now=100.0)
        self.assertFalse(processor.should_publish(now=100.5))
        self.assertTrue(processor.should_publish(now=101.5))

    def test_cli_defaults(self) -> None:
        args = self.roundtrip.parse_args([])
        self.assertEqual(args.map_id, "head-trail")
        self.assertEqual(args.push_port, 63910)
        self.assertEqual(args.result_port, 63912)
        self.assertEqual(
            self.roundtrip.ROUNDTRIP_CAPTURE_REQUEST["selected_streams"],
            ["session.json", "head_pose.json"],
        )
        custom = self.roundtrip.parse_args(["--map-id", "x", "--max-poses", "10"])
        self.assertEqual(custom.map_id, "x")
        self.assertEqual(custom.max_poses, 10)


@pytest.mark.loopback
@pytest.mark.fake_headset
class RoundtripLoopbackTests(unittest.TestCase):
    def test_head_poses_come_back_as_a_rendered_point_cloud(self) -> None:
        roundtrip = load_example("live_feed_roundtrip")
        config = ReceiverConfig(
            host="127.0.0.1",
            push_port=0,
            result_host="127.0.0.1",
            result_port=0,
            quiet=True,
        )
        receiver = LiveFeedReceiver(config)
        self.addCleanup(receiver.close)
        receiver.start()
        self.assertTrue(receiver.wait_result_bound(5.0))

        pull, _welcome = connect_result_socket("127.0.0.1", receiver.result_port)
        self.addCleanup(pull.close)
        self.assertTrue(receiver.result_channel.wait_for_client(5.0))

        def headset() -> None:
            with fake_headset.FakeHeadset("127.0.0.1", receiver.push_port) as device:
                device.session_start()
                for index in range(40):
                    device.head_pose(index * 1_000_000, x=index * 0.05)
                device.session_end()

        thread = threading.Thread(target=headset, daemon=True)
        thread.start()

        session = receiver.accept(timeout=5.0)
        assert session is not None
        self.addCleanup(session.close)

        args = roundtrip.parse_args(["--publish-interval", "0.0", "--min-step-m", "0.0"])
        output = io.StringIO()
        with redirect_stdout(output):
            roundtrip.run_session(session, args)
        thread.join(timeout=5.0)

        # Drain the result stream and confirm the loop closed.
        pull.settimeout(2.0)
        frames = []
        try:
            while True:
                frame = read_frame(pull)
                if frame is None:
                    break
                frames.append(frame)
                if len(frames) > 400:
                    break
        except (socket.timeout, OSError, EOFError):
            pass

        types = [frame.frame_type for frame in frames]
        self.assertEqual(types[0], TYPE_MAP_RESET)
        self.assertIn(TYPE_DENSE_MAP_MANIFEST, types)
        self.assertIn(TYPE_DENSE_MAP_FRAGMENT, types)
        self.assertIn(TYPE_DENSE_MAP_COMMIT, types)

        # Every manifest must be followed by fragments and then a commit, and
        # map_version must never go backwards or the headset drops the update.
        versions = [
            json.loads(frame.payload)["map_version"]
            for frame in frames
            if frame.frame_type == TYPE_DENSE_MAP_MANIFEST
        ]
        self.assertEqual(versions, sorted(versions))
        self.assertEqual(len(set(versions)), len(versions))

        fragments = [frame for frame in frames if frame.frame_type == TYPE_DENSE_MAP_FRAGMENT]
        metadata, binary = parse_composite_payload(fragments[-1].payload)
        self.assertEqual(metadata["chunk_id"], "head-trail_trail")
        self.assertEqual(metadata["operation"], "upsert")
        self.assertEqual(metadata["point_format"], "f32xyz_u8rgba_f32conf")
        self.assertEqual(len(binary) % DENSE_POINT.size, 0)
        self.assertGreater(len(binary) // DENSE_POINT.size, 0)

        statuses = [
            json.loads(frame.payload)
            for frame in frames
            if frame.frame_type == TYPE_ALGORITHM_STATUS
        ]
        self.assertEqual(statuses[0]["state"], "running")
        self.assertEqual(statuses[-1]["state"], "stopped")
        self.assertGreater(statuses[-1]["poses_accepted"], 0)


@pytest.mark.loopback
class CaptureRequestAnnounceTests(unittest.TestCase):
    """The settings page learns the stream set by merely connecting."""

    def test_result_channel_fires_the_on_connect_hook(self) -> None:
        from pyoperator.live_feed.results import ResultChannel

        fired = threading.Event()
        channel = ResultChannel(
            "127.0.0.1", 0, True, quiet=True, on_client_connected=fired.set
        )
        self.addCleanup(channel.close)
        channel.start()
        self.assertTrue(channel.wait_bound(5.0))

        conn, _welcome = connect_result_socket("127.0.0.1", channel.port)
        self.addCleanup(conn.close)
        self.assertTrue(fired.wait(5.0))

    def test_receiver_announces_configured_data_types_on_connect(self) -> None:
        request = {
            "schema": "operator.capture_request.v1",
            "algorithm": "test_viewer",
            "selected_streams": ["session.json", "rgb.hevc", "head_pose.json"],
        }
        receiver = LiveFeedReceiver(
            ReceiverConfig(
                host="127.0.0.1",
                push_port=0,
                result_host="127.0.0.1",
                result_port=0,
                publish_results=False,
                capture_request=request,
                quiet=True,
            )
        )
        self.addCleanup(receiver.close)
        receiver.start()
        self.assertTrue(receiver.wait_result_bound(5.0))

        conn, _welcome = connect_result_socket("127.0.0.1", receiver.result_port)
        self.addCleanup(conn.close)
        conn.settimeout(5.0)
        frame = read_frame(conn)
        assert frame is not None
        self.assertEqual(frame.frame_type, TYPE_CAPTURE_REQUEST)
        self.assertEqual(json.loads(frame.payload), request)

    def test_a_failing_hook_does_not_kill_the_accept_loop(self) -> None:
        from pyoperator.live_feed.results import ResultChannel

        calls = []

        def boom() -> None:
            calls.append(1)
            raise RuntimeError("hook exploded")

        channel = ResultChannel("127.0.0.1", 0, True, quiet=True, on_client_connected=boom)
        self.addCleanup(channel.close)
        channel.start()
        self.assertTrue(channel.wait_bound(5.0))

        first, _welcome = connect_result_socket("127.0.0.1", channel.port)
        self.addCleanup(first.close)
        deadline = time.monotonic() + 5.0
        while not calls and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertEqual(len(calls), 1)

        # A second client must still be accepted despite the first hook raising.
        second, _welcome = connect_result_socket("127.0.0.1", channel.port)
        self.addCleanup(second.close)
        deadline = time.monotonic() + 5.0
        while len(calls) < 2 and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertEqual(len(calls), 2)
        self.assertEqual(channel.accepted_count, 2)

    def test_result_auth_rejects_bad_token_without_replacing_valid_client(self) -> None:
        from pyoperator.live_feed.results import ResultChannel

        channel = ResultChannel(
            "127.0.0.1",
            0,
            True,
            quiet=True,
            auth_token="secret",
        )
        self.addCleanup(channel.close)
        channel.start()
        self.assertTrue(channel.wait_bound(5.0))

        valid, _welcome = connect_result_socket(
            "127.0.0.1",
            channel.port,
            token="secret",
        )
        self.addCleanup(valid.close)
        self.assertTrue(channel.wait_for_client(5.0))
        self.assertEqual(channel.accepted_count, 1)

        rejected = socket.create_connection(("127.0.0.1", channel.port), timeout=5.0)
        rejected.sendall(
            pack_frame(
                TYPE_RESULT_HELLO,
                0,
                0,
                0,
                encode_json(
                    {
                        "schema": "operator.result_hello.v1",
                        "auth_token": "wrong",
                    }
                ),
            )
        )
        rejected.settimeout(5.0)
        self.assertEqual(rejected.recv(1), b"")
        rejected.close()

        # Authentication happens before swapping self._conn, so the rejected
        # peer cannot evict the headset that already proved possession.
        self.assertEqual(channel.accepted_count, 1)
        channel.send_frame(TYPE_ALGORITHM_STATUS, 0, 0, 0, b"{}")
        frame = read_frame(valid)
        assert frame is not None
        self.assertEqual(frame.frame_type, TYPE_ALGORITHM_STATUS)

    def test_result_auth_rejects_non_handshake_frame(self) -> None:
        from pyoperator.live_feed.results import ResultChannel

        channel = ResultChannel(
            "127.0.0.1",
            0,
            True,
            quiet=True,
            auth_token="secret",
        )
        self.addCleanup(channel.close)
        channel.start()
        self.assertTrue(channel.wait_bound(5.0))

        rejected = socket.create_connection(("127.0.0.1", channel.port), timeout=5.0)
        rejected.sendall(pack_frame(TYPE_CAPTURE_REQUEST, 0, 0, 0, b"{}"))
        rejected.settimeout(5.0)
        self.assertEqual(rejected.recv(1), b"")
        rejected.close()
        self.assertFalse(channel.connected)
        self.assertEqual(channel.accepted_count, 0)

    def test_result_auth_rejects_invalid_json_shapes_without_killing_listener(self) -> None:
        from pyoperator.live_feed.results import ResultChannel

        channel = ResultChannel(
            "127.0.0.1",
            0,
            True,
            quiet=True,
            auth_token="secret",
        )
        self.addCleanup(channel.close)
        channel.start()
        self.assertTrue(channel.wait_bound(5.0))

        for payload in (
            encode_json(["not", "an", "object"]),
            encode_json(
                {
                    "schema": "operator.result_hello.v1",
                    "auth_token": 123,
                }
            ),
        ):
            rejected = socket.create_connection(
                ("127.0.0.1", channel.port),
                timeout=5.0,
            )
            rejected.sendall(pack_frame(TYPE_RESULT_HELLO, 0, 0, 0, payload))
            rejected.settimeout(5.0)
            self.assertEqual(rejected.recv(1), b"")
            rejected.close()

        # Invalid but parseable JSON must not escape _authenticate and kill the
        # accept thread. A subsequent valid headset still connects normally.
        valid, _welcome = connect_result_socket(
            "127.0.0.1",
            channel.port,
            token="secret",
        )
        self.addCleanup(valid.close)
        self.assertTrue(channel.wait_for_client(5.0))
        self.assertEqual(channel.accepted_count, 1)

    def test_idle_auth_peer_does_not_block_a_valid_client(self) -> None:
        from pyoperator.live_feed.results import ResultChannel

        channel = ResultChannel(
            "127.0.0.1",
            0,
            True,
            quiet=True,
            auth_token="secret",
        )
        self.addCleanup(channel.close)
        channel.start()
        self.assertTrue(channel.wait_bound(5.0))

        idle = socket.create_connection(("127.0.0.1", channel.port), timeout=5.0)
        self.addCleanup(idle.close)
        deadline = time.monotonic() + 1.0
        while time.monotonic() < deadline:
            with channel._lock:
                if idle.fileno() >= 0 and channel._pending_conns:
                    break
            time.sleep(0.01)

        started = time.monotonic()
        valid, _welcome = connect_result_socket(
            "127.0.0.1",
            channel.port,
            token="secret",
        )
        self.addCleanup(valid.close)
        self.assertLess(time.monotonic() - started, 1.0)
        self.assertTrue(channel.connected)
        self.assertEqual(channel.accepted_count, 1)

    def test_close_cancels_pending_auth_without_resurrection(self) -> None:
        from pyoperator.live_feed.results import ResultChannel

        channel = ResultChannel(
            "127.0.0.1",
            0,
            True,
            quiet=True,
            auth_token="secret",
        )
        channel.start()
        self.assertTrue(channel.wait_bound(5.0))
        pending = socket.create_connection(("127.0.0.1", channel.port), timeout=5.0)
        self.addCleanup(pending.close)
        deadline = time.monotonic() + 1.0
        while time.monotonic() < deadline:
            with channel._lock:
                if channel._pending_conns:
                    break
            time.sleep(0.01)

        started = time.monotonic()
        channel.close()
        self.assertLess(time.monotonic() - started, 1.0)
        with channel._lock:
            self.assertFalse(channel._pending_conns)
            self.assertFalse(channel._auth_threads)
        self.assertFalse(channel.connected)
        self.assertEqual(channel.accepted_count, 0)

        try:
            pending.sendall(
                pack_frame(
                    TYPE_RESULT_HELLO,
                    0,
                    0,
                    0,
                    encode_json(
                        {
                            "schema": "operator.result_hello.v1",
                            "auth_token": "secret",
                        }
                    ),
                )
            )
        except OSError:
            pass
        time.sleep(0.05)
        self.assertFalse(channel.connected)
        self.assertEqual(channel.accepted_count, 0)

    def test_reconnect_replays_a_complete_current_map_snapshot(self) -> None:
        from pyoperator.live_feed.results import ResultChannel

        channel = ResultChannel("127.0.0.1", 0, True, quiet=True)
        publisher = ResultPublisher(channel.send_frame, max_fragment_bytes=64 * 1024)
        channel.on_client_connected = publisher.replay_snapshot
        self.addCleanup(publisher.close)
        self.addCleanup(channel.close)
        channel.start()
        self.assertTrue(channel.wait_bound(5.0))

        # Published with no result client: live writes are dropped, but the
        # current-state snapshot must still make the first connection complete.
        publisher.reset_map("map", reason="test")
        publisher.publish_points(
            map_id="map",
            points=[DensePoint(1.0, 2.0, 3.0)],
            chunk_id="first",
        )
        first, welcome = connect_result_socket("127.0.0.1", channel.port)
        first.settimeout(5.0)
        first_frames = [read_frame(first) for _ in range(4)]
        self.assertEqual(
            [frame.frame_type for frame in first_frames],
            [
                TYPE_MAP_RESET,
                TYPE_DENSE_MAP_MANIFEST,
                TYPE_DENSE_MAP_FRAGMENT,
                TYPE_DENSE_MAP_COMMIT,
            ],
        )
        first.close()

        publisher.publish_points(
            map_id="map",
            points=[DensePoint(4.0, 5.0, 6.0)],
            chunk_id="second",
        )
        second, second_welcome = connect_result_socket("127.0.0.1", channel.port)
        self.addCleanup(second.close)
        self.assertEqual(
            second_welcome["server_instance_id"],
            welcome["server_instance_id"],
        )
        replayed = [read_frame(second) for _ in range(7)]
        self.assertEqual(replayed[0].frame_type, TYPE_MAP_RESET)
        commits = [
            frame.payload_json()["committed_chunks"][0]
            for frame in replayed
            if frame.frame_type == TYPE_DENSE_MAP_COMMIT
        ]
        self.assertEqual(commits, ["first", "second"])


if __name__ == "__main__":
    unittest.main()
