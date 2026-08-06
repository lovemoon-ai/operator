# MemWorld 10 Hz Pose Sampling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Sample the latest Quest pose into 33-frame MemWorld chunks at 10 Hz and keep 10 Hz input and playback metadata consistent across Operator and MemWorld.

**Architecture:** Quest pose reception remains near 90 Hz, while Operator's projection loop is the authoritative 10 Hz model clock. Operator sends the same clock to MemWorld, whose live protocol accepts 10 Hz sessions; the latest-only pending scheduler remains unchanged and immediately starts available work after each output.

**Tech Stack:** Python 3.10, asyncio, unittest, WebSockets, Pillow

---

### Task 1: Lock the Operator model clock to 10 Hz

**Files:**
- Modify: `server/tests/test_memworld_gateway.py`
- Modify: `server/memworld_gateway.py`

- [ ] **Step 1: Change the timing test first**

Replace the 24 Hz expectation with:

```python
def test_model_clock_and_session_use_10_hz(self):
    self.assertEqual(memworld_gateway.MODEL_FPS, 10)
    self.assertEqual(memworld_gateway.PROJECTION_HZ, 10.0)
    self.assertEqual(memworld_gateway.PREVIEW_HZ, 10.0)
    self.assertEqual(memworld_gateway.PLAYBACK_FPS, 10.0)
    self.assertEqual(memworld_gateway.FRAMES_PER_CHUNK, 33)
    self.assertAlmostEqual(memworld_gateway.CHUNK_DURATION_SECONDS, 3.3)
```

- [ ] **Step 2: Run the test and verify the expected failure**

Run:

```bash
server/.venv/bin/python -m unittest \
  server.tests.test_memworld_gateway.MemWorldGatewayTests.test_model_clock_and_session_use_10_hz
```

Expected: failure because `MODEL_FPS`, `PROJECTION_HZ`, and `PREVIEW_HZ` still
contain the old values.

- [ ] **Step 3: Implement the 10 Hz model and preview clocks**

Set:

```python
MODEL_FPS = 10
PLAYBACK_FPS = 10.0
FRAMES_PER_CHUNK = 33
PROJECTION_HZ = float(MODEL_FPS)
CHUNK_DURATION_SECONDS = FRAMES_PER_CHUNK / MODEL_FPS
PREVIEW_HZ = 10.0
```

- [ ] **Step 4: Expose effective model sampling in statistics**

Add `model_sample_count` to `SessionState`, increment it after a projection is
successfully encoded and inserted into the model window, return
`model_sample_hz` from `stats_if_due`, and reset the counter with the other
one-second counters.

- [ ] **Step 5: Run the Operator gateway tests**

Run:

```bash
server/.venv/bin/python -m unittest server.tests.test_memworld_gateway -v
```

Expected: all tests pass.

### Task 2: Make the MemWorld live protocol accept 10 Hz

**Files:**
- Modify: `/home/evophys/code/MemWorld/deploy/egoquest_ws/tests/test_live_session.py`
- Modify: `/home/evophys/code/MemWorld/deploy/egoquest_ws/live_session.py`

- [ ] **Step 1: Change the live-session fixtures and assertions first**

Change valid live session payloads from `"fps": 24` to `"fps": 10`, rename
`test_live_session_fps_is_24` to `test_live_session_fps_is_10`, and update the
invalid-session error assertion to require `fps=10`.

- [ ] **Step 2: Run the test and verify the expected failure**

Run:

```bash
conda run -n memworld python -m unittest \
  deploy.egoquest_ws.tests.test_live_session -v
```

Expected: valid 10 Hz session tests fail because `live_session.FPS` is still 24.

- [ ] **Step 3: Implement the matching protocol contract**

Set:

```python
FPS = 10
```

Update the validation error to:

```python
raise ValueError(
    "live sessions require width=640 height=352 fps=10 frames_per_chunk=33"
)
```

- [ ] **Step 4: Run the MemWorld live-session tests**

Run:

```bash
conda run -n memworld python -m unittest \
  deploy.egoquest_ws.tests.test_live_session -v
```

Expected: all tests pass.

### Task 3: Document and verify the integrated timing

**Files:**
- Modify: `docs/tutorials/quest-memworld-live-demo.md`
- Verify: `server/memworld_worker_client.py`
- Verify: `server/tests/test_memworld_chunks.py`
- Verify: `server/tests/test_memworld_e2e.py`

- [ ] **Step 1: Update the operating guide**

State that native pose reception remains near 90 Hz, effective model sampling
and skeleton preview are 10 Hz, a 33-frame chunk covers 3.3 seconds, and
10 Hz playback also lasts 3.3 seconds.

- [ ] **Step 2: Verify scheduler behavior remains immediate**

Confirm the worker loop calls `slot.finish(chunk.chunk_id)` in `finally`, then
returns directly to `slot.start_next()`. The only 10 ms sleep must remain in the
`chunk is None` branch.

- [ ] **Step 3: Run the related Operator suite**

Run:

```bash
server/.venv/bin/python -m unittest \
  server.tests.test_memworld_gateway \
  server.tests.test_memworld_chunks \
  server.tests.test_memworld_e2e -v
```

Expected: all related tests pass.

- [ ] **Step 4: Inspect the uncommitted changes**

Run:

```bash
git diff -- server/memworld_gateway.py server/tests/test_memworld_gateway.py \
  docs/tutorials/quest-memworld-live-demo.md
```

and in MemWorld:

```bash
git diff -- deploy/egoquest_ws/live_session.py \
  deploy/egoquest_ws/tests/test_live_session.py
```

Expected: only the approved 10 Hz timing, statistics, tests, and documentation
changes appear. Do not commit, stage, or push either repository.
