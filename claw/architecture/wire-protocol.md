# Wire Protocols

Operator uses several independent wire contracts. Keep them separate:

- Teleop control and telemetry between XR and the robot side.
- Timed H.264 video from `xr-bridge` to XR.
- OLCP Live Feed streams between XR and a server.
- TUS uploads from XR ego capture to web ingest.

## Teleop Command TCP

Default port: `63901`.

Command frames follow the original XRoboToolkit-compatible envelope:

```text
u32_le command_len
utf8   command
u32_le data_len
bytes  data
```

XR implementation:

- `xr/scripts/network/protocol.gd`
- `xr/scripts/network/tcp_handler.gd`
- `xr/scripts/network/session.gd`
- `xr/scripts/input/command_sender.gd`
- `xr/scripts/input/xr_state_sender.gd`

Rust implementation:

- `robot/crates/teleop-protocol/src/wire.rs`
- `robot/crates/teleop-protocol/src/transport.rs`
- `robot/crates/xr-bridge/src/pose_server.rs`
- `robot/crates/robot-adapter/src/server.rs`

The v2 session starts with Hello and device descriptor negotiation. Old peers
can still fall back to the legacy path through `Session`.

### Atomic XR state stream

An SDK-mode descriptor contains `xr_stream` with schema version, requested
rate, and stream names. The XR client then sends `XrStateFrame` on the same TCP
envelope. Its JSON payload is defined by
`robot/crates/teleop-protocol/src/xr_state.rs` and contains:

- one `frame_id` and headset monotonic `timestamp_ns`;
- head pose, both controllers and their complete input maps;
- both 26-joint hands;
- optional body joint set and external motion trackers;
- a `sample_timestamp_ns` on every pose/input/hand/body sample.

The headset builds the dictionary without yielding during one Godot render
tick. The bridge publishes it through a Rust `watch` channel: backpressure
drops complete old frames (latest-wins), never individual fields. Existing
robot descriptors omit `xr_stream`, so their command protocol is unchanged.

SDK mode requires the headset `Hello.capabilities` list to contain
`xr_state_v1`; otherwise the connection is closed and the compatibility error
is exposed through Python bridge stats. Exactly one headset owns an embedded
SDK stream, and a newer connection replaces the old socket. `frame_id` is local
to the headset process and may reset after reconnect, so consumers treat a
different id as the next snapshot rather than assuming it is globally
monotonic.

### XRoboToolkit compatibility TCP

Outside Robot settings may select `xrobot_toolkit_v1` instead of the Operator
session protocol. This is a separate wire format and a separate TCP connection;
it is never nested inside `XRoboProtocol` and cannot be active at the same time
as `DeviceCommand` or `XrStateFrame`.

```text
u8      0x3F
u8      command
i32_le  payload_length
bytes   payload
i64_le  unix_timestamp_ms
u8      0xA5
```

The client sends connect (`0x19`), version (`0x6c`), ten-second heartbeat
(`0x23`), and Tracking (`0x6d`) packets. Tracking uses the legacy outer JSON
object with `functionName="Tracking"` and a JSON string in `value`. Controller
fields are always complete. Body is included only for a complete, valid
24-joint `pico_bd_24` sample; incomplete data is omitted rather than replayed.
Top-level and Body timestamps use Unix nanoseconds, joint `t` retains the
OpenXR/PICO source timestamp, and `predictTime` is predicted-display time in
microseconds. Body poses remain in the raw OpenXR values because the legacy
PICO Unity SDK conversion and the old APP's `z/qz/qw` conversion cancel before
the packet reaches RoboticsService. Hand positions are also kept in OpenXR
coordinates; hand rotations explicitly remove Godot's fixed humanoid-bone
orientation adjustment before encoding. For PICO controllers, the right-hand
OpenXR `select_button` is accepted as the legacy right `menuButton`, while the
left mapping remains the dedicated Menu action. Independent Motion output is
disabled while Body is active because requesting it switches the PICO runtime
out of full-body mode. Settings may provide the legacy PICO `EQUIPMENT_SN`;
otherwise the app falls back to its platform unique id. Exact automatic
`EQUIPMENT_SN` lookup requires the PICO Enterprise service libraries, which are
not currently shipped in Operator.
The receive path accepts server frames headed by `0xcf`; the legacy `0x5f`
`timeTest` probe is answered with the same raw `timeTest` payload on `0x6d`.
The implementation lives under `xr/scripts/compat/xrobot_toolkit/` and requires
no robot-side changes or gateway process. This compatibility target covers TCP
`63901`; Episode HTTP and UDP discovery remain independent scopes.

XRoboToolkit FPV is a second, independently selectable video transport. It is
not sent through the Tracking connection. XR automatically binds the first
available local port in `12346..12353`, connects to the PC camera-command
service on TCP `13579`, and sends a length-prefixed `OPEN_CAMERA`. The PC then
connects back to the advertised PICO address and listener port. The local
receive port is transport state and is not an operator-facing setting.

