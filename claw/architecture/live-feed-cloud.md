# Live Feed Cloud Integration

Live Feed streams capture data from XR to a server and streams algorithm
results back to XR for rendering. It is not the same path as ego recording
upload: Live Feed is online OLCP over TCP; ego upload is finalized artifacts
over TUS.

## XR Entry Points

- Scene: `xr/scenes/live_feed_app.tscn`
- Mode script: `xr/scripts/app/modes/live_feed_mode.gd`
- Shared base: `xr/scripts/app/modes/capture_app_base.gd`
- Composition: `xr/scripts/app/composition/live_feed_composition.gd`
- XR-to-server addon: `xr/addons/live-push/`
- Server-to-XR addon: `xr/addons/live-pull/`

`LiveFeedMode` pins `capture_sink = "server"`. The composition creates a
`LiveStreamSink` backed by `LivePushWriter`, then reuses the capture session
controller and platform capture providers.

## Ports

Default development ports:

```text
63910  live-push: XR -> server capture stream
63912  live-pull: server -> XR result stream
```

USB development with a Quest or Pico:

```bash
adb -s <serial> reverse tcp:63910 tcp:63910
adb -s <serial> reverse tcp:63912 tcp:63912
```

For LAN or cloud servers, configure the Live Feed server host in-headset and
skip `adb reverse`.

## XR-To-Server Frames

`live-push` sends OLCP v1 frames. Header integers are big-endian:

```text
magic         4 bytes    "OLCP"
version       1 byte     1
frame_type    1 byte
flags         2 bytes
pts_ns        8 bytes
duration_ns   8 bytes
payload_size  4 bytes
payload       N bytes
```

Current inbound frame types:

| Type | Name | Payload |
| --- | --- | --- |
| 1 | `session_start` | JSON |
| 2 | `rgb_csd` | JSON codec config |
| 3 | `rgb_packet` | HEVC Annex-B access unit |
| 4 | `depth_metadata` | JSON |
| 5 | `depth_frame` | depth bytes or composite payload |
| 6 | `head_pose` | JSON |
| 7 | `controller_pose` | JSON |
| 8 | `hand_joints` | JSON |
| 9 | `controller_input` | JSON |
| 10 | `session_end` | JSON |

When `flags & 2 != 0`, the payload is composite:

```text
u32_be json_size
utf8   json
bytes  binary
```

Servers should parse frames in a socket reader, write durable session metadata,
and put high-rate streams into bounded queues. Do not run mapping or model
inference inside the socket reader.

## Server-To-XR Results

`live-pull` accepts server result frames and renders dense map updates. Current
server-reserved frame types:

```text
110 algorithm_status
111 map_reset
112 dense_map_manifest
113 dense_map_fragment
114 dense_map_commit
115 camera_trajectory
116 map_transform
```

Dense map fragments use the same composite payload layout. The renderer
supports the prototype point formats documented in `xr/addons/live-pull`.

## Example Server

`examples/live-feed-demo/operator_live_feed_server.py` is the current runnable
server prototype. It:

- accepts OLCP v1 live-push frames;
- validates a static Quest capability profile;
- demuxes streams into bounded queues;
- stores durable session artifacts;
- performs a simple depth-fusion point-cloud reconstruction;
- publishes dense-map result frames back to XR over live-pull.

Run:

```bash
cd examples/live-feed-demo
python3 operator_live_feed_server.py \
  --algorithm depth_fusion_pointcloud \
  --push-port 63910 \
  --pull-port 63912
```

## Implementation Guidance

Keep server ingestion and algorithm work separate:

- socket reader: parse, validate, write durable events, enqueue;
- stream queues: bounded per stream, drop old high-rate samples under pressure;
- workers: decode HEVC, align pose/depth, run mapping or inference;
- result writer: publish compact map/status deltas to the pull channel.

Do not send large algorithm results back over the live-push connection. Use the
separate live-pull result channel.
