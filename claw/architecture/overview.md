# Architecture Overview

Operator has five runtime surfaces:

- `xr/` - in-headset Godot Android client.
- `robot/` - Rust Operator SDK core, bridge, protocol, and adapter crates.
- `cpp/` - `liboperator`, the C++ SDK over the Rust core's stable C ABI.
- `python/` - Python-first in-process XR, robot, retargeting, and IK API.
- `web/` - local ingest and review app for ego recordings.

The project supports two primary workflows:

1. Teleoperation: headset tracking and controller input become robot commands;
   robot video and telemetry return to the headset.
2. Egocentric data collection: the headset records SpatialMP4 sessions and
   uploads them to the web ingest stack.

Streaming to an ingest server (formerly the Live Feed mode) is an Output of
ego capture, not a mode: XR pushes RGB/depth/pose samples to a server and
receives algorithm results for in-headset rendering.

## Host-declared Composition

The APK is a general runtime. Apart from fully offline features (Ego local
recording, upload management, Ego streaming to an ingest endpoint), every
behavior that depends on a remote peer is defined by what the connected host
declares, not by a mode baked into the APK. A new robot, algorithm, or scene
does not require an APK rebuild.

### Terms

| Term | Meaning |
| --- | --- |
| headset | The HMD running the Operator APK (Quest / Pico). |
| host | The machine the headset connects to and its program: the robot computer (`xr-bridge` / adapter) for teleop, a GPU server (`operator_xr` program) for navigation or algorithm services. A host publishes declarations and receives headset data. The headset does not distinguish real robots, simulators, or model services. "Source" is reserved for data-source components. |
| host declaration | Everything a host sends to describe a session: the **descriptor** (`DeviceDescriptor`, exchanged once after every `Hello`: `xr_stream`, `capture_streams`, `video_feeds`, `capabilities`) plus the **Blueprint** (rendering and interaction, replaceable by revision during a session). |
| capability | An APK built-in implementation: camera capture, encoders, renderers, permission flows, platform differences. Capabilities grow only with APK versions, never arrive from the network, and are advertised in `Hello.capabilities`. A capability always belongs to the headset; a host only obtains permission to use it. |
| component | A headset-local implementation unit that any host can mount (source / sink / view, plus pure-logic permission units). Components are not part of any wire contract. |
| stream | A named headset→host data stream using OLCP vocabulary: `rgb.hevc`, `depth.u16`, `head_pose.json`, `controller_pose.json`, `controller_input.json`, `hand_joints.json`, `audio.*`. |
| composition | The component wiring in effect for one session, decided by three parties: preset/local defaults, the host declaration, and user-granted permissions and overrides. |
| permission | Unqualified, a **host permission**: the user's grant, made on the headset, allowing one host to use a headset capability or send data to a destination. **System permissions** (Android runtime permissions such as `CAMERA` / `RECORD_AUDIO`, granted by the OS to the APK) are handled inside source components and never appear in the permission layer. |
| ingest endpoint / ingest session | A passive receiver configured (QR) and verified locally on the headset: an upload server or a live push server. N:1, started by the headset/user, never sends declarations (its `capture_request` may only narrow the stream set). Contrast with the 1:1 host session, where the host declares. |
| `godot_ticks_ns` | The single sampling timebase on the headset. See `wire-protocol.md`, "Headset timebase". |

### Principles

These are hard rules:

1. The APK provides capabilities, the host provides declarations, the user
   decides permissions.
2. A declaration states *what* is wanted, never *how*. Hosts declare which
   capabilities to enable, parameter envelopes, and wiring; implementations
   live in the APK. No code, scenes, shaders, or arbitrary resource paths are
   ever transferred.
3. Data flows only to the host that declared it, or to an ingest endpoint
   configured and verified on the headset.
4. Declarations and low-rate state use the latest-wins structured channel;
   high-rate streams (HEVC, depth, point clouds, video) use dedicated binary
   channels. The declaration layer never carries a stream.
5. The headset always owns safety interlocks and control arbitration, system
   permission flows, platform selection, boundary policy, and tracking
   calibration. A host can at most request them.
6. The timestamp chain is a frozen contract: no refactor changes how samplers,
   encoders, or writers timestamp a sample.

### Layers

```text
permission    permission table, memory and revocation, endpoint registry,
              limits, indicators                            (headset-local, data driven)
declaration   host declaration = descriptor (xr_stream / capture_streams /
              video_feeds) + Blueprint (components / assets)
capability    components: source / sink / view              (APK built-in, mountable by any host)
session       host session (1:1: ctrl / xr_state / media_up / media_down)
              ingest session (N:1: media_up + receipts)
```