```text
u32_be command_body_len
i32_le command_name_len
bytes  command_name             # OPEN_CAMERA or CLOSE_CAMERA
i32_le payload_len
bytes  payload
```

The `OPEN_CAMERA` payload is:

```text
u8,u8  magic                    # CA FE
u8     version                  # 1
i32_le width
i32_le height
i32_le fps
i32_le bitrate
i32_le enable_mv_hevc
i32_le render_mode
i32_le pico_video_listener_port
u8 + bytes camera_name
u8 + bytes pico_ipv4
```

The reverse video connection carries complete Annex-B H.264 access units:

```text
u32_be access_unit_len
bytes  annex_b_h264_access_unit
```

`XrtVideoSession` parses these access units and submits them to the same
`LiveVideoView` decoder used by Operator timed video. The wire format has no
source frame sequence or drop counter, so its transport-loss HUD value is
reported as `N/A`; local stale and decoder-busy drops remain available.

For automated PICO launches, Android intent extras map directly to the target:
`operator.teleop.host`, `operator.teleop.port`,
`operator.teleop.protocol=xrobot_toolkit_v1`, and
`operator.teleop.xrobot_toolkit_device_sn`. The latter should be the legacy
PICO `EQUIPMENT_SN` when the deployed RoboticsService identifies clients by SN.
`operator.teleop.pico_body_calibrate=true` opens PICO's body-tracking
calibration flow after XR startup. The same action is available from the
XRoboToolkit-compatible Teleop settings panel.

### Outside Robot descriptor v2

Every descriptor emitted by `robot-service` is normalized to version 2. Legacy
adapter descriptors remain accepted, but the bridge adds the execution
boundary, derives an input contract, and advertises common capabilities before
sending them to XR.

```yaml
descriptor_version: 2
execution:
  kind: outside
  environment: real       # real | simulation | unknown
input_contract:
  rate_hz: 60
  coordinate_space: robot_base
  channels:
    - {name: end_effector, type: pose6d, frame: active_hand}
capabilities:
  teleop: true
  emergency_stop: true
```

`robot-service` is authoritative for this entire descriptor. The client must
not infer a robot profile from `device.type`, and must not substitute a bundled
Inside Robot profile.

### Input sources are hand-agnostic

`input_mapping` sources use the `active_*` family rather than naming a hand:

```text
active_controller_pose  active_grip  active_trigger
active_joystick_x  active_joystick_y  active_joystick_click  active_button_b
```

`active_*` resolves client-side (`xr/scripts/input/control_mode.gd`) to the
DRIVING hand: the last controller to squeeze its grip, latched until that grip
releases, defaulting to whichever controller is active (preferring right) before
the first squeeze. One controller drives one arm, so a single-arm rig works with
either controller. Explicit `left_*` / `right_*` sources still exist for
mappings that must name a side.

`nudge_x` / `nudge_y` (axes) and `nudge_vertical` (button) are the thumbstick
fine-adjust: the adapter integrates them into a persistent robot-frame
end-effector offset at 30 mm/s, horizontal by default and vertical while the
stick click is held. They apply whether or not the deadman is held. This is a
Cartesian offset, so it is only honoured in `pose_mapping.mode: ik`.

### Telemetry values

Beyond `joint_angles` / `num_joints` / `connected`, the arm publishes the data
the headset needs to draw its control-frame overlay:

| key | type | meaning |
| --- | --- | --- |
| `operator_frame` | array[4] | Captured yaw-only control frame (xyzw). **Absent while the deadman is released** — that absence is the client's cue to hide the gizmo. |
| `pose_scale` | float | Hand-delta scale factor. |
| `pose_mirror` | bool | Lateral convention; `true` means hand-right → arm-right. |
| `nudge_offset` | array[3] | Current stick fine-adjust offset, metres, robot frame. |

The client renders the overlay from these rather than re-deriving the retarget
rule, so a change to `scale`/`mirror` in robot-side config cannot leave the
overlay silently lying about which way the arm will move.

**Dual-arm rigs publish this block once per side, prefixed** — `left_operator_frame`,
`right_pose_mirror`, and so on for all four keys. The two arms hold independent
reference frames and are configured with opposite `mirror` (see
`configs/so101_dual_real.yaml`), so one shared block would draw the right gizmo
with the left arm's lateral convention and point it the wrong way. Each side's
`{side}_operator_frame` is absent while *that* side's deadman is released, which
is how the headset hides one arm's gizmo while the other stays live.

Clients detect the dual layout by the presence of `left_pose_mirror` /
`right_pose_mirror`, not `*_operator_frame`: mirror is published unconditionally,
whereas the frame vanishes on release, so keying off the frame would make a dual
rig look single-arm the moment both operators let go.

