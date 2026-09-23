"""Host-declared capture streams: contract dataclasses, XrSession wiring, session media."""

from __future__ import annotations

import asyncio
from dataclasses import replace
import json
import socket
import threading
import time
import unittest
import zlib

import pytest

from operator_xr import (
    CAPTURE_STREAMS_CAPABILITY,
    BridgeConfig,
    CaptureStream,
    CaptureStreamsConfig,
    LocalTask,
    LocalTaskControl,
    StreamControl,
    StreamsControl,
    StreamsStatus,
    StreamStatus,
    XrFrame,
    XrSession,
    stream_capability,
)
from operator_xr.hosted import (
    HostedStreams,
    _read_frame,
    _write_frame,
    create_server,
    make_descriptor,
)
from operator_xr.live_feed import align_by_timestamp
from operator_xr.live_feed.models import Sample, SessionStartSample
from operator_xr.live_feed.protocol import (
    FLAG_COMPOSITE_JSON,
    FLAG_COMPRESSED_ZLIB,
    FLAG_KEYFRAME,
    TYPE_ALGORITHM_STATUS,
    TYPE_DENSE_MAP_COMMIT,
    TYPE_DENSE_MAP_FRAGMENT,
    TYPE_DENSE_MAP_MANIFEST,
    TYPE_DEPTH_FRAME,
    TYPE_DEPTH_METADATA,
    TYPE_HEAD_POSE,
    TYPE_RESULT_HELLO,
    TYPE_RESULT_WELCOME,
    TYPE_RGB_CSD,
    TYPE_RGB_PACKET,
    TYPE_SESSION_END,
    TYPE_SESSION_START,
    encode_json,
    pack_composite_payload,
    pack_frame,
    read_frame,
)
from operator_xr.live_feed.results import DensePoint
from operator_xr.live_feed.simulator import (
    SyntheticHeadset,
    head_pose_payload,
    rgb_csd_payload,
    session_start_payload,
)

from test_session_replay import FakeNative


def _tcp_port() -> int:
    with socket.socket() as sock:
        sock.bind(("0.0.0.0", 0))
        return int(sock.getsockname()[1])


def _capture(**overrides) -> CaptureStreamsConfig:
    values = dict(
        streams=(
            CaptureStream("rgb.hevc", required=True, max_hz=4, max_bitrate_bps=2_000_000, eye="left"),
            CaptureStream("depth.u16", max_hz=5),
        ),
        local_tasks=(
            LocalTask("record", container="spatialmp4", streams=("rgb.hevc", "head_pose.json")),
            LocalTask("upload", endpoint_ref="lab-ingest"),
        ),
    )
    values.update(overrides)
    return CaptureStreamsConfig(**values)


RFC_STATUS = {
    "schema": "operator.streams_status.v1",
    "streams": {
        "rgb.hevc": {"state": "active", "hz": 4, "bitrate_bps": 2000000, "eye": "left"},
        "depth.u16": {"state": "denied", "reason": "permission_denied"},
    },
    "local_tasks": {
        "record": {"state": "running"},
        "upload": {"state": "denied", "reason": "unknown_endpoint"},
    },
}


