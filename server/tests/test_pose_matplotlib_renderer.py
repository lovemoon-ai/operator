import io
import json
import math
from pathlib import Path
import unittest

from PIL import Image

from server.pose_inference_ws import (
    HAND_BONES,
    MatplotlibPoseRenderer,
    _plot_coordinates,
    _rotate_vector_by_quaternion,
)


class PoseGeometryTests(unittest.TestCase):
    def test_identity_quaternion_preserves_forward_vector(self):
        actual = _rotate_vector_by_quaternion(
            (0.0, 0.0, 0.0, 1.0),
            (0.0, 0.0, -1.0),
        )
        self.assertEqual(actual, (0.0, 0.0, -1.0))

    def test_positive_quarter_turn_around_y_rotates_forward_to_left(self):
        half_angle = math.pi / 4.0
        actual = _rotate_vector_by_quaternion(
            (0.0, math.sin(half_angle), 0.0, math.cos(half_angle)),
            (0.0, 0.0, -1.0),
        )
        self.assertAlmostEqual(actual[0], -1.0, places=6)
        self.assertAlmostEqual(actual[1], 0.0, places=6)
        self.assertAlmostEqual(actual[2], 0.0, places=6)

    def test_plot_coordinates_use_right_forward_up_axes(self):
        self.assertEqual(
            _plot_coordinates((2.0, 4.0, 1.0), (1.0, 2.0, 3.0)),
            (1.0, 2.0, 2.0),
        )

    def test_hand_bones_cover_all_five_fingertips(self):
        connected_indices = {index for edge in HAND_BONES for index in edge}
        self.assertTrue({5, 10, 15, 20, 25}.issubset(connected_indices))


class MatplotlibPoseRendererTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        sample_path = (
            Path(__file__).resolve().parents[1]
            / "samples"
            / "quest_pose_frame_000001.json"
        )
        cls.pose = json.loads(sample_path.read_text(encoding="utf-8"))

    def test_complete_pose_renders_decodable_960_by_540_jpeg(self):
        width, height, jpeg = MatplotlibPoseRenderer().render(self.pose, 1)

        self.assertEqual((width, height), (960, 540))
        with Image.open(io.BytesIO(jpeg)) as image:
            self.assertEqual(image.format, "JPEG")
            self.assertEqual(image.size, (960, 540))
            self.assertGreater(len(image.getcolors(maxcolors=960 * 540)), 8)

    def test_image_sequence_changes_the_encoded_frame(self):
        renderer = MatplotlibPoseRenderer()

        first = renderer.render(self.pose, 1)[2]
        second = renderer.render(self.pose, 2)[2]

        self.assertNotEqual(first, second)

    def test_untracked_and_malformed_joints_still_render(self):
        pose = {
            "frame_id": 5,
            "head": {"tracked": False},
            "left": {"tracking": False, "joints": []},
            "right": {
                "tracking": True,
                "joints": [
                    {"tracked": False},
                    {"tracked": True, "position": [1.0, 2.0]},
                    {"tracked": True, "position": [0.1, 1.8, -0.2]},
                ],
            },
        }

        width, height, jpeg = MatplotlibPoseRenderer().render(pose, 1)

        self.assertEqual((width, height), (960, 540))
        with Image.open(io.BytesIO(jpeg)) as image:
            image.verify()


if __name__ == "__main__":
    unittest.main()
