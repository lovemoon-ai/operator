from __future__ import annotations

import hashlib
import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from operator_collector.jobs import (
    JobContext,
    _UploadProgressTracker,
    _create_preview_frames,
    build_dataset_name,
    delete_local_item,
    delete_quest_session,
    import_session,
    label_item,
    preview_item,
    scan,
    upload_item,
    validate_session,
    workstation_state,
)
from operator_collector.runtime import FIXED_MODELSCOPE_REPO_ID, find_tool


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

    def test_preview_reports_missing_ffmpeg(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            session = root / "data" / "sessions" / "demo"
            session.mkdir(parents=True)
            (session / "media.mp4").write_bytes(b"video")
            context = JobContext(
                {"data_root": str(root / "data")},
                lambda _value, _message: None,
            )
            with patch("operator_collector.jobs.find_tool", return_value=""):
                with self.assertRaisesRegex(RuntimeError, "FFmpeg"):
                    preview_item(
                        {"item_id": "item-1", "local_path": str(session)}, context
                    )

    def test_default_quest_root_matches_ego_capture_directory(self) -> None:
        context = JobContext({}, lambda _value, _message: None)
        self.assertEqual(context.quest_root, "/sdcard/DCIM/SpatialMP4")
        self.assertEqual(
            context.quest_roots,
            ["/sdcard/DCIM/SpatialMP4", "/sdcard/Movies/SpatialMP4"],
        )

    def test_custom_quest_root_does_not_replace_standard_scan_roots(self) -> None:
        context = JobContext(
            {"quest_root": "/sdcard/OperatorCustom"},
            lambda _value, _message: None,
        )
        self.assertEqual(
            context.quest_roots,
            [
                "/sdcard/OperatorCustom",
                "/sdcard/DCIM/SpatialMP4",
                "/sdcard/Movies/SpatialMP4",
            ],
        )

    def test_scan_quest_finds_new_and_legacy_layouts_in_both_roots(self) -> None:
        context = JobContext(
            {"adb_path": "/fake/adb"},
            lambda _value, _message: None,
        )

        def fake_run(command: list[str], timeout: float):
            shell = command[-1]
            output = ""
            if "-type d" in shell and "/DCIM/" in shell:
                output = "/sdcard/DCIM/SpatialMP4/20260806_010101\n"
            elif "-type f" in shell and "/Movies/" in shell:
                output = (
                    "/sdcard/Movies/SpatialMP4/20260805_020202.mp4\n"
                    "/sdcard/Movies/SpatialMP4/20260805_020203.partial.mp4\n"
                )
            return subprocess.CompletedProcess(command, 0, output, "")

        with (
            patch("operator_collector.jobs._run", side_effect=fake_run),
            patch("operator_collector.jobs._adb_test_file", return_value=True),
            patch("operator_collector.jobs._adb_file_size", return_value=1234),
        ):
            result = scan({"source": "quest"}, context)

        self.assertEqual(len(result["sessions"]), 2)
        self.assertEqual(
            {session["layout"] for session in result["sessions"]},
            {"session_directory", "legacy_siblings"},
        )
        self.assertEqual(
            {session["quest_root"] for session in result["sessions"]},
            {"/sdcard/DCIM/SpatialMP4", "/sdcard/Movies/SpatialMP4"},
        )
        self.assertTrue(all(session["complete"] for session in result["sessions"]))

    def test_current_layout_validates_and_imports_without_sidecars(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = make_fixture(root)
            shutil.rmtree(fixture / "sidecars")
            qc = validate_session(fixture)
            self.assertTrue(qc["ok"])
            self.assertFalse(qc["checks"]["sidecars"])

            data_root = root / "managed"
            context = JobContext(
                {
                    "adb_path": "/fake/adb",
                    "data_root": str(data_root),
                    "preview_enabled": False,
                },
                lambda _value, _message: None,
            )
            session_id = "20260806_030303"
            media = b"new-layout-media"
            manifest = {
                "schema": "spatialmp4.quest_capture.spool.v3",
                "session_id": session_id,
                "artifacts": {
                    "media": {
                        "bytes": len(media),
                        "sha256": hashlib.sha256(media).hexdigest(),
                    }
                },
            }

            def fake_pull(command: list[str], timeout: float):
                if len(command) >= 4 and command[1] == "pull":
                    destination = Path(command[3])
                    destination.mkdir(parents=True)
                    (destination / f"{session_id}.mp4").write_bytes(media)
                    (destination / "manifest.json").write_text(
                        json.dumps(manifest), encoding="utf-8"
                    )
                    (destination / "android_timebase.json").write_text(
                        "{}", encoding="utf-8"
                    )
                return subprocess.CompletedProcess(command, 0, "", "")

            with patch("operator_collector.jobs._run", side_effect=fake_pull):
                imported = import_session(
                    {
                        "source": "quest",
                        "session_id": session_id,
                        "quest_root": "/sdcard/DCIM/SpatialMP4",
                        "layout": "session_directory",
                    },
                    context,
                )

            imported_path = Path(imported["local_path"])
            self.assertTrue(imported["qc"]["ok"])
            self.assertEqual((imported_path / "media.mp4").read_bytes(), media)
            self.assertTrue((imported_path / "manifest.json").is_file())
            self.assertTrue((imported_path / "android_timebase.json").is_file())

    def test_delete_quest_removes_only_the_scanned_source(self) -> None:
        context = JobContext(
            {"adb_path": "/fake/adb"},
            lambda _value, _message: None,
        )
        commands: list[list[str]] = []

        def fake_run(command: list[str], timeout: float):
            commands.append(command)
            return subprocess.CompletedProcess(command, 0, "", "")

        with (
            patch("operator_collector.jobs._run", side_effect=fake_run),
            patch("operator_collector.jobs._scan_quest", return_value=[]),
        ):
            result = delete_quest_session(
                {
                    "session_id": "20260806_040404",
                    "quest_root": "/sdcard/DCIM/SpatialMP4",
                    "layout": "session_directory",
                },
                context,
            )

        delete_command = commands[0][-1]
        self.assertIn("rm -rf /sdcard/DCIM/SpatialMP4/20260806_040404", delete_command)
        self.assertNotIn("/sdcard/Movies/", delete_command)
        self.assertEqual(result["sessions"], [])

    def test_workstation_state_reports_bundled_python_runtime(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            state = workstation_state(
                {
                    "fixture_root": directory,
                    "data_root": directory,
                }
            )
        self.assertEqual(state["python"], "ready")
        self.assertRegex(str(state["pythonVersion"]), r"^\d+\.\d+\.\d+")

    def test_delete_moves_managed_session_to_trash(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            session = root / "data" / "sessions" / "demo"
            session.mkdir(parents=True)
            (session / "media.mp4").write_bytes(b"video")
            context = JobContext(
                {"data_root": str(root / "data")},
                lambda _value, _message: None,
            )
            result = delete_local_item(
                {"item_id": "item-1", "local_path": str(session)}, context
            )
            self.assertFalse(session.exists())
            trash_path = Path(result["trash_path"])
            self.assertTrue(trash_path.is_dir())
            self.assertEqual(trash_path.parent, root / "data" / "trash")

    def test_upload_always_uses_fixed_private_repository(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            session = root / "data" / "sessions" / "demo"
            session.mkdir(parents=True)
            (session / "media.mp4").write_bytes(b"video")
            progress: list[tuple[float, str, dict[str, object] | None]] = []
            context = JobContext(
                {
                    "data_root": str(root / "data"),
                    "_modelscope_token": "test-secret",
                },
                lambda value, message, metrics=None: progress.append(
                    (value, message, metrics)
                ),
            )
            with patch("modelscope_hub.HubApi") as hub_api:
                result = upload_item(
                    {
                        "item_id": "item-1",
                        "local_path": str(session),
                        "dataset_name": "demo",
                        "repo_id": "attacker/other-repo",
                    },
                    context,
                )
            self.assertEqual(result["repo_id"], FIXED_MODELSCOPE_REPO_ID)
            call = hub_api.return_value.upload_folder.call_args
            self.assertEqual(call.args[0], FIXED_MODELSCOPE_REPO_ID)
            self.assertEqual(call.args[1], "dataset")
            self.assertEqual(call.kwargs["path_in_repo"], "sessions/demo")
            self.assertTrue(call.kwargs["use_cache"])
            self.assertEqual(call.kwargs["max_workers"], 8)
            self.assertEqual(progress[-1][2]["phase"], "completed")

    def test_upload_progress_aggregates_parallel_byte_streams(self) -> None:
        progress: list[tuple[float, str, dict[str, object] | None]] = []
        context = JobContext(
            {},
            lambda value, message, metrics=None: progress.append(
                (value, message, metrics)
            ),
        )
        tracker = _UploadProgressTracker(context, 200, 2, 8)
        first = tracker.tqdm(total=100, unit="B", desc="first")
        second = tracker.tqdm(total=100, unit="B", desc="second")
        first.update(50)
        second.update(100)
        second.close()

        metrics = progress[-1][2]
        self.assertIsNotNone(metrics)
        self.assertEqual(metrics["transferredBytes"], 150)
        self.assertEqual(metrics["totalBytes"], 200)
        self.assertGreater(progress[-1][0], 0.7)

    def test_bundled_tool_is_preferred_over_path(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ffmpeg = root / "tools" / "ffmpeg" / "ffmpeg"
            ffmpeg.parent.mkdir(parents=True)
            ffmpeg.write_bytes(b"binary")
            with patch.dict(
                "os.environ", {"OPERATOR_COLLECTOR_HOME": str(root)}, clear=False
            ):
                self.assertEqual(find_tool({}, "ffmpeg"), str(ffmpeg))


if __name__ == "__main__":
    unittest.main()
