# MuJoCo Agent SOUL

You are the maintainer for the Godot MuJoCo addon. This document explains what was built,
where the code lives, how the modules fit together, and how to build and test the feature
on standalone Android XR devices.

## Purpose

The MuJoCo work implements RFC 003: a Godot 4.5 addon that embeds native MuJoCo on standalone Android XR headsets. The design intent is:

- MuJoCo is the source of truth for physics.
- Godot owns XR rendering, UI, visualization, input, haptics, and data collection orchestration.
- The runtime target is headset-local Quest/PICO execution, not a desktop simulator.
- The first production path is mobile-manipulator teleoperation and LeRobot-compatible episode collection.

The RFC lives at `claw/rfcs/003-godot-mujoco-addon.md`.

## Current Status

Implemented in this branch:

- Godot addon skeleton and runtime API under `xr/addons/godot_mujoco/`.
- Android arm64 GDExtension wrapper around the real MuJoCo C API under `xr/native/godot_mujoco/`.
- MuJoCo assets and a device smoke/physics scenario under `xr/assets/mujoco/`.
- Android XR automation scene under `xr/scenes/mujoco/`.
- Mode routing via `operator.mode=mujoco`.
- Build targets for Quest and PICO MuJoCo APKs.
- Static/package checks and on-device E2E scripts.
- PICO E2E has passed previously with native MuJoCo loaded. The latest physics-assertion E2E requires a connected device to rerun.

## Directory Map

### Addon Runtime

`xr/addons/godot_mujoco/`

- `godot_mujoco.gdextension` declares the Android-only GDExtension and its `libmujoco.so` dependency.
- `plugin.cfg` and `plugin.gd` register the addon in Godot.
- `mj_simulation.gd` is the main high-level simulation API used by scenes.
- `mj_model_resource.gd` stores parsed model metadata: bodies, joints, actuators, geoms, sensors, stable IDs.
- `mj_robot_importer.gd` imports MJCF/URDF metadata into `MjModelResource`.
- `mj_body_tracker.gd` syncs a MuJoCo body transform into a Godot `Node3D`.
- `mj_teleop_rig.gd` maps XR controller state into a structured teleop action/control dictionary.
- `mj_haptics_bridge.gd` converts contact/force observations into controller haptic pulses.
- `mj_lerobot_recorder.gd` records LeRobot-compatible JSONL proxy episodes.
- `mj_dataset_validator.gd` validates metadata, frame order, modalities, and replayability.
- `mj_profiler.gd` samples step timing and runtime stats.
- `mj_scenario.gd` defines scenario/task metadata.
- `mj_reset_policy.gd` applies deterministic reset policy metadata.
- `mj_device_capability_profile.gd` captures device/runtime capability metadata.

### Native Runtime

`xr/native/godot_mujoco/`

- `CMakeLists.txt` builds the Android-only shared library `libgodot_mujoco.so` and links MuJoCo.
- `build.sh` drives the Android NDK/CMake build, syncs `godot-cpp`, and stages native libraries.
- `src/mujoco_native.h` declares the Godot-facing `MjNativeSimulation` class.
- `src/mujoco_native.cpp` owns `mjModel`/`mjData`, XML loading, stepping, reset, controls, body transforms, model summaries, contacts, forces, and state snapshots.
- `src/register_types.cpp` registers the GDExtension entry point.

The native wrapper currently exposes:

- `load_xml_string(xml, name)`
- `reset()`
- `step(dt)`
- `get_status()`
- `get_model_summary()`
- `get_state()`
- `get_observation()`
- `get_body_names()` / `get_joint_names()` / `get_actuator_names()` / `get_geom_names()` / `get_sensor_names()`
- `get_body_transform(body_name)`
- `set_actuator_control(name, value)`
- `set_control_by_index(index, value)`

### Assets and Device Scene

`xr/assets/mujoco/`

- `mobile_manipulator_smoke.xml` is the primary on-device test MJCF.
- `so101_pickplace.xml`, `so101.xml`, and `so101_new_calib.urdf` are SO-101/mobile-manipulator reference assets.

`mobile_manipulator_smoke.xml` intentionally avoids external meshes so it can reliably load inside the APK. It contains:

- A mobile base and simple arm/gripper chain.
- A free red cube.
- A free `falling_box` used to validate gravity and floor contact.
- A free `ramp_ball` used to validate slope rolling.
- Static `inclined_ramp`, `stop_block`, and `floor` geoms.

`xr/scenes/mujoco/mujoco_device_test.gd` and `xr/scenes/mujoco/mujoco_device_test.tscn` implement the on-device automation scene. The scene:

- Requires the native MuJoCo backend.
- Loads the smoke MJCF through `MjSimulation`.
- Adds body trackers and simple visual meshes for dynamic props.
- Runs the simulation at a fixed 120 Hz step independent of render rate.
- Records a JSONL episode via `MjLeRobotRecorder`.
- Validates dataset and replay.
- Validates real physics behavior before passing:
  - `falling_box` must drop significantly and settle near the floor.
  - `ramp_ball` must move along the ramp.
  - Native contact count must become positive.
- Emits `[GodotMuJoCoTest] PHYSICS_PASS ...` and `[GodotMuJoCoTest] PASS ...` on success.

## Runtime Flow

1. Android launches `GodotApp` with intent extras.
2. `xr/android/build/src/com/godot/game/GodotApp.java` forwards automation extras into Godot command-line args:
   - `operator.mode` -> `--operator-mode`
   - `mujoco.duration` -> `--mujoco-duration`
   - `mujoco.min.frames` -> `--mujoco-min-frames`
3. `xr/scenes/mode_select.gd` normalizes `operator.mode=mujoco` and routes to `res://scenes/mujoco/mujoco_device_test.tscn`.
4. The scene instantiates `MjSimulation`.
5. `MjSimulation` imports the MJCF/URDF metadata and tries to instantiate `MjNativeSimulation` through the GDExtension.
6. `MjNativeSimulation` loads expanded MJCF XML into MuJoCo with `mj_loadXML`, creates `mjData`, calls `mj_forward`, then steps via `mj_step`.
7. Godot syncs body transforms for visualization and samples observations for recording.
8. The recorder writes metadata, JSONL frames, and summary to device storage.
9. The E2E script pulls the dataset and validates it on the host.

## Build Integration

Main build files:

- `xr/Makefile`
- `xr/makefiles/Makefile.addons`
- `xr/export_presets.cfg`
- `xr/project.godot`

MuJoCo-specific targets:

```bash
cd xr
make build-mujoco-quest
make build-mujoco-pico
make run-mujoco
```

`build-mujoco-quest` stages:

- Godot XR vendor setup.
- Android template libraries.
- AHB decoder native addon.
- Godot MuJoCo native addon.
- Quest export to `xr/build/quest/Operator.apk`.

`build-mujoco-pico` additionally builds/stages the PICO OpenXR loader and exports to `xr/build/pico/Operator.apk`.

The MuJoCo native build expects:

- Android NDK via `ANDROID_NDK`, `ANDROID_NDK_HOME`, or `ANDROID_NDK_ROOT`.
- MuJoCo Android package via `MUJOCO_ANDROID_ROOT`, defaulting to `/home/duino/opt/mujoco_android`.
- `MUJOCO_ANDROID_ROOT/include/mujoco/mujoco.h`.
- `MUJOCO_ANDROID_ROOT/lib/libmujoco.so`.

The native build stages libraries into both addon and Android JNI locations:

- `xr/addons/godot_mujoco/bin/libgodot_mujoco.so`
- `xr/addons/godot_mujoco/bin/libmujoco.so`
- `xr/android/build/libs/arm64-v8a/libgodot_mujoco.so`
- `xr/android/build/libs/arm64-v8a/libmujoco.so`

Generated `.so` files are build outputs and should stay ignored by Git.

## Test Strategy

There are three layers.

### 1. Static and Package Check

Run from repo root:

```bash
bash tests/03_godot_mujoco_static.sh
```

This checks:

- Required addon/native/test files exist.
- Native source includes real MuJoCo calls such as `mj_loadXML` and `mj_step`.
- Device scene requires native backend and includes dataset/reset/device metadata hooks.
- Device scene includes `PHYSICS_PASS`.
- The MJCF contains `falling_box`, `ramp_ball`, and `inclined_ramp`.
- Quest/PICO APKs include `libgodot_mujoco.so`, `libmujoco.so`, MuJoCo assets, and compiled scripts.
- APK-embedded smoke MJCF includes the physics props.

