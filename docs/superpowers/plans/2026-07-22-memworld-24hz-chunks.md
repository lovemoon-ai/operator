# MemWorld 24 Hz Chunk Timing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Change the 33-frame live MemWorld input from 30 Hz to 24 Hz and measure current real-model throughput with the default 20 inference steps.

**Architecture:** A single `MODEL_FPS = 24` value drives Operator projection scheduling, worker session metadata, dashboard diagnostics, and MemWorld validation/output encoding. Operator emits consecutive non-overlapping 33-frame chunks every 1.375 seconds; the 20 Hz Quest preview remains independent. A real benchmark reports chunk latency, generated-frame throughput, real-time factor, and chunks per minute.

**Tech Stack:** Python 3.10, asyncio/websockets, unittest, NumPy, Pillow, MemWorld/PyTorch/WanVideo.

---

The existing Operator checkout is detached and both repositories contain unrelated work. Do not commit or clean unrelated files; edit and verify only the paths below.

### Task 1: Lock Operator model sampling to 24 Hz

**Files:**
- Modify: `server/tests/test_memworld_gateway.py`
- Modify: `server/memworld_gateway.py`

- [ ] **Step 1: Write the failing timing contract**

```python
def test_model_clock_and_session_use_24_hz(self):
    self.assertEqual(memworld_gateway.MODEL_FPS, 24)
    self.assertEqual(memworld_gateway.PROJECTION_HZ, 24.0)
    self.assertEqual(memworld_gateway.FRAMES_PER_CHUNK, 33)
    self.assertAlmostEqual(
        memworld_gateway.FRAMES_PER_CHUNK / memworld_gateway.MODEL_FPS,
        1.375,
    )
```

Extend the existing worker-session source assertion so `session.start` and dashboard `projection_hz` both derive from `MODEL_FPS`.

- [ ] **Step 2: Verify RED**

Run:

```bash
cd /home/evophys/code/operator
server/.venv/bin/python -m unittest server.tests.test_memworld_gateway -v
```

Expected: FAIL because `MODEL_FPS` is missing and `PROJECTION_HZ` is 30.

- [ ] **Step 3: Implement the shared timing constants**

```python
MODEL_FPS = 24
FRAMES_PER_CHUNK = 33
PROJECTION_HZ = float(MODEL_FPS)
CHUNK_DURATION_SECONDS = FRAMES_PER_CHUNK / MODEL_FPS
```

Use these constants for the projection loop, `session.start`, status metadata, and window construction. Make the 33-frame buffer clear after each emitted chunk so chunk boundaries are 1-33, 34-66, and so on rather than overlapping every frame.

- [ ] **Step 4: Verify GREEN**

Run the targeted test and expect all cases to pass.

### Task 2: Make MemWorld accept and encode 24 Hz live sessions

**Files in `/home/evophys/code/MemWorld`:**
- Modify: `deploy/egoquest_ws/tests/test_live_session.py`
- Modify: `deploy/egoquest_ws/live_session.py`

- [ ] **Step 1: Write the failing protocol test**

```python
def test_live_session_requires_24_fps(self):
    payload = make_session_start(fps=24)
    config = parse_live_session_start(payload, self.project_root)
    self.assertEqual(config.fps, 24)
    with self.assertRaisesRegex(ValueError, "fps=24"):
        parse_live_session_start(make_session_start(fps=30), self.project_root)
```

- [ ] **Step 2: Verify RED**

Run:

```bash
cd /home/evophys/code/MemWorld
conda run -n memworld-egoquest python -m unittest deploy.egoquest_ws.tests.test_live_session -v
```

Expected: FAIL because the live protocol still requires 30 fps.

- [ ] **Step 3: Change the live protocol constant**

Set `FPS = 24` and update the validation message. Output MP4 already uses `config.fps`, so no separate encoder rate is introduced.

- [ ] **Step 4: Verify GREEN**

Run the targeted test and then the full MemWorld WebSocket test suite.

### Task 3: Verify the integrated path and benchmark the model

**Files:**
- Modify: `server/tests/test_memworld_e2e.py`
- Modify: `docs/tutorials/quest-memworld-live-demo.md`

- [ ] **Step 1: Require 24 fps in the end-to-end fake worker**

Assert that `session.start.fps == 24`, that the ZIP still contains exactly 33 frames, and that returned dashboard metadata reports 24 fps.

- [ ] **Step 2: Run all Operator tests**
