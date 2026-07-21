#!/usr/bin/env bash
# Record and validate Pico Ego video at every supported per-eye resolution.
#
# The test installs one Pico APK, launches one short RGB-only recording per
# resolution, and checks the finalized side-by-side MP4 dimensions with
# ffprobe. Device output is isolated under OperatorResolutionTests; the
# operator's normal SpatialMP4 directories and persisted app settings are
# never cleared.
#
# Usage:
#   bash cicd/05_pico_ego_resolution_matrix.sh --serial <pico-serial>
#   bash cicd/05_pico_ego_resolution_matrix.sh --resolutions 1920x1920,1280x1280
#   bash cicd/05_pico_ego_resolution_matrix.sh --skip-build --skip-install

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
XR_DIR="$ROOT/xr"
PKG="com.lovemoon.operator"
ACT="com.godot.game.GodotApp"
APK_PATH="$XR_DIR/build/pico/Operator.apk"

ADB="${ADB:-adb}"
FFPROBE="${FFPROBE:-ffprobe}"
MAKE="${MAKE:-make}"
SERIAL="${PICO_SERIAL:-${ADB_SERIAL:-}}"
CAPTURE_SECONDS="${CAPTURE_SECONDS:-8}"
RESOLUTION_CSV="${RESOLUTIONS:-}"
RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT/cicd/results/pico-ego-resolution-$RUN_ID}"
REMOTE_RUN_ROOT="${DEVICE_ROOT:-/sdcard/DCIM/OperatorResolutionTests/$RUN_ID}"
SKIP_BUILD="${SKIP_BUILD:-0}"
SKIP_INSTALL="${SKIP_INSTALL:-0}"
KEEP_INSTALLED_APK="${KEEP_INSTALLED_APK:-0}"
KEEP_DEVICE_ARTIFACTS="${KEEP_DEVICE_ARTIFACTS:-0}"

DEVICE_MUTATED=0
ORIGINAL_INSTALLED=0
REMOTE_ROOT_CREATED=0
ORIGINAL_APK="$OUTPUT_DIR/Operator-before-test.apk"

log() { echo "[pico-resolution] $*"; }
fail() { echo "[pico-resolution] ERROR: $*" >&2; exit 1; }

usage() {
  sed -n '2,13s/^# \{0,1\}//p' "${BASH_SOURCE[0]}"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --serial) SERIAL="$2"; shift 2 ;;
    --capture-seconds) CAPTURE_SECONDS="$2"; shift 2 ;;
    --resolutions) RESOLUTION_CSV="$2"; shift 2 ;;
    --output-dir) OUTPUT_DIR="$2"; ORIGINAL_APK="$OUTPUT_DIR/Operator-before-test.apk"; shift 2 ;;
    --device-root) REMOTE_RUN_ROOT="$2"; shift 2 ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --skip-install) SKIP_INSTALL=1; shift ;;
    --keep-installed-apk) KEEP_INSTALLED_APK=1; shift ;;
    --keep-device-artifacts) KEEP_DEVICE_ARTIFACTS=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

