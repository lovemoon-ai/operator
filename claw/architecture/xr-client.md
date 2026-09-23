# XR Client Architecture

`xr/` is a Godot 4.5 Android XR project. It uses the mobile renderer, OpenXR
alpha-blend passthrough, and Android plugins for capture, QR scanning, live
streaming, and video decode.

## Top-Level Layout

```text
xr/
  project.godot
  scenes/                  .tscn scene resources and shaders
  scripts/
    app/                   launcher, modes, feature composition
    components/            capability layer: sources, sinks, views, permissions
    session/               host session (1:1) and ingest session (N:1)
    core/                  reusable capture/sensor/time/pipeline logic
    contracts/             typed data contracts
    sinks/                 output adapters
    ui/                    UI controls and XR panels
    teleop/                Inside/Outside targets, profiles, retargeting clients
    network/               teleop protocol clients
    compat/                third-party wire-protocol compatibility layers
    platform/              Quest/Pico/OpenXR capability registry
    xr/                    OpenXR helpers and capture provider registry
    test_support/          on-device test framework
  addons/
    live_video/            reusable H.264 video panel
    live-push/             XR-to-server live feed path
    live-pull/             server-to-XR result path
    *_capture_android/     vendor capture providers
```

`xr/scripts` root is intentionally empty. New scripts should be placed under
the responsibility-specific directories above.

## Scenes And Scripts

Scenes remain necessary because they define Godot node graphs, transforms,
SubViewport/Viewport2DIn3D resources, shaders, and plugin scene instances. UI
logic does not live in scenes anymore; scene resources attach scripts from
`xr/scripts/ui` or `xr/scripts/app`.

| Scene | Script | Notes |
| --- | --- | --- |
| `scenes/main.tscn` | `scripts/app/launcher/mode_select.gd` | Mode launcher. |
| `scenes/teleop_main.tscn` | `scripts/app/modes/teleop_mode.gd` | Thin mode entry point extending `teleop_controller.gd`. |
| `scenes/robot_view/robot_view.tscn` | `scripts/ui/teleop_panel.gd` | Teleop video panel scene. |
| `scenes/capture_app.tscn` | `scripts/app/modes/ego_capture_mode.gd` | Ego capture mode; the Output (`local` / `ingest` / `both`) chooses the sinks. |
| `scenes/vr_mode.tscn` | `scripts/app/modes/vr_mode.gd` | Minimal OpenXR VR mode. |
| `scenes/mujoco/mujoco_device_test.tscn` | `scripts/app/modes/mujoco/mujoco_device_test.gd` | Device smoke scene. |
| `scenes/test_runner.tscn` | `scripts/test_support/runner/test_runner_root.gd` | Module test harness. |

`scripts/ui/teleop_panel.gd` is a small Operator wrapper around
`addons/live_video/live_video_view.gd`. Video decode, access-unit assembly,
AHB/YUV/RGBA presentation, and latency HUD behavior belong to the addon.

## App Modules

`scripts/app/launcher/mode_select.gd` is the boot scene script. It reads
feature tags through `FeatureSet`, renders launcher cards, handles automation
mode intent extras, and routes to mode scenes.

Every launcher card is gated by one `operator_feature_mode_*` flag, Exit
included; there is no separate launcher-card mechanism. A card is visible
only when its flag is set in the preset that produced the APK, so the
shipped card set is a build-time decision. Automation intent extras
(`--es operator.mode <id>`) bypass the cards entirely and are not gated by
these flags, which is how the Live Feed E2E enters Ego capture with the
`ingest` Output.

`scripts/app/modes/` contains scene lifecycle entry points:

- `teleop_mode.gd` extends `teleop_controller.gd`.
- `ego_capture_mode.gd` extends `capture_app_base.gd`.
- `vr_mode.gd` owns the standalone VR scene.
- `mujoco/mujoco_device_test.gd` owns the MuJoCo device smoke flow.

`scripts/app/composition/` is the composition root: given an effective
composition it instantiates components and connects them. It holds no policy
of its own.

- `teleop_composition.gd` wires command output and robot control.
- `ego_capture_composition.gd` maps an Output (`local` / `ingest` / `both`) to
  the mounted sinks; `capture_pipeline.gd` interprets that wiring and owns the
  capture lifecycle for both the Ego mode and a host session.
- `host_capture_composition.gd` turns a host's `capture_streams` declaration
  plus the user's grant into a running composition (loaded by path: the Teleop
  presets ship no capture stack).

