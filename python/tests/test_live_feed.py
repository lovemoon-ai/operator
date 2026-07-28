import dataclasses
import io
import runpy
import socket
import struct
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import patch

from pyoperator.live_feed import (
    AlgorithmDemand,
    capabilities_from_session_start,
    QUEST_CAPTURE_PROFILE,
    StreamEvent,
    LiveFeedServer,
    build_capture_request,
    get_demand,
    main,
    pack_composite_payload,
    pack_frame,
    parse_composite_payload,
    read_frame,
    validate_demand,
)
from pyoperator.live_feed.protocol import read_exact, to_plain


class LiveFeedTests(unittest.TestCase):
    def test_capture_plan_selects_required_streams_and_results(self) -> None:
        plan = validate_demand(
            QUEST_CAPTURE_PROFILE,
            get_demand("depth_fusion_pointcloud"),
        )
        request = build_capture_request(plan)

        self.assertEqual(request["schema"], "operator.capture_request.v1")
        self.assertEqual(request["algorithm"], "depth_fusion_pointcloud")
        self.assertEqual(
            request["selected_streams"],
            ["session.json", "depth.u16", "head_pose.json"],
        )
        self.assertIn("dense_map.point_cloud_delta", request["result_streams"])

        optional = dataclasses.replace(
            get_demand("depth_fusion"),
            optional_streams=("rgb.hevc", "not-available"),
        )
        optional_plan = validate_demand(QUEST_CAPTURE_PROFILE, optional)
        self.assertEqual(optional_plan.selected_streams[-1], "rgb.hevc")

    def test_capture_plan_rejects_missing_inputs_and_result_sinks(self) -> None:
        demand = get_demand("depth_fusion_pointcloud")
        with self.assertRaisesRegex(ValueError, "required streams"):
            validate_demand(
                QUEST_CAPTURE_PROFILE,
                dataclasses.replace(demand, required_streams=("missing",)),
            )
        with self.assertRaisesRegex(ValueError, "result sinks"):
            validate_demand(
                QUEST_CAPTURE_PROFILE,
                dataclasses.replace(demand, result_streams=("missing",)),
            )

    def test_demand_lookup_rejects_unimplemented_and_unknown_algorithms(self) -> None:
        with self.assertRaisesRegex(ValueError, "not implemented"):
            get_demand("vggt_slam2")
        with self.assertRaisesRegex(ValueError, "unknown algorithm"):
            get_demand("unknown")

    def test_olcp_frame_and_composite_payload_round_trip(self) -> None:
        payload = pack_composite_payload({"width": 2, "height": 1}, b"\x01\x02")
        metadata, binary = parse_composite_payload(payload)
        self.assertEqual(metadata, {"height": 1, "width": 2})
        self.assertEqual(binary, b"\x01\x02")

        event = read_frame(io.BytesIO(pack_frame(5, 2, 123, 45, payload)))
        self.assertIsNotNone(event)
        self.assertEqual(event.frame_type, 5)
        self.assertEqual(event.flags, 2)
        self.assertEqual(event.pts_ns, 123)
        self.assertEqual(event.duration_ns, 45)
        self.assertEqual(event.payload, payload)

        json_event = StreamEvent(1, 0, 0, 0, b'{"session_id":"test"}')
        self.assertEqual(json_event.payload_json(), {"session_id": "test"})
        with self.assertRaisesRegex(ValueError, "is not JSON"):
            StreamEvent(3, 0, 0, 0, b"").payload_json()

    def test_olcp_parser_rejects_malformed_frames_and_payloads(self) -> None:
        valid = pack_frame(1, 0, 0, 0, b"{}")
        self.assertIsNone(read_frame(io.BytesIO()))
        with self.assertRaisesRegex(ValueError, "invalid magic"):
            read_frame(io.BytesIO(b"NOPE" + valid[4:]))
        with self.assertRaisesRegex(ValueError, "unsupported OLCP version"):
            read_frame(io.BytesIO(valid[:4] + b"\x02" + valid[5:]))
        with self.assertRaisesRegex(EOFError, "mid-frame"):
            read_frame(io.BytesIO(valid[:-1]))
        oversized = struct.pack(">4sBBHQQI", b"OLCP", 1, 1, 0, 0, 0, 4097)
        with self.assertRaisesRegex(ValueError, "payload too large"):
            read_frame(io.BytesIO(oversized), max_payload_size=4096)
        with self.assertRaisesRegex(ValueError, "too short"):
            parse_composite_payload(b"\x00")
        with self.assertRaisesRegex(ValueError, "exceeds payload"):
            parse_composite_payload(struct.pack(">I", 5) + b"{}")

    def test_socket_reader_and_plain_conversion_helpers(self) -> None:
        sender, receiver = socket.socketpair()
        try:
            sender.sendall(b"abc")
            self.assertEqual(read_exact(receiver, 3), b"abc")
        finally:
            sender.close()
            receiver.close()

        demand = AlgorithmDemand("test", ("required",), (), (), {"limit": 1})
        self.assertEqual(
            to_plain({"demand": demand, "nested": (1, 2)}),
            {
                "demand": {
                    "algorithm": "test",
                    "required_streams": ["required"],
                    "optional_streams": [],
                    "result_streams": [],
                    "limits": {"limit": 1},
                },
                "nested": [1, 2],
            },
        )

    def test_cli_self_test(self) -> None:
        output = io.StringIO()
        with redirect_stdout(output):
            result = main(["--self-test"])
        self.assertEqual(result, 0)
        self.assertIn("self-test ok", output.getvalue())

    def test_cli_prints_plan_and_constructs_server(self) -> None:
        output = io.StringIO()
        with redirect_stdout(output):
            self.assertEqual(main(["--print-plan"]), 0)
        self.assertIn('"schema": "operator.capture_request.v1"', output.getvalue())

        with patch("pyoperator.live_feed.cli.LiveFeedServer") as server_class:
            result = main(
                [
                    "--host", "0.0.0.0",
                    "--push-port", "64010",
                    "--pull-host", "127.0.0.1",
                    "--pull-port", "64012",
                    "--out", "capture",
                    "--no-rgb-colorize",
                    "--no-send-results-to-xr",
                ]
            )
        self.assertEqual(result, 0)
        self.assertEqual(server_class.call_args.kwargs["port"], 64010)
        self.assertEqual(server_class.call_args.kwargs["result_port"], 64012)
        self.assertFalse(server_class.call_args.kwargs["rgb_colorize"])
        server_class.return_value.serve_forever.assert_called_once_with()

    def test_capture_control_listener_is_independent_from_result_publication(self) -> None:
        plan = validate_demand(
            QUEST_CAPTURE_PROFILE,
            get_demand("depth_fusion_pointcloud"),
        )
        server = LiveFeedServer(
            host="127.0.0.1",
            port=0,
            result_host="127.0.0.1",
            result_port=0,
            out_dir=Path("unused"),
            plan=plan,
            max_queue=8,
            auth_token="",
            send_capture_request_to_xr=True,
            send_results_to_xr=False,
            max_events=None,
            publish_interval_s=1.0,
            point_stride=4,
            min_depth_m=0.2,
            max_depth_m=5.0,
            max_points_per_update=100,
            result_fragment_bytes=4096,
            rgb_colorize=False,
            ffmpeg_bin="ffmpeg",
            show_connection_banner=False,
        )
        self.assertTrue(server.accept_result_connections)
        self.assertTrue(server.result_channel.enabled)

        with patch.object(server.result_channel, "send_frame") as send_frame:
            server._send_result_frame(110, 0, 0, 0, b"{}")
            send_frame.assert_not_called()
            with redirect_stdout(io.StringIO()):
                server._announce_capture_request()
            send_frame.assert_called_once()

    def test_module_entry_point_delegates_to_cli(self) -> None:
        with patch("pyoperator.live_feed.cli.main", return_value=7):
            with self.assertRaises(SystemExit) as raised:
                runpy.run_module("pyoperator.live_feed.__main__", run_name="__main__")
        self.assertEqual(raised.exception.code, 7)


