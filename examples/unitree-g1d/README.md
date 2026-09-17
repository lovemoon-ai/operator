# Operator Unitree G1-D Client

`operator-g1d-client` is the robot-side adapter for a Unitree G1-D. It keeps
the existing Rust `xr-bridge` generic: the bridge connects to this process over
the standard length-prefixed adapter protocol, while this process owns the
Unitree SDK2/DDS connection.

The current implementation provides:

- base forward/reverse and yaw control through `AgvClient::Move`;
- lift velocity control through `AgvClient::HeightAdjust`;
- fresh odometry, height, low-state, and joint telemetry;
- local command watchdog, neutral-return interlock, mode arbitration, measured
  base-speed guard, and repeated stop commands;
- a robot-authored Blueprint showing the head-camera video panel, connection
  state, and motion-safety state in the headset;
- a mock backend for tests without a robot;
- simultaneous left/right 7-DoF arm IK from either physical controllers or
  optically tracked bare hands;
- controller-driven BrainCo Revo-1 hands through the robot's existing
  `brainco_hand_server` DDS service;
- G1-D-specific joint limits, per-cycle joint-rate limiting, relative-pose
  engagement, fresh-low-state gating, and `rt/lowcmd` CRC generation.

Starting the process does not move the robot. The Unitree backend remains
read-only unless `--allow-motion` is explicitly supplied, and it does not send
base/lift/arm commands until it has actually taken ownership of that subsystem.

## Build

Build the Rust `liboperator` core before configuring CMake. On a native build
machine this is:

```bash
cargo build --manifest-path robot/Cargo.toml --release -p operator-c
```

Then, on the G1-D computer using its deployed SDK checkout:

```bash
cmake -S examples/unitree-g1d \
  -B examples/unitree-g1d/build \
  -DUNITREE_SDK2_ROOT=/home/unitree/unitree_sdk2 \
  -DLIBOPERATOR_LIBRARY=/path/to/aarch64/liboperator.a
cmake --build examples/unitree-g1d/build -j
cmake -E chdir examples/unitree-g1d/build ctest --output-on-failure
```

`LIBOPERATOR_LIBRARY` should point to a static library built for the same target
architecture as the C++ adapter. If it is omitted, CMake prefers
`robot/target/release/liboperator.a`, then the debug static library, and only
then falls back to a shared library.

For protocol, controller, mock-backend, and Blueprint development on a machine
without the G1-D-specific AGV SDK header, configure an out-of-tree build with:

```bash
cmake -S examples/unitree-g1d -B /tmp/operator-g1d-build \
  -DUNITREE_SDK2_ROOT=/path/to/unitree_sdk2 \
  -DOPERATOR_G1D_WITH_UNITREE=OFF \
  -DLIBOPERATOR_LIBRARY="$PWD/robot/target/release/liboperator.a"
cmake --build /tmp/operator-g1d-build -j
ctest --test-dir /tmp/operator-g1d-build --output-on-failure
```

This still uses SDK2's common JSON utilities, but does not require the G1-D AGV
header. Such a binary rejects `--backend unitree`; it is only for offline
validation.

## Offline smoke test

The default backend is a simulator and never opens DDS:

```bash
examples/unitree-g1d/build/operator-g1d-client \
  --backend mock \
  --descriptor examples/unitree-g1d/config/unitree_g1d_descriptor.json \
  --blueprint examples/unitree-g1d/config/unitree_g1d_blueprint.json
```

In another shell:

```bash
cargo run --manifest-path robot/Cargo.toml -p xr-bridge -- \
  --config examples/unitree-g1d/config/unitree_g1d_bridge.yaml
```

## Hardware bring-up

Run both the native adapter and `xr-bridge` on the G1-D Orin. The adapter uses
a local Unix-domain socket, while `xr-bridge` exposes the Operator ports on the
robot network so the headset connects directly to the robot.

The G1-D computer does not need a Rust toolchain. Cross-compile both the static
ARM64 C++ SDK core and the standalone bridge on the Operator Ubuntu host, then
copy them to the robot:

