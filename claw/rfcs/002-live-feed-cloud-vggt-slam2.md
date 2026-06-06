# RFC-002 Live Feed Cloud Protocol and VGGT-SLAM2 Result Streaming

## Status

Proposed

## Owner

TBD

## Date

2026-06-04

## Summary

Live Feed should be a server-driven cloud pipeline. The XR client
reports what it can produce and render, the server chooses an algorithm
and validates its data demand against those capabilities, then XR streams
only the requested sensor data. The server processes the data through a
cloud algorithm worker and returns renderable results to XR.

The immediate example is VGGT-SLAM2. The server requests RGB HEVC plus
optional head pose and depth, runs a keyframe/submap pipeline, and returns
dense map updates that XR can render in real time.

Dense map output is large. A realistic estimate is around
28 MiB/submap. Therefore the result path must not send one submap as one
large frame, and it must not share a FIFO stream with capture upload.
Result streaming needs an independent channel, manifest/fragment/commit
messages, map-version based stale dropping, level-of-detail, and XR-side
render budgets.

## Core Assumptions and Counterarguments

### Assumption 1: the server drives capture demand

The server-side algorithm is the authority on which data streams are
needed. XR should not stream every available sensor by default.

Counterargument: XR owns device thermal state, permissions, battery,
tracking quality, network quality, and render budget. The final protocol
must be negotiation, not command-only. The server requests; XR accepts,
rejects, or downscopes the request.

### Assumption 2: current OLCP can evolve, but channels must split

The current `OLCP` binary frame format can remain the basic envelope for
sensor frames and small control messages.

Counterargument: large dense-map results do not fit a single reliable
ordered FIFO. TCP can be used for a first result channel, but result data
must be isolated from sensor ingest and control, and the application must
support stale-drop semantics above TCP.

### Assumption 3: VGGT-SLAM2 can consume an RGB-first keyframe stream

VGGT-SLAM2 can be adapted from an image-folder pipeline into a live
keyframe/submap worker. RGB HEVC is the required XR source; head pose and
depth are optional priors for alignment, gating, scale checks, and
debugging.

Counterargument: the public VGGT-SLAM2 repository currently exposes an
image-folder entry point, while real-time camera integration is listed as
future code. This RFC proves the data and transport shape, not the final
runtime performance of a production VGGT-SLAM2 cloud worker.

## Goals

- Define OLCP v1 as implemented today.
- Define the OLCP v2 negotiation model.
- Define XR client responsibilities for capture and result rendering.
- Define cloud server responsibilities for demand validation, ingestion,
  durable logging, queues, algorithm workers, and result publication.
- Define a VGGT-SLAM2 example demand and worker boundary.
- Define a dense-map return path that can handle 28 MiB/submap without
  blocking capture or rendering.
- Keep the current OLCP v1 Quest stream usable during migration.

## Non-Goals

- Implementing the full VGGT-SLAM2 CUDA/GPU worker in this RFC.
- Replacing the current XR Android plugin in one step.
- Choosing a final production transport. TCP result sockets are acceptable
  for the first implementation; QUIC/WebRTC can replace them later.
- Guaranteeing that XR renders full-resolution dense maps. XR renders a
  budgeted, possibly lower-LOD representation.

## Terminology

- `OLCP`: Operator Live Feed Protocol.
- `XR`: the headset client running the Operator Godot app.
- `control channel`: reliable small-message channel for capabilities,
  capture requests, accept/reject, budget, status, and cancellation.
- `sensor ingest channel`: XR-to-server data plane for RGB, depth, pose,
  controller, hand, and session frames.
- `result channel`: server-to-XR data plane for map, trajectory, status,
  and transform updates.
- `submap`: an algorithm-level map update, usually produced from a window
  of selected keyframes.
- `tile`: a spatial partition inside a submap.
- `LOD`: level of detail. Higher LOD means more points/bytes.
- `map_version`: monotonically increasing version for result invalidation.

## Current OLCP v1

OLCP v1 is already implemented by the Live Feed Android plugin. It is
a single TCP stream from XR to server.

Frame header:

```text
magic         4 bytes    "OLCP"
version       1 byte     1
frame_type    1 byte
flags         2 bytes    big-endian
pts_ns        8 bytes    big-endian
duration_ns   8 bytes    big-endian
payload_size  4 bytes    big-endian
payload       N bytes
```

