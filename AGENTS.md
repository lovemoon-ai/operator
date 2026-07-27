# AGENTS.md

## What This Repo Is

Operator is a unified toolkit for teleoperation and egocentric data
collection.

- `robot/` - Rust crates for `teleop-protocol`, `xr-bridge`, and
  `robot-adapter`.
- `python/` - Python-first `pyoperator` package, examples, and tests.
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

The APK ships its native libraries uncompressed (`extractNativeLibs=false`) so
they mmap straight from the APK. Always install with `adb install
--no-incremental` (the `make install-*` targets already do): the default
incremental install can leave a Stored `.so` at a stale offset on reinstall,
and the loader then reads a ZIP header instead of ELF (`bad ELF magic:
504b0304`). MuJoCo fails to load and every simulated robot breaks. A stale
device can be repaired with `--no-incremental` without wiping app data, or with
`make uninstall && make install-quest`.

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
cd python && .venv/bin/python -m pytest -m xr_device --no-cov \
  --run-device --require-device --adb-serial SERIAL

# Teleop robot-configuration page (Inside/Outside switching, robot picker).
bash cicd/xr_module_harness.sh --suite teleop.settings

# Every robot this build ships must start and render on the headset. One app
# launch per robot: instantiating several in one frame kills the renderer.
bash cicd/08_inside_robot_display.sh --screenshots /tmp/robot_shots

# Inside Robot remote retargeting, on-device against a live host service.
# Start the service and forward it to the headset first:
#   cd python && .venv/bin/python -m pyoperator serve --service retargeting --port 8000
#   adb reverse tcp:8000 tcp:8000
bash cicd/xr_module_harness.sh --suite teleop.remote
```

Inside Robot profiles come from `xr/assets/robot_profiles/*.json` and are only
offered when their assets exist. Generate a robot with
`scripts/make-robot/make_<robot>.sh` before expecting it in the picker — robot
bundles under `xr/assets/robots/` are per-checkout, not committed.

Static checks that do not run the XR runtime:

```bash
python3 cicd/validate_xr_features.py
python3 cicd/validate_xr_test_manifests.py
bash cicd/03_godot_mujoco_static.sh
```
