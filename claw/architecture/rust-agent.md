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
    operator/
    operator-c/
    teleop-protocol/
    robot-service/
    xr-bridge/
    pyoperator-native/
    robot-adapter/
    e2e-tests/
```

## Crates

### `operator`

Public Rust SDK facade and the single implementation point for behavior shared
across language SDKs. Blueprint parsing, validation, state patching, sequence
management, capability injection, adapter-envelope serialization, and event
validation live here. Rust callers use it directly; Python and C++ call the
same implementation through bindings.

Key paths:

- `robot/crates/operator/src/lib.rs`
- `robot/crates/operator-c/src/lib.rs`
- `cpp/liboperator/include/operator/operator.hpp`

`operator-c` exports the stable C ABI as `liboperator.a` and `liboperator.so`.
The C++ SDK target is `operator::operator`; its namespace is `operator_sdk`
because `operator` is a C++ keyword.

### `teleop-protocol`

Internal protocol crate used by the public SDK and robot services. It owns:

- command frame encoding and decoding;
- device descriptor parsing;
- transport-level helpers;
- adapter-facing shared types.
- atomic `XrStateFrame` snapshot types.

Key paths:

- `robot/crates/teleop-protocol/src/wire.rs`
- `robot/crates/teleop-protocol/src/descriptor.rs`
- `robot/crates/teleop-protocol/src/transport.rs`
- `robot/crates/teleop-protocol/src/adapter.rs`
- `robot/crates/teleop-protocol/src/xr_state.rs`

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
- `robot/crates/xr-bridge/src/sdk.rs`

### `pyoperator-native`

PyO3 `abi3` extension loaded by the `python/operator_xr` package. It exposes the
Rust `operator::BlueprintPublisher` to both embedded and hosted Python paths,
and starts the shared `xr-bridge` SDK service on a background Tokio runtime for
`XrSession`. It owns no robot policy: Python receives serialized immutable
frames and applies the public `Robot`, `Retargeter`, and `IKSolver` contracts.
`NativeSession.close()` signals shutdown and joins the runtime thread; no
visible `xr-bridge` subprocess is launched.

### `robot-adapter`

Device abstraction and concrete robot drivers. It owns:

- config loading;
- `Device` / `RobotArm` abstractions;
- safety wrappers and limits;
- pose mapping (the single operator→robot retarget, shared by all drivers);
- MuJoCo SO-101 driver path (`mujoco_so101`, spawns the sim as a subprocess);
- real SO-101 driver path (`lerobot_link`, listens for a LeRobot `vr_operator`
  plugin that owns IK and the Feetech bus);
- dual real SO-101 path with one endpoint and one plugin process per arm;
- server that consumes bridge-side commands.

Both drivers implement `ArmDriver` and sit *below* `PoseMapper`, so they only
ever receive robot base-frame targets.

Key paths:

- `robot/crates/robot-adapter/src/main.rs`
- `robot/crates/robot-adapter/src/device.rs`
- `robot/crates/robot-adapter/src/devices/`
- `robot/crates/robot-adapter/src/control/`
- `robot/crates/robot-adapter/src/server.rs`

### `e2e-tests`

Rust integration tests for bridge/adapter round trips and network behavior.

## External Native Adapters

Robots whose vendor SDK has a native toolchain can implement the same
`teleop-protocol` adapter boundary outside the Rust workspace. The native
process owns vendor SDK calls, robot-specific state machines, and local safety;
the existing Rust `xr-bridge` remains the only XR network bridge. Native
adapters use `liboperator` for shared SDK behavior and follow the adapter wire
boundary as it evolves; unknown messages must not be mistaken for motion
commands.

`examples/unitree-g1d/` is the first such client. It is a C++17 process
using Unitree SDK2/DDS and serves the standard `[4-byte little-endian
length][JSON]` protocol over UDS or TCP. The initial hardware scope is the
mobile base and lift. G1-D upper-body state is telemetry-only until its
robot-specific URDF, IK, and low-command takeover sequence are validated. It
also publishes a read-only robot-authored Blueprint for connection and safety
status. Motion authorization remains local to the adapter and is never granted
by Blueprint UI state.

Key paths:

- `examples/unitree-g1d/README.md`
- `examples/unitree-g1d/src/main.cpp`
- `examples/unitree-g1d/src/unitree_backend.cpp`
- `examples/unitree-g1d/config/unitree_g1d_descriptor.json`
- `examples/unitree-g1d/config/unitree_g1d_blueprint.json`
- `examples/unitree-g1d/config/unitree_g1d_bridge.yaml`
- `cpp/liboperator/include/operator/operator.hpp`

## Runtime Responsibilities

The robot side keeps these concerns separate even when they run inside
`robot-service`:

- protocol compatibility belongs in `teleop-protocol`;
- process composition belongs in `robot-service`;
- network fan-out and video transport belong in `xr-bridge`;
- device control and safety belong in `robot-adapter`;
- vendor-native device control may live in `examples/`, behind the same
  adapter protocol boundary;
- Python process embedding belongs in `pyoperator-native` and `python/`;
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
teleop controls. Before transmission, `xr-bridge` normalizes every descriptor
to v2 with `execution.kind: outside`, an explicit `real` / `simulation` /
`unknown` environment, a canonical `input_contract`, and capability flags.

This descriptor is the full compatibility boundary for Outside Robot. XR does
not select Unitree/Galbot/SO101 profiles or connect to retargeting-service on
the robot's behalf. If an outside robot needs retargeting-service, that is an
internal robot-side dependency behind `robot-service`.

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

Run the G1-D native adapter and the existing bridge as two processes:

```bash
# Terminal 1, from the repository root
examples/unitree-g1d/build/operator-g1d-client \
  --backend mock \
  --descriptor examples/unitree-g1d/config/unitree_g1d_descriptor.json \
  --blueprint examples/unitree-g1d/config/unitree_g1d_blueprint.json