### 2. Build Checks

Run from `xr/`:

```bash
make build-mujoco-quest
make build-mujoco-pico
```

Godot may print desktop Linux GDExtension warnings during export because these extensions are Android-only. Those warnings are expected during export if the command exits with status 0 and the APK is produced.

### 3. Device E2E

Run from repo root. The script can auto-detect Quest/PICO, or accept an explicit device kind.

Short PICO run:

```bash
bash tests/03_godot_mujoco_device.sh --device pico --skip-build --duration 20 --min-frames 300
```

Short Quest run:

```bash
bash tests/03_godot_mujoco_device.sh --device quest --skip-build --duration 20 --min-frames 300
```

Auto-detect the single connected device:

```bash
bash tests/03_godot_mujoco_device.sh --skip-build --duration 20 --min-frames 300
```

Long PICO soak test:

```bash
bash tests/03_godot_mujoco_device.sh --device pico --skip-build --duration 600 --min-frames 12000
```

Both devices, when both are connected and authorized:

```bash
PICO_SERIAL=<pico_serial> QUEST_SERIAL=<quest_serial> \
  bash tests/03_godot_mujoco_device.sh --device both --skip-build --duration 60 --min-frames 600
```

The device script does the following:

1. Selects the target device by serial or by manufacturer/model.
2. Builds the correct MuJoCo APK unless `--skip-build` is used.
3. Installs the APK unless `--skip-install` is used.
4. Clears app data and prior MuJoCo datasets.
5. Launches `operator.mode=mujoco` with duration/frame extras.
6. Waits for `[GodotMuJoCoTest] started`.
7. Waits for both `[GodotMuJoCoTest] PHYSICS_PASS` and `[GodotMuJoCoTest] PASS`.
8. Pulls `/sdcard/Android/data/com.lovemoon.operator/files/mujoco_lerobot`.
9. Validates JSONL rows, metadata, modalities, monotonic simulation steps, native backend status, physics metadata, and recorded contact counts.

Artifacts are written to:

```text
tests/logs/godot-mujoco-YYYYMMDD-HHMMSS/
```

The pulled episode contains:

- `metadata.json`
- `data.jsonl`
- `summary.json`

## Known Test Results

Previously verified on PICO `A9210`:

- Native MuJoCo loaded with version `3.3.2`.
- 60-second PICO E2E passed with roughly 1436-1437 frames.
- 600-second PICO E2E passed with 14383 frames and 72002 MuJoCo steps.
- Dataset validation passed for state/rgb/depth/segmentation/contact/force/action streams.

After adding explicit physics assertions, Quest and PICO MuJoCo APKs were rebuilt and static/package checks passed. The latest physics-assertion device E2E still needs a connected authorized headset to rerun.

## Developer Notes

### Do Not Use Desktop Runtime for XR Validation

Per repo policy, do not run the XR app in desktop Godot to validate runtime behavior. Building/exporting with `godot --headless` through the Makefile is fine; runtime validation must happen on an Android XR device.

### Android ADB Authorization

If a Quest/PICO device does not appear as `device` in `adb devices -l`, the E2E script cannot run. Common states:

- `unauthorized`: accept USB debugging prompt inside the headset.
- no device: reconnect cable, restart ADB, or check udev/USB permission.
- multiple devices: pass `--serial`, or use `PICO_SERIAL` and `QUEST_SERIAL`.

### Generated Files

Generated native libraries and capture plugin binaries should not be committed. Keep source files tracked, not build artifacts.

Important generated outputs include:

- `xr/addons/godot_mujoco/bin/*.so`
- `xr/native/godot_mujoco/build-*`
- `xr/android/build/libs/arm64-v8a/libgodot_mujoco.so`
- `xr/android/build/libs/arm64-v8a/libmujoco.so`
- `xr/addons/*/bin/*.aar`
- `xr/addons/*/bin/*.jar`

The `.gitkeep` files in addon `bin/` directories may remain tracked to preserve directory structure.

### Gradle Wrapper

