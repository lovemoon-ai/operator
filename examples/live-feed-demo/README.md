# Live Feed Depth-Fusion Server Example

The server implementation now lives in `pyoperator.live_feed`. This directory
keeps the example documentation and a compatibility script for older checkout
commands.

It accepts the current Quest OLCP v1 stream, validates a depth-fusion data
demand against a Quest capability profile, demuxes incoming frames into bounded
queues, writes durable session artifacts, and runs a small real reconstruction
loop: depth frames are back-projected with the frame intrinsics/FOV, transformed
with the matching depth-eye/head pose, appended into a global point cloud, and
published to the XR return channel once per second as dense-map deltas.

## Run With Quest

From the repository root:

```bash
adb -s 2G0YC1ZF7S0C2D reverse tcp:63910 tcp:63910
adb -s 2G0YC1ZF7S0C2D reverse tcp:63912 tcp:63912
PYTHONPATH=python python3 -m pyoperator.live_feed \
  --algorithm depth_fusion_pointcloud \
  --push-port 63910 \
  --pull-port 63912
```

After installing `pyoperator`, the equivalent command is
`pyoperator-live-feed`. The historical
`examples/live-feed-demo/operator_live_feed_server.py` path remains a thin
compatibility entry point.

Then start the XR app's Live Feed mode on the Quest.

The current XR APK sends OLCP v1 frames immediately after connecting, so this
prototype uses a static Quest capability profile. The target OLCP v2 flow is:

1. XR sends `client_capabilities`.
2. Server validates its algorithm demand.
3. Server sends `capture_request`.
4. XR accepts or rejects.
5. XR streams only the requested data.
6. Server streams algorithm results back to XR for rendering.

See `../../claw/architecture/live-feed-cloud.md` for the protocol contract.

## Inspect The Capture Plan

```bash
PYTHONPATH=python python3 -m pyoperator.live_feed --print-plan
```

This prints the validated server request. Required streams must be supported by
the XR profile. Optional streams are selected only when available.

## Output Layout

Each connection creates a timestamped session directory under
`live_feed_out/`:

```text
session_.../
  capture_plan.json
  events.ndjson
  rgb.h265
  depth/
  results/
    results.ndjson
    map_chunks/
    global_pointcloud.bin
```

`rgb.h265` is written when a v1 XR sender pushes RGB. It is an Annex B HEVC
stream assembled from the RGB CSD and packet frames. When `ffmpeg` is available
on `PATH`, the depth-fusion worker also decodes this stream to RGB frames and
colors projected depth points from the nearest decoded frame. `events.ndjson` is
the durable demux log. Queue drops do not remove data already written to these
files.

## Live Depth-Fusion Demo

The included worker is intentionally simple. It keeps the core reconstruction
dependency-free, and uses the `ffmpeg` command opportunistically for RGB HEVC
decode/coloring:

1. Receive `head_pose` samples and keep a rolling pose buffer.
2. Receive `depth_frame` composite payloads.
3. Build a depth camera model from per-frame FOV/intrinsics/extrinsics.
4. Back-project sampled depth pixels into a point cloud.
5. Transform points into the OpenXR/Godot map frame.
6. Decode HEVC RGB frames with `ffmpeg` when available; project each map point
   into the closest RGB frame for color, falling back to depth-based synthetic
   color when decoding/projection is unavailable.
7. Append to `results/global_pointcloud.bin`.
8. Every `--publish-interval-s` seconds, publish only the new points as
   `dense_map_manifest`, `dense_map_fragment`, and `dense_map_commit`.
9. Archive all RGB packets to `rgb.h265` and count packets/decoded frames for
   diagnostics.

Useful tuning flags:

```bash
PYTHONPATH=python python3 -m pyoperator.live_feed \
  --point-stride 4 \
  --publish-interval-s 1.0 \
  --max-points-per-update 80000 \
  --result-fragment-bytes 1048576
```

Current XR RGB packets are HEVC Annex-B access units, not raw RGB frames. The
demo starts an `ffmpeg -f hevc -i pipe:0 -f rawvideo -pix_fmt rgb24 pipe:1`
decoder by default and aligns decoded frames to depth frames by packet PTS. Use
`--no-rgb-colorize` to disable RGB coloring or `--ffmpeg-bin /path/to/ffmpeg`
to choose a decoder binary.

## VGGT-SLAM2 Integration Shape

VGGT-SLAM consumes ordered images and processes overlapping submaps. For a full
VGGT-SLAM server, keep RGB as the source of truth:

1. Decode the HEVC stream to RGB frames.
2. Select stable keyframes.
3. Build windows of `submap_size + overlap` frames.
4. Keep the overlap frame identical across adjacent windows.
5. Run VGGT-SLAM predictions/optimization on the window.
6. Publish `dense_map_manifest`, `dense_map_fragment`, `dense_map_commit`,
   `camera_trajectory`, `map_transform`, and `algorithm_status` results.

For offline smoke testing against the public image-folder entry point:

```bash
ffmpeg -f hevc -i live_feed_out/<session>/rgb.h265 \
  -vf fps=10 live_feed_out/<session>/keyframes/frame_%06d.jpg
python /path/to/VGGT-SLAM/main.py \
  --image_folder live_feed_out/<session>/keyframes \
  --submap_size 16 \
  --max_loops 1
```

The included `DepthFusionPointCloudWorker` demonstrates the live queue,
pose/depth alignment, point-cloud result-return flow, and XR rendering path
without requiring GPU dependencies. Replace that class with a worker that
decodes HEVC frames and calls the VGGT-SLAM pipeline.

The direct code boundary in the public VGGT-SLAM repo is:

```python
predictions = solver.run_predictions(image_names_subset, model, max_loops, ...)
solver.add_points(predictions)
solver.graph.optimize()
```

`image_names_subset` should be replaced by decoded live keyframes. Keep
`overlapping_window_size=1` semantics by carrying the exact last keyframe into
the next window.

## Result Return Path

Server result frames use OLCP headers with server-reserved types:

```text
100 result_hello           JSON (XR -> server, optional token authentication)
101 capture_request        JSON
102 result_welcome         JSON (server -> XR authentication acknowledgement)
110 algorithm_status       JSON
111 map_reset              JSON
112 dense_map_manifest     JSON
113 dense_map_fragment     4-byte JSON length + JSON + binary points
114 dense_map_commit       JSON
115 camera_trajectory      JSON
116 map_transform          JSON
```

By default this prototype opens `--pull-port` and sends result frames to the
current APK's `live-pull` client. Use `--no-send-results-to-xr` when only
testing inbound capture parsing. The pull listener stays active for
`capture_request`; add `--no-send-capture-request-to-xr` as well to disable the
reverse connection completely.

After authentication the server sends `result_welcome`; the headset does not
show Connected before receiving it. A reconnect is followed by `map_reset` and
a replay of the current bounded map snapshot before new deltas continue.

`--send-capture-request-to-xr` sends the target v2 `capture_request` control
frame at connection time and is enabled by default.

For VGGT-SLAM2 rendering, XR should keep a chunk registry keyed by `chunk_id`,
apply `T_openxr_map`, and render dense-map point chunks as a non-authoritative
overlay.