# Terminal 2, from the repository root
cargo run --manifest-path robot/Cargo.toml -p xr-bridge -- \
  --config examples/unitree-g1d/config/unitree_g1d_bridge.yaml
```

The real SO-101 path runs as **two processes**: `robot-service` does not touch
the serial bus and does not spawn Python. It listens on `arm.lerobot.endpoint`,
and a LeRobot `vr_operator` teleoperator plugin dials in.

```bash
# Terminal 1
cargo run -p robot-service -- --config configs/so101_real.yaml

# Terminal 2 (venv with lerobot_teleoperator_vr_operator installed)
lerobot-teleoperate \
  --teleop.type=vr_operator \
  --teleop.endpoint=uds:/tmp/lerobot-vr.sock \
  --teleop.urdf_path=/path/to/so101_new_calib.urdf \
  --robot.type=so101_follower \
  --robot.port=/dev/ttyACM0 \
  --robot.max_relative_target=5
```

Where the work lives:

- **Rust owns the operator→robot retarget.** `PoseMapper` sits *above* the
  `ArmDriver` boundary, so `mujoco_so101` and `lerobot_link` share it
  byte-for-byte and the sim and real paths cannot drift apart.
- **Python owns IK, the Feetech bus, and calibration**, via LeRobot's own
  placo-backed `RobotKinematics` and `so101_follower`.

The `lerobot_link` driver is deliberately decoupled: targets go through a
latest-wins channel, so a write never blocks on the plugin and a slow consumer
cannot stall the ~72 Hz XR command path. Two consequences follow. Telemetry
lags by one round trip, so devices sample the driver in `get_telemetry()`
rather than trusting the snapshot taken at write time. And a plugin-side error
surfaces on a *subsequent* write rather than the one that caused it.

Device connect blocks until the plugin sends `Hello`: its forward-kinematics
snapshot is what driver-side IK mode needs to seed itself, and Rust has no FK
of its own.

> **Bootstrap caveat.** The plugin's `Hello` reports FK(`home_joints`), which
> only matches reality if the arm is actually near home. Press reset (XR button
> B) before the first enable, and keep `--robot.max_relative_target` set.

Dual SO-101 needs **three** processes: `lerobot-teleoperate` drives exactly one
follower, so each arm gets its own endpoint and its own plugin process (and its
own `--robot.id`, since LeRobot keys calibration by id).

```bash
cargo run -p robot-service -- --config configs/so101_dual_real.yaml
```

The dual path advertises separate XR controls for `left_end_effector`,
`right_end_effector`, `left_gripper`, `right_gripper`, `left_enable`, and
`right_enable`. See `configs/so101_dual_real.yaml` for both plugin invocations.

Each side also publishes its own control-frame telemetry block
(`left_operator_frame`, `right_pose_mirror`, ...) so the headset can draw one
axis gizmo per hand with that arm's true directions; see
`claw/architecture/wire-protocol.md` for the key list and the reason the block is
per-side rather than shared. The deadmen are independent: releasing one grip
stops and un-draws only that arm.

Run top-level E2E scripts from the repo root:

```bash
bash cicd/01_rtsp_test.sh
bash cicd/03_godot_mujoco_device.sh
```