Current client frame types:

```text
1   session_start       JSON
2   rgb_csd             JSON, includes HEVC codec config as base64
3   rgb_packet          HEVC Annex B bytes
4   depth_metadata      JSON
5   depth_frame         raw u16 or composite JSON + u16
6   head_pose           JSON
7   controller_pose     JSON
8   hand_joints         JSON
9   controller_input    JSON
10  session_end         JSON
```

Current flags:

```text
1   keyframe
2   composite_json      4-byte JSON size + JSON + binary payload
```

Current v1 limitations:

- XR starts streaming immediately after connecting.
- There is no capability message.
- The server cannot request a subset of supported streams.
- There is no server-to-XR result reader in the current APK.
- Large server-to-XR dense results must not be added to this same stream.

## Proposed OLCP v2 Channels

OLCP v2 is a multi-channel protocol family. The frame envelope can remain
OLCP-like, but channels have separate connections and flow-control
semantics.

Default development ports:

```text
63910  control or v1 compatibility ingest
63911  sensor ingest
63912  result stream
```

Compatibility mode:

- If XR sends v1 `session_start` on 63910, the server treats 63910 as the
  current v1 ingest stream and uses a static Quest capability profile.
- If XR sends v2 `client_capabilities` on 63910, the server performs the
  v2 handshake and advertises 63911/63912 endpoints.

Target v2 channels:

```text
XR -> Server    control      small reliable messages
XR -> Server    sensor       RGB HEVC, pose, depth, hands, input
Server -> XR    result       map/status/trajectory/transform updates
```

Control should remain low-volume and reliable. Sensor ingest should
prioritize capture durability and timestamps. Result streaming should be
independent, budgeted, and allowed to drop stale map versions.

Control channel frame types:

```text
100  client_capabilities    JSON
101  capture_request        JSON
102  capture_accept         JSON
103  capture_reject         JSON
104  result_budget          JSON
105  result_cancel          JSON
106  heartbeat              JSON
```

## Communication Handshake

### 1. XR connects to control

XR opens TCP to `server:63910`.

### 2. XR sends client capabilities

```json
{
  "schema": "operator.client_capabilities.v1",
  "protocol": "operator.live_feed.v2",
  "device": "quest",
  "app_version": "0.1.0",
  "streams": {
    "session.json": {
      "frame_types": [1, 10],
      "formats": ["json"]
    },
    "rgb.hevc": {
      "frame_types": [2, 3],
      "formats": ["hevc_annexb"],
      "max_hz": 60
    },
    "head_pose.json": {
      "frame_types": [6],
      "formats": ["json"],
      "max_hz": 90
    },
    "depth.u16": {
      "frame_types": [4, 5],
      "formats": ["json_plus_u16_mm"],
      "max_hz": 30
    }
  },
  "result_sinks": {
    "dense_map.tiles": {
      "formats": ["quantized_u16xyz_rgba8_conf8_zstd"],
      "max_fragment_bytes": 1048576,
      "max_visible_points": 300000,
      "max_result_mbps": 80
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

### 3. Server validates algorithm demand

For VGGT-SLAM2:

```json
{
  "algorithm": "vggt_slam2",
  "required_streams": ["session.json", "rgb.hevc"],
  "optional_streams": ["head_pose.json", "depth.u16"],
  "result_streams": [
    "status.json",
    "dense_map.tiles",
    "camera_trajectory.json",
    "map_transform.json"
  ],
  "limits": {
    "rgb_max_hz": 15,
    "head_pose_max_hz": 30,
    "depth_policy": "nearest_keyframe",
    "submap_size": 16,
    "overlap": 1
  }
}
```

Validation rules:

- Every required stream must exist in XR capabilities.
- Every requested result stream must exist in XR result sinks.
- Optional streams are selected only if supported.
- Server limits must not exceed XR max rates and result budgets unless XR
  explicitly accepts the override.

### 4. Server sends capture request

```json
{
  "schema": "operator.capture_request.v1",
  "algorithm": "vggt_slam2",
  "session_id": "live_20260604_001",
  "selected_streams": ["session.json", "rgb.hevc", "head_pose.json", "depth.u16"],
  "result_streams": [
    "status.json",
    "dense_map.tiles",
    "camera_trajectory.json",
    "map_transform.json"
  ],
  "limits": {
    "rgb_max_hz": 15,
    "head_pose_max_hz": 30,
    "depth_policy": "nearest_keyframe",
    "submap_size": 16,
    "overlap": 1
  },
  "endpoints": {
    "sensor_ingest": {
      "transport": "tcp",
      "host": "127.0.0.1",
      "port": 63911
    },
    "result": {
      "transport": "tcp",
      "host": "127.0.0.1",
      "port": 63912
    }
  }
}
```

### 5. XR accepts or rejects

```json
{
  "schema": "operator.capture_accept.v1",
  "session_id": "live_20260604_001",
  "accepted_streams": ["session.json", "rgb.hevc", "head_pose.json", "depth.u16"],
  "result_budget": {
    "max_result_mbps": 80,
    "max_inflight_bytes": 4194304,
    "max_fragment_bytes": 1048576,
    "max_visible_points": 300000,
    "preferred_lod": 2
  }
}
```

XR may reject with a structured reason:

```json
{
  "schema": "operator.capture_reject.v1",
  "reason": "missing_permission",
  "detail": "environment depth permission is unavailable"
}
```

### 6. XR opens data channels

XR opens sensor ingest and result sockets. The result socket is opened by
XR but carries server-to-XR payloads, which works through adb reverse and
NAT-like development setups.

### 7. Server starts the algorithm

The server starts durable logging first, then starts per-stream queues,
then starts the algorithm worker. Queue drops must not delete already
persisted artifacts.

## XR Client Design

The XR client should split Live Feed into these components:

```text
LiveFeedMode
  CapabilityReporter
  CaptureNegotiator
  SensorProducerRegistry
  OlcpSensorIngestWriter
  ResultReceiver
  DenseMapRenderer
  ResultBudgetReporter