The descriptor carries what must be negotiated when a connection is
established and what needs permission; Blueprint carries rendering and
interaction. Components never enter the wire contract: the headset-side
component model lives under `xr/scripts/components/` and is described in
`xr-client.md`.

## Repository Boundaries

```text
robot/
  crates/operator          public Rust SDK and shared behavior
  crates/operator-c        stable C ABI used by liboperator
  crates/teleop-protocol   internal wire types and codecs
  crates/robot-service     robot-side service entry point
  crates/xr-bridge         discovery, video relay, pose/control bridge
  crates/robot-adapter     device abstraction and robot drivers
  crates/pyoperator-native PyO3 bindings over operator and xr-bridge

cpp/
  liboperator/             C++17 headers and CMake target

python/
  operator_xr/              immutable frames, session, robot/control APIs
  operator_xr/protocol/     wire contracts the XR app speaks
  operator_xr/services/     host-side services the app connects to
  operator_xr/integrations/ adapters onto external capability libraries
  examples/                embedded and custom-robot examples
  tests/                   deterministic model/control/replay tests

xr/
  scenes/                  Godot scene resources only
  scripts/app/             launcher, modes, feature composition
  scripts/core/            capture, sensors, time, pipeline primitives
  scripts/contracts/       typed GDScript contracts
  scripts/sinks/           output adapters
  scripts/ui/              UI scripts
  scripts/test_support/    on-device module test harness
  addons/                  Godot plugins and Android integrations

web/
  app/                     Next.js review app and ingest mount
  modules/ego-ingest       TUS receiver library
```

`xr/scenes/` intentionally keeps `.tscn` and shader resources. GDScript lives
under `xr/scripts/` by responsibility. The only remaining `robot_view` path is
the scene resource `xr/scenes/robot_view/robot_view.tscn`; its behavior is
`xr/scripts/ui/teleop_panel.gd`, which wraps the reusable live-video addon.

## Runtime Dataflows

### Teleop

Teleop is one product entry with two execution targets. The operator chooses
the boundary first; this is intentionally independent of whether the outside
target is hardware or a simulator.

| Target | Robot embodiment | Robot metadata | Retargeting |
| --- | --- | --- | --- |
| Inside Robot | In the headset | Bundled XR profile | Native in XR, or remote solver via the operator_xr retargeting service |
| Outside Robot | Behind `robot-service` | Dynamic device descriptor, or local compatibility descriptor | Owned by `robot-service` and its downstream stack |

Remote retargeting for Inside Robot moves only the solver. Tracking originates
in XR and the returned joints are still rendered/simulated in XR. XR never
connects directly to the retargeting service for an Outside Robot; an outside
deployment may use such a service internally without exposing that topology.

```text
                         +-> Inside profile -> native solver ----------------+
XR tracking/controllers |                                                   |
                         +-> Inside profile -> operator_xr retargeting svc --+-> in-headset embodiment
                         |
                         +-> Outside target -> Operator protocol -> robot-service -> robot/adapter or outside simulator
                         |
                         +-> Outside target -> XRoboToolkit v1 -> existing RoboticsService/HoloMotion

optional XRoboToolkit FPV
  -> PICO camera command client + reverse TCP listener
  -> length-prefixed Annex-B H.264 access units
  -> addons/live_video/live_video_view.gd

robot-service xr-bridge component
  -> TCP or UDP timed H.264 packets
  -> scripts/network/tcp_handler.gd or udp_video_handler.gd
  -> scripts/ui/teleop_panel.gd
  -> addons/live_video/live_video_view.gd
```

### Retargeting Ownership

operator_xr is the single Python interface Operator talks to, so the XR app
never has to speak a second package's protocol. Retargeting math lives in the
separate `retargeting` library, which operator_xr calls.

```text
Operator XR app
  | operator_xr wire protocol (hello/frame/result over WebSocket)
  v
operator_xr
  protocol/      versioned envelopes and the RetargetingRequest/Result DTOs
  services/      connection lifetime, session, latest-only backpressure
  integrations/  XrFrame + payload <-> canonical solver types
  | solve()
  v
retargeting (separate repository)
  inputs/results canonical, source-agnostic solver contract
  profiles       how a robot is retargeted, plus model fingerprints
  runtime/       persistent sessions, warm start, native worker supervision
  eepose/...     the algorithms
```

