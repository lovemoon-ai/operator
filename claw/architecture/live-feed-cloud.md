# Live Feed Cloud Architecture

## Goal

Live capture should be driven by the server-side algorithm. The server declares
the data it needs, the XR client streams only supported data, and algorithm
results can be returned to XR for real-time rendering.

This document describes the target architecture. The current Quest APK already
streams OLCP v1 frames to a TCP server. The next protocol step is OLCP v2,
which adds capability negotiation and a server-to-XR result channel.

## Roles

- XR client: owns sensors, capture permissions, compression, local throttling,
  and real-time rendering of returned algorithm results.
- Live Feed server: owns algorithm selection, demand validation, ingestion,
  queues, persistence, time synchronization, and result publication.
- Algorithm worker: consumes a selected frame bus and emits map/status updates.

## Handshake

The target handshake is:

1. XR connects to the server.
2. XR sends `client_capabilities`.
3. Server validates its algorithm demand against those capabilities.
4. Server sends `capture_request`.
5. XR sends `capture_accept` or `capture_reject`.
6. XR streams requested data.
7. Server streams algorithm results back to XR.

The server is still the authority for what data should be streamed. The
capability message only prevents requesting data the XR build cannot provide.

For development, a v1 compatibility server can use a static Quest profile and
validate the algorithm demand before accepting the current one-way OLCP stream.

## Capability Model

Capabilities are named streams, not raw packet types:

```json
{
  "protocol": "operator.live_feed.v2",
  "device": "quest",
  "streams": {
    "rgb.hevc": {
      "required_frame_types": [2, 3],
      "formats": ["hevc_annexb"],
      "max_hz": 60
    },
    "head_pose.json": {
      "required_frame_types": [6],
      "formats": ["json"],
      "max_hz": 90
    },
    "depth.u16": {
      "required_frame_types": [4, 5],
      "formats": ["u16_mm", "json_plus_u16_mm"],
      "max_hz": 30
    }
  },
  "result_sinks": {
    "dense_map.point_cloud_delta": {
      "formats": ["point_chunk_f32xyz_u8rgba_f32conf"]
    },
    "camera_trajectory.json": {
      "formats": ["json"]
    },
    "status.json": {
      "formats": ["json"]
    }
  }
}
```

Algorithm demand is a subset of these capabilities:

```json
{
  "algorithm": "vggt_slam2",
  "required_streams": ["rgb.hevc"],
  "optional_streams": ["head_pose.json", "depth.u16"],
  "result_streams": [
    "dense_map.point_cloud_delta",
    "camera_trajectory.json",
    "status.json"
  ],
  "limits": {
    "rgb_max_hz": 15,
    "head_pose_max_hz": 30,
    "depth_policy": "nearest_keyframe"
  }
}
```

## Ingest Queues

After validation, the server demuxes OLCP frames into bounded queues:

- `rgb_csd`: HEVC codec config and camera metadata.
- `rgb_packet`: HEVC packets.
- `head_pose`: XR head pose samples.
- `depth`: depth metadata and depth frames.
- `controller`: controller pose/input.
- `hands`: hand joints.
- `session`: session start/end and errors.

Queues are bounded. Droppable streams discard oldest data when overloaded.
Non-droppable streams are session metadata, RGB CSD, and explicit end markers.

The durable log is separate from the algorithm queues. The server should write
raw frames or decoded artifacts before dropping queue entries so a session can
be replayed later.

## VGGT-SLAM2 Data Source

VGGT-SLAM and VGGT-SLAM2 are RGB-first pipelines. The public repository entry
point currently consumes an ordered image folder, applies keyframe selection,
and processes overlapping submaps. The live source should therefore expose a
SLAM frame bus centered on RGB keyframes:

```json
{
  "frame_id": 128,
  "pts_ns": 123456789000,
  "image_uri": "session/keyframes/frame_000128.jpg",
  "intrinsics": [[...], [...], [...]],
  "T_head_camera": [[...]],
  "T_openxr_head": [[...]],
  "depth_uri": "session/depth/depth_000128.u16.zst",
  "tracking_valid": true,
  "quality": {
    "mean_flow_from_last_keyframe": 63.4,
    "blur": 0.12
  }
}
```

For VGGT-SLAM2:

- Required XR stream: `rgb.hevc`.
- Optional XR stream: `head_pose.json` for keyframe gating and map alignment.
- Optional XR stream: `depth.u16` for scale checks and depth priors.
- Server decodes HEVC, selects keyframes, keeps an identical overlap frame
  between adjacent submaps, and calls the VGGT-SLAM worker on windows of
  `submap_size + overlap`.

The important invariant is that overlap frames are identical images with stable
frame IDs. Do not replace the overlap frame with a nearby timestamp.

The current public VGGT-SLAM 2.0 code has a concrete offline shape:

- `main.py` reads `--image_folder`, sorts images, and optionally downsamples.
- Keyframe selection uses `solver.flow_tracker.compute_disparity(...)`.
- A submap is processed when the selected list reaches
  `submap_size + overlapping_window_size`.
- The solver call boundary is
  `solver.run_predictions(image_names_subset, model, max_loops, ...)`.
- Results enter the map through `solver.add_points(predictions)` followed by
  `solver.graph.optimize()`.
- Dense output is available from map/submap point cloud APIs such as
  `save_framewise_pointclouds(...)` and `get_points_list_in_world_frame(...)`.

The live worker should preserve that boundary: replace `image_names_subset`
with a stream-backed keyframe window, then publish the updated submap points and
poses through the Operator result channel instead of the local Viser viewer.

## Result Return Channel

Small control/status results may share the OLCP v2 control channel. Large dense
map results must use an independent server-to-XR result channel so capture
upload and control messages are not blocked by map payloads.

Small result frames use the OLCP header with server-reserved types:

```text
100 client_capabilities    JSON
101 capture_request        JSON
102 capture_accept         JSON
103 capture_reject         JSON
104 result_budget          JSON
105 result_cancel          JSON
110 algorithm_status       JSON
111 map_reset              JSON
112 dense_map_manifest     JSON
113 dense_map_fragment     4-byte JSON length + JSON + binary fragment
114 dense_map_commit       JSON
115 camera_trajectory      JSON
116 map_transform          JSON
```

Dense map updates are manifest/fragment/commit deltas. A full submap can
be around 28 MiB, so it must not be sent as one payload. The detailed
transport design is in `claw/rfcs/002-live-feed-cloud-vggt-slam2.md`.

Manifest entries describe chunks:

```json
{
  "schema": "operator.dense_map_manifest.v1",
  "map_id": "session-abc",
  "map_version": 42,
  "submap_id": 7,
  "chunk_id": "submap_7_chunk_0",
  "operation": "upsert",
  "coordinate_frame": "map",
  "T_openxr_map": [[...]],
  "encoding": "quantized_u16xyz_rgba8_conf8_zstd",
  "fragment_count": 12
}
```

The binary payload is sent in fragments. XR renders committed chunks by
`chunk_id`, replacing chunks on `upsert` and deleting them on `delete`.

## XR Rendering Contract

XR should render returned maps as a non-authoritative overlay:

- Maintain `map_id`, `map_version`, and `chunk_id` registry.
- Apply `T_openxr_map` before rendering.
- Use point budget and LOD on device.
- Prefer chunk replacement over per-point mutation.
- Render status and stale-map warnings if result updates stop.

The algorithm result should not block capture. If XR cannot render results fast
enough, it may drop old result chunks and keep the latest `map_transform` and
status.

## Prototype Location

The server prototype is in `examples/live-feed-vggt-slam2/`.

It validates a VGGT-SLAM2 demand against a Quest capture profile, ingests the
current OLCP v1 stream, writes durable logs, exposes per-stream queues, and
publishes mock dense-map deltas using the same result schema intended for the
future XR return channel.