class CapabilityNegotiationTests(unittest.TestCase):
    """The server plans against what the headset says it can send."""

    def session_start(self, **overrides):
        info = {
            "stream_name": "live_x",
            "protocol": "operator.live_feed.v1",
            "rgb_width": 1280,
            "rgb_height": 960,
            "depth_expected": True,
            "head_pose_expected": True,
            "controller_pose_expected": True,
            "hand_joints_expected": True,
            "controller_input_expected": True,
        }
        info.update(overrides)
        return info

    def test_capabilities_reflect_the_headset_flags(self) -> None:
        caps = capabilities_from_session_start(self.session_start())
        self.assertEqual(
            sorted(caps.streams),
            [
                "controller_input.json",
                "controller_pose.json",
                "depth.u16",
                "hand_joints.json",
                "head_pose.json",
                "rgb.hevc",
                "session.json",
            ],
        )

    def test_disabled_streams_are_absent(self) -> None:
        caps = capabilities_from_session_start(
            self.session_start(hand_joints_expected=False, depth_expected=False)
        )
        self.assertNotIn("hand_joints.json", caps.streams)
        self.assertNotIn("depth.u16", caps.streams)
        # session.json is implicit: a session_start proves it.
        self.assertIn("session.json", caps.streams)

    def test_missing_rgb_dimensions_drop_the_rgb_stream(self) -> None:
        caps = capabilities_from_session_start(self.session_start(rgb_width=0, rgb_height=0))
        self.assertNotIn("rgb.hevc", caps.streams)
        caps_bad = capabilities_from_session_start(self.session_start(rgb_width="junk"))
        self.assertNotIn("rgb.hevc", caps_bad.streams)

    def test_plan_uses_negotiated_capabilities(self) -> None:
        caps = capabilities_from_session_start(self.session_start())
        plan = validate_demand(caps, get_demand("depth_fusion_pointcloud"))
        request = build_capture_request(plan)
        self.assertEqual(
            request["selected_streams"], ["session.json", "depth.u16", "head_pose.json"]
        )

    def test_headset_without_depth_fails_the_depth_fusion_demand(self) -> None:
        # This is the case the static profile used to hide: the server would
        # have requested depth from a headset that cannot produce it.
        caps = capabilities_from_session_start(self.session_start(depth_expected=False))
        with self.assertRaisesRegex(ValueError, "required streams"):
            validate_demand(caps, get_demand("depth_fusion_pointcloud"))

    def test_result_sinks_are_preserved_from_the_template(self) -> None:
        caps = capabilities_from_session_start(self.session_start())
        self.assertIn("dense_map.point_cloud_delta", caps.result_sinks)


if __name__ == "__main__":
    unittest.main()