```bash
sudo apt install gcc-aarch64-linux-gnu
rustup target add aarch64-unknown-linux-gnu
rustup target add aarch64-unknown-linux-musl
cd robot
CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER=aarch64-linux-gnu-gcc \
  cargo build --release --target aarch64-unknown-linux-gnu -p operator-c
RUSTFLAGS="-C linker=rust-lld -C link-self-contained=yes" \
  cargo build --release --target aarch64-unknown-linux-musl -p xr-bridge
scp target/aarch64-unknown-linux-gnu/release/liboperator.a \
  unitree@192.168.124.50:/home/unitree/operator/lib/liboperator.a
scp target/aarch64-unknown-linux-musl/release/xr-bridge \
  unitree@192.168.124.50:/home/unitree/operator/bin/xr-bridge
```

The deployed bridge config starts
`examples/unitree-g1d/scripts/teleimager_h264.py` with the robot's `tv` Python
environment. The helper subscribes to the existing head-camera JPEG stream at
`tcp://127.0.0.1:55555`, crops the left image from the 1280x480 stereo pair,
and runs low-latency `libx264`. `xr-bridge` supervises that process and relays
its Annex-B H.264 output to the headset over TCP/UDP port `12345`. The Orin
therefore needs the existing `teleimager.service`, `pyzmq`, `/usr/bin/ffmpeg`,
and the `libx264` encoder.

The head-camera helper enables `--tone-correction on` for the current UVC
camera. It compresses already-clipped highlights and slightly compensates the
green cast before H.264 encoding. This improves the headset view but cannot
recover detail that the camera's automatic exposure already clipped in the raw
JPEG. Disable it with `--tone-correction off` after hardware exposure/white
balance is corrected in the root-owned `teleimager.service`.

Configure the G1-D C++ build with
`-DLIBOPERATOR_LIBRARY=/home/unitree/operator/lib/liboperator.a`. The final
adapter binary contains the Rust core statically and does not need
`liboperator.so` at runtime.

First start the robot process without motion authorization:

```bash
/home/unitree/operator/examples/unitree-g1d/build/operator-g1d-client \
  --backend unitree \
  --listen uds:/tmp/operator-g1d.sock \
  --network-interface eth0 \
  --domain 0 \
  --descriptor /home/unitree/operator/examples/unitree-g1d/config/unitree_g1d_descriptor.json \
  --blueprint /home/unitree/operator/examples/unitree-g1d/config/unitree_g1d_blueprint.json
```

Then start the bridge on the G1-D Orin:

```bash
/home/unitree/operator/bin/xr-bridge \
  --config /home/unitree/operator/examples/unitree-g1d/config/unitree_g1d_bridge.yaml
```

The Quest connects to the robot Wi-Fi address (`192.168.124.50` for the
current deployment) on Operator command port `63901`.

Do the read-only health/identity checks first. Only after the robot, workspace,
feedback topics, and absence of competing controllers are confirmed, restart
the robot process with explicit motion authorization:

```bash
/home/unitree/operator/examples/unitree-g1d/build/operator-g1d-client \
  --backend unitree \
  --listen uds:/tmp/operator-g1d.sock \
  --network-interface eth0 \
  --domain 0 \
  --allow-motion \
  --descriptor /home/unitree/operator/examples/unitree-g1d/config/unitree_g1d_descriptor.json \
  --blueprint /home/unitree/operator/examples/unitree-g1d/config/unitree_g1d_blueprint.json
```

The initial limits are intentionally conservative and configurable from the
CLI. They are starting values for supervised validation, not manufacturer
limits or a substitute for checking measured motion.

The current defaults are `0.12 m/s` base command, `0.40 rad/s` yaw command,
`0.20 m/s` measured linear-speed guard, `0.75 rad/s` measured yaw-speed guard,
`0.35 m` arm displacement per engagement, `1.0 rad/s` commanded arm joint
speed, and a `2.0 rad/s` measured arm-speed guard.
G1-D command values do
not map one-to-one to measured velocity, so tune from fresh odometry rather
than treating these values as calibrated physical limits.

`--blueprint` is optional when the JSON sits beside the descriptor under the
default name `unitree_g1d_blueprint.json`. The adapter uses `liboperator` for
Blueprint validation, state sequence allocation, adapter-envelope generation,
event validation, and descriptor capability/spec-hash injection. The protocol
smoke test checks that hash against `specs/blueprint/v1.json`. Deploy the
adapter, bridge, and headset from the same checkout after a Blueprint spec
change.

The Blueprint controls presentation only. Its `video_panel` makes the declared
head-camera feed visible. G1-D intentionally omits `controller_help` so the
legacy generic hand overlay does not cover its robot-specific status lamps. It
does not unlock motion or replace neutral-return interlocks, reset confirmation,
the watchdog, or the local E-stop.

