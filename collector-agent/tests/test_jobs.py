from __future__ import annotations

import hashlib
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from operator_collector.jobs import (
    JobContext,
    _create_preview_frames,
    build_dataset_name,
    import_session,
    label_item,
    scan,
    validate_session,
)


def make_fixture(root: Path, session_id: str = "20260804_020030") -> Path:
    fixture = root / "fixture"
    sidecars = fixture / "sidecars"
    (sidecars / "poses").mkdir(parents=True)
    (sidecars / "depth").mkdir(parents=True)
    media = b"operator-test-media"
    (fixture / "media.mp4").write_bytes(media)
    manifest = {
        "schema": "spatialmp4.quest_capture.spool.v3",
        "session_id": session_id,
        "session_start_unix_us": 1785808830902943,
        "artifacts": {
            "media": {
                "bytes": len(media),
                "sha256": hashlib.sha256(media).hexdigest(),
            }
        },
        "stream_confirmations": {
            "depth": {"status": "missing", "requested": True}
        },
    }
    text = json.dumps(manifest)
    (fixture / "manifest.json").write_text(text, encoding="utf-8")
    (sidecars / "manifest.json").write_text(text, encoding="utf-8")
    camera = [
        {"eye": "left", "timestamp_ns": 1_000_000_000},
        {"eye": "left", "timestamp_ns": 1_033_333_333},
    ]
    (sidecars / "left_camera_frames.jsonl").write_text(
        "\n".join(json.dumps(value) for value in camera) + "\n", encoding="utf-8"
    )
    (sidecars / "right_camera_frames.jsonl").write_text("", encoding="utf-8")
    (sidecars / "poses" / "hands.jsonl").write_text("", encoding="utf-8")
    (sidecars / "depth" / "frames.jsonl").write_text("", encoding="utf-8")
    return fixture


class JobTests(unittest.TestCase):
    def test_scan_import_validate_and_label_fixture(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = make_fixture(root)
            data_root = root / "data"
            progress: list[tuple[float, str]] = []
            context = JobContext(
                {
                    "fixture_root": str(fixture),
                    "data_root": str(data_root),
                    "preview_enabled": False,
                },
                lambda value, message: progress.append((value, message)),
            )

            scanned = scan({}, context)
            self.assertEqual(scanned["sessions"][0]["session_id"], "20260804_020030")

            imported = import_session(
                {"session_id": "20260804_020030", "delete_after": True}, context
            )
            imported_path = Path(imported["local_path"])
            self.assertTrue(imported_path.is_dir())
            self.assertTrue(imported["qc"]["ok"])
            self.assertIn("Depth requested but missing", imported["qc"]["warnings"])
            self.assertFalse(imported["quest_deleted"])
            self.assertTrue((imported_path / "qc.json").is_file())

            labeled = label_item(
                {
                    "item_id": "item-1",
                    "source_session_id": "20260804_020030",
                    "local_path": str(imported_path),
                    "label": "wash",
                },
                context,
            )
            self.assertEqual(labeled["dataset_name"], "20260804_wash_020030902")
            labeled_path = Path(labeled["local_path"])
            self.assertTrue(labeled_path.is_dir())
            self.assertEqual(
                json.loads((labeled_path / "labels.json").read_text())["label"], "wash"
            )
            self.assertTrue(progress)

    def test_validate_rejects_media_hash_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            fixture = make_fixture(Path(directory))
            (fixture / "media.mp4").write_bytes(b"corrupt")
            qc = validate_session(fixture)
            self.assertFalse(qc["ok"])
            self.assertIn("media SHA-256 mismatch", qc["errors"])

    def test_scan_and_import_local_without_adb(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            local_source = make_fixture(root)
            data_root = root / "managed"
            context = JobContext(
                {
                    "local_source_root": str(local_source),
                    "data_root": str(data_root),
                    "preview_enabled": False,
                },
                lambda _value, _message: None,
            )

            scanned = scan({"source": "local"}, context)
            self.assertEqual(scanned["source"], "local")
            self.assertEqual(scanned["sessions"][0]["session_id"], "20260804_020030")
            self.assertEqual(scanned["sessions"][0]["source"], "local")

            imported = import_session(
                {
                    "source": "local",
                    "source_path": scanned["sessions"][0]["source_path"],
                    "session_id": "20260804_020030",
                },
                context,
            )
            self.assertTrue(imported["qc"]["ok"])
            self.assertTrue(Path(imported["local_path"]).is_dir())

    def test_build_dataset_name_uses_session_clock_and_manifest_millis(self) -> None:
        value = build_dataset_name(
            "20260804_020030", "wash", {"session_start_unix_us": 1785808830902943}
        )
        self.assertEqual(value, "20260804_wash_020030902")

    def test_preview_samples_first_two_minutes_every_twenty_seconds(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = make_fixture(root)
            context = JobContext(
                {"data_root": str(root / "data"), "ffmpeg_path": "/fake/ffmpeg"},
                lambda _value, _message: None,
            )

            def fake_run(command: list[str], timeout: int):
                self.assertEqual(timeout, 60 * 60)
                self.assertIn("120", command)
                self.assertIn("6", command)
                self.assertIn("crop=iw/2:ih:0:0,fps=1/20,scale=640:-2", command)
                pattern = Path(command[-1])
                for index in range(1, 4):
                    pattern.with_name(f"{index:02d}.jpg").write_bytes(b"jpeg")
                return None

            with patch("operator_collector.jobs._run", side_effect=fake_run):
                previews = _create_preview_frames(fixture, context)

            self.assertEqual([path.name for path in previews], ["01.jpg", "02.jpg", "03.jpg"])


if __name__ == "__main__":
    unittest.main()
