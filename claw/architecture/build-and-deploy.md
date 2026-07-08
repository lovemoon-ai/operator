# Build And Deploy

## Host Requirements

XR builds require:

- Godot 4.5.1 stable on `PATH` as `godot`.
- matching Godot Android export templates.
- Android platform tools (`adb`).
- Android NDK for native XR addons.
- a real Quest, Pico, or Glass XR device for runtime validation.

The Makefile can take more than 10 minutes on the first Android export because
it prepares Godot Android templates and Gradle state.

## XR Builds

Run from `xr/`:

```bash
make deps
make build-quest
make build-pico
make build-glassxr
make build-quest-test
```

Output APKs:

| Target | APK |
| --- | --- |
| `build-quest` | `xr/build/quest/Operator.apk` |
| `build-pico` | `xr/build/pico/Operator.apk` |
| `build-glassxr` | `xr/build/glassxr/Operator.apk` |
| `build-quest-test` | `xr/build/quest_test/Operator.apk` |

The export process may invoke `godot --headless`; that is export tooling only.
Do not use desktop headless Godot to run or test the XR project.

## Install And Run

Run from `xr/`:

```bash
make install
make install-pico
make ship-quest
make ship-pico
make log
make crash
```

Quest 3 and Quest 3S share the Meta Quest APK family. Use `build-quest` /
`ship-quest`; do not add a Quest 3S export preset unless packaging or store
targeting changes. To target the Quest 3S currently used for validation:

```bash
QUEST_SERIAL=340YC10GBF1DS9 make ship-quest
```

`ship-*` targets build, install, configure `adb reverse` where needed, relaunch
the app, and tail filtered logs.

Useful manual commands:

```bash
adb devices
adb -s <serial> install -r xr/build/quest/Operator.apk
adb -s <serial> shell am force-stop com.lovemoon.operator
adb -s <serial> logcat -c
adb -s <serial> logcat | rg 'Operator|godot'
```

## Automation Modes

The launcher script `xr/scripts/app/launcher/mode_select.gd` handles
automation mode intent extras and routes to:

- `teleop`
- `ego_capture`
- `live_feed`
- `vr`
- `mujoco`

The MuJoCo test script wraps this for real devices:

```bash
bash cicd/03_godot_mujoco_device.sh --device quest
bash cicd/03_godot_mujoco_device.sh --device pico
bash cicd/03_godot_mujoco_device.sh --device both
```

Quest device E2E scripts accept either `--serial <adb-serial>` or
`QUEST_SERIAL=<adb-serial>`, including Quest 3S devices such as
`340YC10GBF1DS9`.

## XR Tests

Run from the repo root:

```bash
python3 cicd/validate_xr_features.py
python3 cicd/validate_xr_test_manifests.py
bash cicd/03_godot_mujoco_static.sh
bash cicd/xr_module_harness.sh --suite capture.pipeline --serial <serial>
```

Device E2E tests:

```bash
bash cicd/01_rtsp_test.sh
bash cicd/02_ego_record.sh
bash cicd/03_godot_mujoco_device.sh
bash cicd/04_live_feed_e2e.sh
```

Do not replace these with local fixtures. The XR runtime depends on Android XR
device APIs and vendor plugins.

## Robot Builds

Run from `robot/`:

```bash
cargo build --release
cargo test
```

The Rust workspace contains:

- `crates/teleop-protocol`
- `crates/robot-service`
- `crates/xr-bridge`
- `crates/robot-adapter`
- `crates/e2e-tests`

## Web App

Run from `web/`:

```bash
npm install
npm run dev
```

Default local URL: `http://localhost:3000/`.

The XR Ego settings upload URL for local testing is:

```text
http://<host-ip>:3000/api/ingest
```

## Known Runtime Status

Quest and Pico production APKs build and install with the current script
layout. The module harness is available through the Quest test APK. The MuJoCo
device smoke path is the authority for MuJoCo runtime status because it covers
native device execution.