class CaptureContractTests(unittest.TestCase):
    def test_descriptor_block_matches_the_rfc_shape(self) -> None:
        # No transport: media ports and token belong to the session.
        config = _capture()
        self.assertEqual(
            config.to_descriptor_dict(),
            {
                "schema_version": 1,
                "streams": [
                    {"name": "rgb.hevc", "required": True, "max_hz": 4, "max_bitrate_bps": 2000000, "eye": "left"},
                    {"name": "depth.u16", "required": False, "max_hz": 5},
                ],
                "local_tasks": [
                    {"kind": "record", "container": "spatialmp4", "streams": ["rgb.hevc", "head_pose.json"]},
                    {"kind": "upload", "endpoint_ref": "lab-ingest"},
                ],
            },
        )
        self.assertEqual(config.stream("depth.u16").max_hz, 5)
        self.assertIsNone(config.stream("hand_joints.json"))
        self.assertEqual(stream_capability("rgb.hevc"), "stream.rgb.hevc")
        self.assertEqual(CAPTURE_STREAMS_CAPABILITY, "capture_streams_v1")

    def test_declarations_are_validated_strictly(self) -> None:
        invalid_streams = [
            dict(name="audio.aac"),
            dict(name="rgb.hevc", required="yes"),
            dict(name="rgb.hevc", max_hz=0),
            dict(name="rgb.hevc", max_hz=float("inf")),
            dict(name="rgb.hevc", max_hz=True),
            dict(name="rgb.hevc", max_bitrate_bps=0),
            dict(name="rgb.hevc", max_bitrate_bps=1.5),
            dict(name="rgb.hevc", eye="right"),
        ]
        for kwargs in invalid_streams:
            with self.subTest(stream=kwargs), self.assertRaises(ValueError):
                CaptureStream(**kwargs)

        invalid_tasks = [
            dict(kind="stream"),
            dict(kind="record", streams="rgb.hevc"),
            dict(kind="record", streams=("rgb.hevc", "rgb.hevc")),
            dict(kind="record", streams=("audio.aac",)),
            dict(kind="record", container="mkv"),
            dict(kind="record", endpoint_ref="lab"),
            dict(kind="upload"),
            dict(kind="upload", endpoint_ref="https://lab.example/ingest"),
            dict(kind="upload", endpoint_ref="10.0.0.2:9000"),
            dict(kind="upload", endpoint_ref=" "),
            dict(kind="upload", endpoint_ref="lab", container="spatialmp4"),
        ]
        for kwargs in invalid_tasks:
            with self.subTest(task=kwargs), self.assertRaises(ValueError):
                LocalTask(**kwargs)
        self.assertEqual(LocalTask("record", streams=["rgb.hevc"]).streams, ("rgb.hevc",))

        rgb = CaptureStream("rgb.hevc")
        invalid_configs = [
            dict(streams=()),
            dict(streams=("rgb.hevc",)),
            dict(streams=rgb),
            dict(streams=(rgb, rgb)),
            dict(streams=(rgb,), local_tasks=(LocalTask("record"), LocalTask("record"))),
        ]
        for kwargs in invalid_configs:
            with self.subTest(config=kwargs), self.assertRaises(ValueError):
                CaptureStreamsConfig(**kwargs)
        tasks_only = CaptureStreamsConfig(streams=[], local_tasks=[LocalTask("record")])
        self.assertEqual(tasks_only.streams, ())
        with self.assertRaisesRegex(ValueError, "CaptureStreamsConfig"):
            BridgeConfig(capture_streams={"streams": []})

    def test_media_ports_join_the_port_group(self) -> None:
        config = BridgeConfig()
        self.assertEqual((config.media_up_port, config.media_down_port), (63905, 63906))
        BridgeConfig(media_up_port=0, media_down_port=0)  # media disabled
        BridgeConfig(media_up_port=0, media_down_port=63901 + 5)
        feed = dict(name="head", tcp_port=12345, rtsp_url="rtsp://x")
        from operator_xr import VideoFeedConfig

        invalid = [
            dict(media_up_port=-1),
            dict(media_down_port=65536),
            dict(media_up_port=True),
            dict(media_up_port="63905"),
            dict(media_up_port=7000, media_down_port=7000),
            dict(media_up_port=63901),
            dict(media_down_port=63903),
            dict(media_up_port=12345, video_feeds=(VideoFeedConfig(**feed),)),  # feed uses 12345
        ]
        for kwargs in invalid:
            with self.subTest(config=kwargs), self.assertRaises(ValueError):
                BridgeConfig(capture_streams=_capture(), **kwargs)
        # Media is bound only for a declared envelope: without one, the
        # defaults must not reject a video feed that reuses those ports.
        BridgeConfig(video_feeds=(VideoFeedConfig(**feed),))
        BridgeConfig(video_feeds=(VideoFeedConfig(name="head", tcp_port=63905, rtsp_url="rtsp://x"),))

    def test_status_parses_the_rfc_example(self) -> None:
        status = StreamsStatus.from_json(json.dumps(RFC_STATUS))
        self.assertTrue(status.is_active("rgb.hevc"))
        self.assertFalse(status.is_active("depth.u16"))
        self.assertFalse(status.is_active("hand_joints.json"))
        self.assertEqual(status.stream("rgb.hevc").hz, 4)
        self.assertEqual(status.stream("depth.u16").reason, "permission_denied")
        self.assertIsNone(status.stream("hand_joints.json"))
        self.assertEqual(status.local_task("record").state, "running")
        self.assertEqual(status.local_task("upload").reason, "unknown_endpoint")
        self.assertEqual(status.to_dict(), RFC_STATUS)
        # Unknown fields from newer headsets are ignored.
        newer = json.loads(json.dumps(RFC_STATUS))
        newer["streams"]["rgb.hevc"]["future"] = 1
        self.assertTrue(StreamsStatus.from_dict(newer).is_active("rgb.hevc"))
        clipped = StreamStatus("active", "limit", hz=2.0)
        self.assertEqual(clipped.to_dict(), {"state": "active", "reason": "limit", "hz": 2.0})

    def test_status_rejects_invalid_reports(self) -> None:
        invalid = [
            [],
            {"schema": "operator.streams_status.v2"},
            {"schema": "operator.streams_status.v1", "streams": []},
            {"schema": "operator.streams_status.v1", "streams": {"rgb.hevc": "active"}},
            {"schema": "operator.streams_status.v1", "streams": {"rgb.hevc": {"state": "on"}}},
            {"schema": "operator.streams_status.v1", "streams": {"rgb.hevc": {"state": "active", "reason": "busy"}}},
            {"schema": "operator.streams_status.v1", "streams": {"rgb.hevc": {"state": "active", "hz": -1}}},
            {"schema": "operator.streams_status.v1", "streams": {"rgb.hevc": {"state": "active", "bitrate_bps": 1.5}}},
            {"schema": "operator.streams_status.v1", "streams": {"rgb.hevc": {"state": "active", "eye": "both"}}},
            {"schema": "operator.streams_status.v1", "local_tasks": {"record": {"state": "active"}}},
        ]
        for value in invalid:
            with self.subTest(value=value), self.assertRaises(ValueError):
                StreamsStatus.from_dict(value)

    def test_unsupported_status_denies_every_declaration(self) -> None:
        status = StreamsStatus.unsupported(_capture())
        self.assertEqual(
            {name: (item.state, item.reason) for name, item in status.streams.items()},
            {"rgb.hevc": ("denied", "unsupported"), "depth.u16": ("denied", "unsupported")},
        )
        self.assertEqual(status.local_task("upload").reason, "unsupported")

    def test_control_accepts_dicts_and_validates(self) -> None:
        control = StreamsControl(
            streams={"rgb.hevc": {"hz": 2, "bitrate_bps": 1_000_000, "paused": False}},
            local_tasks={"record": {"running": True}},
        )
        self.assertEqual(
            json.loads(control.to_json()),
            {
                "schema": "operator.streams_control.v1",
                "streams": {"rgb.hevc": {"hz": 2, "bitrate_bps": 1000000, "paused": False}},
                "local_tasks": {"record": {"running": True}},
            },
        )
        typed = StreamsControl(streams={"depth.u16": StreamControl(paused=True)})
        self.assertEqual(
            typed.to_dict(),
            {"schema": "operator.streams_control.v1", "streams": {"depth.u16": {"paused": True}}},
        )
        self.assertEqual(LocalTaskControl(running=False).to_dict(), {"running": False})
        invalid = [
            dict(),
            dict(streams=[("rgb.hevc", {})]),
            dict(streams={"audio.aac": {"hz": 1}}),
            dict(streams={"rgb.hevc": {"hz": 0}}),
            dict(streams={"rgb.hevc": {"bitrate_bps": -1}}),
            dict(streams={"rgb.hevc": {"paused": "no"}}),
            dict(streams={"rgb.hevc": {"fps": 2}}),
            dict(streams={"rgb.hevc": 2}),
            dict(local_tasks={"stream": {"running": True}}),
            dict(local_tasks={"record": {"running": 1}}),
        ]
        for kwargs in invalid:
            with self.subTest(control=kwargs), self.assertRaises(ValueError):
                StreamsControl(**kwargs)

        config = _capture(local_tasks=(LocalTask("record"),))
        control.validate_for(config)
        with self.assertRaisesRegex(ValueError, "streams not declared"):
            StreamsControl(streams={"hand_joints.json": {"hz": 1}}).validate_for(config)
        with self.assertRaisesRegex(ValueError, "local tasks not declared"):
            StreamsControl(local_tasks={"upload": {"running": True}}).validate_for(config)


