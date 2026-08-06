# Quest Unbounded Pose Logging Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Send Quest poses once per Godot process frame, measure per-component tracked FPS, and print one complete compact pose JSON sample per connection.

**Architecture:** The Quest WebSocket client removes only its artificial 20 Hz pose timer; placeholder JPEG output remains independently capped at 20 Hz. The Python service extends its per-connection statistics and owns a one-shot pose logger, preserving the existing latest-only inference queue.

**Tech Stack:** Godot 4.5 GDScript, Python 3.10, `unittest`, `websockets`

---

### Task 1: Server tracked-rate statistics and one-shot sample

**Files:**
- Modify: `server/tests/test_pose_inference_ws.py`
- Modify: `server/pose_inference_ws.py`

- [ ] **Step 1: Write failing tests for component FPS**

Update the existing statistics test to call:

```python
pose = {
    "frame_id": 8,
    "head": {"tracked": True},
    "left": {"tracking": True},
    "right": {"tracking": False},
}
stats.record_pose(128, pose)
```

Assert the snapshot contains:

```python
"head_tracked_fps": 1.0,
"left_hand_tracked_fps": 1.0,
"right_hand_tracked_fps": 0.0,
```

Also assert all three counters reset to `0.0` in the next empty window.

- [ ] **Step 2: Write a failing one-shot logging test**

Import `FirstPoseLogger`, call it twice with different full poses under
`patch("builtins.print")`, and assert print is called once. Split the printed
line after `POSE_SAMPLE `, parse it with `json.loads`, and assert the first
pose is preserved without private keys beginning with `_`.

- [ ] **Step 3: Run the focused tests and verify RED**

Run:

```bash
server/.venv/bin/python -m unittest   server.tests.test_pose_inference_ws.PoseInferenceServiceTests.test_connection_stats_reports_one_second_rates_and_resets_window   server.tests.test_pose_inference_ws.PoseInferenceServiceTests.test_first_pose_logger_prints_one_compact_complete_sample -v
```

Expected: FAIL because `record_pose` does not accept a pose object and
`FirstPoseLogger` does not exist.

- [ ] **Step 4: Implement the minimal server behavior**

Add three tracked counters to `ConnectionStats`. Change
`record_pose(byte_count, frame_id)` to `record_pose(byte_count, pose)`,
derive head from `pose["head"]["tracked"]` and hands from
`pose["left"|"right"]["tracking"]`, expose the three rates in snapshots, and
reset them after every window.

Add:

```python
class FirstPoseLogger:
    def __init__(self) -> None:
        self._logged = False

    def log(self, pose: dict[str, Any]) -> None:
        if self._logged:
            return
        public_pose = {
            key: value for key, value in pose.items() if not key.startswith("_")
        }
        print(
            "POSE_SAMPLE " + json.dumps(
                public_pose, separators=(",", ":"), ensure_ascii=False
            ),
            flush=True,
        )
        self._logged = True
```

Create one logger in `websocket_handler`, invoke it on the first authenticated
pose, and pass the pose object to `stats.record_pose`.

- [ ] **Step 5: Run the focused tests and verify GREEN**

Run the same two-test command. Expected: both tests PASS.

### Task 2: Remove the Quest pose-rate limiter

**Files:**
- Create: `server/tests/test_pose_inference_client_source.py`
- Modify: `xr/addons/pose-inference/pose_inference_client.gd`

- [ ] **Step 1: Write a failing source-contract test**

Create a Python `unittest` that reads the GDScript source and asserts:

```python
self.assertNotIn("SEND_INTERVAL_S", source)
self.assertNotIn("_send_accum", source)
self.assertRegex(
    source,
    r"if _state == WebSocketPeer\.STATE_OPEN:\s+"
    r"_drain_packets\(\)\s+_send_pose\(\)",
)
```

This repository has no GDScript unit-test runner, and project instructions
forbid desktop headless XR execution; this contract test guards the intended
frame-driven call site without running the XR project on desktop.

- [ ] **Step 2: Run the test and verify RED**

Run:

```bash
server/.venv/bin/python -m unittest   server.tests.test_pose_inference_client_source -v
```

Expected: FAIL because `SEND_INTERVAL_S` and `_send_accum` still exist.

- [ ] **Step 3: Implement frame-driven sending**

Delete `TARGET_HZ`, `SEND_INTERVAL_S`, and `_send_accum`. Replace the open
WebSocket branch with:

```gdscript
if _state == WebSocketPeer.STATE_OPEN:
        _drain_packets()
        _send_pose()
```

Do not alter `run_inference` or its 20 Hz image interval.

- [ ] **Step 4: Run the source-contract test and verify GREEN**

Run the same test command. Expected: PASS.

### Task 3: Keep the operator guide accurate and verify the baseline

**Files:**
- Modify: `docs/tutorials/quest-pose-inference.md`

- [ ] **Step 1: Update runtime and statistics documentation**

State that Quest sends one pose per Godot process frame with no artificial
client cap, while placeholder images remain 20 Hz. Document the three tracked
FPS fields and explain that exactly one `POSE_SAMPLE` compact full JSON object
is logged per connection.

- [ ] **Step 2: Run the complete remote server test suite**

Run:

```bash
server/.venv/bin/python -m unittest discover -s server/tests -v
```

Expected: all tests PASS with zero failures.

- [ ] **Step 3: Check patch hygiene and inspect scope**

Run:

```bash
git diff --check
git status --short
```

Expected: no whitespace errors. Only the planned files plus pre-existing user
changes appear. Do not commit: this remote checkout is a dirty detached HEAD,
and the user did not authorize history changes.

- [ ] **Step 4: Hand off runtime commands**

Do not restart the active service or install an APK. Provide the user with the
Quest build/install command, service restart command, QR URL, and
`journalctl -f` command so they can run the device test themselves.
