# MemWorld Quest Live Demo Design

## Goal

Add an Operator Quest mode named `memWorld` that uses live Quest head and hand
poses as MemWorld conditioning. The first version projects the hands into the
left passthrough camera image plane without capturing RGB/YUV frames, sends a
640x352 skeleton preview back to Quest, and displays MemWorld inference output
in a computer browser.

The existing QR-code connection flow remains the only user-facing connection
setup. The existing `pose_inference` mode remains unchanged.

## Scope

The first version:

- reads left-camera Camera2 metadata through `QuestCapturePlugin`;
- does not create an ImageReader or start camera capture;
- sends uncapped head and hand poses from Quest to Operator;
- maps the OpenXR 26-joint hands to the 21 landmarks used by MemWorld;
- projects those landmarks with real intrinsics and lens extrinsics;
- renders black-background 640x352 hand-skeleton frames;
- returns the latest skeleton frame to Quest at 20 Hz;
- resamples the latest pose state at 24 Hz into consecutive, non-overlapping 33-frame model chunks;
- runs MemWorld in a separate GPU process;
- shows skeleton, model output, rates, latency, and queue state in a browser;
- uses `/home/evophys/code/MemWorld/assets/egoquest_0717_013_scene_08.png`
  for both the initial RGB frame and the first static-memory frame.

Sending generated model frames back to Quest and capturing real passthrough RGB
are explicitly outside the first version.

## Architecture

The system has three independently recoverable parts:

1. The Quest `memWorld` scene handles QR connection, calibration discovery,
   uncapped pose transmission, and PINF skeleton display.
2. The Operator MemWorld gateway handles authentication, projection, rendering,
   rate conversion, latest-only chunk buffering, the browser dashboard, and the
   local worker connection.
3. The MemWorld GPU worker owns model loading, per-session inference state, and
   MP4 generation.

Quest communicates only with Operator. Operator connects to MemWorld over a
persistent WebSocket bound to `127.0.0.1`, so the GPU worker is not exposed on
the LAN. A slow or unavailable model worker must not stop pose reception or the
20 Hz Quest skeleton preview.

## Quest Mode and QR Connection

The public mode name is exactly `memWorld`. Mode selection accepts
`memWorld`, `memworld`, and `mem_world` as aliases but normalizes them to
`memWorld`.

The computer dashboard displays the QR code. Its payload contains:

```json
{
  "mode": "memWorld",
  "url": "ws://<computer-ip>:<port>/memworld",
  "token": "<ephemeral-token>"
}
```

Quest reuses the existing token validation and reconnect behavior. The token
remains valid for the lifetime of the gateway process.

## Calibration and Coordinate Transform

At connection startup, Quest calls a new metadata-only plugin method for the
left passthrough camera. The method enumerates Camera2 characteristics and
returns the actual YUV output size that the existing capture path would select,
intrinsic calibration, lens distortion when available, and lens pose
translation/rotation. It must not open a camera device or create a capture
session.

Each calibration packet has a `calibration_id`. Operator keeps the latest
valid packet for the session and records its ID on projected frames.

For each pose sample:

```text
T_world_camera = T_world_head * T_head_camera
P_camera = inverse(T_world_camera) * P_world_joint
```

One calibration adapter owns all Android Camera2, OpenXR, and MemWorld axis,
handedness, quaternion-order, and unit conversions. The projection layer never
duplicates those conversions. Points with invalid tracking, non-finite values,
or non-positive camera depth are not drawn.

The projection uses the reported source resolution, `fx`, `fy`, `cx`,
`cy`, skew, and lens distortion when the device reports a supported model.
Unsupported or absent distortion falls back to the pinhole model and is
reported in diagnostics.

## Image Transform

The source camera plane is resized with preserved aspect ratio to width 640.
The top is then cropped so the bottom 352 rows remain:

```text
scale = 640 / source_width
scaled_height = round(source_height * scale)
crop_top = scaled_height - 352
```

The transformed intrinsics are:

```text
fx' = fx * scale
fy' = fy * scale
cx' = cx * scale
cy' = cy * scale - crop_top
skew' = skew * scale
```