The dependency is one-way: `operator-xr[retargeting]` imports `retargeting`;
`retargeting` never imports operator_xr, opens a socket, or learns about OpenXR.
Anything Operator-shaped — wire payloads, quaternion order, body joint sets —
is translated in `operator_xr/integrations/retargeting.py`.

Both Teleop paths therefore share one solver core:

| Path | Caller | Result consumer |
| --- | --- | --- |
| Inside Robot + remote | `operator_xr.services.retargeting` | Returned to the headset, applied to the in-headset embodiment |
| Outside Robot + Python | `OperatorRetargeter` in a host control loop | Written to the user's robot |

Run the service with `operator serve --service retargeting` (the
`operator-retargeting` command is an alias of the same service).

### Python-embedded Teleop

```text
Python application
  -> operator_xr.xr_bridge.start()
  -> PyO3 in-process xr-bridge SDK mode
  <- one immutable XrStateFrame per headset render sample
  -> Blueprint + latest BlueprintState
  <- ordered BlueprintEvent
  -> Python Retargeter -> optional IKSolver -> user Robot
```

The embedded path and the existing Operator `robot-service` path are peers. SDK mode is
selected by the descriptor's optional `xr_stream` block; descriptors without
that block continue to use `DeviceCommand`. The Python consumer receives one
latest-wins frame and never assembles state from granular getters.

Python backends behind a standalone `xr-bridge` can publish the same
Blueprint contract with `HostedBlueprint`. The adapter boundary forwards
Blueprint/state toward XR and ordered UI events back to Python without moving
the existing device-command or telemetry control path.

The Blueprint contract is mode-independent; see
`claw/architecture/blueprint.md`. Outside Robot Teleop is its first host adapter,
not part of the runtime or primitive definitions. A future VR or Realtime Feed
mode can attach the same runtime and provide its own external-view mappings.

Outside Robot Blueprint follows the same ownership direction as control:
the robot-side Python application declares built-in XR UI through a versioned
blueprint and publishes bound state (including policy-rate robot poses), while the headset performs
rendering, tracking, gesture recognition, and hit testing locally. Users may
persistently override visibility only for components marked
`user_overridable`. `robot_model` obtains content-addressed, data-only GLB model
assets and articulation from the connected robot; the headset validates and
caches them separately from pose traffic. Arbitrary executable resources are
not part of the contract. `make_robot` and APK robot bundles are Inside-only.
The local system Blueprint retains the connection/recenter controller menu and
status lamps across disconnect, alongside the settings launcher. The robot's
Blueprint is a separate scope, cleared on disconnect; input bindings and their
acknowledgements cannot outlive that scope. Video/FPV,
controller help, control-frame gizmos, operation trajectories, hand menus, and
robot status UI stay hidden unless the active Blueprint declares their built-in
component. Inside Robot does not use this protocol because it has no external
robot session; that is a product boundary rather than a Blueprint limitation.

Outside Robot can alternatively select `xrobot_toolkit_v1`. That target opens
its own TCP connection and emits the legacy binary XRoboToolkit packets expected
by existing HoloMotion deployments. XRoboToolkit compatibility is offered only
in Pico builds (`OS.has_feature("pico")`); other platforms hide the protocol
choices, skip the UDP beacon listener, and normalize any persisted
`xrobot_toolkit_v1` setting back to Operator. It does not create an adapter gateway and
does not alter the Operator session, descriptor, video, or robot-side protocol.
The Operator, SDK, and XRoboToolkit senders are mutually exclusive. This mode
covers the HoloMotion RoboticsService tracking ingress on TCP `63901` and the
XRoboToolkit robot beacon on UDP `29888`, which populates the same settings list
as Operator's own `63900` discovery; Episode HTTP and FPV remain separate
integrations. An optional PICO device
SN setting can reproduce the legacy `EQUIPMENT_SN` handshake identity when the
deployed RoboticsService requires it. Video is selected independently in the
Teleop `Video` group: Operator timed H.264 keeps the existing client path,
while XRoboToolkit FPV uses `OPEN_CAMERA` plus a reverse TCP connection and
feeds the resulting Annex-B access units into the same decoder and SBS display.

Ego capture owns recording only. Robot profiles, retargeting solvers, and robot
embodiments are Teleop responsibilities and must not be attached to Ego mode.

### Ego Capture

