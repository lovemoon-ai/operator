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
make build-pico-test
```

Output APKs:

| Target | APK |
| --- | --- |
| `build-quest` | `xr/build/quest/Operator.apk` |
| `build-pico` | `xr/build/pico/Operator.apk` |
| `build-glassxr` | `xr/build/glassxr/Operator.apk` |
| `build-quest-test` | `xr/build/quest_test/Operator.apk` |
| `build-pico-test` | `xr/build/pico_test/Operator.apk` |

### XR Build Profiles

`OPERATOR_BUILD_PROFILE` picks which export preset Godot runs and which native
dependencies Make builds first. The default is `full`.

| Profile | Quest preset | Pico preset |
| --- | --- | --- |
| `full` | `Meta Quest` | `Pico` |
| `teleop` | `Meta Quest Teleop` | `Pico Teleop` |

```bash
# Full APKs (default).
make build-quest
make build-pico

# Teleop-only APKs for faster iteration.
OPERATOR_BUILD_PROFILE=teleop make build-quest
OPERATOR_BUILD_PROFILE=teleop make build-pico

# Equivalent convenience aliases.
make build-quest-teleop
make build-pico-teleop
```

The Teleop presets enable only the Teleop and Exit product modes, set the
cold-start quick entry to `teleop`, and exclude the Android capture AARs, QR
scanner, SpatialMP4/FFmpeg stack, Live Push, and native hand-capture extension —
both its `.so` and its `.gdextension` descriptor. They also omit the static
`operator_capture_stack` export feature and disable camera, microphone, audio
configuration, and broad external-storage permissions. Their resource filter
drops the Capture, Live Feed and VR scenes and the scripts only those modes use.
They retain AHB video, MuJoCo, retargeting, and Pico OpenXR, so both Outside
Robot and Inside Robot Teleop keep working.

Nothing in the build edits `export_presets.cfg`. A Teleop preset is an ordinary
Godot preset, so exporting `Pico Teleop` from the editor produces the same APK
as `make build-pico-teleop`. Each Teleop preset is a derivation of its full
counterpart and may differ only in its name, resource filter, static Capture
feature, Capture-only Android permissions, and `operator_*` options.
`cicd/validate_xr_features.py` enforces that pairing — unrelated Android,
signing, or OpenXR drift still fails validation.

`operator_capture_stack` must be written directly in the full presets'
`custom_features`. Features returned dynamically by one Godot export plugin are
not visible to sibling plugins or GDExtension library matching during the same
export, so deriving this tag from `operator_feature_mode_*` would silently omit
native Capture libraries.

A resource filter is the riskiest half of a Teleop preset. It is written broadly
enough to strip a whole product surface, so it can also catch a base class the
retained surface still needs: excluding `scripts/sinks/sink_contract.gd` once
removed the `SensorSink` that `robot_control_sink.gd` extends, which made
`teleop_mode.gd` fail to parse. The export logged nothing, the APK looked right,
and Teleop reached the launcher but never started. The validator's rule (j)
closes that gap — it expands each Teleop filter and fails if anything the preset
keeps still resolves something the preset drops, whether by `res://` path or by
a `class_name` only the dropped script declares.

Both profiles write to the same APK path per platform, so `make install-pico`
installs whichever APK was built last.

Override the preset's quick entry for a single build — a Teleop-only APK that
still opens on the launcher:

```bash
OPERATOR_BUILD_PROFILE=teleop OPERATOR_QUICK_ENTRY=launcher make build-pico
```

`OPERATOR_QUICK_ENTRY` overrides the startup route only. Every other part of the
product surface comes from the preset alone.

Inspect the resolved configuration without building:

```bash
OPERATOR_BUILD_PROFILE=teleop make print-build-profile
```

`build-quest-test` and `build-pico-test` pin `full` with Make `override`, so they
keep the test harness even when a command-line `OPERATOR_BUILD_PROFILE=teleop` is
passed.

The export process may invoke `godot --headless`; that is export tooling only.
Do not use desktop headless Godot to run or test the XR project.

An APK artifact does not by itself prove that the exported GDScript dependency
graph is valid. Godot may write the APK while logging a parser failure, with a
downstream `Could not resolve class` hiding the original type error. Every
Android export target streams and captures the Godot log and fails on
`SCRIPT ERROR`, `Parse Error`, `Could not resolve class`, or
`Failed to load script` (`OPERATOR_ALLOW_SCRIPT_ERRORS=1` overrides). When
diagnosing a failure, fix the earliest parser error first. Dynamic GDScript
results should use explicit `Variant` or concrete annotations rather than
ambiguous `:=` inference.

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

A route is only served when its `operator_feature_mode_*` option is enabled in
the APK's export preset; otherwise the launcher logs the refusal and shows the
launcher. `mujoco` is the exception — an internal bring-up scene with no
feature flag, so it always resolves.

`vr` is refused by every preset the repo ships: `operator_feature_mode_vr` has
never been enabled. Turning that one option on restores the launcher card and
the intent together, and the full presets already pack the scene. There is
deliberately no `make run-vr` target while the option is off.

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
# Same suite on a Pico build (preset "Pico Test"), for Pico-only branches:
bash cicd/xr_module_harness.sh --platform pico --suite teleop.settings --serial <serial>
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

## Versioning And Release

The root `VERSION` file holds the one release version (SemVer, e.g. `0.2.0` or
`0.3.0-rc.1`) for all components:

- Rust: `robot/Cargo.toml` `[workspace.package] version`, inherited by every crate.
- Python: `operator_xr` (published on PyPI as `operator-xr`) uses
  `dynamic = ["version"]`, so maturin takes the Cargo version (`0.3.0-rc.1`
  becomes `0.3.0rc1`). Read it with `operator_xr.__version__` or
  `operator --version`.
- C++: `cpp/liboperator` reads `VERSION` at configure time; the linked library
  reports its version through `operator_version()` / `operator_sdk::version()`.
- XR: `xr/project.godot` `application/config/version`. The `operator-features`
  export plugin sets the APK versionName to that value and versionCode to
  `git rev-list --count HEAD`, and writes the short commit into the PCK. Teleop
  and Ego settings show the version, commit, and build time on their
  **Version info** page.

`scripts/version.py set X.Y.Z` updates every copy and `scripts/version.py check`
fails if anything has drifted. Releases follow `claw/sop/release.md`. Pushing a
`vX.Y.Z` tag triggers `.github/workflows/python-release.yml`, which builds
`operator-xr` wheels (Linux x86_64/aarch64, macOS arm64) and an sdist, then
publishes them through PyPI Trusted Publishing. Pre-release tags publish as PyPI
pre-releases, which `pip` only installs with `--pre` or an exact version.

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
