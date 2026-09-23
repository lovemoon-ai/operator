# Wire Protocols

Operator uses several independent wire contracts. Keep them separate:

- Teleop control and telemetry between XR and the robot side.
- Timed H.264 video from `xr-bridge` to XR.
- OLCP Live Feed streams between XR and a server.
- TUS uploads from XR ego capture to web ingest.

## Headset timebase

The headset has exactly one sampling timebase, `godot_ticks_ns`: the Godot
`Time.get_ticks_usec()` domain expressed in nanoseconds. OpenXR `XrTime`,
Android `System.nanoTime()`, and Camera2 sensor timestamps are all mapped into
it through captured offsets. This table is the single timebase contract for
every wire and file format that carries headset sample times:

| Data | Where it is stamped | Domain |
| --- | --- | --- |
| Head / controller / hand pose (Ego tracks, OLCP) | `pose_sampler.resolve_pose_timestamp_ns`: OpenXR predicted display time (`XrTime`, `CLOCK_MONOTONIC`) + `getXrTimeToGodotTicksOffsetNs`, else Godot ticks | `godot_ticks_ns` |
| RGB (HEVC) | Encoder `bufferInfo.presentationTimeUs * 1000`; the camera plugin maps Camera2 sensor timestamps into the same domain | `godot_ticks_ns` |
| Depth | `depth_timestamp_source_priority: [openxr_runtime_display_time, godot_async_callback_ticks]` | `godot_ticks_ns` |
| Audio | `AudioCapture`: `System.nanoTime() + clockMonotonicToGodotTicksOffsetNs`; AAC frame 0 is anchored at the first microphone read | `godot_ticks_ns` |
| SpatialMP4 `operator_static` | `session_start_unix_us`, `session_start_godot_ticks_us`, `timebase_hz=1e6`, `media_pts_domain="godot_ticks_ns"`, `media_pts_clock="clock_monotonic_ns"` | contract record |
| OLCP `pts_ns` | Kotlin `enqueue(Frame(type, flags, timestampNs, ...))` passes the GDScript timestamp through unchanged; `session_start` carries `session_start_godot_ticks_us` | `godot_ticks_ns` |
| `XrStateFrame.timestamp_ns` / `sample_timestamp_ns` | `XrTrackingSource`, one timestamp per tick with the pose row's definition: predicted display time + the capture plugin's `XrTime` offset, else the sampling instant (builds without the capture plugin, such as the teleop profile). XrStateSink copies the `SensorFrame` timestamp; only a Pico body record's own `source_timestamp_ns` differs, and v1 strips it | `godot_ticks_ns` |

Alignment between Ego tracks therefore depends on every sampler stamping in the
same domain, not on any writer-side conversion. OLCP samples and
`XrStateFrame` share both domain and instant with the Ego tracks.

Rules:

- Samplers, encoders, plugins, `SessionSpoolWriter`, and `LivePushWriter` own
  timestamping. Component extraction moves code only; the timestamp a
  `SensorFrame` carries reaches every sink unchanged.
- There is no session-relative conversion on the wire. A consumer that needs
  relative time subtracts `session_start_godot_ticks_us` itself;
  `operator_xr.live_feed.SessionStartSample` exposes it, and
  `operator_xr.live_feed.align_by_timestamp` pairs OLCP samples with `XrFrame`s
  by timestamp.
- `XrStateFrame` timestamp semantics changed once, with the host-session
  channel unification: `xr_tracking_sampler` stamped the sampling instant
  (`_ticks_usec()*1000`, or TrackingProvider's read instant for head,
  controllers and controller input). Since `XrStateSink` replaced it, every
  `timestamp_ns` / `sample_timestamp_ns` in a frame is the tick's pose
  timestamp. With the predicted display time this is about one frame later
  than before. Field names, shape and domain are unchanged. Consumers checked:
  xr-bridge only reports the last value in its stats, `operator_xr` replay
  paces by deltas, and light-o1 / retargeting never read these timestamps.

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
- `xr/scripts/input/xr_state_sender.gd` (`xr_state` channel), fed by
  `xr/scripts/components/sources/xr_tracking_source.gd` →
  `xr/scripts/components/sinks/xr_state_sink.gd`

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

Embedded SDK consumers now configure these names through Python
`BridgeConfig.streams` / Rust `BridgeConfig.xr_streams`. The default is
`["head", "controllers", "hands"]`; body and independent trackers are opt-in.
SDK requests reject empty, duplicate or unknown names. The legacy wire semantics
of omitted/empty `streams` remain "all", so new SDKs never emit an empty request.
Requested body/motion data establishes a tracking lease in XR. System settings
own calibration and user confirmation; this is independent of Blueprint and
does not add a new wire schema or a remote "calibration completed" command.

