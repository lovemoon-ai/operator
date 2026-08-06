# MemWorld Generated Frames to Quest Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Send MemWorld-generated JPEG frames to Quest over the existing PINF channel, while sending nothing before the first model result.

**Architecture:** Keep skeleton rendering exclusively for model conditioning and the browser dashboard. Change the existing Quest preview loop to select the current generated frame from `DashboardState`, then wrap it with the latest Pose identifiers so the Quest freshness guard accepts it.

**Tech Stack:** Python 3.10, asyncio, unittest, WebSockets, existing PINF binary protocol

---

### Task 1: Lock the Quest output behavior with an end-to-end regression test

**Files:**
- Modify: `server/tests/test_memworld_e2e.py`

- [ ] **Step 1: Make the fake worker wait before publishing its output**

Add an `allow_worker_output = asyncio.Event()` next to `worker_received`. In
`fake_worker`, wait for this event after `chunk.started` and before sending
`chunk.output`.

- [ ] **Step 2: Assert no PINF image is sent before model output**

After enough Pose messages have been sent to create the first chunk, attempt a
short Quest receive while the fake worker is blocked:

```python
with self.assertRaises(asyncio.TimeoutError):
    await asyncio.wait_for(quest.recv(), timeout=0.15)
```

This must fail on the old implementation because it sends skeleton JPEGs.

- [ ] **Step 3: Assert the first PINF after worker output is generated**

Release `allow_worker_output`, receive the next binary PINF packet, decode it,
and assert:

```python
self.assertIn(pinf.jpeg, output_frames)
self.assertEqual(pinf.frame_id, latest_pose_frame_id)
self.assertEqual(pinf.capture_time_ns, latest_pose_capture_time_ns)
```

- [ ] **Step 4: Run the regression test and verify RED**

Run:

```bash
server/.venv/bin/python -m unittest \
  server.tests.test_memworld_e2e.MemWorldEndToEndTests.test_pose_to_pinf_chunk_worker_and_dashboard -v
```

Expected: FAIL because a skeleton PINF packet arrives before the worker output.

### Task 2: Switch the existing Quest preview loop to model playback

**Files:**
- Modify: `server/memworld_gateway.py`
- Modify: `docs/tutorials/quest-memworld-live-demo.md`

- [ ] **Step 1: Change only the preview loop source**

Change the signature to:

```python
async def preview_loop(
    connection: Any,
    state: SessionState,
    dashboard: DashboardState,
) -> None:
```

On every approximately 8.89 Hz tick, require a fresh latest Pose, call
`dashboard.model_frame()`, skip the send if it returns empty bytes, and call
`pack_image_frame` with the latest Pose `frame_id/capture_time_ns` plus the
generated JPEG.

- [ ] **Step 2: Pass DashboardState from the session task wiring**

Replace:

```python
asyncio.create_task(preview_loop(connection, state))
```

with:

```python
asyncio.create_task(preview_loop(connection, state, dashboard))
```

- [ ] **Step 3: Update the tutorial wording**

State that Quest remains black before the first worker result, then displays
generated JPEGs at about 8.89 Hz. Keep the browser skeleton preview documented
as diagnostics only.

- [ ] **Step 4: Verify GREEN and all regressions**

Run:

```bash
server/.venv/bin/python -m unittest discover -s server/tests -v
bash -n run_quest_memworld.sh run_memworld_direct_dmd1000_worker.sh
```

Expected: all Operator tests pass and both scripts have valid Bash syntax.

No Git commit is created; changes remain local as requested.