## Controls

| Input | Action |
| --- | --- |
| Left stick Y | base forward/reverse |
| Right stick X | base yaw |
| X | upper arms down, elbows slightly outward, forearms forward; open both hands |
| Y | return both arms to the straight-down initial pose; open both hands |
| Left/right controller grip | hold to drive that arm from the controller pose |
| Left/right bare-hand fist | hold to drive that arm from the tracked wrist pose |
| Left/right trigger | hold to execute that Revo-1 fixed grasp; release to open |
| B | latch software emergency stop |
| A twice within 2 seconds, with controls neutral | clear software emergency stop |

Base, lift, and arm modes are mutually exclusive. Both arms may be driven
simultaneously, but pressing X/Y or moving a drive stick while an arm deadman is
held stops all modes as a conflict. Arm engagement captures the current wrist,
measured robot pose, and operator head yaw, so taking control does not command
a jump. Later wrist motion is interpreted relative to that Grip-edge baseline
in the yaw-normalized operator frame; for bare hands, opening the hand releases
the deadman. Tracking loss, stale joint feedback, an unreachable IK
target, or exceeding the per-engagement workspace radius stops arm updates and
requires all motion controls to return to neutral before resuming.

X latches a robot-side ready-pose action: shoulder pitch/yaw and wrists return
near neutral, shoulder roll moves to `+0.20/-0.20 rad`, and elbow joint position
moves to `0 rad`, so the upper arms hang down, the elbows sit slightly outward,
and the forearms point forward. Y returns to the straight-down initial pose with
neutral shoulders/wrists and elbow joint position `pi/2 rad`.
Both Revo-1 hands open at the same time. The action uses measured joint feedback,
runs at a bounded joint rate (default `0.5 rad/s`), and ends only after all arm
joints are within `0.04 rad` of the target.

After a disconnect, watchdog stop, or feedback fault, all motion axes must
return to neutral before motion can resume. The two-press confirmation is
enforced by `xr-bridge`; the native adapter receives one sanitized `reset=true`
command and independently rejects it if emergency stop or any motion axis is
active in the same frame. Once the arm low-level channel has been acquired, a
release or emergency stop refreshes the hold target from measured joint state
instead of continuing toward an old target or dropping upper-body torque.

The IK and protocol paths have offline tests. Treat the first hardware run as a
supervised bring-up: verify the installed G1-D SDK/firmware joint map, clear the
workspace, confirm no competing `rt/lowcmd` publisher, start with a reduced
`--max-arm-joint-velocity`, and keep the physical E-stop available.

The arm mapping follows Unitree's `xr_teleoperate` design where practical: the
operator head yaw defines forward, IK translation is weighted over orientation,
solutions use measured joints as the warm start, and a four-sample
`0.4/0.3/0.2/0.1` weighted filter precedes measured-state velocity clipping.
Reference implementation: https://github.com/unitreerobotics/xr_teleoperate

### BrainCo Revo-1 controller mode

The adapter does not open BrainCo serial ports. The robot's existing
`brainco_hand_server` remains their sole owner and exposes normalized DDS topics
`rt/brainco/{left,right}/{cmd,state}`. The adapter subscribes to fresh state and
publishes bounded targets while that side's physical controller is actively
tracked. Releasing trigger/grip commands a smooth return to open; controller
tracking loss, timeout, disconnect, or stop holds the latest measured position.
Revo-1 has five controllable motors; the six-slot DDS `ThumbAux`
position is Revo2-only and is always held at its measured value.

Controller trigger selects one fixed grasp target for all five Revo-1 motors;
releasing it selects the open target. Grip remains only the corresponding arm
IK deadman. Trigger hysteresis prevents threshold chatter. Target changes are
rate-limited by `--max-hand-rate` (default `1.0` normalized unit/s), and measured
speed is guarded by `--max-measured-hand-speed` (default `1.5`). Absolute
normalized current is strongly EMA-filtered before applying `--max-hand-current`
(default `0.8`), so one-sample start/stop spikes do not false-trigger it.
The fixed close position is configured by `--revo1-grasp-target` (default `0.85`).

The input mapping is carried by `unitree_g1d_descriptor.json`, not by the
Blueprint. A read-only adapter still receives and validates those commands but
does not call the Unitree motion APIs. Restart it with `--allow-motion` only for
a supervised motion session.