Dexterous-hand integrations use flat six-element arrays so they remain valid
`DeviceTelemetry` values and can be merged into any arm adapter. The channel
order is thumb proximal flex (`Thumb`), thumb metacarpal
abduction/opposition (`ThumbAux`), index, middle, ring, pinky. The Quest
bare-hand mapper derives thumb flexion from thumb-joint bend and thumb
abduction/opposition from the metacarpal direction in the palm-local frame
so the two motors no longer mirror one scalar curl value.

| key | type | meaning |
| --- | --- | --- |
| `revo2_left_target` / `revo2_right_target` | array[6] | Last commanded normalized motor positions, 0 open to 1000 closed. |
| `revo2_left_position` / `revo2_right_position` | array[6] | Measured normalized motor positions. |
| `revo2_left_current` / `revo2_right_current` | array[6] | Filtered signed normalized motor current. This is a load proxy, not calibrated force. |
| `revo2_left_stall` / `revo2_right_stall` | array[6] | Per-motor contact/stall flags encoded as 0 or 1. |

The XR client renders target-to-actual displacement separately from current
intensity. It must not label position error as force because Revo2 Basic's
internal position-loop stiffness is not part of this protocol.

The hand adapter/runtime UDP link uses the version-2 `BCH2` packet. Bit `0x0001`
of its little-endian `u16` flags field requests an immediate current-position
hold. The runtime captures its own latest measured position for this operation;
the packet's position fields are only a backwards-compatible fallback. While a
previously active hand remains locked, the adapter repeats hold packets so one
lost UDP datagram cannot leave the previous motion target active.

### Adapter → plugin control state

`AdapterToLerobot::Control` carries two gates with strictly separate owners
(they previously contended over one field and cancelled each other out):

- `stopped` — e-stop latch. Set by `emergency_stop`/watchdog, cleared when fresh
  targets resume or on reset. Checked first, so it overrides everything.
- `enabled` — "the operator intends motion", i.e. deadman held **or** stick
  nudging. Owned solely by `ArmDriver::set_motion_allowed`.

## Discovery

Default port: `63900`.

The bridge advertises itself by UDP broadcast. XR listens with
`xr/scripts/network/discovery.gd`, fills the settings UI, and can still use
manual host entry or `adb reverse` loopback workflows.

## Pose UDP

Default port: `63902`.

High-frequency pose updates use sequence-aware UDP. Robot-side consumers drop
old sequence numbers rather than queue stale motion. This plane is separate
from the command TCP channel so slow consumers do not block fresh pose data.

## Telemetry TCP

Default port: `63903`.

Telemetry is a dedicated robot-to-XR stream. XR feeds it into session state and
UI status. The Rust side emits aggregate latency and device status from the
bridge/adapter runtime.

## Timed Video

Default port: `12345` for TCP and UDP.

The current video payload is timed H.264 access-unit data. Header integers are
big-endian.

```text
u64 frame_id
u32 nal_index
u32 nal_count
u32 pipeline_mode
u64 capture_start_ns
u64 capture_end_ns
u64 encode_start_ns
u64 encode_end_ns
u64 read_wait_ns
u64 parse_ns
u64 send_ns
u32 nal_len
bytes nal_data
```

XR parses this in `XRoboProtocol.decode_timed_video_frame()` and forwards
packet dictionaries to `TeleopPanel.report_video_packet()`, inherited from
`LiveVideoView`.

### UDP Fragmentation

Large timed-video packets are fragmented with the `NLFR` header:

```text
magic          4 bytes  "NLFR"
version        1 byte
flags          1 byte
fragment_index u16_be
fragment_count u16_be
frame_id       u64_be
timed_header   80 bytes on every fragment
payload        bytes
```

XR reassembles fragments in `xr/scripts/network/udp_video_handler.gd`.

## Inside Robot remote retargeting

Default development port: `8000`. This is a separate WebSocket protocol, owned
and served by pyoperator (`pyoperator serve --service retargeting`, or the
`retargeting-service` alias); it is not a robot-service control plane. The
protocol lives in `python/pyoperator/protocol/retargeting.py` and the service
in `python/pyoperator/services/retargeting.py`. Solving is delegated to the
`retargeting` library, which owns profiles, solvers, and model fingerprints and
never sees this protocol.

Endpoints:

- `GET /healthz` reports service and available profiles.
- `GET /v1/profiles` returns public profile metadata and model fingerprints.
- `WS /v1/retarget` creates one persistent, warm-started solver session.

The first WebSocket message is a versioned handshake:

```json
{"type":"hello","protocol_version":1,"profile_id":"unitree_g1","input_type":"skeleton_frame_v1","model_hash":""}
```