## Components And Sessions

The capability layer is one component per capability, with a single
`source -> StreamBinding -> sink` dataflow. Every sink receives the same
`SensorFrame` with its timestamp unchanged; views consume only ctrl messages
and `media_down`, never `SensorFrame`s.

| Directory | Contents |
| --- | --- |
| `components/sources/` (Node) | `camera_source.gd`, `depth_source.gd`, `audio_source.gd`, `hand_source.gd`, `xr_tracking_source.gd` |
| `components/sinks/` (RefCounted) | `live_push_sink.gd` (OLCP `media_up`), `xr_state_sink.gd` (XrStateFrame encoder) alongside `sinks/spatialmp4`, `sinks/upload`, `sinks/robot_control` |
| `components/views/` (Node3D) | `dense_map_view.gd`, mounted under a Blueprint `dense_map` external view or as the ingest minimap |
| `components/permissions/` (RefCounted) | `permission_table.gd` (category to policy, grants remembered per host and declaration hash), `stream_planner.gd` (declaration x local limits x permission x advertised capability), `endpoint_registry.gd`, `endpoint_verifier.gd` |
| `session/` | `host_session.gd` (1:1; the only place ctrl commands are sent and received), `host_discovery.gd`, `ingest_session.gd` (N:1) |

Declarations and permissions only enter `StreamPlanner`; it only decides what
to connect and never touches data.

## Core Modules

- `scripts/core/capture/` - session state machine, writer adapters, spool
  writers, and live writer adapters.
- `scripts/core/sensors/` - pose, depth, and controller samplers plus the
  GDScript decision logic for hand/body/motion capture.
- `scripts/core/pipeline/stream_binding.gd` - binds capture streams to sinks.
- `scripts/core/time/timebase.gd` - timestamp domains and conversion metadata.
- `scripts/contracts/` - stable GDScript contracts used by modes, sinks, and
  tests.
- `scripts/sinks/` - concrete outputs: SpatialMP4, upload queue, robot
  control, and the sink contract.
- `native/hand_capture/` - GDExtension owning the hot joint-capture paths in
  C++: `NativeOpenXRHandCapture` owns Quest/PICO `XR_EXT_hand_tracking`
  trackers and writes MP4 HJNT on an independent 60 Hz worker clock;
  `NativeHandSampler` handles render-driven live push;
  `NativeBodyMotionWriter`
  packs/serializes body joints and motion-tracker records into MP4 metadata
  tracks. GDScript keeps only the
  per-frame trigger, runtime selection, and diagnostics.
- `native/pico_openxr/` - PICO OpenXR bridge; camera RGB frames are pumped
  by a dedicated native worker: `XR_PICO_camera_image` raw RGBA pointer -> GLES
  eye textures -> GPU stereo composition -> NDK MediaCodec input Surface ->
  native SpatialMP4 ABI. The hot path never creates a GDScript
  `PackedByteArray` or Java `ByteArray`; a reusable CPU staging buffer is used
  only for an incompatible runtime pixel/row layout. The shared
  `native/hand_capture` worker supplies the independent 60 Hz hand stream for
  both Quest and PICO. GDScript starts/stops the workers, provides the
  OpenXR-to-Godot clock offset, and drains small
  `QcCamera` diagnostic counters only. The PICO API currently exposes raw RGBA
  instead of a texture/AHardwareBuffer, so one native client-memory-to-GPU
  upload remains unavoidable.

PICO RGB configuration is runtime capability-driven. After the OpenXR session
starts, the bridge enumerates camera ids, per-eye resolutions, formats,
transfer types, and frame rates through `XR_PICO_camera_image`. The settings UI
shows the common stereo resolution set (or the left-camera set for mono) and an
`Auto` choice. `Auto` passes no preferred dimensions, allowing the runtime to
select a supported configuration; an explicit choice must be negotiated
exactly or capture is rejected. No product model, codename, or device serial is
used to select a camera profile, so the same `Pico` export is shared by PICO
headsets with different camera shapes.

## UI Pointer Ownership

`OperatorInteraction` selects the UI input source and supplies the same
controller eligibility decision to `SettingsInteractionRouter`. A tracked
bare-hand aim on the right must not displace a physical controller on the left.