SDK mode requires the headset `Hello.capabilities` list to contain
`xr_state_v1`; otherwise the connection is closed and the compatibility error
is exposed through Python bridge stats. Exactly one headset owns an embedded
SDK stream, and a newer connection replaces the old socket. `frame_id` is local
to the headset process and may reset after reconnect, so consumers treat a
different id as the next snapshot rather than assuming it is globally
monotonic.

### Host-declared capture streams

A host that wants headset media (camera, depth, OLCP pose streams) declares it
in the descriptor next to `xr_stream`. Rust:
`robot/crates/teleop-protocol/src/streams.rs`; Python:
`operator_xr.capture` (`BridgeConfig.capture_streams`).

```json
"capture_streams": {
  "schema_version": 1,
  "streams": [
    {"name": "rgb.hevc",  "required": true,  "max_hz": 4, "max_bitrate_bps": 2000000, "eye": "left"},
    {"name": "depth.u16", "required": false, "max_hz": 5}
  ],
  "local_tasks": [
    {"kind": "record", "container": "spatialmp4", "streams": ["rgb.hevc", "head_pose.json"]},
    {"kind": "upload", "endpoint_ref": "lab-ingest"}
  ]
}
```

- **Envelope.** The block declares the *set* of streams and their *upper
  limits* (`max_hz`, `max_bitrate_bps`, `eye` ∈ `left` / `mono` / `stereo`).
  That envelope is what the user grants, once per (host address, declaration
  hash); the descriptor is resent after every `Hello`, so a reconnect with the
  same declaration does not ask again. Stream names use the OLCP vocabulary
  (`rgb.hevc`, `depth.u16`, `head_pose.json`, `controller_pose.json`,
  `controller_input.json`, `hand_joints.json`).
- **`required` never blocks the connection.** A denied required stream only
  changes `StreamsStatus` and prompt priority; the host degrades itself.
