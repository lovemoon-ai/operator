# Live Feed Cloud Integration

Live Feed streams capture data from XR to a server and streams algorithm
results back to XR for rendering. It is not the same path as ego recording
upload: Live Feed is online OLCP over TCP; ego upload is finalized artifacts
over TUS.

## XR Entry Points

- Scene: `xr/scenes/live_feed_app.tscn`
- Scene script: `xr/scripts/app/modes/capture_app_base.gd`
- Composition: `xr/scripts/app/composition/live_feed_composition.gd`
- XR-to-server addon: `xr/addons/live-push/`
- Server-to-XR addon: `xr/addons/live-pull/`

The scene attaches `capture_app_base.gd` directly and pins
`capture_sink = "server"` as a scene property.
(`xr/scripts/app/modes/live_feed_mode.gd` sets the same property in `_init()`
but is currently unreferenced.) The composition creates a `LiveStreamSink`
backed by `LivePushWriter`, then reuses the capture session controller and
platform capture providers.

The launcher card for this mode is controlled by
`operator_feature_mode_live_feed`, which is `false` in every shipped preset;
Live Feed is entered through the `operator.mode` intent extra. See
`claw/architecture/xr-client.md` for the launcher card contract.

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

Flags are shared across frame types: bit `0x0001` marks an RGB keyframe,
`0x0002` marks a composite JSON+binary payload, and `0x0004` zlib-compresses
the binary portion. RGB packets are already HEVC/H.264 access units. Depth is
decoded to little-endian `u16` millimetres; after parsing any composite prefix,
receivers inflate frames carrying `0x0004` and validate the result against
`width * height * 2`. Unflagged raw depth remains supported.

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
100 result_hello
101 capture_request
102 result_welcome
110 algorithm_status
111 map_reset
112 dense_map_manifest
113 dense_map_fragment
114 dense_map_commit
115 camera_trajectory
116 map_transform
```

`result_hello` is the only XR-to-server frame on this socket. It is sent as
soon as TCP connects with schema `operator.result_hello.v1` and the same
optional `auth_token` used by `session_start`. The server validates the hello,
then replies with `operator.result_welcome.v1` (type 102) before replacing an
existing result client or sending control/result data. XR does not report the
connection as ready until that acknowledgement arrives.

The result publisher retains the current headset-visible map snapshot, bounded
to the same chunk and point budgets as the XR renderer. After every authenticated
reconnect it sends `map_reset`, replays that snapshot, and then resumes live
deltas. This makes reconnect independent of frames lost with the old TCP socket.

Dense map fragments use the same composite payload layout. The renderer
supports the prototype point formats documented in `xr/addons/live-pull`.

## Capture Negotiation

The captured stream set is a server decision, not a headset setting: the
algorithm knows what it needs, and pushing anything else wastes headset
bandwidth on data the server discards.

The exchange rides the live-pull channel because the headset's push socket is
write-only (`LiveFeedServerPlugin` holds only a `DataOutputStream`), and because
the settings page connects to live-pull before any capture exists — which is
exactly when the stream set has to be known:

```text
1. Operator opens Live Feed settings and presses Connect.
2. XR connects live-pull (63912) and sends result_hello (100).
3. Server authenticates it and confirms with result_welcome (102).
4. Server sends capture_request (101) listing
   selected_streams.
5. XR maps those to its capture flags and shows them read-only in settings.
6. Operator starts capture; only the requested streams are pushed.
7. On session_start the server re-plans against the headset's real
   capabilities (the *_expected flags) and re-sends capture_request if the
   set narrowed.
```

`capture_request` payload is `operator.capture_request.v1` (see
`build_capture_request`). Stream names map to capture flags via
`SERVER_STREAM_TO_OPTION` in `capture_app_base.gd`; `controller_input.json`
shares `record_controller_pose` because the provider derives one from the other.

Runtime input-mode auto-detection (hands vs controllers) may still *narrow* the
set — there is no controller data while the user is bare-handed — but never
widens it beyond the request.

Hand tracking and controller tracking are mutually exclusive at the provider
level, and which one is live is a physical fact software cannot change. So when
the algorithm asks for the source the operator is not holding, the client does
not silently send nothing: it shows a notice asking them to switch
(`UI_SERVER_WANTS_HANDS` / `UI_SERVER_WANTS_CONTROLLERS`) in both the settings
callout and the record control's status line, so it is visible whether or not
capture has started.

Disable with `--no-send-capture-request-to-xr` to fall back to the headset's
locally persisted stream selection.

## Python Package Layout

`pyoperator.live_feed` separates transport from algorithm so applications do not
have to copy server internals:

| Module | Responsibility |
| --- | --- |
| `protocol.py` | OLCP framing, capability negotiation, capture planning |
| `models.py` | Typed samples, camera models, rigid transforms; no I/O |
| `decoders.py` | Optional RGB decoding through `ffmpeg` |
| `runtime.py` | `LiveFeedReceiver` / `LiveFeedSession`, bounded queues, recording |
| `results.py` | `ResultChannel`, `ResultPublisher`, `DensePoint` |
| `server.py` | Depth-fusion reference server composed from the modules above |

`LiveFeedReceiver` owns the push socket and reader thread and yields typed
samples; `ResultPublisher` owns the result framing rules, including the
mandatory `manifest -> fragments -> commit` ordering and monotonically
increasing `map_version` (the XR client discards manifests whose version is
older than the newest one it has seen).

Two runnable examples show the two directions:

- `python/examples/live_feed_viewer.py` - one-way capture data, headset to
  Python, with live visualisation. It sends one `capture_request` control frame
  so XR can display the requested data types, but publishes no algorithm
  results.
- `python/examples/live_feed_roundtrip.py` - bidirectional. Converts the head
  pose trail into a point cloud and streams it back for in-headset rendering.

## Example Server

`python/pyoperator/live_feed/server.py` is the current runnable server
implementation. It is packaged with `pyoperator`, while
`examples/live-feed-demo/operator_live_feed_server.py` remains a compatibility
entry point. The server:

- accepts OLCP v1 live-push frames;
- validates a static Quest capability profile;
- demuxes streams into bounded queues;
- stores durable session artifacts;
- performs a simple depth-fusion point-cloud reconstruction;
- publishes dense-map result frames back to XR over live-pull.

Run:

```bash
PYTHONPATH=python python3 -m pyoperator.live_feed \
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
