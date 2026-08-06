# MemWorld Live JPEG Dashboard Design

## Goal

Remove MP4 generation from the persistent MemWorld live Demo and display each
33-frame model result in the browser as a 10 Hz JPEG image sequence. Favor the
newest completed model result over uninterrupted playback of an older result.

## Worker output

`EgoQuestRuntime.infer_live_chunk()` already receives the generated result as 33
PIL images. It will keep the final image as the next model anchor, encode every
image to a 640×352 JPEG at quality 88, and package the 33 JPEG files into an
in-memory ZIP. ZIP entries use deterministic names:

```text
frames/000.jpg
...
frames/032.jpg
```

JPEG data is already compressed, so ZIP uses stored entries rather than applying
another compression pass. The live result is never written as MP4 and does not
call `save_video()`. The existing non-live/batch inference path continues to
produce MP4 and is outside this change.

The worker sends one atomic binary ZIP after `chunk.output`. Metadata declares:

- `frame_count=33`
- `fps=10.0`
- `frame_format=jpeg`
- `mime_type=application/vnd.operator.memworld-frames+zip`
- `byte_length` equal to the ZIP payload size

## Operator validation

The Operator worker client accepts only the live JPEG-sequence MIME type,
validates the declared byte length and frame count, and unpacks exactly
`frames/000.jpg` through `frames/032.jpg`. Missing, additional, empty, or
non-JPEG frames reject the result without updating the dashboard.

The validated result contains an immutable tuple of 33 JPEG byte strings instead
of an MP4 payload.

## Latest-first playback

The dashboard stores one active model sequence. When a new completed chunk
arrives, it immediately replaces the active sequence and resets playback to frame
0, even if the previous sequence has not finished. There is no model-output
pending buffer.

At 10 Hz, frame index is derived from monotonic elapsed time:

```text
index = min(floor(elapsed_seconds × 10), 32)
```

If no newer chunk arrives after 3.3 seconds, the dashboard freezes on frame 32.
It does not loop stale motion. Input scheduling remains unchanged: one running
model chunk plus one replaceable pending input chunk.

Dashboard status exposes:

- `output_chunk_id`
- `playing_chunk_id`
- `model_frame_index`
- `model_frame_count`
- `model_playback_fps`
- `inference_ms`
- `jpeg_encode_ms`
- `frame_zip_bytes`
- `frame_zip_receive_ms`
- `frame_zip_unpack_ms`

Because every new result becomes active immediately, `output_chunk_id` and
`playing_chunk_id` identify the same chunk.

`jpeg_encode_ms` measures Worker JPEG encoding and ZIP construction.
`frame_zip_receive_ms` measures the Operator wait from the output metadata to
the complete WebSocket binary message, and therefore includes loopback/network
transfer plus event-loop scheduling. `frame_zip_unpack_ms` measures strict ZIP
validation and extraction. Operator prints the same values in one
`MEMWORLD_OUTPUT` line for every completed chunk.

## Browser behavior

The dashboard replaces the `<video src="/model.mp4">` element with
`<img id="model" src="/model.jpg">`. A dedicated 100 ms browser timer refreshes
`/model.jpg` with a cache-busting query parameter. The existing 500 ms status
timer remains separate, so diagnostic JSON does not need to be requested at 10
Hz.

`/model.jpg` returns the active frame with `Content-Type: image/jpeg` and
`Cache-Control: no-store`. Before the first model result it returns HTTP 404.
`/model.mp4` is removed.

## Error and interruption behavior

- An invalid ZIP leaves the currently displayed sequence unchanged.
- Worker disconnection leaves the last active sequence frozen at its last frame.
- A new Quest session may replace the displayed result only after its first
  valid model output arrives.
- A browser refresh resumes at the frame implied by server monotonic time; the
  browser does not own playback state.

## Live startup warmup

The worker performs exactly two full live-path warmup inferences before sending
the first `session.ready` event in a worker process. The warmups use the real
session's resolution, frame count, inference steps, CFG, cached prompt
embeddings, and static-memory tensors, with synthetic identity camera poses and
blank 640×352 keypoint images.

Warmup runs use a separate `LiveRuntimeSession`. Their generated images are
discarded, and they cannot advance the real session's chunk index, input anchor,
or history. Later Quest sessions in the same worker process reuse the warmed
model and do not run warmup again.

`session.ready` reports `warmup_runs`, `warmup_each_ms`, `warmup_ms`, and
`warmup_performed_now`. A warmup failure produces `session.failed` instead of
starting a partially warmed live session.

## Verification

- Unit tests first prove JPEG ZIP encoding, metadata, strict unpacking, 10 Hz
  frame selection, immediate latest-chunk replacement, and final-frame freeze.
- The live protocol integration test proves a fake 33-frame ZIP reaches
  `DashboardState` without any MP4.
- Dashboard HTML tests prove `/model.jpg` and the 100 ms image timer are present
  while `/model.mp4` and `<video>` are absent.
- Existing 10 Hz pose/chunk scheduling tests remain green.
- Warmup tests prove two isolated runs occur before the first ready event and
  that later sessions in the same process do not repeat them.

## Non-goals

- Sending generated model frames to Quest.
- Streaming individual frames before the complete model chunk is returned.
- Changing model inference, the 33-frame chunk size, four-step inference, or
  CFG 1.0.
