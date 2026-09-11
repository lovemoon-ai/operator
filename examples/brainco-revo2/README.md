# BrainCo Revo2 Teleop Example

This example runs the BrainCo Revo2 dual-hand service through Operator's
mode-independent Blueprint protocol. The robot process publishes the
head label, per-hand status lamps, left-palm control menu, and five-finger
tactile feedback; the headset owns rendering, hand interaction, tracked
fingertip placement, and user visibility overrides.

The PICO APK, ARM64 `xr-bridge`, and deployed `pyoperator` files must come from
the same checkout. Blueprint negotiation includes the generated
`specs/blueprint/v1.json` SHA-256 digest; a mixed deployment keeps tracking,
commands, telemetry, and video connected but deliberately disables Blueprint
UI. `xr-bridge` logs the expected and received digest when this happens.

The service starts read-only by default. Physical hand commands require both
the explicit `--allow-commands` flag and an unlock event from the palm menu. In
read-only mode the menu remains interactive as an input preview, but the hand
runtime never calls a motion API. Tracking loss, stale telemetry, disconnect,
or shutdown sends a hold command and relocks control.

## Thor/Orin ARM64 Build

Thor reports `aarch64` from `uname -m`. Do not copy
`robot/target/release/xr-bridge` from an x86-64 development machine: that file
is a host binary and fails on Thor with `Exec format error`.

Cross-build a static ARM64 binary from an x86-64 host:

```bash
rustup target add aarch64-unknown-linux-musl
cd robot
CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER=rust-lld \
  cargo build --release -p xr-bridge --target aarch64-unknown-linux-musl

file target/aarch64-unknown-linux-musl/release/xr-bridge
# Expected: ELF 64-bit ... ARM aarch64 ... statically linked
```

Deploy that target-specific artifact, then verify it on Thor before starting
the service:

```bash
scp target/aarch64-unknown-linux-musl/release/xr-bridge \
  unitree@192.168.124.64:/tmp/xr-bridge.aarch64

ssh unitree@192.168.124.64 \
  'install -m 0755 /tmp/xr-bridge.aarch64 \
     /home/unitree/ws/operator-hand/bin/xr-bridge.new && \
   mv -f /home/unitree/ws/operator-hand/bin/xr-bridge.new \
     /home/unitree/ws/operator-hand/bin/xr-bridge && \
   rm -f /tmp/xr-bridge.aarch64 && \
   file /home/unitree/ws/operator-hand/bin/xr-bridge && \
   /home/unitree/ws/operator-hand/bin/xr-bridge --help | head'
```

Building directly on an ARM64 Linux host may use the normal
`cargo build --release -p xr-bridge` output instead, but always verify the
deployed file reports `ARM aarch64`. Rebuild and reinstall the headset APK from
the same checkout whenever `specs/blueprint/v1.json` changes.

## Validate From The Checkout

Build `xr-bridge`, connect the Revo2 serial interfaces, and run:

```bash
cd robot
cargo build --release -p xr-bridge
cd ..

python3 examples/brainco-revo2/revo2_thor_service.py \
  --xr-bridge robot/target/release/xr-bridge \
  --bridge-config robot/configs/revo2_tuning.yaml \
  --check
```

Run without motion first:

```bash
python3 examples/brainco-revo2/revo2_thor_service.py \
  --xr-bridge robot/target/release/xr-bridge \
  --bridge-config robot/configs/revo2_tuning.yaml
```

Only after clearing the workspace and confirming the serial identities, add
`--allow-commands`. The headset then connects to the host's normal Outside
Robot endpoint and the palm menu remains the authoritative motion gate.

See `../../docs/tutorials/revo2-dual-hand-teleop.md` for hardware identities,
Thor bundle deployment, port requirements, telemetry, and safety details.
