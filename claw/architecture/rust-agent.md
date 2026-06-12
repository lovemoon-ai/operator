# Rust Side Architecture

`robot/` is a Rust workspace for the robot/server side of Operator.

```text
robot/
  Cargo.toml
  configs/
    xr-bridge-default.yaml
    mujoco_so101.yaml
    mujoco_so101_descriptor.yaml
  crates/
    teleop-protocol/
    xr-bridge/
    robot-adapter/
    e2e-tests/
```

## Crates

### `teleop-protocol`

Shared protocol crate. It owns:

- command frame encoding and decoding;
- device descriptor parsing;
- transport-level helpers;
- adapter-facing shared types.

Key paths:

- `robot/crates/teleop-protocol/src/wire.rs`
- `robot/crates/teleop-protocol/src/descriptor.rs`
- `robot/crates/teleop-protocol/src/transport.rs`
- `robot/crates/teleop-protocol/src/adapter/`

### `xr-bridge`

Bridge between XR clients and robot/video sources. It owns:

- UDP discovery;
- TCP command/pose server;
- UDP pose server;
- telemetry server;
- video source ingestion;
- TCP and UDP video fan-out;
- latency and watchdog support.

Key paths:

- `robot/crates/xr-bridge/src/main.rs`
- `robot/crates/xr-bridge/src/discovery.rs`
- `robot/crates/xr-bridge/src/pose_server.rs`
- `robot/crates/xr-bridge/src/pose_udp_server.rs`
- `robot/crates/xr-bridge/src/telemetry_server.rs`
- `robot/crates/xr-bridge/src/video/`

### `robot-adapter`

Device abstraction and concrete robot drivers. It owns:

- config loading;
- `Device` / `RobotArm` abstractions;
- safety wrappers and limits;
- pose mapping;
- MuJoCo SO-101 driver path;
- server that consumes bridge-side commands.

Key paths:

- `robot/crates/robot-adapter/src/main.rs`
- `robot/crates/robot-adapter/src/device.rs`
- `robot/crates/robot-adapter/src/devices/`
- `robot/crates/robot-adapter/src/control/`
- `robot/crates/robot-adapter/src/server.rs`

### `e2e-tests`

Rust integration tests for bridge/adapter round trips and network behavior.

## Runtime Responsibilities

The robot side should keep these concerns separate:

- protocol compatibility belongs in `teleop-protocol`;
- network fan-out and video transport belong in `xr-bridge`;
- device control and safety belong in `robot-adapter`;
- scenario-level verification belongs in `e2e-tests` or top-level shell tests.

## Video

`xr-bridge` publishes timed H.264 packets over TCP and UDP. It can ingest from
RTSP or platform video sources, normalize H.264 access units, attach timing
metadata, and fan out to connected XR clients.

XR consumes the stream through:

- `xr/scripts/network/tcp_handler.gd`
- `xr/scripts/network/udp_video_handler.gd`
- `xr/scripts/ui/teleop_panel.gd`
- `xr/addons/live_video/live_video_view.gd`

## Device Descriptors

Descriptors advertise robot identity, control schema, input mapping, and video
feed transport choices. XR uses them to select TCP or UDP video and configure
teleop controls.

Current config examples live in `robot/configs/`.

## Common Commands

Run from `robot/`:

```bash
cargo build --release
cargo test
```

Run top-level E2E scripts from the repo root:

```bash
bash tests/01_rtsp_test.sh
bash tests/03_godot_mujoco_device.sh
```
