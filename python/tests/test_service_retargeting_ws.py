"""End-to-end retargeting service: the exact traffic the XR client speaks.

Needs FastAPI (the `retargeting` pyoperator extra) and the solver library.
"""

import unittest

from pyoperator.services.retargeting import create_app

try:
    import retargeting
except ImportError:  # pragma: no cover - environment dependent
    retargeting = None

try:
    from fastapi.testclient import TestClient
except ImportError:  # pragma: no cover - environment dependent
    TestClient = None


@unittest.skipIf(retargeting is None, "the retargeting solver library is not installed")
@unittest.skipIf(TestClient is None, "fastapi is not installed")
class RetargetingServiceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.runtime = retargeting.RetargetingRuntime()
        self.profile = self.runtime.describe_profile("so101")
        self.client = TestClient(create_app(self.runtime))
        self.addCleanup(self.client.close)

    def hello(self, **overrides) -> dict:
        message = {
            "type": "hello",
            "protocol_version": 1,
            "profile_id": "so101",
            "input_type": "end_effector_pose_v1",
            "model_hash": self.profile.model_hash,
        }
        message.update(overrides)
        return message

    def home_payload(self) -> dict:
        from retargeting.lie import mat_to_quat

        session = self.runtime.create_session("so101")
        self.addCleanup(session.close)
        transform = session.robot.fk(session.robot.home_q)
        return {
            "position": transform[:3, 3].tolist(),
            "orientation_wxyz": mat_to_quat(transform[:3, :3]).tolist(),
        }

    def test_health_lists_available_profiles(self) -> None:
        response = self.client.get("/healthz")
        self.assertEqual(response.status_code, 200)
        self.assertIn("so101", response.json()["available_profiles"])

    def test_profile_discovery_never_leaks_deployment_paths(self) -> None:
        profiles = self.client.get("/v1/profiles").json()["profiles"]
        by_id = {profile["profile_id"]: profile for profile in profiles}
        self.assertIn("so101", by_id)
        self.assertNotIn("options", by_id["so101"])

    def test_frame_roundtrip_returns_joint_positions(self) -> None:
        with self.client.websocket_connect("/v1/retarget") as socket:
            socket.send_json(self.hello())
            ack = socket.receive_json()
            self.assertEqual(ack["type"], "hello_ack")
            self.assertEqual(ack["profile"]["profile_id"], "so101")

            socket.send_json(
                {
                    "type": "frame",
                    "frame_id": 9,
                    "timestamp_ns": 789,
                    "payload": self.home_payload(),
                }
            )
            result = socket.receive_json()
            self.assertEqual(result["type"], "result")
            self.assertEqual(result["frame_id"], 9)
            self.assertEqual(result["profile_id"], "so101")
            self.assertEqual(result["output_type"], "joint_positions_v1")
            self.assertEqual(len(result["q"]), len(self.profile.joint_names))

            socket.send_json({"type": "reset"})
            self.assertEqual(socket.receive_json()["type"], "reset_ack")

    def test_bad_frame_is_reported_without_dropping_the_session(self) -> None:
        with self.client.websocket_connect("/v1/retarget") as socket:
            socket.send_json(self.hello())
            socket.receive_json()
            socket.send_json(
                {
                    "type": "frame",
                    "frame_id": 3,
                    "timestamp_ns": 1,
                    "payload": {"position": [float("inf"), 0.0, 0.0]},
                }
            )
            error = socket.receive_json()
            self.assertEqual(error["type"], "error")
            self.assertEqual(error["frame_id"], 3)

            socket.send_json(
                {
                    "type": "frame",
                    "frame_id": 4,
                    "timestamp_ns": 2,
                    "payload": self.home_payload(),
                }
            )
            self.assertEqual(socket.receive_json()["type"], "result")

    def test_rejected_handshake_closes_the_socket(self) -> None:
        with self.client.websocket_connect("/v1/retarget") as socket:
            socket.send_json(self.hello(profile_id="nope"))
            error = socket.receive_json()
            self.assertEqual(error["code"], "unknown_profile")

    def test_post_handshake_protocol_error_is_reported_before_close(self) -> None:
        with self.client.websocket_connect("/v1/retarget") as socket:
            socket.send_json(self.hello())
            socket.receive_json()
            socket.send_json({"type": "ping"})
            error = socket.receive_json()
            self.assertEqual(error["type"], "error")
            self.assertEqual(error["code"], "invalid_message")

    def test_post_handshake_invalid_json_is_reported_before_close(self) -> None:
        with self.client.websocket_connect("/v1/retarget") as socket:
            socket.send_json(self.hello())
            socket.receive_json()
            socket.send_text("{")
            error = socket.receive_json()
            self.assertEqual(error["type"], "error")
            self.assertEqual(error["code"], "invalid_json")