The selected Quest camera is expected to produce `scaled_height >= 352`. A
smaller result is treated as an invalid calibration rather than silently
changing the agreed crop.

The renderer draws the two 21-point hands and their standard landmark edges on
a black RGB image. Left and right hands use distinct colors. It preserves source
`frame_id`, `capture_time_ns`, and `calibration_id`.

## OpenXR Hand Mapping

The OpenXR 26-joint arrays are mapped as follows:

- wrist: 1 -> 0
- thumb: 2, 3, 4, 5 -> 1, 2, 3, 4
- index: 7, 8, 9, 10 -> 5, 6, 7, 8
- middle: 12, 13, 14, 15 -> 9, 10, 11, 12
- ring: 17, 18, 19, 20 -> 13, 14, 15, 16
- little: 22, 23, 24, 25 -> 17, 18, 19, 20

OpenXR palm joint 0 and metacarpals 6, 11, 16, and 21 are not passed to the
model landmark representation.

## Rates and Buffering

Quest transmits pose samples without an application-level rate limit. Operator
stores only the newest received sample.

Two independent clocks consume that state:

- a 20 Hz preview clock renders and sends the newest skeleton as the existing
  PINF JPEG format;
- a 24 Hz model clock records the newest valid c2w and skeleton into consecutive,
  non-overlapping 33-frame buffers.

Each complete chunk therefore covers `33 / 24 = 1.375` seconds of sampled
motion and a new chunk is produced every 1.375 seconds. Chunk timestamps remain
the source of truth for observed capture jitter.

The model scheduler has exactly two slots:

- `running_chunk`, which cannot be replaced while inference is active;
- `pending_chunk`, which is overwritten whenever a newer complete window is
  available.

There is no FIFO inference queue. When inference finishes, the worker receives
the newest pending window. Skipped-window counts are visible in diagnostics.

## Operator-to-MemWorld Protocol

Operator is a WebSocket client and MemWorld is a server on
`ws://127.0.0.1:8765`. Control messages are JSON. Large payloads are binary.

Operator sends one `session.start` message containing protocol version,
session ID, 640x352 dimensions, 24 input fps, 1.5 playback fps, 33 frames per
chunk, and the configured
initial/static-memory asset paths. MemWorld loads the fixed assets once and
keeps model state under that session ID.

For each input, Operator sends a `chunk.input` JSON message followed by a ZIP
payload containing:

- `manifest.json`;
- `c2ws.npy` with float32 shape `[33, 4, 4]`;
- `keypoints/000.png` through `keypoints/032.png`;
- optional `pose_debug.json`.

The worker replies with `chunk.output` JSON followed by MP4 bytes. The control
message contains the session and chunk IDs, frame count, output fps, inference
time, and `drop_first_frame`. Operator discards mismatched or stale outputs.

## Dashboard

The gateway serves one browser page containing the QR code, latest projected
skeleton, latest model video, connection health, and these measurements:

- Quest pose rate;
- pose-to-projection latency;
- Quest skeleton send rate;
- current 33-frame window fill;
- running, pending, and skipped chunk IDs/counts;
- worker inference time and output age.

## Inference Throughput Measurement

The benchmark uses one real 33-frame 640x352 chunk and the gateway's current
default of 20 inference steps. Report:

- wall-clock inference seconds per chunk;
- generated-frame throughput, `33 / inference_seconds`;
- real-time factor, `inference_seconds / 1.375`;
- sustainable chunk rate, `60 / inference_seconds`.

## Output Playback Rate

Input sampling and output playback have separate time bases:

- `fps=24` describes the captured pose/keypoint/camera trajectory samples;
- `playback_fps=1.5` controls only MP4 encoding and `chunk.output.fps`.

A 33-frame output therefore plays for `33 / 1.5 = 22` seconds. This closely
matches the measured 22.59-second average inference time without changing the
1.375-second physical motion represented by the input chunk.

The worker validates `0 < playback_fps <= fps`. Missing or invalid live-session
values are rejected rather than silently changing playback. The model still
returns the complete MP4 after chunk inference; this change does not make the
diffusion pipeline emit frames incrementally.
