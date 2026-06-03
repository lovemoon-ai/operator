# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

> `CLAUDE.md` is a symlink to `AGENTS.md`. Edit `AGENTS.md`.

## What this repo is

Teleoperate-Anything is a two-sided system that lets a VR/MR headset
(Pico, Quest, Glass XR) drive an arbitrary teleoperable device (robot
arm, RC car, MuJoCo sim, …) over a LAN. Two halves talk over a custom
TCP+UDP protocol on a shared Layer-2 subnet:

- **`robot/`** — Rust agent (`robo-agent`). Runs on the robot host
  (Raspberry Pi, Mac dev box, Linux). Owns the device hardware, the
  H.264 video pipeline, mDNS/UDP discovery, and the TCP command +
  telemetry servers. Cross-compiles to `aarch64-unknown-linux-gnu`
  for Pi via `cross`.
- **`xr/`** — Godot 4.5 client APK. Runs in-headset. Hosts OpenXR,
  reads controller pose, sends `DeviceCommand` frames, decodes H.264
  via Android `MediaCodec`, and renders the feed in the passthrough
  scene. Pure GDScript on top of a Kotlin plugin
  (`KotlinVideoDecoderPlugin`) plus a C++ GDExtension
  (`xr/native/ahb_decoder`) for the zero-copy AHB video path.

Other top-level dirs:

- **`claw/`** — Project's own design-doc system.
- **`tools/mac_mock_streamer.py`** — Pure-Python reference
  implementation of the wire protocol. Useful when debugging XR-side
  behaviour without bringing up the Rust agent.
- **`examples/mujuco-arm-so101/`** — MuJoCo SO-101 sim with a JSON-line
  bridge; the `mujoco_so101` driver in `robot/src/devices/` spawns it
  as a subprocess for end-to-end teleop without physical hardware.

## Common commands

### Robot side (Rust)

Run from `robot/`:

```bash
make build              # cargo build --release (local arch)
make build-rpi          # cross-compile to aarch64-unknown-linux-gnu via `cross`
make deploy             # scp binary + config to $RPI_HOST over SSH
make test               # cargo test
make run                # cargo run --release with config/default.yaml + RUST_LOG=debug

# macOS-specific: stream from the built-in FaceTime camera to a
# connected XR client (used for end-to-end smoke tests without robot
# hardware). Pre-kills prior runs and frees ports 63900/63901/12345.
make run-mac-local-camera

# Same as above but launches in a fresh Terminal.app window so macOS
# TCC grants camera permission to ffmpeg. Use this when invoking from
# VSCode/Cursor/Conductor — those aren't TCC-registered for camera
# and the permission prompt never appears, causing ffmpeg to hang
# inside AVFoundation init forever.
make run-mac-local-camera-bg
```

Single-test patterns:

```bash
cd robot
cargo test --test e2e_protocol_test           # one integration test file
cargo test --test watchdog_test               # uses tokio test-util paused clock
cargo test --lib network::protocol            # one module
cargo test --release --example latency_bench  # examples in robot/examples/
```

Different device profiles live in `robot/config/*.yaml`. Switch device
by changing the `device.descriptor_file` field — see `default.yaml`
for the arm setup, `device_rc_car.yaml`, `device_robot_arm.yaml`,
`device_safety_smoke.yaml`. The `arm.driver` field selects between
`dynamixel | feetech_sts | feetech_scs | dummy | mujoco_so101`.

### XR side (Godot + Android)

Run from `xr/`. The build hits `godot --headless` so the `godot`
binary must be on `PATH` (Godot 4.5.1.stable). Android export
templates must be installed at the matching version — the Makefile
auto-extracts the AAR from `~/Library/Application Support/Godot/...`
or `~/.local/share/godot/...`.

```bash
make build              # build-quest — produces build/quest/XRoboToolkit.apk
make build-pico         # build/pico/XRoboToolkit.apk
make build-glassxr      # build/glassxr/XRoboToolkit.apk
make install            # adb install -r the Quest APK
make install-pico
make ship-pico          # build + install + adb-reverse + relaunch + filtered logcat tail
make ship-pico-fast     # same as ship-pico but skips build (when only the robot changed)

make reverse            # set adb reverse for 12345/63901/63900 so Pico → Mac via 127.0.0.1
                        # MUST re-run after adb daemon restart or USB replug
make log                # adb logcat filtered for XRoboToolkit/godot/OpenXR
make crash              # dump full logcat to crash.log
make godot              # open the project in the Godot editor
```

The AHB GDExtension (`xr/native/ahb_decoder/`) is a separate build:

```bash
# First time only:
git submodule update --init --depth=1 third_party/godot-cpp
ln -sfn ../../../third_party/godot-cpp xr/native/ahb_decoder/godot-cpp

xr/native/ahb_decoder/build.sh          # Release
xr/native/ahb_decoder/build.sh Debug    # symbol-level debugging
# Drops libahb_decoder.so into both xr/addons/ahb_decoder/ (for
# GDExtension) and xr/android/build/libs/arm64-v8a/ (for
# System.loadLibrary in the Kotlin plugin).
```

## Architecture
See `claw/architecture/overview.md`..

## Project conventions

- **Read `claw/issues/*.md` before touching the area they cover.**
  They document tried-and-reverted approaches and trip-wires.
  `005-decisions.md` in particular is load-bearing for any video,
  transport, or threading change.
- The `safety.rs` / `SafeDevice` chain is a deliberate single-path
  gate. Don't add new device entrypoints that bypass it — every
  command must go through `SafeDevice::execute`.
- Cross-platform code: V4L2 + hardware encode is Linux-only; macOS
  uses ffmpeg/AVFoundation via the `device: /dev/video0` →
  AVFoundation rewrite. Don't add `#[cfg(target_os = "linux")]`-only
  imports outside the `[target.'cfg(...)']` dependency block in
  `Cargo.toml` or behind `#[cfg]` in source.
- The `.conductor/` directory and `conductor.log` are local
  session/worktree state for the Conductor tool and are gitignored
  — don't depend on them.

## Run test

- Run video e2e test: bash tests/01_xr_video.sh