```

### CapabilityReporter

Reports supported streams and result sinks. Capabilities should include
current runtime constraints, not only build-time support:

- permissions granted
- environment depth availability
- thermal or battery restrictions
- maximum practical sensor rates
- maximum result fragment bytes
- point-rendering budget

### CaptureNegotiator

Connects to the server control channel, sends capabilities, receives
`capture_request`, and either accepts or rejects it. It then configures
sensor producers from the accepted stream list.

### SensorProducerRegistry

Owns the mapping from named streams to concrete producers:

```text
session.json        session metadata
rgb.hevc            Quest capture HEVC encoder output
head_pose.json      OpenXR head pose sampler
depth.u16           environment depth sampler
controller_pose     controller tracker
hand_joints         hand tracker
controller_input    input event sampler
```

Only accepted streams should be enabled.

### ResultReceiver

Reads server-to-XR result frames from the result channel. It must not run
on the same queue as sensor upload. It should:

- parse small status/control frames immediately
- assemble dense-map fragments by `map_version` and `chunk_id`
- drop fragments for stale `map_version`
- enforce `max_inflight_bytes`
- publish ready chunks to the renderer only after commit

### ResultBudgetReporter

XR should periodically report render and network budgets:

```json
{
  "schema": "operator.result_budget.v1",
  "session_id": "live_20260604_001",
  "latest_map_version": 41,
  "max_result_mbps": 60,
  "max_inflight_bytes": 4194304,
  "max_visible_points": 250000,
  "preferred_lod": 2,
  "render_frame_budget_ms": 2.0,
  "dropped_result_frames": 7
}
```

The server uses this to select LOD, defer refinement, or stop sending old
versions.

## Cloud Server Design

The server should be split into protocol, ingest, algorithm, and result
layers:

```text
LiveFeedServer
  AlgorithmRegistry
  CapabilityValidator
  CaptureSession
    DurableSessionLog
    OlcpSensorIngestReader
    StreamQueues
    AlgorithmWorker
    ResultPublisher
    ResultFlowController
