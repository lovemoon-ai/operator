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

Rust implementation:

- `robot/crates/teleop-protocol/src/wire.rs`
- `robot/crates/teleop-protocol/src/transport.rs`
- `robot/crates/xr-bridge/src/pose_server.rs`
- `robot/crates/robot-adapter/src/server.rs`

The v2 session starts with Hello and device descriptor negotiation. Old peers
can still fall back to the legacy path through `Session`.

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

XR push path:

- `xr/scripts/app/modes/live_feed_mode.gd`
- `xr/scripts/app/composition/live_feed_composition.gd`
- `xr/addons/live-push/`

XR pull path:

- `xr/addons/live-pull/`
- `examples/live-feed-demo/operator_live_feed_server.py`

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