The service replies with `hello_ack` and its authoritative profile. XR checks
the protocol, profile id, input type, output type, and expected joint-vector
size. `model_hash` is optional for XR because the solver model is server-side;
deployment clients that possess the same solver artifact may supply it for an
exact fingerprint check.

Frames use monotonic ids and nanosecond timestamps:

```json
{"type":"frame","frame_id":42,"timestamp_ns":123456789,"payload":{}}
{"type":"result","frame_id":42,"profile_id":"unitree_g1","output_type":"joint_positions_v1","q":[]}
```

The server input queue and XR client pending slot are both latest-only. Slow
solves drop stale unsolved tracking frames instead of accumulating motion lag.
`{"type":"reset"}` clears solver warm-start state. Closing the WebSocket closes
the solver session and its persistent native worker. A native worker that does
not answer within its configured response timeout is terminated and the socket
closes with a server error instead of leaving a wedged session alive.

## Video Transport Selection

Device descriptors include video feed information. XR selects UDP only when a
feed advertises a usable `udp_port` and `transport` is `udp` or `auto`.
Otherwise it uses TCP. TCP remains the default because it works with USB
`adb reverse` smoke tests.

Relevant paths:

- `xr/scripts/app/modes/teleop_controller.gd`
- `xr/scripts/contracts/teleop/device_descriptor.gd`
- `robot/crates/teleop-protocol/src/descriptor.rs`
- `robot/configs/*descriptor*.yaml`

## Live Feed OLCP

Default development ports:

- `63910` - XR pushes capture frames to server.
- `63912` - XR pulls result frames from server.

OLCP v1 frame header:

```text
magic         4 bytes  "OLCP"
version       1 byte   1
frame_type    1 byte
flags         u16_be
pts_ns        u64_be
duration_ns   u64_be
payload_size  u32_be
payload       bytes
```

Flag registry:

- `0x0001` - keyframe (RGB packet).
- `0x0002` - composite payload: `u32_be JSON size`, UTF-8 JSON, then binary.
- `0x0004` - the binary portion is zlib-compressed.

RGB packets are already HEVC/H.264 encoded access units and receive no extra
transport compression. Depth's canonical decoded representation remains
little-endian `u16` millimetres. A depth producer may set `0x0004` per frame
when zlib reduces its size; receivers parse the optional composite prefix
first, then decompress the binary portion. Raw legacy depth frames remain
valid. Receivers must bound decompression (the Python implementation uses
64 MiB) and validate decoded size against `width * height * 2`.

XR push path:

- `xr/scripts/app/modes/capture_app_base.gd`
- `xr/scripts/app/composition/live_feed_composition.gd`
- `xr/addons/live-push/`

XR pull path:

- `xr/addons/live-pull/`
- `python/pyoperator/live_feed/server.py`

The pull connection starts with client-first `result_hello` (type 100). Its
`operator.result_hello.v1` JSON carries the same optional auth token as the
push-side `session_start`; a token-configured server authenticates it before
exposing result data or replacing the active XR client. The server then sends
`result_welcome` (type 102, `operator.result_welcome.v1`); only receipt of this
frame transitions XR from authenticating to connected.

The pull channel then carries `capture_request` (type 101): the server tells
the headset which streams to capture. Reconnecting also triggers a
`map_reset` plus a bounded current-state snapshot before live deltas resume. See
`claw/architecture/live-feed-cloud.md` for the negotiation flow and frame
type registry.

## Ego Upload TUS

Ego capture uploads finalized artifacts to a TUS 1.0.0 endpoint.

The required upload set is:

- `manifest.json` - session and file inventory. It records artifact kinds,
  filenames, byte sizes, hashes such as `sha256`, and upload/derivation state.
  It is the right place for information about files, including the final hash of
  `media.mp4`.
- `media.mp4` - the raw SpatialMP4 recording. New recordings should be
  self-contained for replay-critical sensor metadata; readers must not require
  extra files for calibration, timing, depth metadata, body extras, or motion
  trackers.

Optional artifacts include generated previews and Rerun `.rrd` files. Ingest
should use metadata embedded in `media.mp4` for replay-critical sensor data.

Creation:

```text
POST /api/ingest
Tus-Resumable: 1.0.0
Upload-Length: <bytes>
Upload-Metadata: session_id <b64>,artifact_kind <b64>,filename <b64>,schema <b64>
```

Chunk upload:

```text
PATCH /api/ingest/<resourceId>
Tus-Resumable: 1.0.0
Content-Type: application/offset+octet-stream
Upload-Offset: <offset>
Content-Length: <bytes>
```

XR uploader path:

- `xr/scripts/sinks/upload/ego_uploader.gd`
- `xr/scripts/sinks/upload/upload_queue_sink.gd`

Server path:

- `web/modules/ego-ingest/`
- `web/app/server.ts`