```

### AlgorithmRegistry

Each algorithm declares:

- required input streams
- optional input streams
- result streams
- default limits
- worker factory

For VGGT-SLAM2, the registry entry is the demand shown in the handshake
section.

### DurableSessionLog

The durable log is separate from real-time queues. The server should
persist:

- `capture_plan.json`
- `events.ndjson`
- `rgb.h265`
- decoded keyframes, if decoding is enabled
- depth artifacts
- result manifests and fragments

The rule is: write durable artifacts before dropping real-time queue
entries.

### StreamQueues

The server demuxes OLCP frames into bounded queues:

```text
session
rgb_csd
rgb_packet
head_pose
depth
controller
hands
result
```

Queues are allowed to drop oldest samples for real-time streams. Session
metadata, codec config, and explicit end markers should be treated as
non-droppable.

### VGGT-SLAM2 Worker Boundary

The public VGGT-SLAM2 repository currently has an image-folder boundary:

```python
predictions = solver.run_predictions(image_names_subset, model, max_loops, ...)
solver.add_points(predictions)
solver.graph.optimize()
```

The live worker should keep that semantic boundary but replace
`image_names_subset` with a stream-backed keyframe window:

```text
rgb.hevc packets
  -> HEVC decoder
  -> RGB frame bus
  -> keyframe selector
  -> submap window of submap_size + overlap
  -> solver.run_predictions(...)
  -> solver.add_points(...)
  -> solver.graph.optimize()
  -> result publisher
```

The overlap frame must be the exact same frame ID and image bytes in both
neighboring submaps.

Optional streams:

- `head_pose.json`: keyframe gating, coarse map alignment, tracking
  quality checks.
- `depth.u16`: scale checks, depth priors, debugging, and quality gates.

## Result Return Protocol

Dense-map result data is large. At 28 MiB/submap:

```text
1.0 s update interval  -> 28 MiB/s, about 235 Mbps payload
0.5 s update interval  -> 56 MiB/s, about 470 Mbps payload
```

This must not be sent as one OLCP payload. It must also not share the
sensor ingest connection.

### Result frame types

Result channel frame types:

```text
110  algorithm_status       JSON
111  map_reset              JSON
112  dense_map_manifest     JSON
113  dense_map_fragment     composite JSON + binary
114  dense_map_commit       JSON
115  camera_trajectory      JSON
116  map_transform          JSON
```

### Dense map manifest

The manifest describes a logical submap result before fragments arrive.

```json
{
  "schema": "operator.dense_map_manifest.v1",
  "session_id": "live_20260604_001",
  "map_id": "map_001",
  "map_version": 42,
  "submap_id": 7,
  "operation": "upsert",
  "coordinate_frame": "map",
  "T_openxr_map": [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1]],
  "total_uncompressed_bytes": 29360128,
  "encoding": "quantized_u16xyz_rgba8_conf8_zstd",
  "tiles": [
    {
      "chunk_id": "submap_0007_lod2_tile_0000",
      "lod": 2,
      "aabb_min": [-2.0, -1.0, 0.5],
      "aabb_max": [2.0, 1.0, 4.0],
      "point_count": 60000,
      "compressed_bytes": 480000,
      "fragment_count": 1
    }
  ]
}
```

### Dense map fragment

Fragments carry a small JSON header plus binary payload. Target fragment
size should be 256 KiB to 1 MiB.

```json
{
  "schema": "operator.dense_map_fragment.v1",
  "session_id": "live_20260604_001",
  "map_id": "map_001",
  "map_version": 42,
  "chunk_id": "submap_0007_lod2_tile_0000",
  "fragment_index": 0,
  "fragment_count": 1,
  "offset": 0,
  "payload_bytes": 480000,
  "payload_encoding": "zstd",
  "payload_crc32": "0x12345678"
}
```

The frame payload is:

```text
4-byte JSON length BE
JSON metadata
binary fragment payload
```

### Dense map commit

Commit tells XR that a logical chunk or version can be displayed.

```json
{
  "schema": "operator.dense_map_commit.v1",
  "session_id": "live_20260604_001",
  "map_id": "map_001",
  "map_version": 42,
  "committed_chunks": ["submap_0007_lod2_tile_0000"],
  "replace_versions_before": 42
}
```

XR may display low-LOD chunks before all high-LOD chunks arrive. It
should only replace a visible chunk when the replacement chunk is complete
and committed.

### Stale drop and flow control

The server must not call `sendall` on a full 28 MiB submap. It should
maintain an application-level result queue:

```text
max_inflight_bytes      default 4 MiB
max_fragment_bytes      default 1 MiB
active_map_version      latest generated version
send_order              status, transform, LOD preview, visible tiles, refinement
drop_policy             drop queued fragments older than active_map_version
```

If `map_version=43` is generated while version 42 is still queued, the
server should stop queueing version 42 fragments unless XR explicitly asks
for them. Bytes already inside the kernel TCP buffer cannot be revoked, so
the application must keep socket buffers and in-flight bytes bounded.

### Encoding

The first implementation should avoid raw `float32 xyz` for high-volume
results. Recommended dense point tile encoding:

```text
tile AABB
uint16 x, y, z in local tile coordinates
uint8 r, g, b, a
uint8 confidence
optional uint8 semantic label
zstd or lz4 compression
```

This changes the point payload from about 20 bytes/point
(`f32 xyz + rgba + f32 conf`) toward roughly 10 to 12 bytes/point before
compression, depending on whether confidence and labels are present.

Draco or meshopt can be evaluated later, but CPU cost must be measured on
both server and Quest.

## XR Display and Rendering Design

XR renders server results as a non-authoritative overlay.

### Data structures

```text
MapRegistry
  map_id
  latest_map_version
  T_openxr_map
  chunks_by_id