OpenXR profile names are useful but can lag a hand/controller switch on Pico.
In the shipped action map, `trigger`, `grip`, joystick and physical button
actions are controller-only; bare hands use `hand_pinch`/`hand_pinch_ready`.
Fresh per-action press edges can therefore override a stale hand profile.
Fallback ownership survives release/idle, but is reset on tracker/profile
replacement or application pause/resume, and is relinquished by a new explicit
bare-hand pinch. Merely receiving optical hand joints does not steal ownership.
Existing held values are baselined on source changes, not replayed as new presses.

Pose selection requires finite, non-degenerate transforms as well as tracking
flags: Pico can mark an aim pose tracked while its orientation contains NaN.
A usable default pose is the fallback. The router rejects non-finite node
transforms, and the visual rebuilds a unit-scale basis for each accepted sample
instead of preserving a previously contaminated scale through `look_at()`.

Use `--es operator.interaction_debug 1` for opt-in on-device snapshots. They
include the runtime profile, selected pose, fallback ownership, hit target and
ray mesh visibility/transform. A running renderer or a valid pose alone is not
proof that a ray was actually displayed.

## Teleop Runtime

`teleop_controller.gd` presents one Teleop entry and creates exactly one
`TeleopTarget` at runtime:

- `OutsideRobotTarget` connects to `robot-service`. The returned descriptor is
  authoritative for robot identity, input mapping, capabilities, telemetry,
  video, and whether execution is real or simulated. XR does not show a local
  robot-type selector for this target.
- `InsideRobotTarget` owns the in-headset embodiment and exposes the robot
  profiles this build ships. Native mode runs the solver locally. Remote mode
  sends canonical tracking frames to the operator_xr retargeting service; only
  the solve is remote and the embodiment remains in XR.

The settings page has one `Robot Control` group. Its first row picks the
type — `Inside` or `Outside` — and only that side's settings are shown: the
robot picker and retargeting backend for Inside, or discovery, address, and
connection state for Outside.

The discovered-host list belongs to one wire protocol at a time. A host only
answers the protocol its beacon announced, so choosing a protocol re-lists the
endpoints that speak it and hides the rest rather than offering rows that
cannot connect; a beacon predating the protocol field is an Operator host. Host
labels carry an unbounded robot name and address, so the page widens its
composition layer — viewport and quad together, keeping text the same physical
size — to fit the longest row instead of clipping it.

A configuration item's Test action is diagnostic preview only; it must not be
the owner of runtime state. `Connect` is the activation boundary: the selected
target starts, required transports connect, every enabled runtime
visualization becomes active, and the page stays open reporting the outgoing
frame rate in its title bar so the operator can see frames actually leaving the
headset. `Disconnect` stops the target and clears that indicator.
Descriptor-driven features may be pre-enabled from discovery metadata for
immediate disconnected/connecting feedback, then must be reconciled against
the authoritative descriptor returned by the live session.

Opening or closing the page does not move the link: its streams and any
running Inside embodiment carry on, so the send rate the page reports describes
a live session. Only `Connect` and `Disconnect` move the link, and the rate
reads `Not sending` whenever the link is up but no frames are leaving. What
the page guards is input. While the pointer rests on or presses the page,
every controller key, the grip deadman included, is neutralised for all
senders, so frames keep flowing but cannot steer the robot; touch-driven
Blueprint widgets are suspended and the Revo2 palm unlock re-locks while the
page is open. The bottom action closes the page and saves display
preferences, never the endpoint: launch auto-connect only targets an endpoint
that `Connect` saved.

`Display` options are the live view rather than a staged form, so each applies
and persists the moment it is flipped. `Show VR Pose` renders the canonical
skeleton in every scope: an Inside session anchors it beside the in-headset
robot, and every other scope gets a head-tracked skeleton owned by the Teleop
controller. `Main menu placement` chooses whether the page follows the head or
stays pinned to the spot it was opened at.

For descriptor-driven dual-hand control, the left bare hand owns a palm menu.
The menu appears only after the tracked palm faces the headset with all five
fingers open for a stable interval, uses wider exit thresholds to avoid pose
jitter, follows below the hand with filtered motion, and billboards toward the
head so its text remains readable. Only the tracked right index fingertip can
press its controls; it is not registered as a ray target. A touch must be armed
outside the press volume before entry, remains latched until release, and never
unlocks merely because the menu appeared. Disconnect, reconnect, settings-open,
and Teleop-exit boundaries restore the locked state. Per-hand joint validity
continues to gate each hand independently, so losing one hand stops only that
side. The implementation uses the shared OpenXR joint path for identical Quest
and Pico behavior.

