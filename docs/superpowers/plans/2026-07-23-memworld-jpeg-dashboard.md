# MemWorld Live JPEG Dashboard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the persistent live Demo's MP4 result with an atomic 33-JPEG sequence and display the newest completed chunk in the browser at 10 Hz.

**Architecture:** MemWorld encodes the 33 generated PIL frames to an in-memory, stored ZIP and sends it through the existing live WebSocket. Operator strictly validates and unpacks the sequence, immediately replaces the current dashboard sequence, and serves the monotonic-time-selected frame from `/model.jpg`; batch inference keeps its existing MP4 path.

**Tech Stack:** Python 3.10, asyncio, WebSockets, Pillow, zipfile, unittest, browser JavaScript

---

### Task 1: Encode live model frames without MP4

**Files:**
- Create: `/home/evophys/code/MemWorld/deploy/egoquest_ws/live_frames.py`
- Create: `/home/evophys/code/MemWorld/deploy/egoquest_ws/tests/test_live_frames.py`

- [ ] **Step 1: Write the failing encoder tests**

Create tests that build 33 `640×352` PIL images, call
`encode_jpeg_sequence(images)`, and assert:

```python
self.assertEqual(names, [f"frames/{index:03d}.jpg" for index in range(33)])
self.assertEqual(archive.getinfo(names[0]).compress_type, zipfile.ZIP_STORED)
self.assertEqual(Image.open(io.BytesIO(archive.read(names[0]))).size, (640, 352))
```

Also assert 32 images and a wrong-sized image raise `ValueError`.

- [ ] **Step 2: Run the encoder tests and verify RED**

Run:

```bash
cd /home/evophys/code/MemWorld
conda run -n memworld-egoquest python -m unittest \
  deploy.egoquest_ws.tests.test_live_frames -v
```

Expected: import failure because `live_frames.py` does not exist.

- [ ] **Step 3: Implement the focused frame-sequence encoder**

Define:

```python
FRAME_COUNT = 33
FRAME_SIZE = (640, 352)
JPEG_QUALITY = 88
LIVE_FRAME_MIME_TYPE = "application/vnd.operator.memworld-frames+zip"

def encode_jpeg_sequence(images) -> bytes:
    frames = tuple(images)
    if len(frames) != FRAME_COUNT:
        raise ValueError(...)
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_STORED) as archive:
        for index, image in enumerate(frames):
            rgb = image.convert("RGB")
            if rgb.size != FRAME_SIZE:
                raise ValueError(...)
            encoded = io.BytesIO()
            rgb.save(encoded, format="JPEG", quality=JPEG_QUALITY)
            archive.writestr(f"frames/{index:03d}.jpg", encoded.getvalue())
    return output.getvalue()
```

- [ ] **Step 4: Run the encoder tests and verify GREEN**

Run the command from Step 2. Expected: all encoder tests pass.

### Task 2: Change the MemWorld live protocol payload

**Files:**
- Modify: `/home/evophys/code/MemWorld/deploy/egoquest_ws/raw_input_adapter.py`
- Modify: `/home/evophys/code/MemWorld/deploy/egoquest_ws/server.py`
- Modify: `/home/evophys/code/MemWorld/deploy/egoquest_ws/tests/test_live_session.py`

- [ ] **Step 1: Change the live protocol test first**

Replace the fake live MP4 with a `LiveFrameChunk(payload=b"fake-frame-zip")`.
Assert `chunk.output` contains:

```python
self.assertEqual(output["frame_count"], 33)
self.assertEqual(output["frame_format"], "jpeg")
self.assertEqual(
    output["mime_type"],
    "application/vnd.operator.memworld-frames+zip",
)
self.assertIn(b"fake-frame-zip", sent)
```

Add a source assertion that `infer_live_chunk` calls
`encode_jpeg_sequence(video)` and does not contain `save_video`.

- [ ] **Step 2: Run the live-session tests and verify RED**

Run:

```bash
conda run -n memworld-egoquest python -m unittest \
  deploy.egoquest_ws.tests.test_live_session -v
```

Expected: failure because `LiveFrameChunk` and JPEG metadata do not exist.

- [ ] **Step 3: Implement the live-only result type and runtime path**

Add:

```python
@dataclass(frozen=True)
class LiveFrameChunk:
    clip_index: int
    start_frame: int
    end_frame: int
    drop_first_frame: bool
    payload: bytes
```

Change `infer_live_chunk(session, chunk)` to retain the last generated frame as
the next anchor and return `LiveFrameChunk(payload=encode_jpeg_sequence(video))`.
Remove its `output_path`, directory creation, MP4 read, and live `save_video`
import. Do not change the batch `stream()` MP4 implementation.

- [ ] **Step 4: Send JPEG ZIP metadata from the live server**

Call `infer_live_chunk(state, chunk)` without an output path and send
`frame_format="jpeg"` plus `LIVE_FRAME_MIME_TYPE`. Preserve `fps`,
`drop_first_frame`, `inference_ms`, and `byte_length`.

- [ ] **Step 5: Run the MemWorld tests**

Run:

```bash
conda run -n memworld-egoquest python -m unittest \
  deploy.egoquest_ws.tests.test_live_frames \
  deploy.egoquest_ws.tests.test_live_session \
  deploy.egoquest_ws.tests.test_server_protocol -v
```

Expected: all tests pass and batch MP4 protocol tests remain green.

### Task 3: Validate and unpack JPEG sequences in Operator

**Files:**
- Create: `server/memworld_frame_sequence.py`
- Create: `server/tests/test_memworld_frame_sequence.py`
- Modify: `server/memworld_worker_client.py`
- Modify: `server/tests/test_memworld_gateway.py`

- [ ] **Step 1: Write strict unpacking tests**

Build an in-memory ZIP containing 33 minimal valid JPEG files and assert
`unpack_jpeg_sequence()` returns an immutable 33-frame tuple. Add tests for a
missing frame, an extra file, and non-JPEG bytes.

- [ ] **Step 2: Change worker-output tests first**

Pass metadata containing:

```python
{
    "type": "chunk.output",
    "chunk_id": 3,
    "frame_count": 33,
    "frame_format": "jpeg",
    "mime_type": LIVE_FRAME_MIME_TYPE,
    "byte_length": len(payload),
}
```

Assert `result.frames` contains 33 images and invalid MIME or byte length raises
`ValueError`.

- [ ] **Step 3: Run Operator protocol tests and verify RED**

Run:

```bash
cd /home/evophys/code/operator
server/.venv/bin/python -m unittest \
  server.tests.test_memworld_frame_sequence \
  server.tests.test_memworld_gateway -v
```

Expected: failures because the unpacker and `WorkerResult.frames` do not exist.

- [ ] **Step 4: Implement the strict unpacker**

Define the same MIME type and deterministic names. Reject a ZIP unless its
`namelist()` exactly equals the 33 expected names. Reject empty frames and bytes
that do not begin with JPEG SOI (`ff d8`) and end with JPEG EOI (`ff d9`).

- [ ] **Step 5: Update WorkerResult and live client**

Replace `payload: bytes` with `frames: tuple[bytes, ...]`. Validate MIME type,
`frame_format`, `frame_count`, `byte_length`, then call
`unpack_jpeg_sequence(payload)`. Rename live variables and errors from MP4 to
frame ZIP.

- [ ] **Step 6: Run Operator protocol tests and verify GREEN**

Run the command from Step 3. Expected: all tests pass.

### Task 4: Serve the latest sequence as a 10 Hz image

**Files:**
- Modify: `server/memworld_gateway.py`
- Modify: `server/tests/test_memworld_gateway.py`

- [ ] **Step 1: Write latest-first playback tests**

Create 33 distinguishable byte frames. Start chunk 1 at time 100.0 and assert:

```python
self.assertEqual(state.model_frame(now=100.00), frames_1[0])
self.assertEqual(state.model_frame(now=100.19), frames_1[1])
self.assertEqual(state.model_frame(now=103.30), frames_1[32])
```

Update chunk 2 at time 101.0 and assert it immediately returns
`frames_2[0]`, proving the unfinished first chunk was discarded. Assert status
reports chunk 2, frame index 0, frame count 33, and playback FPS 10.

- [ ] **Step 2: Change dashboard HTML tests first**

Assert the page contains `/model.jpg`, an `<img id="model">`, and a 100 ms model
refresh timer. Assert `/model.mp4` and `<video` are absent.

- [ ] **Step 3: Run gateway tests and verify RED**

Run:

```bash
server/.venv/bin/python -m unittest server.tests.test_memworld_gateway -v
```

Expected: failures because the state and page still expose MP4.

- [ ] **Step 4: Implement latest-first DashboardState**

Store one active tuple, start time, and playback FPS. `update_model_frames()`
atomically replaces all active state. `model_frame(now=None)` computes:

```python
index = min(int(max(0.0, now - started_at) * playback_fps), len(frames) - 1)
```

and updates status. `status_json()` refreshes the derived frame index before
serializing.

- [ ] **Step 5: Replace the HTTP and browser video path**

Serve `/model.jpg` as `image/jpeg`; remove `/model.mp4`. Replace `<video>` with
the model `<img>`. Keep status polling at 500 ms and add a separate function
called every 100 ms that appends `Date.now()` to `/model.jpg`.

- [ ] **Step 6: Connect worker results to frame playback**

Change `_on_worker_result()` to pass `result.frames`, chunk metadata, and
`PLAYBACK_FPS` to `update_model_frames()`.

- [ ] **Step 7: Run gateway tests and verify GREEN**

Run the command from Step 3. Expected: all tests pass.

### Task 5: Verify the complete live path and update documentation

**Files:**
- Modify: `server/tests/test_memworld_e2e.py`
- Modify: `docs/tutorials/quest-memworld-live-demo.md`

- [ ] **Step 1: Change the E2E fake worker first**

Send a valid 33-frame ZIP and JPEG metadata. Assert the dashboard returns the
first JPEG from `model_frame()` and status reports 33 frames, 10 Hz, and the
received chunk ID.

- [ ] **Step 2: Run E2E and verify RED**

Run:

```bash
server/.venv/bin/python -m unittest \
  server.tests.test_memworld_e2e.MemWorldEndToEndTests.test_pose_to_pinf_chunk_worker_and_dashboard -v
```

Expected: failure while the fake worker or assertion still uses MP4.

- [ ] **Step 3: Complete the E2E test and documentation**

Document that live results are 33 JPEGs, the browser selects a frame at 10 Hz,
new results interrupt old playback immediately, and no live MP4 is encoded or
written. Remove statements that the dashboard shows a model video.

- [ ] **Step 4: Run all related remote tests**

Operator:

```bash
server/.venv/bin/python -m unittest \
  server.tests.test_memworld_frame_sequence \
  server.tests.test_memworld_gateway \
  server.tests.test_memworld_chunks \
  server.tests.test_memworld_e2e -v
```

MemWorld:

```bash
conda run -n memworld-egoquest python -m unittest \
  deploy.egoquest_ws.tests.test_live_frames \
  deploy.egoquest_ws.tests.test_live_session \
  deploy.egoquest_ws.tests.test_server_protocol -v
```

Expected: all tests pass.

- [ ] **Step 5: Audit uncommitted scope**

Inspect both repositories with `git status --short` and targeted source reads.
Confirm the live Demo contains no `/model.mp4`, live `video/mp4`, or live
`save_video()` path. Do not stage, commit, or push.

### Task 6: Warm the persistent live inference path

**Files:**
- Modify: `/home/evophys/code/MemWorld/deploy/egoquest_ws/raw_input_adapter.py`
- Modify: `/home/evophys/code/MemWorld/deploy/egoquest_ws/server.py`
- Create: `/home/evophys/code/MemWorld/deploy/egoquest_ws/tests/test_live_warmup.py`
- Modify: `/home/evophys/code/MemWorld/deploy/egoquest_ws/tests/test_live_session.py`

- [x] **Step 1: Write failing isolation and server-lifecycle tests**

Assert two calls use one temporary runtime session, preserve the real session
anchor and chunk index, expose timing metadata, and run only once per worker.

- [x] **Step 2: Implement isolated two-run warmup**

Before the first `session.ready`, run two 33-frame inferences with identity
camera transforms and blank keypoint frames. Reuse the requested 640×352
resolution, steps, CFG, prompt embeddings, and static memory, but discard all
generated output and temporary history.

- [x] **Step 3: Report and verify timings**

Return per-run and total timing in `session.ready`, log the same values, and
verify against the real model. The 2026-07-23 RTX 4090 check measured 3979.9 ms
and 3011.0 ms; a second session skipped warmup and reached ready in 48.9 ms.