case "$OUTPUT_DIR" in
  /*) ;;
  *) OUTPUT_DIR="$ROOT/$OUTPUT_DIR"; ORIGINAL_APK="$OUTPUT_DIR/Operator-before-test.apk" ;;
esac

run_adb() {
  "$ADB" -s "$SERIAL" "$@"
}

stop_app_and_wait() {
  local deadline=$(( $(date +%s) + 10 ))
  # Some PICO runtimes retain the immersive task after the Linux process has
  # exited and return START_TASK_TO_FRONT for the next intent, dropping its
  # new automation extras. Move Home first so the spatial container detaches.
  run_adb shell input keyevent KEYCODE_HOME >/dev/null 2>&1 || true
  sleep 0.5
  run_adb shell am force-stop "$PKG" >/dev/null 2>&1 || true
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if [ -z "$(run_adb shell pidof "$PKG" 2>/dev/null | tr -d '\r')" ]; then
      sleep 0.5
      return 0
    fi
    sleep 0.25
  done
  fail "timed out waiting for $PKG to stop"
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required tool: $1"
}

is_supported_resolution() {
  [[ "$1" =~ ^[1-9][0-9]*x[1-9][0-9]*$ ]]
}

device_looks_like_pico() {
  local serial="$1"
  local identity=""
  local attempt
  # ADB can transiently return an empty property response while two USB XR
  # devices are active. Retry the generic manufacturer/brand probe; never
  # fall back to a model, product codename, or serial allowlist.
  for attempt in 1 2 3; do
    identity="$("$ADB" -s "$serial" shell 'getprop ro.product.manufacturer; getprop ro.product.brand' 2>/dev/null | tr '\r\n' ' ')"
    case "$(printf '%s' "$identity" | tr '[:upper:]' '[:lower:]')" in
      *pico*|*picovr*) return 0 ;;
    esac
    sleep 0.25
  done
  return 1
}

pick_pico_device() {
  if [ -n "$SERIAL" ]; then
    device_looks_like_pico "$SERIAL" || fail "device $SERIAL does not look like a Pico"
    return
  fi
  local matches=()
  local candidate
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    if device_looks_like_pico "$candidate"; then
      matches+=("$candidate")
    fi
  done < <("$ADB" devices | awk 'NR > 1 && $2 == "device" {print $1}')
  [ "${#matches[@]}" -eq 1 ] || fail "expected one connected Pico; pass --serial explicitly"
  SERIAL="${matches[0]}"
}

restore_device() {
  local rc=$?
  trap - EXIT INT TERM
  if [ -n "$SERIAL" ]; then
    run_adb shell am force-stop "$PKG" >/dev/null 2>&1 || true
    if [ "$REMOTE_ROOT_CREATED" = "1" ] && [ "$KEEP_DEVICE_ARTIFACTS" != "1" ]; then
      case "$REMOTE_RUN_ROOT" in
        /sdcard/DCIM/OperatorResolutionTests/*|/sdcard/Movies/OperatorResolutionTests/*)
          run_adb shell rm -rf "$REMOTE_RUN_ROOT" >/dev/null 2>&1 || true
          ;;
        *)
          log "leaving non-standard device root untouched: $REMOTE_RUN_ROOT"
          ;;
      esac
    fi
    if [ "$DEVICE_MUTATED" = "1" ] && [ "$KEEP_INSTALLED_APK" != "1" ]; then
      if [ "$ORIGINAL_INSTALLED" = "1" ] && [ -f "$ORIGINAL_APK" ]; then
        log "restoring APK that was installed before the test"
        run_adb install -r -d "$ORIGINAL_APK" > "$OUTPUT_DIR/adb-restore.log" 2>&1 || {
          log "APK restore failed; see $OUTPUT_DIR/adb-restore.log"
          rc=1
        }
      elif [ "$ORIGINAL_INSTALLED" = "0" ]; then
        run_adb uninstall "$PKG" >/dev/null 2>&1 || true
      fi
    fi
  fi
  if [ "$rc" -ne 0 ]; then
    log "test failed; artifacts kept in $OUTPUT_DIR"
  fi
  exit "$rc"
}
trap restore_device EXIT INT TERM

backup_installed_apk() {
  local package_paths
  local base_path
  package_paths="$(run_adb shell pm path "$PKG" 2>/dev/null | tr -d '\r' || true)"
  if [ -z "$package_paths" ]; then
    ORIGINAL_INSTALLED=0
    return
  fi
  ORIGINAL_INSTALLED=1
  base_path="$(printf '%s\n' "$package_paths" | sed -n 's/^package://p' | head -n1)"
  [ -n "$base_path" ] || fail "could not resolve installed APK path for $PKG"
  run_adb pull "$base_path" "$ORIGINAL_APK" > "$OUTPUT_DIR/adb-backup.log"
  [ -s "$ORIGINAL_APK" ] || fail "installed APK backup is empty"
  log "backed up the currently installed APK"
}

wait_for_log_marker() {
  local marker="$1"
  local timeout="$2"
  local log_path="$3"
  local deadline=$(( $(date +%s) + timeout ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    run_adb logcat -d -v threadtime > "$log_path" 2>&1 || true
    if grep -Fq "$marker" "$log_path"; then
      return 0
    fi
    sleep 0.5
  done
  return 1
}

wait_for_app_exit() {
  local timeout="$1"
  local deadline=$(( $(date +%s) + timeout ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if [ -z "$(run_adb shell pidof "$PKG" 2>/dev/null | tr -d '\r')" ]; then
      return 0
    fi
    sleep 0.25
  done
  return 1
}

probe_runtime_resolutions() {
  local log_path="$OUTPUT_DIR/runtime-capabilities.log"
  local json_path="$OUTPUT_DIR/runtime-capabilities.json"
  local marker="PICO RGB runtime capabilities: "
  local line

  log "probing XR_PICO_camera_image runtime capabilities" >&2
  stop_app_and_wait
  run_adb logcat -c >/dev/null 2>&1 || true
  run_adb shell am start -S --activity-clear-task --activity-multiple-task -n "$PKG/$ACT" \
    --es operator.mode ego_capture \
    --es operator.capture.interaction_mode head \
    --es operator.capture.capability_probe true >/dev/null
  if ! wait_for_log_marker "$marker" 45 "$log_path"; then
    fail "runtime camera capability probe did not complete; see $log_path"
  fi
  line="$(grep -F "$marker" "$log_path" | tail -n1)"
  printf '%s\n' "${line#*"$marker"}" > "$json_path"
  wait_for_log_marker "PICO RGB capability probe complete; quitting" 5 "$log_path" || true
  if ! wait_for_app_exit 10; then
    stop_app_and_wait
  fi
  python3 - "$json_path" <<'PY'
import json
import sys

doc = json.load(open(sys.argv[1], encoding="utf-8"))
entries = doc.get("stereo_resolutions") or []
values = []
for entry in entries:
    width = int(entry.get("width", 0))
    height = int(entry.get("height", 0))
    if width > 0 and height > 0:
        values.append(f"{width}x{height}")
if not values:
    raise SystemExit("runtime reported no stereo RGB resolutions")
print(",".join(values))
PY
}

record_and_validate() {
  local resolution="$1"
  local width="${resolution%x*}"
  local height="${resolution#*x}"
  local expected_width=$((width * 2))
  local expected_video="${expected_width}x${height}"
  local remote_root="$REMOTE_RUN_ROOT/$resolution"
  local log_path="$OUTPUT_DIR/$resolution.log"
  local remote_mp4
  local local_mp4="$OUTPUT_DIR/$resolution.mp4"
  local actual_video
  local crash_log="$OUTPUT_DIR/$resolution-crash.log"

  log "recording $resolution per eye; expecting $expected_video side-by-side"
  stop_app_and_wait
  run_adb shell mkdir -p "$remote_root"
  run_adb logcat -c >/dev/null 2>&1 || true
  run_adb shell am start -S --activity-clear-task --activity-multiple-task -n "$PKG/$ACT" \
    --es operator.mode ego_capture \
    --es operator.capture.interaction_mode head \
    --es operator.capture.export_coordinate_space LOCAL \
    --es operator.capture.auto_start true \
    --es operator.capture.auto_stop_seconds "$CAPTURE_SECONDS" \
    --es operator.capture.rgb_resolution "$resolution" \
    --es operator.capture.save_root "$remote_root" \
    --es operator.capture.rgb_only true >/dev/null

  if ! wait_for_log_marker "Capture session started:" 45 "$log_path"; then
    fail "$resolution did not start recording; see $log_path"
  fi
  cp "$log_path" "$OUTPUT_DIR/$resolution-start.log"
  if ! wait_for_log_marker "Capture session stopped:" "$((CAPTURE_SECONDS + 60))" "$log_path"; then
    fail "$resolution did not finalize; see $log_path"
  fi
  # Finalization is complete at the stop marker. Stop the process before the
  # automation timer's delayed app quit so the next resolution starts cleanly.
  stop_app_and_wait
  run_adb logcat -d -v threadtime > "$log_path" 2>&1 || true
  run_adb logcat -b crash -d > "$crash_log" 2>&1 || true
  if grep -Fq "Cmdline: $PKG" "$crash_log"; then
    fail "$resolution app process crashed; see $crash_log"
  fi

  remote_mp4="$(sed -n 's/.*Capture session stopped: //p' "$log_path" | tail -n1 | tr -d '\r')"
  [ -n "$remote_mp4" ] || fail "$resolution stop marker did not contain an MP4 path"
  case "$remote_mp4" in
    "$remote_root"/*.mp4) ;;
    *) fail "$resolution finalized outside its isolated root: $remote_mp4" ;;
  esac
  run_adb pull "$remote_mp4" "$local_mp4" > "$OUTPUT_DIR/$resolution-pull.log"
  [ "$(wc -c < "$local_mp4" | tr -d ' ')" -gt 100000 ] || fail "$resolution MP4 is unexpectedly small"

  actual_video="$("$FFPROBE" -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0:s=x "$local_mp4" | head -n1 | tr -d '\r')"
  [ "$actual_video" = "$expected_video" ] || fail "$resolution encoded $actual_video, expected $expected_video"
  printf '%s\t%s\t%s\n' "$resolution" "$actual_video" "$local_mp4" >> "$OUTPUT_DIR/results.tsv"
  log "passed $resolution -> $actual_video"
}

require_tool "$ADB"
require_tool "$FFPROBE"
require_tool "$MAKE"
case "$CAPTURE_SECONDS" in
  ''|*[!0-9]*) fail "--capture-seconds must be a positive integer" ;;
esac
[ "$CAPTURE_SECONDS" -gt 0 ] || fail "--capture-seconds must be greater than zero"

pick_pico_device
mkdir -p "$OUTPUT_DIR"
printf 'per_eye\tencoded_video\tlocal_mp4\n' > "$OUTPUT_DIR/results.tsv"
log "using Pico $SERIAL"

if [ "$SKIP_BUILD" != "1" ]; then
  log "building Pico APK once for the full matrix"
  (cd "$XR_DIR" && "$MAKE" build-pico) > "$OUTPUT_DIR/build.log" 2>&1 || fail "Pico build failed; see $OUTPUT_DIR/build.log"
fi
[ -f "$APK_PATH" ] || fail "Pico APK not found: $APK_PATH"

if [ "$SKIP_INSTALL" != "1" ]; then
  backup_installed_apk
  log "installing test APK without clearing app data"
  run_adb install -r -d "$APK_PATH" > "$OUTPUT_DIR/adb-install.log" 2>&1 || fail "APK install failed; see $OUTPUT_DIR/adb-install.log"
  DEVICE_MUTATED=1
fi

run_adb shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
run_adb shell wm dismiss-keyguard >/dev/null 2>&1 || true
run_adb shell pm grant "$PKG" android.permission.CAMERA >/dev/null 2>&1 || true
run_adb shell appops set "$PKG" MANAGE_EXTERNAL_STORAGE allow >/dev/null 2>&1 || true
if [ -z "$RESOLUTION_CSV" ]; then
  RESOLUTION_CSV="$(probe_runtime_resolutions)"
fi
IFS=',' read -r -a RESOLUTION_LIST <<< "$RESOLUTION_CSV"
[ "${#RESOLUTION_LIST[@]}" -gt 0 ] || fail "runtime reported no resolutions"
for resolution in "${RESOLUTION_LIST[@]}"; do
  is_supported_resolution "$resolution" || fail "invalid resolution: $resolution"
done
log "runtime resolution matrix: $RESOLUTION_CSV"
if run_adb shell ls -d "$REMOTE_RUN_ROOT" >/dev/null 2>&1; then
  fail "refusing to reuse existing device output root: $REMOTE_RUN_ROOT"
fi
run_adb shell mkdir -p "$REMOTE_RUN_ROOT"
REMOTE_ROOT_CREATED=1

for resolution in "${RESOLUTION_LIST[@]}"; do
  record_and_validate "$resolution"
done

log "all ${#RESOLUTION_LIST[@]} resolution recordings passed"
log "results: $OUTPUT_DIR/results.tsv"
