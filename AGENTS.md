# AGENTS.md

## What this repo is

Operator is an unified toolkit for teleoperation and egocentric data collection. 

- **`robot/`** — xr-bridge and robot-adapter.
- **`xr/`** — Godot 4.5 client APK. Runs in-headset.
- **`claw/`** — Project's own design-doc system.
- **`examples/mujuco-arm-so101/`** — MuJoCo SO-101 simulation.

## Common commands

### XR side (Godot + Android)

It costs much time ( > 10 minites )to build godot apk for the first time. Please
run it in background avoiding timeout when building project.

Run from `xr/`. The build hits `godot --headless` so the `godot`
binary must be on `PATH` (Godot 4.5.1.stable). Android export
templates must be installed at the matching version — the Makefile
auto-extracts the AAR from `~/Library/Application Support/Godot/...`
or `~/.local/share/godot/...`.

```bash
make deps               # sync pinned third-party repos into ../.deps
make build-pico         # build/pico/Operator.apk
make build-quest        # build/quest/Operator.apk
make build-glassxr      # build/glassxr/Operator.apk
make install            # adb install -r the Quest APK
make install-pico
make ship-pico          # build + install + adb-reverse + relaunch + filtered logcat tail
make ship-quest         # build + install + adb-reverse + relaunch + filtered logcat tail
make log                # adb logcat filtered for Operator/godot
make crash              # dump full logcat to crash.log
```

NEVER try to run "godot --headless" mode on desktop to test xr project.
Android XR device is required to run xr project.

### Robot side (Rust)

TBD

## Architecture
See `claw/architecture/overview.md`..

## Run test

- Run video e2e test: bash tests/01_rtsp_test.sh
- Run ego recording e2e test: bash tests/02_ego_record.sh
- Run mujoco test: bash tests/03_godot_mujoco_device.sh
- Run live feed e2e test: bash tests/04_live_feed_e2e.sh

DON'T try to create any fixture for these tests. ONLY run the tests on target
device.
