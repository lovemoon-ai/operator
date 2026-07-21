# AGENTS.md

## What This Repo Is

Operator is a unified toolkit for teleoperation and egocentric data
collection.

- `robot/` - Rust crates for `teleop-protocol`, `xr-bridge`, and
  `robot-adapter`.
- `xr/` - Godot 4.5 Android XR client APK. It runs in-headset.
- `web/` - local ingest and review app for egocentric recordings.
- `claw/` - current architecture documentation.
- `examples/mujuco-arm-so101/` - MuJoCo SO-101 simulation.

## XR Side

Run from `xr/`. First Android export can take more than 10 minutes, so run
long builds in the background when useful. The build invokes
`godot --headless` for export only; do not use desktop headless mode to run or
test the XR project.

Required host state:

- `godot` on `PATH`, version 4.5.1 stable.
- matching Android export templates.
- Android platform tools on `PATH`.
- a real Android XR device for runtime tests.

```bash
make deps
make build-pico
make build-quest
make build-glassxr
make install
make install-pico
make ship-pico
make ship-quest
make log
make crash
```

## Robot Side

Run from `robot/`.

```bash
cargo build --release
cargo test
```

## Architecture

See `claw/architecture/overview.md`. Historical RFC, issue, lesson, and v2
planning documents have been removed from the repo; keep architecture docs
current instead of adding new history logs.

## Tests

Run device tests only on target devices. Do not create local fixtures to
replace device coverage.

```bash
bash cicd/01_rtsp_test.sh
bash cicd/02_ego_record.sh
bash cicd/03_godot_mujoco_device.sh
bash cicd/04_live_feed_e2e.sh
```

Static checks that do not run the XR runtime:

```bash
python3 cicd/validate_xr_features.py
python3 cicd/validate_xr_test_manifests.py
bash cicd/03_godot_mujoco_static.sh
```
