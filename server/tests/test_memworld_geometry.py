import io
import unittest

import numpy as np
from PIL import Image

from server.memworld_geometry import (
    CameraCalibration,
    OPENXR_JOINT_INDICES,
    camera_c2w_from_pose,
    map_openxr_hand,
    memworld_c2w,
    project_world_points,
    render_hand_skeleton,
)


def calibration_payload():
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
        "lens_pose_translation": [-0.03, 0.0, 0.015],
        "lens_pose_rotation": [0.0, 0.0, 0.0, 1.0],
    }


class CameraCalibrationTests(unittest.TestCase):
    def test_bottom_crop_adjusts_intrinsics(self):
        calibration = CameraCalibration.from_json(calibration_payload())
        output = calibration.output_intrinsics()
        self.assertEqual((output.width, output.height), (640, 352))
        self.assertAlmostEqual(output.fx, 500.0)
        self.assertAlmostEqual(output.fy, 500.0)
        self.assertAlmostEqual(output.cx, 320.0)
        self.assertAlmostEqual(output.cy, 112.0)
        self.assertEqual(output.crop_top, 128)

    def test_openxr_26_maps_to_memworld_21(self):
        joints = [
            {"tracked": True, "position": [float(index), 0.0, 1.0]}
            for index in range(26)
        ]
        mapped = map_openxr_hand({"tracking": True, "joints": joints})
        self.assertEqual(OPENXR_JOINT_INDICES, (1, 2, 3, 4, 5, 7, 8, 9, 10, 12, 13, 14, 15, 17, 18, 19, 20, 22, 23, 24, 25))
        self.assertEqual([int(point[0]) for point in mapped], list(OPENXR_JOINT_INDICES))

    def test_camera_pose_composes_lens_offset(self):
        calibration = CameraCalibration.from_json(calibration_payload())
        pose = {
            "tracked": True,
            "position": [1.0, 2.0, 3.0],
            "rotation": [0.0, 0.0, 0.0, 1.0],
        }
        camera = camera_c2w_from_pose(pose, calibration)
        np.testing.assert_allclose(camera[:3, 3], [0.97, 2.0, 3.015])
        self.assertEqual(memworld_c2w(camera).shape, (4, 4))

    def test_center_point_projects_into_bottom_crop(self):
        calibration = CameraCalibration.from_json(calibration_payload())
        points, valid = project_world_points(
            np.asarray([[0.0, 0.0, 1.0]]),
            np.eye(4),
            calibration,
        )
        self.assertTrue(valid[0])
        np.testing.assert_allclose(points[0], [320.0, 112.0])

    def test_behind_camera_point_is_invalid(self):
        calibration = CameraCalibration.from_json(calibration_payload())
        _, valid = project_world_points(
            np.asarray([[0.0, 0.0, -1.0]]),
            np.eye(4),
            calibration,
        )
        self.assertFalse(valid[0])

    def test_renderer_outputs_640_by_352_jpeg(self):
        calibration = CameraCalibration.from_json(calibration_payload())
        pose = {
            "frame_id": 3,
            "capture_time_ns": 5,
            "head": {
                "tracked": True,
                "position": [0.0, 0.0, 0.0],
                "rotation": [0.0, 0.0, 0.0, 1.0],
            },
            "left": {
                "tracking": True,
                "joints": [
                    {"tracked": True, "position": [0.001 * index, 0.0, 1.0]}
                    for index in range(26)
                ],
            },
            "right": {"tracking": False, "joints": []},
        }
        rendered = render_hand_skeleton(pose, calibration)
        self.assertEqual(rendered.image.size, (640, 352))
        output = io.BytesIO()
        rendered.image.save(output, format="JPEG")
        self.assertEqual(Image.open(io.BytesIO(output.getvalue())).size, (640, 352))


if __name__ == "__main__":
    unittest.main()
