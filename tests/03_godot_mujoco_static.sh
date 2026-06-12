#!/usr/bin/env bash
# Static/package verification for RFC 003 Godot MuJoCo addon.

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
XR="$ROOT/xr"
APK_QUEST="$XR/build/quest/Operator.apk"
APK_PICO="$XR/build/pico/Operator.apk"
MUJOCO_DEVICE_TEST_GD="$ROOT/xr/scripts/app/modes/mujoco/mujoco_device_test.gd"

require_file() {
  [ -s "$ROOT/$1" ] || { echo "missing file: $1" >&2; exit 1; }
}

for path in \
  xr/addons/godot_mujoco/godot_mujoco.gdextension \
  xr/addons/godot_mujoco/mj_simulation.gd \
  xr/addons/godot_mujoco/mj_robot_importer.gd \
  xr/addons/godot_mujoco/mj_lerobot_recorder.gd \
  xr/addons/godot_mujoco/mj_dataset_validator.gd \
  xr/addons/godot_mujoco/mj_profiler.gd \
  xr/addons/godot_mujoco/mj_scenario.gd \
  xr/addons/godot_mujoco/mj_reset_policy.gd \
  xr/addons/godot_mujoco/mj_device_capability_profile.gd \
  xr/addons/godot_mujoco/mj_haptics_bridge.gd \
  xr/native/godot_mujoco/src/mujoco_native.cpp \
  xr/assets/mujoco/mobile_manipulator_smoke.xml \
  xr/assets/mujoco/so101_pickplace.xml \
  xr/assets/mujoco/so101_new_calib.urdf \
  xr/scripts/app/modes/mujoco/mujoco_device_test.gd \
  tests/03_godot_mujoco_device.sh; do
  require_file "$path"
done

bash -n "$ROOT/tests/03_godot_mujoco_device.sh"

grep -q 'mj_step(model, data)' "$ROOT/xr/native/godot_mujoco/src/mujoco_native.cpp"
grep -q 'mj_loadXML' "$ROOT/xr/native/godot_mujoco/src/mujoco_native.cpp"
grep -q 'require_native_backend = true' "$MUJOCO_DEVICE_TEST_GD"
grep -q 'MjDatasetValidator.validate_episode' "$MUJOCO_DEVICE_TEST_GD"
grep -q 'MjResetPolicy.apply' "$MUJOCO_DEVICE_TEST_GD"
grep -q 'MjDeviceCapabilityProfile.collect' "$MUJOCO_DEVICE_TEST_GD"
grep -q 'PHYSICS_PASS' "$MUJOCO_DEVICE_TEST_GD"
grep -q 'falling_box' "$ROOT/xr/assets/mujoco/mobile_manipulator_smoke.xml"
grep -q 'ramp_ball' "$ROOT/xr/assets/mujoco/mobile_manipulator_smoke.xml"
grep -q 'inclined_ramp' "$ROOT/xr/assets/mujoco/mobile_manipulator_smoke.xml"

check_apk() {
  local apk="$1"
  local listing
  [ -s "$apk" ] || { echo "missing APK: $apk" >&2; exit 1; }
  listing="$(unzip -Z1 "$apk")"
  grep -q 'lib/arm64-v8a/libgodot_mujoco.so' <<<"$listing"
  grep -q 'lib/arm64-v8a/libmujoco.so' <<<"$listing"
  grep -q 'assets/assets/mujoco/mobile_manipulator_smoke.xml' <<<"$listing"
  grep -q 'assets/addons/godot_mujoco/mj_dataset_validator.gdc' <<<"$listing"
  grep -q 'assets/addons/godot_mujoco/mj_profiler.gdc' <<<"$listing"
  grep -q 'assets/scripts/app/modes/mujoco/mujoco_device_test.gdc' <<<"$listing"
  unzip -p "$apk" assets/assets/mujoco/mobile_manipulator_smoke.xml | grep -q 'falling_box'
  unzip -p "$apk" assets/assets/mujoco/mobile_manipulator_smoke.xml | grep -q 'ramp_ball'
  unzip -p "$apk" assets/assets/mujoco/mobile_manipulator_smoke.xml | grep -q 'inclined_ramp'
}

check_apk "$APK_QUEST"
check_apk "$APK_PICO"

echo "Godot MuJoCo static/package checks passed"