- **The transport belongs to the session, not the declaration.** A host
  application never names an address, port or token. For a capture-capable
  headset, `xr-bridge` injects a sibling `media` block into the descriptor it
  sends on that connection:

  ```json
  "media": {"protocol": "olcp.v1", "push_port": 63905, "result_port": 63906,
            "auth_token": "<minted per headset connection>"}
  ```

  The headset pushes granted streams as OLCP sessions to the *connected peer's
  address* (never a declared one) on `push_port`, and pulls results from
  `result_port`, carrying the in-band `auth_token` (see
  [Live Feed OLCP](#live-feed-olcp) for the frame format, which is identical).
  The token is valid only while that ctrl connection owns the session: when it
  ends or is replaced, both media connections close. `media` is absent when the
  headset lacks `capture_streams_v1`, when the host declares no
  `capture_streams`, and on the adapter path, which serves no media.
- **`local_tasks`** ask the headset to `record` locally or `upload` to an
  ingest endpoint. `endpoint_ref` names an endpoint already configured and
  verified on the headset; URLs and `host[:port]` values are rejected.

The headset advertises `capture_streams_v1` in `Hello.capabilities` when it
understands the block, plus `stream.<name>` (for example `stream.rgb.hevc`) for
every stream it can produce. Two ctrl commands then use the same TCP envelope.
They are not Blueprint messages:

- `StreamsStatus` (headset → host, `operator.streams_status.v1`), sent after
  negotiation, permission changes, capability narrowing, and each
  `StreamsControl`. Stream `state` ∈ `pending` / `active` / `paused` /
  `denied`; local task `state` ∈ `pending` / `running` / `idle` / `denied` /
  `failed`. Optional `reason` ∈ `permission_denied` / `revoked` /
  `unsupported` / `limit` / `unknown_endpoint`; `limit` accompanies an
  active/paused stream whose parameters were clipped to the envelope.

  ```json
  {"schema": "operator.streams_status.v1",
   "streams": {"rgb.hevc":  {"state": "active", "hz": 4, "bitrate_bps": 2000000, "eye": "left"},
               "depth.u16": {"state": "denied", "reason": "permission_denied"}},
   "local_tasks": {"record": {"state": "running"},
                   "upload": {"state": "denied", "reason": "unknown_endpoint"}}}
  ```

- `StreamsControl` (host → headset, `operator.streams_control.v1`) adjusts
  parameters inside the granted envelope without re-asking the user. Every
  field is optional (`hz` > 0, `bitrate_bps` > 0, `paused`; `local_tasks`
  entries take `running`). The headset clips out-of-envelope values and reports
  `limit`.

  ```json
  {"schema": "operator.streams_control.v1",
   "streams": {"rgb.hevc": {"hz": 2, "bitrate_bps": 1000000, "paused": false}},
   "local_tasks": {"record": {"running": true}}}
  ```

`xr-bridge` keeps the latest validated `StreamsStatus` (latest-wins, cleared
when that connection ends) and queues `StreamsControl` in order, forwarding it
only to a headset that advertised `capture_streams_v1`. On the adapter boundary
they travel as `BridgeToAdapter::StreamsStatus` (sent only to adapters whose
descriptor declares `capture_streams`) and `AdapterToBridge::StreamsControl`;
the bridge drops an invalid adapter declaration instead of forwarding it. The
standalone hosted path exposes them through `operator_xr.hosted.HostedStreams`,
which declares streams but carries no media: capture media requires the
embedded `XrSession`, whose `BridgeConfig.media_up_port` / `media_down_port`
(default `63905` / `63906`) are the ports the bridge advertises.

Compatibility:

| Headset | Host | Behaviour |
| --- | --- | --- |
| Old APK | declares `capture_streams` | Unknown field ignored; no `capture_streams_v1`, no `StreamsStatus`. The host treats every declared stream and task as `denied` / `unsupported` (`XrSession.streams_status()` synthesizes this) and never sends `StreamsControl`. |
| New APK | no `capture_streams` | Descriptor unchanged; behaviour is exactly as before. |
| New APK | declares `capture_streams` | Envelope prompt, `StreamsStatus`, `StreamsControl` as above. |

### Robot-authored Blueprint

An Operator session may also advertise `blueprint_v1`. Both the embedded
`XrSession` path and the standalone `xr-bridge` + operator_xr hosted adapter path
support it. The protocol is mode-independent. Outside Robot is the first
integration; VR operation or Realtime Feed can reuse the same contract through
their own lifecycle adapters. Inside Robot does not currently use it because it
has no external robot session.

Capability negotiation is content-addressed. A Blueprint-producing descriptor
must contain both `blueprint_v1: true` and
`blueprint_spec_sha256: <generated digest>`. The headset advertises
`blueprint_v1` plus `blueprint_v1@sha256:<generated digest>` in `Hello`.
`xr-bridge` enables the stream only when both hashes equal its own generated
digest. A hosted adapter without a `HostedBlueprint` does not advertise either
descriptor capability. A mismatch is logged and disables only Blueprint; the
control, telemetry, and video paths remain connected. The headset also verifies
the descriptor hash itself instead of relying only on the bridge's forwarding
decision.

Blueprint uses the command TCP connection and three versioned JSON payloads:

- `Blueprint` (`operator.blueprint.v1`) replaces the complete
  component tree. A JSON `null` payload clears it.
- `BlueprintState` (`operator.blueprint_state.v1`) replaces
  the complete binding-value snapshot for one blueprint id and revision.
  Sequence numbers are strictly increasing within that revision; XR rejects
  stale or mismatched states.
- `BlueprintEvent` (`operator.blueprint_event.v1`) carries
  ordered interaction events from XR to Python. The bridge rejects events for
  a blueprint id or revision that is no longer active.

Version 1 intentionally accepts only built-in XR primitives. Their complete,
normative definitions live in `specs/blueprint/v1.json`; generated Python,
Rust, and GDScript bindings keep callers, transport validation, and the headset
runtime aligned. Payloads cannot contain GDScript, scenes, shaders, model URLs,
or executable callbacks. In particular, `DeviceDescriptor.video_feeds`
negotiates the transport and decoder input, while `video_panel` controls
Blueprint-driven visibility.
Hiding or omitting `video_panel` does not disconnect, stop decoding, or alter
the packet path.

Revision, sequence, and timestamp fields are non-negative JSON integers (not
integral JSON floats) and must not exceed `9223372036854775807`, the common
signed 64-bit range accepted by Python, Rust, and Godot. Blueprint color strings
are limited to HTML hexadecimal forms (`#rgb`, `#rgba`, `#rrggbb`, or
`#rrggbbaa`); colors may also be encoded as three- or four-element numeric
arrays.

The v1 limits and all primitive properties, bindings, anchors, defaults,
constraints, events, host kinds, and singleton rules come from the canonical
spec. Python validates authored definitions and bound values, Rust validates
the transport payload, and XR revalidates untrusted wire data before creating
nodes or changing an external view. All three execute generated value-type
conformance cases. Binding ranges and array lengths are enforced before state
is forwarded, state keys not declared by any component binding are rejected,
and reuse of one state key with incompatible value contracts is rejected. The
spec generator rejects unknown semantic keys so a spec extension cannot be
accepted until its consumers are intentionally updated.

`user_overridable` controls local precedence. For overridable components, a
visibility choice stored on the headset under the blueprint id wins over the
robot-provided `visible` property or binding. Teleop settings exposes Follow
Robot, Show, and Hide choices; `properties.settings_label` may provide the
human-readable row name. Non-overridable components ignore local visibility
changes. Opening Teleop settings suspends Blueprint interaction and rendering
without discarding the blueprint; disconnecting,
switching targets, clearing from Python, or leaving Teleop removes it.

The data path is designed not to become a control-loop bottleneck. Blueprints
are low-frequency structural updates. Embedded Blueprint state is a Rust
`watch` value; hosted operator_xr uses the same latest-snapshot semantics and a
single coalesced wake-up per connected bridge. A slow socket writer therefore
does not build an unbounded state queue. The socket reader remains a separate
task, and XR state/control sampling does not wait for Blueprint rendering.
On the headset, bound properties are recomputed only when state changes; each
render frame updates only dynamic head/controller/palm anchors, while palm
gesture work stays entirely local.

For the standalone bridge path, the local adapter boundary carries
`Blueprint` and `BlueprintState` from adapter to bridge, and
`BlueprintEvent` from bridge to adapter. These frames are optional;
adapters that do not publish a blueprint retain control and media transport,
but native Operator Teleop renders no robot visualization. The system-owned
settings launcher remains available for reconnecting or changing targets.

### XRoboToolkit compatibility TCP

Outside Robot settings may select `xrobot_toolkit_v1` instead of the Operator
session protocol. This is a separate wire format and a separate TCP connection;
it is never nested inside `XRoboProtocol` and cannot be active at the same time
as `DeviceCommand` or `XrStateFrame`.

`blueprint_v1` is not part of the XRoboToolkit v1 compatibility
protocol. Selecting XRoboToolkit clears any active Operator Blueprint, and
the XRT connection carries no Blueprint, Blueprint state, or UI event
messages. Supporting robot-authored UI there would require a separately
versioned XRT extension or an additional side channel.

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
24-joint `pico_bd_24` sample; incomplete data is omitted rather than replayed,
and it ships on every tracking frame rather than on a slower sub-cadence — the
legacy consumer re-reads Body on its own ~70 Hz timer, so a slower sender only
feeds it duplicates.

Thumbsticks, triggers and grips pass through a `0.05` deadzone before encoding.
The receiving stack feeds these straight into a base-velocity command and has no
deadzone of its own, so an untouched controller's few-thousandths of rest noise
would otherwise become a slow unattended drift. The thumbstick band is radial,
not per-axis, and values outside the band are not rescaled.

Section presence is the protocol's stop signal, and the three sections are not
symmetric:

- `Controller` and `Hand` are **sent and neutralized**. The peer latches the last
  section it saw and only clears it when a new one arrives, so omitting them
  leaves a held trigger held and the fingers driving from the last grasp.
- `Body` is **omitted**. An absent `Body` reads as "no body this frame" and
  stops; 24 identity poses do not — they are a valid skeleton that retargets to a
  rest pose, and a humanoid told to hold a rest pose walks its limbs there.

`Hand` is additionally all-or-nothing: both `leftHand` and `rightHand`, or no
section. The peer indexes them without checking they exist, and one unguarded
throw discards the whole frame, `Body` included.
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
`63901` and the UDP `29888` robot beacon below; Episode HTTP remains an
independent scope. The whole compatibility surface is gated to Pico builds:
non-Pico exports never show the protocol choices, never start the beacon
listener, and normalize persisted XRT settings back to Operator.

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
`operator.teleop.xrobot_toolkit_device_sn`. Set
`operator.teleop.show_video_panel=true` to override the persisted panel toggle
for that launch without rewriting the saved settings. The device-SN extra
should be the legacy PICO `EQUIPMENT_SN` when the deployed RoboticsService
identifies clients by SN. The settings page has no SN field; without the
extra the sender identifies the headset by its own unique id.
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

Dual-arm descriptors that support both controller and bare-hand operation use
`left_arm_pose` / `right_arm_pose` and `left_arm_grip` / `right_arm_grip`.
Each pair selects a physical controller when its interaction profile is active;
otherwise it selects the optically tracked wrist pose and derives the deadman
value from finger flexion. Controller-inferred hand joints are not accepted as
a second deadman source.

The G1-D Revo-1 controller profile maps trigger to a side-specific fixed grasp
action. Pressing past the hysteresis threshold drives all five supported motors
to the configured grasp target; release drives them to open. Grip remains the
arm IK deadman. A side-specific `*_controller_active` source keeps the hand
stream enabled while that controller is tracked. Tracking loss holds the latest
measured pose. Revo-1's unused ThumbAux DDS slot is held at measured position.

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
order is thumb metacarpal opposition (`Thumb` / `thumb_aux`), thumb proximal
flexion (`ThumbAux` / `thumb_flex`), index, middle, ring, pinky. The Quest
bare-hand mapper derives thumb flexion from thumb-joint bend and opposition
from the metacarpal direction in the palm-local frame plus a scale-normalized
thumb-index pinch constraint. Per-hand One-Euro filtering and a `0.008` output
deadband suppress tracking shimmer without adding a fixed low-pass delay.

| key | type | meaning |
| --- | --- | --- |
| `revo2_left_target` / `revo2_right_target` | array[6] | Last commanded normalized motor positions, 0 open to 1000 closed. |
| `revo2_left_position` / `revo2_right_position` | array[6] | Measured normalized motor positions. |
| `revo2_left_current` / `revo2_right_current` | array[6] | Filtered signed normalized motor current. This is a load proxy, not calibrated force. |
| `revo2_left_stall` / `revo2_right_stall` | array[6] | Per-motor contact/stall flags encoded as 0 or 1. |
| `revo2_left_touch_normal` / `revo2_right_touch_normal` | array[5] | Raw per-finger normal tactile magnitude in thumb, index, middle, ring, pinky order. |
| `revo2_left_touch_tangential` / `revo2_right_touch_tangential` | array[5] | Raw per-finger tangential tactile magnitude. |
| `revo2_left_touch_direction` / `revo2_right_touch_direction` | array[5] | Raw per-finger tangential direction reported by the hand firmware. |
| `revo2_left_touch_proximity` / `revo2_right_touch_proximity` | array[5] | Raw per-finger capacitive proximity magnitude. |
| `revo2_left_touch_status` / `revo2_right_touch_status` | array[5] | Raw per-finger firmware status word for diagnostics. |

The XR client renders target-to-actual displacement separately from current
intensity. It must not label position error as force because Revo2 Basic's
internal position-loop stiffness is not part of this protocol.

Touch-capable Revo2 hands add five fingertip samples rather than six motor
samples because the thumb flexion and opposition motors share one physical
thumb tactile sensor. Raw values remain uncalibrated on the wire. The XR client
uses a logarithmic relative-intensity mapping and must not label them as newtons.

The current hand adapter/runtime UDP link uses the version-3 `BCH2` packet,
whose six position and speed values follow the channel order above. Version 2
is retained only for legacy HoloMotion receivers, where the first two channels
were flexion then opposition. Bit `0x0001` of the little-endian `u16` flags
field requests an immediate current-position hold. The runtime captures its own
latest measured position for this operation; the packet's position fields are
only a backwards-compatible fallback. While a previously active hand remains
locked, the adapter repeats hold packets so one lost UDP datagram cannot leave
the previous motion target active.

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

### XRoboToolkit robot beacon

Default port: `29888`.

A separate, non-overlapping broadcast domain: XRoboToolkit hosts announce
themselves in their own binary format on their own port, so Operator has to
listen for both to populate one settings list.

```text
u8      0xCF
u8      0x7E
i32_le  ip_length
bytes   ip                       # ASCII dotted quad
i64_le  unix_timestamp_ms
u8      0xA5
```

`xr/scripts/compat/xrobot_toolkit/xrt_discovery.gd` listens, and a parsed
beacon is offered as an `xrobot_toolkit_v1` peer on TCP `63901`. Because `29888`
is a shared LAN broadcast port, the parser validates magic bytes, exact total
length, trailer, and that the address field is a real IP before anything reaches
the connect path. The payload address wins over the datagram's sender address so
a multi-homed host advertises the interface it wants used. A host that stops
broadcasting for ten seconds is dropped. Entries discovered on Operator's own
`63900` protocol always take precedence over a beacon for the same address.

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
and served by operator_xr (`operator serve --service retargeting`, or the
`operator-retargeting` alias); it is not a robot-service control plane. The
protocol lives in `python/operator_xr/protocol/retargeting.py` and the service
in `python/operator_xr/services/retargeting.py`. Solving is delegated to the
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
- `xr/scripts/app/composition/ego_capture_composition.gd`
- `xr/scripts/components/sinks/live_push_sink.gd`
- `xr/addons/live-push/`

XR pull path:

- `xr/addons/live-pull/`
- `python/operator_xr/live_feed/server.py`

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
