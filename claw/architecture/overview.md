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
  pyoperator/             immutable frames, session, robot/control APIs
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

```text
XR tracking/controllers
  -> scripts/input/command_sender.gd
  -> scripts/sinks/robot_control/robot_control_sink.gd
  -> TCP command channel
  -> robot-service
  -> robot-adapter device driver

robot-service xr-bridge component
  -> TCP or UDP timed H.264 packets
  -> scripts/network/tcp_handler.gd or udp_video_handler.gd
  -> scripts/ui/teleop_panel.gd
  -> addons/live_video/live_video_view.gd
```

### Python-embedded Teleop

```text
Python application
  -> pyoperator.xr_bridge.start()
  -> PyO3 in-process xr-bridge SDK mode
  <- one immutable XrStateFrame per headset render sample
  -> Python Retargeter -> optional IKSolver -> user Robot
```

The embedded path and the existing `robot-service` path are peers. SDK mode is
selected by the descriptor's optional `xr_stream` block; descriptors without
that block continue to use `DeviceCommand`. The Python consumer receives one
latest-wins frame and never assembles state from granular getters.

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
`res://scripts/app/launcher/mode_select.gd`. The launcher opens one of these
mode scenes:

| Mode | Scene | Script |
| --- | --- | --- |
| Launcher | `xr/scenes/main.tscn` | `xr/scripts/app/launcher/mode_select.gd` |
| Teleop | `xr/scenes/teleop_main.tscn` | `xr/scripts/app/modes/teleop_mode.gd` |
| Ego capture | `xr/scenes/capture_app.tscn` | `xr/scripts/app/modes/ego_capture_mode.gd` |
| Live Feed | `xr/scenes/live_feed_app.tscn` | `xr/scripts/app/modes/live_feed_mode.gd` |
| VR | `xr/scenes/vr_mode.tscn` | `xr/scripts/app/modes/vr_mode.gd` |
| MuJoCo smoke | `xr/scenes/mujoco/mujoco_device_test.tscn` | `xr/scripts/app/modes/mujoco/mujoco_device_test.gd` |
| Module tests | `xr/scenes/test_runner.tscn` | `xr/scripts/test_support/runner/test_runner_root.gd` |

## Documentation Map

- XR client details: `xr-client.md`
- Rust side details: `rust-agent.md`
- Build and device procedures: `build-and-deploy.md`
- Wire contracts: `wire-protocol.md`
- Live Feed server integration: `live-feed-cloud.md`
