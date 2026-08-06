# Matplotlib Quest Pose Visualization Design

Date: 2026-07-22
Status: Approved for implementation

## Summary

Replace the static placeholder image in `server/pose_inference_ws.py` with a headless Matplotlib 3D visualization of the newest Quest head and hand pose. The existing WebSocket, authentication, latest-pose buffering, 20 Hz scheduler, PINF binary framing, QR page, and statistics remain unchanged.

## Goals

- Render the latest accepted Quest pose as a 960x540 JPEG.
- Show the head position and forward direction.
- Show both hands as OpenXR 26-joint skeletons with distinct colors.
- Return changing images to Quest at the existing target of 20 Hz.
- Keep pose reception responsive while Matplotlib renders.
- Continue operating when a hand or individual joint is not tracked.

## Non-goals

- A desktop GUI window on the server.
- Photorealistic hands or a body mesh.
- Pose history, recording, or playback.
- Changing the Quest protocol or QR payload.
- Rendering faster than the existing 20 Hz image schedule.

## Architecture

A `MatplotlibPoseRenderer` class will live in `server/pose_inference_ws.py`. It owns one persistent Matplotlib Figure, Agg canvas, and 3D axes for a client connection. Agg is selected explicitly so the service works without an X server.

The first valid head position becomes the renderer origin. Subsequent poses are shown relative to that stable origin, which keeps the plot readable while preserving visible head and hand motion. Plot coordinates map XR `[x, y, z]` to `[x, -z, y]`, so the chart uses right, forward, and up axes.

The current `run_inference` loop keeps the newest pose behavior. Every 50 ms it renders the latest pose, packs the JPEG with `pack_image_frame`, and sends it through the existing connection.

## Visual Content

The frame contains:

- A green head marker.
- A short head-forward vector derived from the `[x, y, z, w]` quaternion.
- Left-hand joints and bones in cyan.
- Right-hand joints and bones in orange.
- Tracked joints as points and valid bone pairs as lines.
- A compact overlay containing pose frame ID, image sequence, and left/right tracking state.
- Fixed axis limits and equal box aspect to avoid per-frame zoom jitter.

The OpenXR hand edges are:

- Wrist to palm.
- Wrist through the four thumb joints to the thumb tip.
- Palm through the five joints of each of index, middle, ring, and little fingers.

A line is emitted only when both endpoint joints have valid tracked positions.

## Concurrency and Timing

Matplotlib rendering is synchronous CPU work, so `run_inference` invokes it with `asyncio.to_thread`. This prevents a slow frame from blocking the WebSocket receive loop. A process-wide rendering lock protects Matplotlib from concurrent access if more than one Quest connects.

The scheduler does not queue render requests. When rendering falls behind, it resumes from the current loop time and uses the newest pose, preserving low latency rather than attempting to catch up.

## Error Handling

- Missing head data: render hands using the existing origin, or a zero origin before one is available.
- Missing hand or `tracking: false`: omit that hand and keep producing frames.
- Missing or malformed joints: skip only those points and bones.
- Matplotlib import failure: exit at startup with a clear dependency error.
- Rendering exception: propagate to the connection task so the existing service log exposes the failure; no corrupt PINF frame is sent.
- JPEG output remains below the protocol's 8 MiB limit.

## Dependencies and Operation

Add `matplotlib>=3.8,<4` to `server/requirements-pose-inference.txt` and install it into `server/.venv`.

The normal command and QR workflow remain unchanged:

```bash
server/.venv/bin/python server/pose_inference_ws.py
```

No new command-line option is required; the Matplotlib skeleton becomes the default image renderer.

## Testing

Tests will be written before implementation and will cover:

1. Quaternion rotation produces the expected head-forward vector.
2. A complete sample pose renders a decodable 960x540 JPEG.
3. Different poses or image sequences produce different JPEG bytes.
4. Missing and untracked hand joints do not prevent rendering.
5. The inference loop accepts an injected renderer for a fast protocol-level test and continues sending the newest pose at the existing cadence.
6. The complete existing pose inference test suite remains green.

Rendering tests use the checked-in one-frame sample at `server/samples/quest_pose_frame_000001.json`.

## Acceptance Criteria

- The remote virtual environment imports Matplotlib successfully.
- Existing server tests and new renderer tests pass remotely.
- Starting the existing service exposes the same QR page and WebSocket URL.
- With Quest connected, terminal statistics show approximately 20 image frames per second.
- Quest displays a changing 3D head-and-hand skeleton image.
- Pose reception remains near the Quest runtime rate and does not build a backlog.