class CaptureNative(FakeNative):
    """FakeNative plus the capture-stream and session-media native surface."""

    def __init__(self, **kwargs) -> None:
        super().__init__(**kwargs)
        self.status_json: str | None = None
        self.controls: list[str] = []
        self.connected = False
        self.supported = False
        self.up_frames: list[tuple] = []
        self.down_frames: list[tuple] = []
        self.down_error: Exception | None = None

    def streams_status_json(self):
        return self.status_json

    def send_streams_control_json(self, payload: str) -> None:
        self.controls.append(payload)

    def poll_media_frame(self, timeout: float):
        return self.up_frames.pop(0) if self.up_frames else None

    def send_media_down_frame(self, frame_type, flags, pts_ns, duration_ns, payload) -> None:
        if self.down_error is not None:
            raise self.down_error
        self.down_frames.append((frame_type, flags, pts_ns, duration_ns, payload))

    def stats_json(self) -> str:
        return json.dumps(
            {
                "running": self.running,
                "connected": self.connected,
                "capture_streams_supported": self.supported,
                "media_up_connected": bool(self.up_frames),
                "media_up_frames": len(self.up_frames),
            }
        )


class XrSessionCaptureTests(unittest.TestCase):
    def _session(self, **overrides) -> XrSession:
        config = BridgeConfig(capture_streams=_capture(**overrides))
        session = XrSession(config, _native_factory=CaptureNative)
        self.addCleanup(session.close)
        return session

    def test_without_capture_streams_session_is_unchanged(self) -> None:
        session = XrSession(_native_factory=FakeNative).start()
        self.addCleanup(session.close)
        self.assertIsNone(session.capture)
        self.assertNotIn("capture_streams_json", session._native.kwargs)
        self.assertFalse(session.stats().capture_streams_supported)
        with self.assertRaisesRegex(RuntimeError, "capture_streams"):
            session.streams_control({"rgb.hevc": {"hz": 2}})

    def test_declaration_carries_no_transport_and_media_ports_reach_the_bridge(self) -> None:
        session = self._session()
        capture = session.capture
        assert capture is not None
        with self.assertRaisesRegex(RuntimeError, "not running"):
            next(capture.frames())

        kwargs = session._native.kwargs
        declared = json.loads(kwargs["capture_streams_json"])
        self.assertEqual(declared, capture.config.to_descriptor_dict())
        # The transport is the session's: the bridge issues it per headset
        # connection, so the declaration carries no ports and no token.
        self.assertNotIn("sink", declared)
        self.assertNotIn("media", declared)
        self.assertEqual(
            (kwargs["media_up_port"], kwargs["media_down_port"]),
            (session.config.media_up_port, session.config.media_down_port),
        )
        self.assertEqual([stream["name"] for stream in declared["streams"]], ["rgb.hevc", "depth.u16"])

    def test_frames_parse_relayed_media_and_stop_with_the_session(self) -> None:
        session = self._session().start()
        capture = session.capture
        native = session._native
        native.up_frames = [
            (TYPE_SESSION_START, 0, 0, 0, encode_json(session_start_payload(stream_name="s0"))),
            (TYPE_HEAD_POSE, 0, 1_000_000_123, 0, encode_json(head_pose_payload())),
            (TYPE_SESSION_END, 0, 0, 0, encode_json({"stream_name": "s0", "reason": "finish"})),
        ]
        samples = []
        for sample in capture.frames(timeout=0.01):
            samples.append(sample)
            if len(samples) == 3:
                session.close()
        self.assertEqual([s.kind for s in samples], ["session_start", "head_pose", "session_end"])
        # Headset godot_ticks_ns passes through the relay untouched.
        self.assertEqual(samples[1].pts_ns, 1_000_000_123)

    def test_results_go_to_the_headset_and_survive_a_missing_client(self) -> None:
        session = self._session().start()
        capture = session.capture
        native = session._native
        capture.results.publish_points(map_id="nav", points=[DensePoint(0.0, 0.0, 1.0)])
        self.assertEqual(
            [frame[0] for frame in native.down_frames],
            [TYPE_DENSE_MAP_MANIFEST, TYPE_DENSE_MAP_FRAGMENT, TYPE_DENSE_MAP_COMMIT],
        )
        # No headset result client: the frame is dropped, not raised.
        native.down_error = RuntimeError("no media_down client")
        capture.results.publish_points(map_id="nav", points=[DensePoint(0.0, 0.0, 2.0)])

    def test_streams_status_parses_and_synthesizes_compatibility(self) -> None:
        session = self._session().start()
        native = session._native
        self.assertIsNone(session.streams_status())  # nothing connected

        native.connected = True
        status = session.streams_status()  # old APK: no capture_streams_v1
        self.assertEqual(status.stream("rgb.hevc"), StreamStatus("denied", "unsupported"))
        self.assertEqual(status.local_task("record").reason, "unsupported")

        native.supported = True
        self.assertIsNone(session.streams_status())  # new APK, not reported yet
        self.assertTrue(session.stats().capture_streams_supported)

        native.status_json = json.dumps(RFC_STATUS)
        self.assertTrue(session.streams_status().is_active("rgb.hevc"))

    def test_streams_control_validates_against_declaration(self) -> None:
        session = self._session().start()
        native = session._native
        session.streams_control({"rgb.hevc": {"hz": 2}}, local_tasks={"record": {"running": True}})
        self.assertEqual(
            json.loads(native.controls[-1]),
            {
                "schema": "operator.streams_control.v1",
                "streams": {"rgb.hevc": {"hz": 2}},
                "local_tasks": {"record": {"running": True}},
            },
        )
        session.streams_control(StreamsControl(streams={"depth.u16": {"paused": True}}))
        self.assertEqual(json.loads(native.controls[-1])["streams"], {"depth.u16": {"paused": True}})
        with self.assertRaisesRegex(ValueError, "not declared"):
            session.streams_control({"hand_joints.json": {"hz": 2}})
        with self.assertRaisesRegex(ValueError, "inside the StreamsControl"):
            session.streams_control(
                StreamsControl(streams={"rgb.hevc": {"hz": 1}}),
                local_tasks={"record": {"running": False}},
            )
        with self.assertRaises(ValueError):
            session.streams_control({"rgb.hevc": {"hz": -1}})
        self.assertEqual(len(native.controls), 2)


