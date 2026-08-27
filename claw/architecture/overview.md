# Architecture Overview

Operator has four runtime surfaces:

- `xr/` - in-headset Godot Android client.
- `robot/` - Rust robot-side bridge, protocol, and adapter crates.
- `python/` - Python-first in-process XR, robot, retargeting, and IK API.
- `web/` - local ingest and review app for ego recordings.

The project supports two primary workflows:

1. Teleoperation: headset tracking and controller input become robot commands;
   robot video and telemetry return to the headset.
2. Egocentric data collection: the headset records SpatialMP4 sessions and
   uploads them to the web ingest stack.

Live Feed is the streaming variant of ego capture: XR pushes RGB/depth/pose
samples to a server and receives algorithm results for in-headset rendering.

## Repository Boundaries

```text
robot/
  crates/teleop-protocol   shared Rust protocol types and codecs
  crates/robot-service     robot-side service entry point
  crates/xr-bridge         discovery, video relay, pose/control bridge
  crates/robot-adapter     device abstraction and robot drivers
  crates/pyoperator-native PyO3 in-process bridge binding

python/
  pyoperator/              immutable frames, session, robot/control APIs
  pyoperator/protocol/     wire contracts the XR app speaks
  pyoperator/services/     host-side services the app connects to
  pyoperator/integrations/ adapters onto external capability libraries
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
| Inside Robot | In the headset | Bundled XR profile | Native in XR, or remote solver via the pyoperator retargeting service |
| Outside Robot | Behind `robot-service` | Dynamic device descriptor, or local compatibility descriptor | Owned by `robot-service` and its downstream stack |

Remote retargeting for Inside Robot moves only the solver. Tracking originates
in XR and the returned joints are still rendered/simulated in XR. XR never
connects directly to the retargeting service for an Outside Robot; an outside
deployment may use such a service internally without exposing that topology.

```text
                         +-> Inside profile -> native solver ----------------+
XR tracking/controllers |                                                   |
                         +-> Inside profile -> pyoperator retargeting svc --+-> in-headset embodiment
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

pyoperator is the single Python interface Operator talks to, so the XR app
never has to speak a second package's protocol. Retargeting math lives in the
separate `retargeting` library, which pyoperator calls.

```text
Operator XR app
  | pyoperator wire protocol (hello/frame/result over WebSocket)
  v
pyoperator
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

The dependency is one-way: `pyoperator[retargeting]` imports `retargeting`;
`retargeting` never imports pyoperator, opens a socket, or learns about OpenXR.
Anything Operator-shaped — wire payloads, quaternion order, body joint sets —
is translated in `pyoperator/integrations/retargeting.py`.

Both Teleop paths therefore share one solver core:

| Path | Caller | Result consumer |
| --- | --- | --- |
| Inside Robot + remote | `pyoperator.services.retargeting` | Returned to the headset, applied to the in-headset embodiment |
| Outside Robot + Python | `PyOperatorRetargeter` in a host control loop | Written to the user's robot |

Run the service with `pyoperator serve --service retargeting` (the
`retargeting-service` command remains as an alias for existing deployments).

### Python-embedded Teleop

```text
Python application
  -> pyoperator.xr_bridge.start()
  -> PyO3 in-process xr-bridge SDK mode
  <- one immutable XrStateFrame per headset render sample
  -> Python Retargeter -> optional IKSolver -> user Robot
```

The embedded path and the existing Operator `robot-service` path are peers. SDK mode is
selected by the descriptor's optional `xr_stream` block; descriptors without
that block continue to use `DeviceCommand`. The Python consumer receives one
latest-wins frame and never assembles state from granular getters.

Outside Robot can alternatively select `xrobot_toolkit_v1`. That target opens
its own TCP connection and emits the legacy binary XRoboToolkit packets expected
by existing HoloMotion deployments. It does not create an adapter gateway and
does not alter the Operator session, descriptor, video, or robot-side protocol.
The Operator, SDK, and XRoboToolkit senders are mutually exclusive. This mode
covers the HoloMotion RoboticsService tracking ingress on TCP `63901`; Episode
HTTP, discovery, and FPV remain separate integrations. An optional PICO device
SN setting can reproduce the legacy `EQUIPMENT_SN` handshake identity when the
deployed RoboticsService requires it. Video is selected independently in the
Teleop `Video` group: Operator timed H.264 keeps the existing client path,
while XRoboToolkit FPV uses `OPEN_CAMERA` plus a reverse TCP connection and
feeds the resulting Annex-B access units into the same decoder and SBS display.

Ego capture owns recording only. Robot profiles, retargeting solvers, and robot
embodiments are Teleop responsibilities and must not be attached to Ego mode.

### Ego Capture

```text
Quest/Pico capture provider
  -> scripts/core/capture/capture_session_controller.gd
  -> scripts/sinks/spatialmp4/spatialmp4_sink.gd
  -> scripts/sinks/upload/ego_uploader.gd
  -> web/modules/ego-ingest TUS receiver
```

### Live Feed

```text
XR live-feed mode
  -> scripts/app/composition/live_feed_composition.gd
  -> addons/live-push OLCP v1 stream
  -> live feed server
  -> addons/live-pull result stream
  -> dense map / status rendering
```

## Current XR Modes

`xr/project.godot` boots `res://scenes/main.tscn`, which attaches
`res://scripts/app/launcher/mode_select.gd`. By default it shows the launcher;
an Android export preset can set `operator_quick_entry` to `teleop`,
`ego_capture`, or `live_feed` to route the process's first launcher visit
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
set `operator_quick_entry` to `teleop`, and drop the capture, live-feed and VR
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
| Live Feed | `xr/scenes/live_feed_app.tscn` | `xr/scripts/app/modes/live_feed_mode.gd` |
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