How an Inside robot is drawn depends on what its profile declares. A profile
with an `overlay_script` uses that bespoke, retargeting-aware overlay
(the humanoids). Otherwise a `visual_model` GLB is rendered by
`mujoco_mesh_view.gd`, which binds the bundle's nodes to the simulation's
bodies by name (the URDF `_link` suffix is normalised away) and drives them
from MuJoCo body transforms; robots with neither fall back to the debug
skeleton. Adding a robot therefore does not require writing a renderer.

Inside robots are not hardcoded. `RobotProfileRegistry` scans the manifests in
`xr/assets/robot_profiles/*.json` and offers a profile only when every path in
its `required_assets` is present, because robot bundles under `assets/robots/`
are generated per checkout (`scripts/make-robot/`) rather than committed. A
build without a robot's meshes withholds it and names it under the picker
instead of offering an embodiment it cannot render. Adding a robot therefore
means generating its assets and dropping a manifest beside the others — no
GDScript change. Manifests must stay in each preset's export `include_filter`,
or the packed build discovers nothing.

Changing target or leaving Teleop stops the old target before creating the new
one. Target-owned tracking providers, solvers, sockets, overlays, and
simulations are therefore released as one lifecycle unit. The controller panel
can show `REAL`, `SIM`, or `OUTSIDE` from the active descriptor, but native
Outside Robot sessions render it only when their Blueprint declares the
`controller_help` built-in view.

The Outside target creates the v2 network stack at runtime:

- `Session` for Hello, descriptor, telemetry, and Blueprint messages.
- `BlueprintRuntime` for mode-independent declarative XR UI. It
  instantiates built-in `robot_model`, `ground_grid`, `model_lighting`, `input_binding`, `label`, `status_lamp`, and
  `fingertip_tactile` components and gates the existing `video_panel`,
  `controller_help`, `control_frame`, and `operation_trajectory` views. It binds
  latest state values, persists permitted visibility overrides, exposes Follow
  Source / Show / Hide choices in Teleop settings, and sends interaction events
  back through `Session`. Outside Robot is currently the adapter that owns this
  runtime. A separate locally authored system Blueprint keeps the controller
  connection/recenter menu and status lamps available without a robot Blueprint.
  The controller menu is a runtime menu: it is disabled while the settings page
  is open, and while no robot is connected its connection row reads `Connect a
  robot` and opens Settings on the robot group instead of connecting on its own.
  `menu_item` and legacy `palm_menu`/`controller_menu` contribute data to the
  single `SystemMenuHost`; hand/controller presenters share that system-owned
  panel. Remote declarations never allocate independent menus. Source tokens
  preserve remote event identities and cannot invoke local connection actions.
  Disconnect clears only the robot scope; local transport actions never enter
  the robot event stream. The `input_binding` primitive arbitrates dual-trigger
  holds before pointer clicks and waits for matching host acknowledgements
  before confirmation haptics. Recenter is a persistent local display offset,
  not a reset of the host's simulation or root pose.
- `CommandSender` for controller/tracking command frames.
- `XrStateSender`, the `xr_state` channel: one atomic tracking snapshot per
  tick when `xr_stream` is advertised by an embedded `operator_xr` session.
- `RobotControlSink` as the mode-facing command output.
- `TcpHandler` for command and TCP video streams.
- `UdpVideoHandler` for UDP timed video packets.
- `XrtVideoSession` for the optional XRoboToolkit camera-command and reverse
  FPV TCP flow.
- `RobotClockSync` for latency reporting.
- settings and controller overlays from `scripts/ui`.
- `EEPoseTrajectory` for the optional Blueprint-gated, descriptor-driven
  operation trail. It
  observes successfully queued `DeviceCommand` poses, renders independent
  left/right world-space paths, keeps the latest two deadman segments per hand,
  and starts a new segment after each release so inactive controller motion is
  never joined into the trail. A successfully queued reset-to-home command
  clears both hands' trails before its bundled poses can be rendered.

The Blueprint runtime is deliberately mode-independent and separate from the
tracking/control hot path. A blueprint rebuild happens only when its source
publishes a new structural revision. State updates refresh bound properties;
the per-frame loop contains only components attached to moving head,
controller, or palm anchors. Opening Settings suspends those components, while
the owning mode suspends or clears it. The current Teleop adapter clears it on
disconnect, target replacement, Python `clear()`, and Teleop exit so an old
robot cannot leave stale UI in the next session. XR owns all palm
tracking and touch interaction, so no hand-joint stream is echoed back merely
to render a menu.