class TimebaseTests(unittest.TestCase):
    def _start(self, info: dict) -> SessionStartSample:
        return SessionStartSample(
            kind="session_start", frame_type=1, pts_ns=0, recv_monotonic_ns=0, info=info
        )

    def test_session_start_timebase_accessors(self) -> None:
        start = self._start(
            {"session_start_unix_us": 1_700_000_000_000_000, "session_start_godot_ticks_us": 12_345_678}
        )
        self.assertEqual(start.session_start_unix_us, 1_700_000_000_000_000)
        self.assertEqual(start.session_start_godot_ticks_us, 12_345_678)
        self.assertEqual(
            start.godot_ticks_ns_to_unix_ns(12_345_678_000 + 5_000),
            1_700_000_000_000_000_000 + 5_000,
        )
        missing = self._start({"session_start_godot_ticks_us": "x"})
        self.assertIsNone(missing.session_start_godot_ticks_us)
        self.assertIsNone(missing.session_start_unix_us)
        self.assertIsNone(missing.godot_ticks_ns_to_unix_ns(1))
        unset_wall_clock = self._start({"session_start_unix_us": 0, "session_start_godot_ticks_us": 1})
        self.assertIsNone(unset_wall_clock.godot_ticks_ns_to_unix_ns(1))

    def test_align_by_timestamp_pairs_nearest_frame_in_the_same_domain(self) -> None:
        def sample(pts_ns: int) -> Sample:
            return Sample(kind="head_pose", frame_type=0, pts_ns=pts_ns, recv_monotonic_ns=0)

        def frame(timestamp_ns: int) -> XrFrame:
            return XrFrame(1, timestamp_ns, timestamp_ns, "openxr_stage", None, None, None, None, ())

        frames = [frame(t) for t in (300, 100, 200)]  # unsorted input
        samples = [sample(t) for t in (240, 90, 150, 1_000, 50)]
        pairs = align_by_timestamp(samples, frames, max_delta_ns=60)
        self.assertEqual(
            [(s.pts_ns, f.timestamp_ns if f else None) for s, f in pairs],
            [(50, 100), (90, 100), (150, 100), (240, 200), (1_000, None)],
        )
        only = sample(5)
        self.assertEqual(align_by_timestamp([only], []), [(only, None)])
        # Equidistant frames: the earlier one wins.
        self.assertEqual(align_by_timestamp([sample(150)], frames)[0][1].timestamp_ns, 100)
        self.assertEqual(align_by_timestamp([], frames), [])
        with self.assertRaises(ValueError):
            align_by_timestamp(samples, frames, max_delta_ns=-1)


