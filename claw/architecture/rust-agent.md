# Rust Side Architecture

`robot/` is a Rust workspace for the robot/server side of Operator.

```text
robot/
  Cargo.toml
  configs/
    xr-bridge-default.yaml
    mujoco_so101.yaml
    mujoco_so101_descriptor.yaml
    so101_real.yaml
    so101_real_descriptor.yaml
    so101_dual_real.yaml
    so101_dual_real_descriptor.yaml
  crates/
    teleop-protocol/
    robot-service/
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

### `robot-service`

Robot-side service entry point. It reads one shared YAML config, starts the
adapter component, then starts the XR-facing bridge against the same local
adapter endpoint. This is the default process to run next to a robot.

Key paths:

- `robot/crates/robot-service/src/main.rs`
- `robot/configs/mujoco_so101.yaml`
- `robot/configs/so101_real.yaml`
- `robot/configs/so101_dual_real.yaml`

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
- `robot/crates/xr-bridge/src/service.rs`
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
- real SO-101 driver path through a Python/LeRobot Feetech control process;
- dual real SO-101 path with one hardware control process per arm;
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

The robot side keeps these concerns separate even when they run inside
`robot-service`:

- protocol compatibility belongs in `teleop-protocol`;
- process composition belongs in `robot-service`;
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

Run the SO-101 simulator robot service:

```bash
cargo run -p robot-service -- --config configs/mujoco_so101.yaml
```

Run the real SO-101 robot service after installing LeRobot in the selected Python
environment and confirming the Feetech serial port:

```bash
cargo run -p robot-service -- --config configs/so101_real.yaml
```

The real hardware path spawns `robot/scripts/so101_real_control.py control
--port /dev/ttyACM0`. The Python control process reads the motor calibration
already stored on the bus, applies conservative servo parameters, monitors
current/load reflex thresholds, and bounds streamed teleop setpoint steps.

Run the dual real SO-101 robot service after setting distinct left/right
Feetech serial ports in `dual_arm.left.so101.port` and
`dual_arm.right.so101.port`:

```bash
cargo run -p robot-service -- --config configs/so101_dual_real.yaml
```

The dual path advertises separate XR controls for `left_end_effector`,
`right_end_effector`, `left_gripper`, `right_gripper`, `left_enable`, and
`right_enable`, then starts two `so101_real_control.py control --port ...`
subprocesses inside one `robot-service` run.

Run top-level E2E scripts from the repo root:

```bash
bash cicd/01_rtsp_test.sh
bash cicd/03_godot_mujoco_device.sh
```
