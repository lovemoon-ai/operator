import unittest

from server.pose_inference_protocol import LatestPose, ProtocolError, pack_image_frame, unpack_image_frame


class PoseInferenceProtocolTests(unittest.TestCase):
    def test_image_frame_round_trip(self):
        encoded = pack_image_frame(7, 123_456, 640, 480, b"jpeg-bytes")

        frame = unpack_image_frame(encoded)

        self.assertEqual(frame.frame_id, 7)
        self.assertEqual(frame.capture_time_ns, 123_456)
        self.assertEqual((frame.width, frame.height), (640, 480))
        self.assertEqual(frame.jpeg, b"jpeg-bytes")

    def test_bad_magic_is_rejected(self):
        with self.assertRaises(ProtocolError):
            unpack_image_frame(b"NOPE" + b"\x01" * 32)

    def test_latest_pose_replaces_older_frame(self):
        latest = LatestPose()
        latest.replace({"frame_id": 1})
        latest.replace({"frame_id": 2})

        self.assertEqual(latest.take()["frame_id"], 2)
        self.assertIsNone(latest.take())


if __name__ == "__main__":
    unittest.main()
