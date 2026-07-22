from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path


sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from spatialmp4_metadata import (  # noqa: E402
    RERUN_FRAME_METADATA_KINDS,
    camera2_metadata_candidates,
    resolve_rgb_camera_count,
    resolve_android_timebase_metadata,
)


class SpatialMp4MetadataTest(unittest.TestCase):
    def test_rerun_only_eagerly_decodes_consumed_frame_metadata(self) -> None:
        self.assertNotIn("rgb_frame_index", RERUN_FRAME_METADATA_KINDS)
        self.assertEqual(
            {"depth_frame_meta", "body_frame_meta", "motion_trackers"},
            set(RERUN_FRAME_METADATA_KINDS),
        )

    def test_mp4_metadata_is_sufficient_without_external_files(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            input_path = Path(raw_root) / "session" / "session.mp4"
            operator_static = {
                "camera2_characteristics": {
                    "left": {"recording_width": 1280, "recording_height": 960},
                    "right": {"recording_width": 1280, "recording_height": 960},
                },
                "android_timebase": {"rgb_timestamp_domain": "godot_ticks_ns"},
            }

            candidates, errors = camera2_metadata_candidates(input_path, operator_static, "left")
            timebase, source, timebase_error = resolve_android_timebase_metadata(
                input_path,
                operator_static,
            )

            self.assertEqual(1, len(candidates))
            self.assertTrue(candidates[0][2], "first candidate must be MP4-embedded metadata")
            self.assertEqual(1280, candidates[0][0]["recording_width"])
            self.assertEqual([], errors)
            self.assertEqual("mp4", source)
            self.assertEqual("godot_ticks_ns", timebase["rgb_timestamp_domain"])
            self.assertIsNone(timebase_error)
            self.assertFalse(input_path.parent.exists(), "resolution must not create external metadata directories")

    def test_missing_mp4_metadata_does_not_fall_back_to_external_files(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            session_dir = Path(raw_root) / "session"
            session_dir.mkdir()
            input_path = session_dir / "session.mp4"
            (session_dir / "left_camera_characteristics.json").write_text("{}")
            (session_dir / "android_timebase.json").write_text("{}")

            candidates, errors = camera2_metadata_candidates(input_path, None, "left")
            timebase, source, timebase_error = resolve_android_timebase_metadata(input_path, None)

            self.assertEqual([], candidates)
            self.assertEqual([], errors)
            self.assertIsNone(timebase)
            self.assertEqual("", source)
            self.assertIsNone(timebase_error)

    def test_rgb_camera_count_prefers_resolved_manifest_options(self) -> None:
        manifest = {
            "capture_options": {"stereo_rgb": True},
            "resolved_capture_options": {"rgb_camera_count": 1},
        }
        operator_static = {
            "camera2_characteristics": {"left": {}, "right": {}},
        }

        self.assertEqual(1, resolve_rgb_camera_count(manifest, operator_static))

    def test_rgb_camera_count_falls_back_to_embedded_camera2_eyes(self) -> None:
        mono_static = {"camera2_characteristics": {"left": {"camera_id": "50"}}}
        stereo_static = {
            "camera2_characteristics": {
                "left": {"camera_id": "50"},
                "right": {"camera_id": "51"},
            }
        }

        self.assertEqual(1, resolve_rgb_camera_count(None, mono_static))
        self.assertEqual(2, resolve_rgb_camera_count(None, stereo_static))
        self.assertIsNone(resolve_rgb_camera_count(None, None))


if __name__ == "__main__":
    unittest.main()
