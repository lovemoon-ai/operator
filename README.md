# Operator

Operator is a unified toolkit for robot teleoperation and egocentric data
collection. It contains:

- `xr/` - Godot 4.5 Android XR client for Quest, Pico, and Glass XR.
- `robot/` - Rust teleop protocol, robot adapter, and XR bridge crates.
- `web/` - local ingest and review app for egocentric recordings.
- `examples/` - runnable MuJoCo and live-feed server examples.
- `tests/` - device and protocol smoke tests.
- `claw/architecture/` - current architecture documentation.

## Current Shape

```text
XR headset (xr/)                         Robot / server side
----------------                         -------------------
Launcher mode cards                      xr-bridge / robot-adapter
  -> Teleop mode      TCP commands  ->   teleop-protocol
  -> Ego capture      TUS upload    ->   web ego-ingest
  -> Live feed        OLCP push     ->   live-feed server
  -> VR mode          OpenXR only
  -> MuJoCo test      device smoke  ->   Godot MuJoCo addon
```

The XR project follows the current modular layout:

- `xr/scenes/` holds Godot scene resources only.
- `xr/scripts/app/` holds launchers, app modes, feature composition, and
  scene lifecycle controllers.
- `xr/scripts/core/` holds capture, sensor, pipeline, and time primitives.
- `xr/scripts/contracts/` holds typed data contracts shared across modes.
- `xr/scripts/sinks/` holds output adapters for SpatialMP4, upload, live
  stream, robot control, and JSONL sidecars.
- `xr/scripts/ui/` holds all UI scripts, including `teleop_panel.gd`.
- `xr/scripts/test_support/` holds the on-device module test harness.

`xr/scenes/robot_view/robot_view.tscn` is still a scene resource because
`teleop_main.tscn` instances it as the 3D video panel. Its script is
`xr/scripts/ui/teleop_panel.gd`, a thin Operator-facing wrapper around
`xr/addons/live_video/live_video_view.gd`.

## Common Commands

XR builds run from `xr/` and require Godot 4.5.1 stable, Android export
templates, Android platform tools, and a real Android XR device.

```bash
cd xr
make deps
make build-quest
make build-pico
make build-glassxr
make install
make install-pico
make ship-quest
make ship-pico
make log
make crash
```

Do not run the XR project with desktop `godot --headless` as a substitute for
runtime testing. The client depends on Android XR device APIs.

Robot-side Rust commands run from `robot/`:

```bash
cargo build --release
cargo test
```

Web commands run from `web/`:

```bash
npm install
npm run dev
```

## Device Tests

Run these from the repository root with the target headset attached:

```bash
bash tests/01_rtsp_test.sh
bash tests/02_ego_record.sh
bash tests/03_godot_mujoco_device.sh --device quest
bash tests/03_godot_mujoco_device.sh --device pico
bash tests/04_live_feed_e2e.sh
bash tests/xr_module_harness.sh --suite capture.pipeline --serial <quest-serial>
```

Static validation that does not launch the XR runtime:

```bash
python3 tests/validate_xr_features.py
python3 tests/validate_xr_test_manifests.py
bash tests/03_godot_mujoco_static.sh
```

## Docs

- Architecture index: `claw/CLAW.md`
- System overview: `claw/architecture/overview.md`
- XR client: `claw/architecture/xr-client.md`
- Build and deploy: `claw/architecture/build-and-deploy.md`
- Wire protocols: `claw/architecture/wire-protocol.md`
- Live Feed: `claw/architecture/live-feed-cloud.md`
- Robot side: `claw/architecture/rust-agent.md`