class HostedStreamsTests(unittest.IsolatedAsyncioTestCase):
    async def test_descriptor_status_and_control_over_the_adapter_protocol(self) -> None:
        class Adapter:
            def connect(self) -> None: ...
            def disconnect(self) -> None: ...
            def handle_command(self, command) -> None: ...
            def telemetry(self):
                return {"values": {}}
            def stop(self, reason) -> None: ...

        capture = _capture()
        descriptor = make_descriptor(name="Hosted Nav", capture_streams=capture)
        self.assertEqual(descriptor["capture_streams"], capture.to_descriptor_dict())
        # The adapter path serves no media: only xr-bridge injects `media`.
        self.assertNotIn("media", descriptor)
        self.assertNotIn("capture_streams", make_descriptor(name="plain"))

        seen: list[StreamsStatus] = []
        streams = HostedStreams(on_status=seen.append)
        with self.assertRaisesRegex(RuntimeError, "no xr-bridge"):
            streams.control({"rgb.hevc": {"hz": 2}})
        server = await create_server(
            Adapter(), descriptor, host="127.0.0.1", port=0, telemetry_hz=1.0, streams=streams
        )
        address = server.sockets[0].getsockname()
        reader, writer = await asyncio.open_connection(*address)
        lock = asyncio.Lock()
        await _write_frame(writer, lock, {"type": "Hello"})
        response = await _read_frame(reader)
        self.assertEqual(response["capture_streams"], descriptor["capture_streams"])

        await _write_frame(writer, lock, {"type": "StreamsStatus", "status": {"schema": "bad"}})
        await _write_frame(writer, lock, {"type": "StreamsStatus", "status": RFC_STATUS})
        for _ in range(100):
            if streams.status() is not None:
                break
            await asyncio.sleep(0.01)
        self.assertTrue(streams.status().is_active("rgb.hevc"))
        self.assertEqual(len(seen), 1)

        streams.control({"rgb.hevc": {"hz": 2}})
        streams.control(StreamsControl(local_tasks={"record": {"running": False}}))
        controls = []
        while len(controls) < 2:
            frame = await asyncio.wait_for(_read_frame(reader), 2.0)
            if frame["type"] == "StreamsControl":
                controls.append(frame["control"])
        self.assertEqual(controls[0]["streams"], {"rgb.hevc": {"hz": 2}})
        self.assertEqual(controls[1]["local_tasks"], {"record": {"running": False}})

        # A cleared status (the reporting headset went away) drops the stale
        # report while this adapter stays connected.
        streams._push_status(None)
        self.assertIsNone(streams.status())
        await _write_frame(writer, lock, {"type": "StreamsStatus", "status": RFC_STATUS})
        for _ in range(100):
            if streams.status() is not None:
                break
            await asyncio.sleep(0.01)
        self.assertTrue(streams.status().is_active("rgb.hevc"))

        writer.close()
        await writer.wait_closed()
        for _ in range(100):
            if streams.status() is None:
                break
            await asyncio.sleep(0.01)
        self.assertIsNone(streams.status())
        server.close()
        await server.wait_closed()


