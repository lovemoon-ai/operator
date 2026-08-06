# MemWorld Quest Live Demo Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a `memWorld` Quest mode that sends uncapped head/hand poses, uses metadata-only left-camera calibration to generate 640x352 hand conditioning, previews it on Quest at 20 Hz, and runs latest-only MemWorld chunks for browser visualization.

**Architecture:** Quest connects only to an Operator gateway using the existing QR, JSON pose, and PINF image patterns. Operator owns projection, rate conversion, dashboard state, and a one-running/one-pending scheduler; it sends compact binary ZIP chunks over a localhost WebSocket to a separate MemWorld GPU worker.

**Tech Stack:** Godot 4.5 GDScript, Kotlin Camera2 Godot plugin, Python 3.10 asyncio/websockets, NumPy, Pillow, qrcode, MemWorld/PyTorch/WanVideo.

---

The remote Operator checkout is detached and already contains unrelated uncommitted work. Implementation steps intentionally do not create commits or branches; every edit is restricted to the listed files and verified with targeted diffs.

### Task 1: Camera2 metadata-only calibration API

**Files:**
- Modify: `xr/android_plugin/questcapture/src/main/java/com/spatialmp4/questcapture/QuestCapturePlugin.kt`
- Modify: `xr/addons/quest_capture_android/api/XRCaptureProvider.gd`
- Test: `server/tests/test_memworld_quest_source.py`

- [ ] **Step 1: Add a failing source-contract test**

```python
def test_plugin_exposes_metadata_only_query():
    source = QUEST_PLUGIN.read_text(encoding="utf-8")
    assert "fun queryPassthroughCameraMetadataJson(eye: String): String" in source
    body = source.split("fun queryPassthroughCameraMetadataJson", 1)[1].split("@UsedByGodot", 1)[0]
    assert "openEyeCamera" not in body
    assert "ImageReader.newInstance" not in body
```

- [ ] **Step 2: Run the targeted test and confirm it fails**

Run: `server/.venv/bin/python -m unittest server.tests.test_memworld_quest_source -v`

Expected: FAIL because the metadata-only method and facade do not exist.

- [ ] **Step 3: Add the Kotlin query and typed GDScript facade**

The Kotlin method obtains `CameraManager`, calls the existing characteristic enumeration, selects `left`, and returns JSON with:

```json
{
  "ok": true,
  "metadata_only": true,
  "calibration_id": "<camera-id>:<width>x<height>",
  "selected_yuv_size": {"width": 1280, "height": 960},
  "lens_intrinsic_calibration": [0, 0, 0, 0, 0],
  "lens_distortion": [],
  "lens_pose_translation": [0, 0, 0],
  "lens_pose_rotation": [0, 0, 0, 1]
}
```

Errors return `{"ok":false,"error":"..."}`. The method must not call `ensureBackgroundThread`, `openEyeCamera`, or create a capture session. Add:

```gdscript
func query_passthrough_camera_metadata_json(eye: String = "left") -> String:
        if _plugin == null:
                return JSON.stringify({"ok": false, "error": "QuestCapturePlugin unavailable"})
        return str(_plugin.call("queryPassthroughCameraMetadataJson", eye))
```

- [ ] **Step 4: Re-run the source-contract test**

Expected: PASS.

### Task 2: Quest `memWorld` scene and transport

**Files:**
- Create: `xr/addons/memworld/memworld_client.gd`
- Create: `xr/scenes/memworld_app.gd`
- Create: `xr/scenes/memworld_app.tscn`
- Modify: `xr/scenes/mode_select.gd`
- Modify: `xr/scripts/i18n/localization.gd`
- Modify: `xr/export_presets.cfg`
- Test: `server/tests/test_memworld_quest_source.py`

- [ ] **Step 1: Extend the source test for the public mode and calibration hello**

```python
def test_memworld_client_sends_calibration_in_hello():
    source = MEMWORLD_CLIENT.read_text(encoding="utf-8")
    assert '"mode", "")) not in ["memWorld", "memworld", "mem_world"]' in source
    assert '"protocol": "operator.memworld.v1"' in source
    assert '"calibration": _calibration' in source
```

- [ ] **Step 2: Confirm the new assertions fail**

Run the same unittest command; expect missing-file failures.

- [ ] **Step 3: Implement the client and scene**

`MemWorldClient` copies the proven full-duplex behavior of
`PoseInferenceClient`, keeps uncapped `_send_pose()`, accepts all three QR
aliases, sends `operator.memworld.v1` plus calibration in `hello`, and parses
the unchanged PINF v1 binary frame.

`memworld_app.gd` follows `pose_inference_app.gd`, binds
`XRCaptureProvider`, queries left-camera metadata before opening the QR
scanner, injects it into the client, and never calls `start_cameras()`.

- [ ] **Step 4: Register the mode**

Add internal mode `memworld`, scene routing, launcher feature
`operator_launcher_card_memworld`, English/Chinese labels, and aliases
`memWorld`, `memworld`, and `mem_world`. The QR payload remains exactly
`"mode":"memWorld"`.