One capture pipeline with a chosen Output: `local`, `ingest`, or `both`
(`scripts/app/composition/ego_capture_composition.gd`). The sources, the
StreamBinding and the timestamps are identical for all three; only the mounted
sinks differ.

```text
CameraSource / DepthSource / AudioSource / PoseSource / HandSource / BodySource
  -> scripts/core/pipeline/stream_binding.gd  (one SensorFrame, every sink)
  -> local:  SpatialMp4Sink -> UploadQueueSink -> web/modules/ego-ingest TUS receiver
  -> ingest: LivePushSink -> OLCP v1 -> live feed server
             -> addons/live-pull results -> DenseMapView
```

Ingest is the former Live Feed mode: same OLCP wire, same server, chosen as an
Output instead of a separate mode and scene.

### Host capture

A host session may declare the streams it wants (`capture_streams`, see
`wire-protocol.md`). The same pipeline serves it; the session injects the
destination.

```text
DeviceDescriptor.capture_streams + session `media` block
  -> scripts/components/permissions/permission_table.gd   (user grant)
  -> scripts/components/permissions/stream_planner.gd     (envelope x limits x capability)
  -> scripts/app/composition/host_capture_composition.gd
  -> CameraSource -> StreamBinding -> LivePushSink -> host session media_up
  -> StreamsStatus (headset -> host) / StreamsControl (host -> headset)
```

## Current XR Modes

`xr/project.godot` boots `res://scenes/main.tscn`, which attaches
`res://scripts/app/launcher/mode_select.gd`. By default it shows the launcher;
an Android export preset can set `operator_quick_entry` to `teleop` or
`ego_capture` to route the process's first launcher visit
directly into that mode. Explicit `operator.mode` launch arguments take
priority. Returning from a mode still shows the launcher instead of reopening
the configured quick entry.

The quick-entry target must have its matching `operator_feature_mode_*` option
enabled in the same export preset.

Every mode route — a launcher card, an `operator.mode` launch argument, and the
quick entry itself — is gated on `operator_feature_mode_*` alone. A mode whose
feature is off in the running build cannot be reached by any of them.

Build-time specialization is a choice of preset, not a rewrite of one.
`OPERATOR_BUILD_PROFILE=teleop` makes Make export the `Meta Quest Teleop` /
`Pico Teleop` preset instead of `Meta Quest` / `Pico`, and build only the native
dependencies those presets keep. The Teleop presets enable Teleop and Exit,
set `operator_quick_entry` to `teleop`, and drop the capture and VR
resources plus the Android capture, QR, SpatialMP4/FFmpeg, Live Push and
hand-capture dependencies. Nothing mutates `export_presets.cfg`, so exporting a
Teleop preset from the Godot editor produces the same APK as the make target.
`OPERATOR_QUICK_ENTRY` overrides the preset's startup route for one build and
nothing else. `cicd/validate_xr_features.py` keeps each Teleop preset identical
to its full counterpart apart from name, resource filter and `operator_*`
options, and rejects a resource filter that drops something the retained
surface still resolves — by path or by `class_name`.

The launcher opens one of these mode scenes:

| Mode | Scene | Script |
| --- | --- | --- |
| Launcher | `xr/scenes/main.tscn` | `xr/scripts/app/launcher/mode_select.gd` |
| Teleop | `xr/scenes/teleop_main.tscn` | `xr/scripts/app/modes/teleop_mode.gd` |
| Ego capture | `xr/scenes/capture_app.tscn` | `xr/scripts/app/modes/ego_capture_mode.gd` |
| VR | `xr/scenes/vr_mode.tscn` | `xr/scripts/app/modes/vr_mode.gd` |
| MuJoCo smoke | `xr/scenes/mujoco/mujoco_device_test.tscn` | `xr/scripts/app/modes/mujoco/mujoco_device_test.gd` |
| Module tests | `xr/scenes/test_runner.tscn` | `xr/scripts/test_support/runner/test_runner_root.gd` |

VR is present but unreachable: no preset has ever enabled
`operator_feature_mode_vr`, so it has no launcher card and its intent is
refused. The full presets still pack the scene, so enabling that single option
is all that is needed to bring it back.

## Documentation Map

- XR client details: `xr-client.md`
- Rust side details: `rust-agent.md`
- Build and device procedures: `build-and-deploy.md`
- Wire contracts: `wire-protocol.md`
- Live Feed server integration: `live-feed-cloud.md`
- Worked host-declared composition example: `examples/lightnav/README.md`