try:
    from operator_xr import _native  # noqa: F401
except ImportError:
    HAS_NATIVE = False
else:
    HAS_NATIVE = True


@unittest.skipUnless(HAS_NATIVE, "requires the built operator_xr native extension")
@pytest.mark.loopback
@pytest.mark.fake_headset
class NativeCaptureStreamsTests(unittest.TestCase):
    def _config(self) -> BridgeConfig:
        from test_native_lifecycle import _config

        return replace(_config(), capture_streams=_capture())

    def test_native_rejects_invalid_capture_streams(self) -> None:
        with self.assertRaisesRegex(ValueError, "capture_streams"):
            _native.NativeSession(capture_streams_json='{"streams":[{"name":"rgb.hevc","eye":"x"}]}')
        with self.assertRaisesRegex(ValueError, "capture_streams_json"):
            _native.NativeSession(capture_streams_json="{")
        native = _native.NativeSession()
        with self.assertRaisesRegex(ValueError, "StreamsControl"):
            native.send_streams_control_json('{"schema":"x"}')
        with self.assertRaisesRegex(RuntimeError, "not running"):
            native.send_streams_control_json('{"schema":"operator.streams_control.v1"}')

    def test_capture_capable_headset_round_trip(self) -> None:
        from test_native_lifecycle import (
            _connect_fake_headset,
            _recv_named,
            _send_frame,
            _wait_until,
        )

        config = self._config()
        with XrSession(config) as session:
            with self.assertRaisesRegex(RuntimeError, "no headset"):
                session.streams_control({"rgb.hevc": {"hz": 2}})
            headset, descriptor = _connect_fake_headset(
                config.pose_port,
                ["xr_state_v1", CAPTURE_STREAMS_CAPABILITY, stream_capability("rgb.hevc")],
            )
            try:
                self.assertEqual(
                    descriptor["capture_streams"], config.capture_streams.to_descriptor_dict()
                )
                # The session owns its media transport: the bridge injects the
                # ports it serves and a token minted for this connection.
                media = descriptor["media"]
                self.assertEqual(media["protocol"], "olcp.v1")
                self.assertEqual(
                    (media["push_port"], media["result_port"]),
                    (config.media_up_port, config.media_down_port),
                )
                self.assertTrue(media["auth_token"])
                self.assertTrue(session.stats().capture_streams_supported)
                self.assertIsNone(session.streams_status())

                _send_frame(headset, "StreamsStatus", RFC_STATUS)
                self.assertTrue(_wait_until(lambda: session.streams_status() is not None))
                self.assertTrue(session.streams_status().is_active("rgb.hevc"))

                session.streams_control({"rgb.hevc": {"hz": 2, "paused": False}})
                control = json.loads(_recv_named(headset, "StreamsControl"))
                self.assertEqual(
                    control,
                    {"schema": "operator.streams_control.v1", "streams": {"rgb.hevc": {"hz": 2.0, "paused": False}}},
                )
            finally:
                headset.close()
            self.assertTrue(_wait_until(lambda: not session.stats().connected))
            self.assertIsNone(session.streams_status())

    def test_old_headset_is_reported_unsupported_and_never_controlled(self) -> None:
        from test_native_lifecycle import _connect_fake_headset, _wait_until

        config = self._config()
        with XrSession(config) as session:
            headset, descriptor = _connect_fake_headset(config.pose_port)
            try:
                self.assertIn("capture_streams", descriptor)
                # No capture_streams_v1: nothing to carry, so no media block.
                self.assertNotIn("media", descriptor)
                self.assertTrue(_wait_until(lambda: session.stats().connected))
                status = session.streams_status()
                self.assertEqual(status.stream("rgb.hevc").reason, "unsupported")
                with self.assertRaisesRegex(RuntimeError, "capture_streams_v1"):
                    session.streams_control({"rgb.hevc": {"hz": 2}})
            finally:
                headset.close()

    def test_session_without_capture_streams_keeps_descriptor_shape(self) -> None:
        from test_native_lifecycle import _config, _connect_fake_headset

        config = _config()
        with XrSession(config) as session:
            self.assertIsNone(session.capture)
            headset, descriptor = _connect_fake_headset(
                config.pose_port, ["xr_state_v1", CAPTURE_STREAMS_CAPABILITY]
            )
            try:
                self.assertNotIn("capture_streams", descriptor)
                self.assertNotIn("media", descriptor)
                self.assertIsNone(session.streams_status())
            finally:
                headset.close()