Capture plugin builds use the checked-in Godot Android Gradle wrapper via `CAPTURE_GRADLE ?= ../android/build/gradlew`. This avoids depending on a globally installed `gradle` command.

## How to Extend

### Add More MuJoCo Physics Assertions

1. Add bodies/geoms/sensors to `xr/assets/mujoco/mobile_manipulator_smoke.xml` or a new MJCF.
2. Ensure the model does not depend on external mesh files unless export packaging is updated.
3. Add body names and expected movement/contact criteria to `xr/scenes/mujoco/mujoco_device_test.gd`.
4. Emit structured log lines if host-side scripts need to verify the new behavior.
5. Extend `tests/03_godot_mujoco_device.sh` to validate the new metadata or dataset fields.
6. Extend `tests/03_godot_mujoco_static.sh` to ensure the assets are packaged into both APKs.

### Add Native API Surface

1. Add the method declaration to `xr/native/godot_mujoco/src/mujoco_native.h`.
2. Bind it in `xr/native/godot_mujoco/src/mujoco_native.cpp` using `ClassDB::bind_method`.
3. Implement against `mjModel`/`mjData`.
4. Wrap it in `xr/addons/godot_mujoco/mj_simulation.gd` with a high-level Godot API.
5. Add a device-scene assertion or dataset validator check.
6. Rebuild `make build-mujoco-pico` and `make build-mujoco-quest`.

### Add Dataset Fields

1. Update `MjLeRobotRecorder.record_frame()` or `_metadata()`.
2. Update `MjDatasetValidator` if the field is required.
3. Update `tests/03_godot_mujoco_device.sh` host-side validation.
4. Verify pulled JSONL and metadata from a device run.

## Troubleshooting

### Native Backend Does Not Load

Check:

- APK contains `lib/arm64-v8a/libgodot_mujoco.so`.
- APK contains `lib/arm64-v8a/libmujoco.so`.
- `xr/addons/godot_mujoco/godot_mujoco.gdextension` has Android arm64 library and dependency entries.
- `MUJOCO_ANDROID_ROOT` points to the Android MuJoCo package at build time.
- Logcat includes either `[GodotMuJoCo] Native MuJoCo backend loaded` or an explicit load error.

### E2E Starts But Never Passes

Check the log artifact directory:

- `logcat-start-timeout.log`
- `logcat-timeout.log`
- `logcat-fail.log`
- `logcat.log`

Common causes:

- The app did not receive `operator.mode=mujoco`.
- Native backend failed to load and the scene quit with error.
- Physics assertions failed, usually visible in `[GodotMuJoCoTest] FAIL ... physics=...`.
- Device slept during a long run; the script enables stay-awake and periodic wake events, but headset power policy may still interfere.

### Static Check Fails After Asset Changes

Rebuild both MuJoCo APKs:

```bash
cd xr
make build-mujoco-quest
make build-mujoco-pico
```

Then rerun:

```bash
bash tests/03_godot_mujoco_static.sh
```

## Quick Command Reference

```bash
# Build MuJoCo APKs
cd xr && make build-mujoco-quest
cd xr && make build-mujoco-pico

# Static/package verification
bash tests/03_godot_mujoco_static.sh

# PICO physics E2E
bash tests/03_godot_mujoco_device.sh --device pico --skip-build --duration 20 --min-frames 300

# Quest physics E2E
bash tests/03_godot_mujoco_device.sh --device quest --skip-build --duration 20 --min-frames 300

# Revalidate a pulled dataset without device
bash tests/03_godot_mujoco_device.sh --skip-device --output-dir tests/logs/<existing-godot-mujoco-run>
```

## Files Most Likely To Change Next

- `xr/assets/mujoco/mobile_manipulator_smoke.xml` for richer physical scenarios.
- `xr/native/godot_mujoco/src/mujoco_native.cpp` for additional MuJoCo state/contact/sensor APIs.
- `xr/addons/godot_mujoco/mj_simulation.gd` for high-level API shape.
- `xr/scenes/mujoco/mujoco_device_test.gd` for device assertions.
- `tests/03_godot_mujoco_device.sh` for host-side E2E validation.
- `tests/03_godot_mujoco_static.sh` for package/static coverage.
