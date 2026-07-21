# /// script
# requires-python = ">=3.10"
# dependencies = ["numpy>=1.26.0"]
# ///

from __future__ import annotations

import sys
import unittest
from pathlib import Path

try:
    import numpy as np
except ImportError:  # Keep dependency-light unittest discovery usable.
    np = None


@unittest.skipIf(np is None, "numpy is required for geometry regression tests")
class EnvironmentDepthGeometryTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
        global openxr_depth_camera_pose
        global project_rdf_points_to_image
        global unproject_environment_depth_via_inverse_projection
        from environment_depth_geometry import (
            openxr_depth_camera_pose,
            project_rdf_points_to_image,
            unproject_environment_depth_via_inverse_projection,
        )

    def test_openxr_depth_eye_to_rdf_flips_y_and_z(self) -> None:
        camera_pose = openxr_depth_camera_pose(np.eye(4, dtype=np.float64))
        np.testing.assert_array_equal(
            camera_pose[:3, :3],
            np.diag([1.0, -1.0, -1.0]),
        )
        self.assertAlmostEqual(np.linalg.det(camera_pose[:3, :3]), 1.0)

        point_rdf = np.array([[0.2, 0.4, 2.0]], dtype=np.float64)
        point_world = (camera_pose[:3, :3] @ point_rdf.T).T
        np.testing.assert_allclose(point_world, [[0.2, -0.4, -2.0]])

        point_rdf_recovered = (
            np.linalg.inv(camera_pose[:3, :3]) @ point_world.T
        ).T
        uv, mask = project_rdf_points_to_image(
            point_rdf_recovered,
            fx=100.0,
            fy=100.0,
            cx=320.0,
            cy=240.0,
            width=640,
            height=480,
        )
        self.assertTrue(mask[0])
        np.testing.assert_allclose(uv[0], [330.0, 260.0])

    def test_inverse_projection_points_land_on_aligned_left_rgb(self) -> None:
        # For a 1x1 depth frame at two metres, this synthetic inverse matrix
        # emits OpenXR world point (0, 0, -2). An aligned RDF RGB camera has
        # the Y/Z basis conversion below, so the point must project to centre.
        inverse_projection_view = np.array(
            [
                [1.0, 0.0, 0.0, 0.0],
                [0.0, 1.0, 0.0, 0.0],
                [0.0, 0.0, 0.0, -1.0],
                [0.0, 0.0, 0.0, 0.5],
            ],
            dtype=np.float64,
        )
        result = unproject_environment_depth_via_inverse_projection(
            np.array([[2.0]], dtype=np.float32),
            inverse_projection_view,
            near_z=1.0,
            far_z=None,
            depth_min_m=0.1,
            depth_max_m=5.0,
            stride=1,
        )
        self.assertIsNotNone(result)
        points_world, depth_values = result
        np.testing.assert_allclose(points_world, [[0.0, 0.0, -2.0]])
        np.testing.assert_allclose(depth_values, [2.0])

        rgb_pose = openxr_depth_camera_pose(np.eye(4, dtype=np.float64))
        points_rgb_rdf = (
            np.linalg.inv(rgb_pose[:3, :3]) @ points_world.T
        ).T
        uv, mask = project_rdf_points_to_image(
            points_rgb_rdf,
            fx=200.0,
            fy=200.0,
            cx=320.0,
            cy=240.0,
            width=640,
            height=480,
        )
        self.assertTrue(mask[0])
        np.testing.assert_allclose(uv[0], [320.0, 240.0])


if __name__ == "__main__":
    unittest.main()
