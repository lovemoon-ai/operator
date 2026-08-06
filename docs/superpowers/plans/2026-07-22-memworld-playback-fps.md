# MemWorld Independent Playback FPS Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Preserve 24 Hz model input while encoding and advertising each 33-frame generated MP4 at 1.5 fps.

**Architecture:** Operator sends both `fps=24` and `playback_fps=1.5` in `session.start`. MemWorld validates the clocks separately, retains playback FPS in live runtime state, passes it to MP4 encoding, and reports it in `chunk.output.fps`.

**Tech Stack:** Python 3.10, unittest, asyncio/websockets, MemWorld/PyTorch/WanVideo.

---

Both repositories already contain unrelated direct changes. Do not commit, branch, or clean other files.

### Task 1: Operator playback-rate contract

**Files:**
- Modify: `server/tests/test_memworld_gateway.py`
- Modify: `server/tests/test_memworld_e2e.py`
- Modify: `server/memworld_gateway.py`

- [ ] **Step 1: Write failing tests**

```python
self.assertEqual(memworld_gateway.MODEL_FPS, 24)
self.assertEqual(memworld_gateway.PLAYBACK_FPS, 1.5)
self.assertEqual(start["fps"], 24)
self.assertEqual(start["playback_fps"], 1.5)
```

- [ ] **Step 2: Verify RED**

```bash
cd /home/evophys/code/operator
server/.venv/bin/python -m unittest server.tests.test_memworld_gateway server.tests.test_memworld_e2e -v
```

Expected: FAIL because the playback-rate constant and protocol field are missing.

- [ ] **Step 3: Implement the gateway field**

Add `PLAYBACK_FPS = 1.5`, send it in `session.start`, and expose it in ready diagnostics. Do not change `MODEL_FPS=24`, `PROJECTION_HZ=24`, or `PREVIEW_HZ=20`.

- [ ] **Step 4: Verify GREEN**

Re-run the targeted Operator tests and expect all cases to pass.

### Task 2: MemWorld playback clock

**Files in `/home/evophys/code/MemWorld`:**
- Modify: `deploy/egoquest_ws/tests/test_live_session.py`
- Modify: `deploy/egoquest_ws/live_session.py`
- Modify: `deploy/egoquest_ws/raw_input_adapter.py`
- Modify: `deploy/egoquest_ws/server.py`

- [ ] **Step 1: Write failing tests**

```python
config = parse_live_session_start(make_start(fps=24, playback_fps=1.5), root)
self.assertEqual(config.fps, 24)
self.assertEqual(config.playback_fps, 1.5)
```

Also reject `playback_fps <= 0` and `playback_fps > fps`. Require `session.ready.playback_fps == 1.5` and `chunk.output.fps == 1.5`.

- [ ] **Step 2: Verify RED**

```bash
cd /home/evophys/code/MemWorld
conda run -n memworld-egoquest python -m unittest discover -s deploy/egoquest_ws/tests -p 'test_live_session.py' -v
```

Expected: FAIL because playback FPS is not parsed, retained, encoded, or reported.

- [ ] **Step 3: Implement the separate playback clock**

Add `playback_fps: float` to `LiveSessionConfig` and `LiveRuntimeSession`. Validate `0 < playback_fps <= fps`. Encode with:

```python
save_video(video, str(output_path), fps=session.playback_fps, quality=5)
```

Report `fps=config.playback_fps` in `chunk.output`; keep `session.ready.fps=24` and add `session.ready.playback_fps=1.5`.

- [ ] **Step 4: Verify GREEN**

Re-run the targeted and full MemWorld WebSocket suites.

### Task 3: Integrated verification

- [ ] **Step 1: Run all Operator tests**

```bash
cd /home/evophys/code/operator
server/.venv/bin/python -m unittest discover -s server/tests -v
```

- [ ] **Step 2: Run all MemWorld tests**

```bash
cd /home/evophys/code/MemWorld
conda run -n memworld-egoquest python -m unittest discover -s deploy/egoquest_ws/tests -p 'test_*.py' -v
```

- [ ] **Step 3: Real-model smoke test**

Send one default 20-step 24 Hz/33-frame chunk with `playback_fps=1.5`. Verify `chunk.output.fps == 1.5`, a valid MP4 `ftyp` header, and duration near 22 seconds with `ffprobe`.

- [ ] **Step 4: Stop services**

Verify ports 8765, 63920, and 63921 have no listeners.
