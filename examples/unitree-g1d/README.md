# Operator Unitree G1-D Client

`operator-g1d-client` is the robot-side adapter for a Unitree G1-D. It keeps
the existing Rust `xr-bridge` generic: the bridge connects to this process over
the standard length-prefixed adapter protocol, while this process owns the
Unitree SDK2/DDS connection.

The current implementation is the first safe hardware milestone:

- base forward/reverse and yaw control through `AgvClient::Move`;
- lift velocity control through `AgvClient::HeightAdjust`;
- fresh odometry, height, low-state, and joint telemetry;
- local command watchdog, neutral-return interlock, mode arbitration, measured
  base-speed guard, and repeated stop commands;
- a robot-authored Blueprint showing the head-camera video panel, connection
  state, and motion-safety state in the headset;
- a mock backend for tests without a robot;
- no arm command publishing yet. Joint state is exposed, but `dual_arm` remains
  false until G1-D-specific kinematics and the low-command takeover sequence are
  validated on the target robot.

Starting the process does not move the robot. The Unitree backend remains
read-only unless `--allow-motion` is explicitly supplied, and it does not send
base/lift zero commands until it has actually taken ownership of that subsystem.

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
`0.20 m/s` measured linear-speed guard, and `0.75 rad/s` measured yaw-speed
guard. G1-D command values do
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
| X | lower lift |
| Y | raise lift |
| B | latch software emergency stop |
| A twice within 2 seconds, with controls neutral | clear software emergency stop |

Base and lift modes are mutually exclusive. Pressing X/Y while either drive
stick is active stops both modes as a conflict. After a disconnect, watchdog stop, or feedback fault,
all motion axes must return to neutral before motion can resume. The two-press
confirmation is enforced by `xr-bridge`; the native adapter receives one
sanitized `reset=true` command and independently rejects it if emergency stop
or any motion axis is active in the same frame.

The input mapping is carried by `unitree_g1d_descriptor.json`, not by the
Blueprint. A read-only adapter still receives and validates those commands but
does not call the Unitree motion APIs. Restart it with `--allow-motion` only for
a supervised motion session.