Video transport is descriptor-driven. TCP is the default and supports USB
`adb reverse`; UDP is selected when the descriptor advertises a usable UDP
port and `transport` is `udp` or `auto`.

The Teleop settings surface also exposes an independent `Video` group. It can
connect directly to Operator timed H.264 at a configured host/port, or select
XRoboToolkit FPV compatibility. The compatibility path opens its own command
connection and local reverse-video listener; it never passes XRT frames through
the Operator 80-byte timed-video parser. Both paths converge on
`LiveVideoView`, including mono/SBS display, controller-ray distance adjustment,
and a separate performance bar above the video with reset-position control. The
video `Connect` action temporarily forces the shared preview visible while
preserving the saved visibility preference for the normal Teleop view.

`XrStateSender` samples in `_process` after Godot advances OpenXR for the render
frame. `XrTrackingSource` emits the tick's head/controllers/input/hands as
`SensorFrame`s on its `StreamBinding` without yielding, then calls
`end_of_tick()`, on which `XrStateSink` assembles the snapshot. Body and motion
trackers are re-delivered each tick with their own lower-rate sample timestamp. It is disabled
for normal robot descriptors, so `CommandSender` behavior and bandwidth are
unchanged outside Python SDK mode.

`XrTrackingSource` owns that atomic sampling; `XrStateSink` owns the encoding.
On Pico, a request containing `body` takes priority over independent motion
trackers: neither `request_motion_trackers` nor `sample_motion_trackers` is
called in body mode, including during failed body startup. The latter can
implicitly request object-tracking mode and disrupt the ankle trackers used by
full-body tracking. `motion_trackers` stays empty in that mode. A motion-only
request retains independent tracker sampling; other platforms are unchanged.
Pico body availability requires the runtime to advertise `XR_BD_body_tracking`,
not merely connected/calibrated pucks. The native `Operator-PicoBody` log reports
the runtime's advertised vendor extensions, enabled flags, and rate-limited
start/sample diagnostics without logging joint poses.