Chunk
  chunk_id
  map_version
  lod
  aabb
  point_count
  gpu_buffer
  visible
```

### Rendering rules

- Apply `T_openxr_map` before rendering.
- Keep a hard visible point budget.
- Prefer latest committed map version.
- Keep low-LOD preview visible while higher LOD is still arriving.
- Replace whole chunks, not individual points.
- Drop fragments for stale map versions.
- Fade or mark stale map overlays if status updates stop.
- Do not use returned map geometry for safety-critical robot control.

### Budgeting

Initial Quest target:

```text
visible points        200k to 500k
fragment size         256 KiB to 1 MiB
in-flight result      2 MiB to 8 MiB
update interval       500 ms to 1000 ms
first visible result  low LOD only
```

For a 28 MiB full submap, XR should usually receive a low-LOD preview
first, then refinements only if network and render budgets allow.

## Migration Plan

### Phase 0: current prototype

- Current XR sends OLCP v1 to server.
- Server uses a static Quest profile.
- Server validates VGGT-SLAM2 demand.
- Server demuxes queues and writes durable logs.
- Server produces mock dense-map result artifacts on disk.

Prototype path:

```text
examples/live-feed-vggt-slam2/
```

### Phase 1: v2 control handshake

- Add XR `client_capabilities`.
- Add server `capture_request`.
- XR enables only accepted streams.
- Keep sensor ingest on TCP.
- Keep result frames disabled or disk-only.

### Phase 2: independent result channel

- XR opens result socket.
- Add result receiver and fragment assembler.
- Add `dense_map_manifest`, `dense_map_fragment`, and
  `dense_map_commit`.
- Add `result_budget` updates.
- Render mock dense map chunks.

### Phase 3: VGGT-SLAM2 cloud worker

- Decode HEVC to RGB frames.
- Select live keyframes.
- Maintain `submap_size + overlap` windows.
- Call the VGGT-SLAM2 solver boundary.
- Convert map/submap points to tiled LOD result payloads.

### Phase 4: transport upgrade

If TCP result streaming is insufficient:

- Move result stream to QUIC or WebRTC data channels.
- Use unreliable/unordered delivery for high-LOD fragments.
- Keep control reliable and ordered.
- Preserve the same manifest/fragment/commit semantics.

## Open Questions

- Should control be a separate socket from 63910 even in v2, or should
  63910 remain the permanent control endpoint?
- What compression library is acceptable on Quest for real-time point
  tiles: zstd, lz4, Draco, meshopt, or a custom quantized block format?
- What is the practical Quest point budget for stable frame rate in this
  app's renderer?
- Should dense map results be aligned to OpenXR local space directly, or
  should XR estimate and smooth `T_openxr_map` from server trajectory
  updates?
- How should loop closure updates be displayed when a map version changes
  a large part of the previous geometry?

## Acceptance Criteria

- Server rejects algorithm demands that are not supported by XR
  capabilities.
- XR streams only accepted data streams.
- Sensor ingest continues even when result streaming is slow.
- 28 MiB/submap is fragmented and does not appear as one OLCP payload.
- XR can drop stale map versions without corrupting the visible map.
- XR can render a low-LOD dense map preview within its point budget.
- Server can downscope result LOD based on XR `result_budget`.
- VGGT-SLAM2 integration can replace the mock worker without changing the
  protocol or renderer contract.