- [ ] **Step 5: Run source tests**

Expected: all source-contract tests pass.

### Task 3: Operator calibration, projection, and renderer

**Files:**
- Create: `server/memworld_geometry.py`
- Create: `server/tests/test_memworld_geometry.py`
- Modify: `server/requirements-pose-inference.txt`

- [ ] **Step 1: Write projection tests**

```python
def test_crop_adjusts_intrinsics_for_bottom_640x352():
    transformed = calibration.output_intrinsics()
    assert transformed.width == 640
    assert transformed.height == 352
    assert transformed.cy == calibration.scaled_cy - calibration.crop_top

def test_openxr_26_maps_to_memworld_21():
    points = map_openxr_hand(make_numbered_joints())
    assert points.source_indices == (1, 2, 3, 4, 5, 7, 8, 9, 10, 12, 13, 14, 15, 17, 18, 19, 20, 22, 23, 24, 25)
```

- [ ] **Step 2: Run tests and confirm missing-module failure**

Run: `server/.venv/bin/python -m unittest server.tests.test_memworld_geometry -v`.

- [ ] **Step 3: Implement focused geometry types**

Implement `CameraCalibration.from_json()`, normalized quaternion matrices,
`camera_c2w_from_pose()`, `memworld_c2w()`, 26-to-21 mapping, calibrated
projection, source-to-640x352 crop mapping, and Pillow skeleton rendering.
Invalid/non-finite/behind-camera joints remain absent rather than clamped.

- [ ] **Step 4: Run geometry tests**

Expected: mapping, transform, crop, invalid-depth, and 640x352 image tests pass.

### Task 4: Latest-only chunk protocol and scheduler

**Files:**
- Create: `server/memworld_chunks.py`
- Create: `server/tests/test_memworld_chunks.py`

- [ ] **Step 1: Write chunk tests**

```python
def test_zip_contains_c2ws_and_33_keypoint_frames():
    payload = pack_live_chunk(make_samples(33))
    with ZipFile(BytesIO(payload)) as archive:
        assert np.load(archive.open("c2ws.npy")).shape == (33, 4, 4)
        assert len([name for name in archive.namelist() if name.startswith("keypoints/")]) == 33

def test_pending_slot_keeps_only_newest_chunk():
    scheduler.submit(chunk_1)
    scheduler.submit(chunk_2)
    assert scheduler.take_pending().chunk_id == chunk_2.chunk_id
```

- [ ] **Step 2: Confirm tests fail, then implement**

Implement immutable projected samples, a 33-item rolling window, ZIP packing,
and a `LatestChunkSlot` with one running and one replaceable pending chunk.

- [ ] **Step 3: Run chunk tests**

Expected: all chunk serialization and replacement tests pass.

### Task 5: MemWorld live session protocol and runtime

**Files in `/home/evophys/code/MemWorld`:**
- Create: `deploy/egoquest_ws/live_session.py`
- Modify: `deploy/egoquest_ws/raw_input_adapter.py`
- Modify: `deploy/egoquest_ws/server.py`
- Create: `deploy/egoquest_ws/tests/test_live_session.py`
- Modify: `deploy/egoquest_ws/tests/test_server_protocol.py`

- [ ] **Step 1: Write live bundle and persistent protocol tests**

```python
def test_live_bundle_requires_33_c2ws_and_keypoints():
    chunk = parse_live_chunk(valid_live_bundle())
    assert chunk.c2ws.shape == (33, 4, 4)
    assert len(chunk.keypoint_frames) == 33

def test_session_start_accepts_multiple_chunks_on_one_socket():
    events = asyncio.run(exercise_live_session(two_chunks=True))
    assert [event["type"] for event in events] == [
        "session.ready", "chunk.started", "chunk.output",
        "chunk.started", "chunk.output",
    ]
```

- [ ] **Step 2: Confirm tests fail**

Run: `python -m unittest discover -s deploy/egoquest_ws/tests -p 'test_*.py' -v`.

- [ ] **Step 3: Implement validation and dispatch**

`live_session.py` safely extracts `manifest.json`, `c2ws.npy`, and exactly
33 numbered keypoint images. `server.py` dispatches first-message
`session.start` to a persistent loop while retaining the legacy
`infer.start` protocol unchanged.

- [ ] **Step 4: Add real-runtime live methods**

At session start, load the fixed initial/static image and encode static memory.
For each chunk call `WanVideoMemoryPipeline` with `keypoint_frames`,
`c2ws`, static memory, and the session's current anchor image. After inference,
set the last generated frame as the next anchor and return MP4. This keeps
temporal session state without retaining an unbounded pose/image history.

- [ ] **Step 5: Run all EgoQuest WebSocket tests**

Expected: legacy and live protocol tests pass.

### Task 6: Operator gateway, worker client, QR dashboard

**Files:**
- Create: `server/memworld_worker_client.py`
- Create: `server/memworld_gateway.py`
- Create: `server/tests/test_memworld_gateway.py`