`SystemCompatibilityNotice` checks Pico OS on app startup, including quick-entry
modes. The platform adapter reads `ro.build.display.id` through the native bridge
(not Android's release/API level). Versions below **5.13.0** trigger an upgrade
notice, following PICO's [official Body Tracking requirements](https://developer.picoxr.com/document/native/body-tracking/)
for both `XR_BD_body_tracking` and `XR_PICO_body_tracking2`. The notice displays
the current version and this minimum from the same version policy. Meeting the
version floor alone does not establish compatibility. Once an XR session exists,
the check also detects a missing `XR_BD_body_tracking` extension. Unknown version
strings and not-yet-initialized sessions are not treated as old systems. The
localized, head-locked notice shows the installed version and asks the user to
update PICO to the latest system release, then restart Operator. It waits for XR
initialization and remains until acknowledged; acknowledgement lasts across scene changes
and headset re-don for the process. No updates are installed automatically, no
mode is disabled, and other headset platforms do not receive this prompt.

The normal `XrStateSender` sends `XrStateSink.frame_v1()`, the unchanged v1 schema;
the optional `XrtSender` converts the same snapshot to XRoboToolkit Tracking
JSON and frames it with the legacy byte-command envelope. Selecting
`xrobot_toolkit_v1` creates a separate outside target with its own TCP client,
handshake, heartbeat, reconnect, and neutral-frame safety behavior. It bypasses
Operator `Session`, `DeviceDescriptor`, video, and clock sync. The composition
root also clears `BlueprintRuntime`; Blueprint/state/event commands are
not defined by the XRT v1 wire format. It enforces
`CommandSender XOR XrStateSender XOR XrtSender`. The compatibility
sampler starts PICO full-body tracking only when XRT transmission becomes
active, so merely constructing the optional target cannot perturb the normal
Operator path. It deliberately does not request the
independent motion-tracker mode: PICO exposes those as mutually disruptive
runtime modes, and Body is the HoloMotion P0 input. The legacy `predictTime`
keeps the OpenXR predicted-display clock, while top-level and Body timestamps
are converted to Unix nanoseconds at the sender boundary. The encoder removes
Godot's hand-joint bone-axis adjustment to recover the raw legacy PICO hand
quaternion and maps PICO's right system/select action to legacy `menuButton`.

The Inside profile registry is deliberately not consulted by Outside Robot.
This prevents a headset release from becoming the compatibility gate for a new
real robot or outside simulator.

## Compatibility Layers

`scripts/compat/` holds adapters that speak a third party's wire protocol so
Operator can drop into an existing deployment without changing the peer. They
are deliberately separate from `scripts/network/`, which owns Operator's own
protocol: nothing under `compat/` is a dependency of the native path, so
deleting a subdirectory removes exactly one interop story and nothing else.

`scripts/compat/xrobot_toolkit/` implements the legacy XRoboToolkit TCP
protocol, letting Operator drive hosts that still run the old PICO app's
`RoboticsService`.

| Script | Responsibility |
| --- | --- |
| `xrt_protocol.gd` | Byte-command envelope framing and shared constants. |
| `xrt_client.gd` | TCP connection, heartbeat, and receive-buffer framing/resync. |
| `xrt_discovery.gd` | UDP `29888` robot-beacon listener and beacon parser. |
| `xrt_tracking_encoder.gd` | Builds the Tracking JSON payload (head, controllers, hands, body). |
| `xrt_sender.gd` | Per-frame send loop, `appState.focus`, and neutral frames. |
| `xrt_camera_protocol.gd` | FPV camera command and response encoding. |
| `xrt_video_session.gd` | FPV video stream lifecycle feeding the shared video panel. |

Safety note: the sender emits an explicit neutral frame whenever the app loses
focus or is paused, and then holds the stream — heartbeats continue so the
connection stays up, but no live pose leaves a headset nobody is wearing. The
legacy peer holds the last frame it received, so `Head`, `Controller` and `Hand`
are sent neutralized rather than omitted; `Body` is the inverse case and is
omitted, because a receiver stops on an absent body but retargets 24 identity
poses into a commanded rest pose. See `XrtTrackingEncoder.neutral()`.

## Tracking Session Service

`TrackingSessions` (`TrackingSessionService`) is an application autoload and
the only owner of Pico tracker startup, shutdown, mode requests, calibration
launch and body/motion publication. Each consumer acquires a weak-owner lease
for the capabilities it actually uses and releases only its own lease.
Recorder preparation and body/motion writing, `XrTrackingSource`, and
`BodyPoseProvider` all use this boundary. Inside derives demand from the
profile's `requires_body_tracking` and optional body display; Outside derives
it from negotiated streams or the XRoboToolkit protocol, never bundled robot
model lists. Configuration alone does not activate an Outside sampler.

The SDK's `BridgeConfig.streams` defaults to head/controllers/hands; body and
motion trackers must be explicitly requested by consumers (whole-body-control
requests body). Python, the native binding and Rust SDK validate the request;
the existing `DeviceDescriptor.xr_stream.streams` carries it with no Blueprint
or wire-schema change. Empty SDK lists are rejected, since the legacy wire's
empty-list meaning remains "all streams".

`PicoTrackingCalibration` owns process-local **user confirmation**, independently
of pages and recording options. Its compatibility workflow is: successfully open
PICO system calibration, leave and return to Operator, then explicitly press
"I completed this calibration" while the requested tracking data is valid.
Returning (including cancelling setup) alone never authorizes data publication.
Confirmation is a user attestation, not automatic proof of a new calibration;
the UI states this explicitly. Disconnect/continuity-loss epochs revoke
confirmation; normal page changes, releasing one lease, or recreating
an OpenXR session do not erase a still-valid confirmation. No demand
means no calibration prompt, and head/controller/hand-only consumers and other
platforms are unaffected. The last release stops unneeded runtime tracking.
Pico body-ready to `INVALID` while a tracker is active is conservatively treated
as continuity loss; `LIMITED` and intentional resource stops are not losses.

The native bridge uses the supported `XR_PICO_body_tracking2` tracking-state
API, not the obsolete `xrGetBodyTrackerCalibStatePICO` symbol (absent on the
Pico 5.15.7 runtime). A 20 Hz read-only monitor retains body continuity losses
across Android pauses; it does not manufacture calibration-completion epochs.
The monitor is joined before native session/instance destruction. OS pause/resume
and OpenXR focus events distinguish opening setup from returning to Operator.
Before accepting the explicit click, the service rechecks live body poses
(including finite/non-collapsed positions) or valid independent motion poses.
Invalid data keeps confirmation disabled. Motion-only prepares independent
tracking after returning from system calibration and before confirmation.

The service arbitrates Pico's mutually exclusive body and independent motion
modes. Body-priority protocol requests keep their existing semantics, but a new
consumer cannot preempt a mode another owner still needs: it receives
`mode_conflict`. In particular, opening body visualization cannot steal an active
motion-tracking control session. The calibration workflow may probe/start body before
readiness, but no unconfirmed data is published. Independent tracker counts are
never interpreted as full-body connectivity. Consumers clear cached frames on
invalidation; an optional body display hides unavailable geometry instead of
substituting a synthetic skeleton around the Pico gate.

Recording finalizes the current file if required tracking is lost. Inside
retargeting stops canonical-frame output and rejects queued results. XRoboToolkit
sends its defined neutral frame and holds live output; Operator SDK state streaming
closes its transport because v1 has no universal robot-neutral command. These
control paths latch loss and require explicit Connect/re-arm; neither calibration
completion, focus recovery, nor automatic transport reconnection resumes motion.
Already-calibrated startup may wait for its first data frame without a new latch.
Optional body visualization does not suspend a controller-only robot target.

Capture and Teleop display the same status vocabulary, recalibration action and
separate confirmation button; the confirmation button appears only after return.
The Teleop row is outside the Inside/Outside UI containers and follows demand,
not the selected protocol. Its required row reads the active robot consumer's
lease via passive `tracking_report()`; a separate optional row reads only the
local body display's lease. It never derives robot requirements from global
`summary()` or activates a sampler just to display settings. Lease membership
changes notify the UI even when the underlying tracking mode is unchanged.
When required tracking blocks a target, settings focus the Robot group; an
interlocked SDK lease remains visible after safety disconnect until explicit
disconnect/replacement or re-arm. Calibration actions still go to the single
service, and no robot message can assert user confirmation.
`cicd/validate_tracking_ownership.py` rejects direct
tracker lifecycle/data calls outside the service; device tests are still required.

## Capture Runtime

`capture_app_base.gd` handles shared capture-mode lifecycle:

- intent extras and automation entry points for device tests;
- permission and platform provider setup;
- capture start/stop UI;
- QR-based ingest configuration;
- upload queue integration.

Capture modes do not own robot constraints or retargeting UI. Body tracking may
still be recorded as sensor data, but turning it into a robot pose is a Teleop
concern.

Capture translates its selected body/motion streams into tracking leases.
Both the early start check and the controller's final pre-writer check query
the shared service, covering button, volume-key and automated starts. The
sampler's publication boundary also checks readiness. Closing settings or
stopping a recording cannot clear another consumer's calibration or stop its
tracker. Loss monitoring continues with the settings page closed.

The Output panel also owns the export reference-space contract. Operators
choose `STAGE`, `LOCAL`, or `LOCAL_FLOOR`; before recording starts the app asks
Godot's OpenXR interface to activate the corresponding play space and waits
for the runtime to confirm it. Capture is blocked if the runtime falls back to
a different space. Head and controller samples use their unadjusted `XRPose`
transforms, while the independent native hand worker locates joints against
that same active `XrSpace`. The selected value is fixed for the session and is
stored in capture options and `operator_static` metadata.

RGB calibration is intentionally not rebased: Camera2/OpenXR camera
extrinsics remain `T_head_camera`. A reader obtains a camera pose in the chosen
export space by composing
`T_export_camera = T_export_head * T_head_camera`. `operator_static` declares
both the export space and this head-relative extrinsics contract.

Mode-specific composition chooses the sink chain:

- Ego capture writes local SpatialMP4 artifacts and can upload through TUS.
- Live Feed streams selected sensor/video data to a server through OLCP.

Each local Ego recording is stored as one movable session directory:

```text
<capture_root>/
  <session_id>/
    <session_id>.mp4
    manifest.json
```

This is the complete recording. Pose, body, depth, camera calibration, timebase,
and RGB frame-index metadata are embedded in MP4 tracks/metadata. Local-session
discovery continues to recognize the historical `<capture_root>/<session_id>.mp4`
sibling layout so existing recordings remain available for preview, upload, and
deletion.

## Ego Recording Container Contract

Raw ego recordings should converge on a self-contained SpatialMP4 as the
canonical replay artifact. A consumer that only has `media.mp4` must be able to
recover the sensor payloads and metadata required for spatial interpretation:
RGB/depth pixels, audio, head/controller/hand/body tracks, Camera2 calibration,
RGB frame timing, depth frame metadata, body frame extras, and motion trackers.
MP4 metadata is the source of truth.

`manifest.json` remains a first-class upload artifact. Its role is file and
session inventory, not sensor interpretation. It records artifact filenames,
kinds, sizes, hashes such as `sha256`, upload status, derivation status, and any
file-level metadata that cannot live inside the MP4 without creating circular
dependencies. In particular, `media.mp4` cannot embed its own final hash; that
belongs in `manifest.json` or the ingest database.

The MP4 container contract uses media tracks for high-volume samples and `mett`
timed-metadata tracks for structured metadata:

| Track | Payload | Timing |
| --- | --- | --- |
| RGB / depth / audio | Encoded media samples and existing ICAM/ECAM/DSTR side-data. | Per media sample. |
| head / controllers / hands / body joints | Existing pose and joint `mett` payloads. | Per sensor sample. |
| `operator_static` | Static replay metadata: schema, capture options needed for parsing, device/provider identity, Camera2 characteristics, and Android timebase. | Single packet at PTS 0. |
| `rgb_frame_index` | Eye, frame index, Camera2 sensor timestamp, timestamp source, camera id, dimensions. | Per RGB frame. |
| `depth_frame_meta` | OpenXR depth metadata such as timestamp source, runtime display time, projection/inverse-projection columns, near/far range, FOV tangents, and `local_from_depth_eye`. | Per depth frame. |
| `body_frame_meta` | Frame-level `body_flags` and provider-specific body extras that do not fit the compact body-joints payload. | Per body frame. |
| `motion_trackers` | PICO motion tracker pose samples, velocities, accelerations, battery state, and power-key events. | Per tracker sample/event. |

Environment-depth replay uses each frame's `local_from_depth_eye` and
inverse-projection metadata for every OpenXR provider. Metric depth points are
unprojected in RDF image coordinates (X right, Y down, Z forward), then mapped
into the OpenXR/Godot eye basis (X right, Y up, Z back) with an explicit Y/Z
axis flip before RGB reprojection. This is selected by the embedded depth
metadata contract, never by headset model, codename, or serial number.

Readers should use embedded MP4 metadata tracks for geometry and timing, while
`manifest.json` remains artifact inventory and integrity metadata. Default
uploads require only `manifest.json` and `media.mp4`. Unbounded raw depth dumps
remain local diagnostics and are not part of the upload artifact contract.

## Platform Registry

`scripts/platform/registry/platform_registry.gd` chooses the best provider for
platform capabilities. Quest, Pico, and generic OpenXR adapters report capture,
QR, live-stream, and sensor capability availability. Device tests can use fake
providers from `scripts/test_support/fakes/platform`.

## XR Session Policy

`scripts/xr/xr_session_policy.gd` is an autoload that applies session-wide XR
policy independently of the active mode. Today it disables the safety boundary:
it calls `PlatformRegistry.apply_boundary_policy(false)` once the OpenXR
interface is initialized and re-applies on `session_begun` and
`session_focussed`.

The registry fans the request out to both adapters and aggregates the results
into one of four states — `not_applicable`, `applied`, `partial`, `failed` —
worst-wins, so one adapter's failure cannot be masked by the other's success.
`partial` means PICO's required enable call succeeded but a best-effort
visibility setter did not, so the guardian mesh may still be drawn.

PICO uses the `XR_PICO_virtual_boundary` extension through the `pico_openxr`
GDExtension, which also disables the boundary directly in `_on_session_created`
so the policy holds before any mode script runs.

Quest needs no runtime call. Its guardian is suppressed at install time by the
`com.oculus.feature.BOUNDARYLESS_APP` manifest feature, injected with
`android:required="true"` by `addons/quest_capture_android/export_plugin.gd`.
The pinned vendor plugin (`addons/godotopenxrvendors`, upstream_tag
`4.3.1-stable`) ships no `XR_META_boundary_visibility` wrapper, so the Quest
adapter reports `not_applicable` and the policy logs that at info level instead
of warning. The adapter still probes for the singleton as an optional upgrade
path should a later vendor release add one.

Operator runs a single XR session across all modes, so one call covers launcher,
teleop, and capture. See `claw/lessons/007-pico-safety-boundary-openxr-virtual-boundary.md`.

## Test Harness

`scripts/test_support/` is an in-app module test framework. It is activated by
exporting an APK with the test-harness feature and launching with intent extras:

```bash
bash cicd/xr_module_harness.sh --suite capture.pipeline --serial <serial>
```

The harness runs on the target headset, logs `OPERATOR_TEST_*` markers, and
pulls JSON result files from the app external files directory.

Static manifest validation is host-side only:

```bash
python3 cicd/validate_xr_features.py
python3 cicd/validate_xr_test_manifests.py
```
