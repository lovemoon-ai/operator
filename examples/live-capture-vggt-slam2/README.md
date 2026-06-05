# Live Capture VGGT-SLAM2 Server Prototype

This example is the server-side prototype for Operator live capture.

It accepts the current Quest OLCP v1 stream, validates a VGGT-SLAM2 data demand
against a Quest capability profile, demuxes incoming frames into bounded queues,
writes durable session artifacts, and publishes mock dense-map deltas using the
result schema intended for the XR return channel.

## Run With Quest

From this directory:

```bash
adb -s 2G0YC1ZF7S0C2D reverse tcp:63910 tcp:63910
python3 operator_live_capture_server.py --algorithm vggt_slam2
```

Then start the XR app's Live Capture mode on the Quest.

The current XR APK sends OLCP v1 frames immediately after connecting, so this
prototype uses a static Quest capability profile. The target OLCP v2 flow is:

1. XR sends `client_capabilities`.
2. Server validates its algorithm demand.
3. Server sends `capture_request`.
4. XR accepts or rejects.
5. XR streams only the requested data.
6. Server streams algorithm results back to XR for rendering.

See `../../claw/architecture/live-capture-cloud.md` for the protocol contract.

## Inspect The Capture Plan

```bash
python3 operator_live_capture_server.py --print-plan
```

This prints the validated server request. Required streams must be supported by
the XR profile. Optional streams are selected only when available.

## Output Layout

Each connection creates a timestamped session directory under
`live_capture_out/`:

```text
session_.../
  capture_plan.json
  events.ndjson
  rgb.h265
  depth/
  results/
    results.ndjson
    map_chunks/
```

`rgb.h265` is an Annex B HEVC stream assembled from the RGB CSD and packet
frames. `events.ndjson` is the durable demux log. Queue drops do not remove data
already written to these files.

## VGGT-SLAM2 Integration Shape

VGGT-SLAM consumes ordered images and processes overlapping submaps. For a live
server, keep RGB as the source of truth:

1. Decode the HEVC stream to RGB frames.
2. Select stable keyframes.
3. Build windows of `submap_size + overlap` frames.
4. Keep the overlap frame identical across adjacent windows.
5. Run VGGT-SLAM predictions/optimization on the window.
6. Publish `dense_point_chunk`, `camera_trajectory`, `map_transform`, and
   `algorithm_status` results.

For offline smoke testing against the public image-folder entry point:

```bash
ffmpeg -f hevc -i live_capture_out/<session>/rgb.h265 \
  -vf fps=10 live_capture_out/<session>/keyframes/frame_%06d.jpg
python /path/to/VGGT-SLAM/main.py \
  --image_folder live_capture_out/<session>/keyframes \
  --submap_size 16 \
  --max_loops 1
```

The included `MockVggtSlam2Worker` demonstrates the live queue and result-return
flow without requiring GPU dependencies. Replace that class with a worker that
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
110 algorithm_status       JSON
111 map_reset              JSON
112 dense_point_chunk      4-byte JSON length + JSON + binary points
113 camera_trajectory      JSON
114 map_transform          JSON
115 mesh_chunk             4-byte JSON length + JSON + binary mesh
```

By default this prototype writes result frames to disk and does not send them
back to the current APK. Use `--send-results-to-xr` only after the XR client has
a read loop and renderer for the returned frame types.

`--send-capture-request-to-xr` sends the target v2 `capture_request` control
frame at connection time. It is disabled by default because the current APK is a
v1 sender and does not yet consume server-to-XR frames.

For VGGT-SLAM2 rendering, XR should keep a chunk registry keyed by `chunk_id`,
apply `T_openxr_map`, and render dense-map point chunks as a non-authoritative
overlay.
