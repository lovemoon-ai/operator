import unittest

from pyoperator.protocol.retargeting import (
    PROTOCOL_VERSION,
    ProtocolError,
    RetargetingRequest,
    RetargetingResult,
    error_message,
    frame_id_of,
    parse_frame_envelope,
    parse_hello,
)


def hello_message(**overrides):
    message = {
        "type": "hello",
        "protocol_version": PROTOCOL_VERSION,
        "profile_id": "so101",
        "input_type": "end_effector_pose_v1",
        "model_hash": "sha256:abc",
    }
    message.update(overrides)
    return message


class HelloTests(unittest.TestCase):
    def test_accepts_the_negotiated_version(self) -> None:
        hello = parse_hello(hello_message())
        self.assertEqual(hello.profile_id, "so101")
        self.assertEqual(hello.model_hash, "sha256:abc")

    def test_rejects_another_protocol_version(self) -> None:
        with self.assertRaises(ProtocolError) as caught:
            parse_hello(hello_message(protocol_version=99))
        self.assertEqual(caught.exception.code, "unsupported_protocol")

    def test_rejects_a_non_hello_first_message(self) -> None:
        with self.assertRaises(ProtocolError) as caught:
            parse_hello({"type": "frame"})
        self.assertEqual(caught.exception.code, "hello_required")

    def test_rejects_missing_and_malformed_fields(self) -> None:
        for message in (
            hello_message(profile_id=""),
            hello_message(input_type=None),
            hello_message(protocol_version="1"),
            hello_message(protocol_version=True),
        ):
            with self.assertRaises(ProtocolError):
                parse_hello(message)

    def test_rejects_a_non_object_message(self) -> None:
        with self.assertRaises(ProtocolError) as caught:
            parse_hello(["hello"])
        self.assertEqual(caught.exception.code, "invalid_message")


class FrameEnvelopeTests(unittest.TestCase):
    def test_parses_identity_and_payload(self) -> None:
        request = parse_frame_envelope(
            {"type": "frame", "frame_id": 7, "timestamp_ns": 42, "payload": {"a": 1}}
        )
        self.assertEqual(request, RetargetingRequest(7, 42, {"a": 1}))

    def test_rejects_the_wrong_type_and_a_missing_payload(self) -> None:
        with self.assertRaises(ProtocolError):
            parse_frame_envelope({"type": "reset"})
        with self.assertRaises(ProtocolError):
            parse_frame_envelope({"type": "frame", "frame_id": 1, "timestamp_ns": 1})

    def test_frame_id_of_ignores_non_integers(self) -> None:
        self.assertEqual(frame_id_of({"frame_id": 3}), 3)
        self.assertIsNone(frame_id_of({"frame_id": True}))
        self.assertIsNone(frame_id_of({"frame_id": "3"}))
        self.assertIsNone(frame_id_of("nope"))


class ResultTests(unittest.TestCase):
    def test_wire_result_matches_the_client_contract(self) -> None:
        wire = RetargetingResult(
            frame_id=9,
            timestamp_ns=11,
            profile_id="so101",
            output_type="joint_positions_v1",
            positions=(0.1, 0.2),
            joint_names=("a", "b"),
            status="orientation_degraded",
            iterations=4,
            solve_time_us=1650,
            metrics={"pos_err_m": 0.001},
            degradation={"reason": "unreachable"},
        ).to_wire()
        self.assertEqual(wire["type"], "result")
        self.assertEqual(wire["frame_id"], 9)
        self.assertEqual(wire["q"], [0.1, 0.2])
        self.assertEqual(wire["joint_names"], ["a", "b"])
        self.assertEqual(wire["status"], "orientation_degraded")
        self.assertEqual(wire["metrics"], {"pos_err_m": 0.001})
        self.assertEqual(wire["degradation"], {"reason": "unreachable"})

    def test_error_message_scopes_to_a_frame_when_known(self) -> None:
        self.assertEqual(
            error_message("bad", "why"), {"type": "error", "code": "bad", "message": "why"}
        )
        self.assertEqual(error_message("bad", "why", 5)["frame_id"], 5)
