#!/usr/bin/env bash
# Device end-to-end smoke test for RFC 003 Godot MuJoCo addon.
#
# Builds and installs the XR APK, launches Operator in mujoco automation mode,
# waits for the in-headset simulation/record/replay validator to pass, then
# pulls the LeRobot-compatible proxy episode written on-device.
#
# Usage:
#   bash tests/03_godot_mujoco_device.sh                 # auto-detect Quest/PICO
#   bash tests/03_godot_mujoco_device.sh --device quest
#   bash tests/03_godot_mujoco_device.sh --device pico --duration 600
#   bash tests/03_godot_mujoco_device.sh --device both
#   bash tests/03_godot_mujoco_device.sh --skip-device --output-dir tests/logs/godot-mujoco-...
#   SKIP_BUILD=1 SKIP_INSTALL=1 bash tests/03_godot_mujoco_device.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
XR_DIR="$ROOT/xr"
PKG="com.lovemoon.operator"
ACT="com.godot.game.GodotApp"
ADB="${ADB:-adb}"
MAKE="${MAKE:-make}"
DEVICE_KIND="${DEVICE_KIND:-auto}"
ADB_SERIAL_OVERRIDE="${ADB_SERIAL:-}"
PICO_SERIAL="${PICO_SERIAL:-}"
QUEST_SERIAL="${QUEST_SERIAL:-}"
DURATION="${MUJOCO_DURATION:-600}"
MIN_FRAMES="${MUJOCO_MIN_FRAMES:-0}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT/tests/logs/godot-mujoco-$(date +%Y%m%d-%H%M%S)}"
SKIP_BUILD="${SKIP_BUILD:-0}"
SKIP_INSTALL="${SKIP_INSTALL:-0}"
SKIP_DEVICE="${SKIP_DEVICE:-0}"
CLEAR_APP_DATA="${CLEAR_APP_DATA:-1}"
START_TIMEOUT_SECONDS="${START_TIMEOUT_SECONDS:-45}"
RUN_TIMEOUT_SECONDS="${RUN_TIMEOUT_SECONDS:-180}"
KEEP_DEVICE_AWAKE="${KEEP_DEVICE_AWAKE:-1}"
WAKE_INTERVAL_SECONDS="${WAKE_INTERVAL_SECONDS:-20}"
SERIAL=""
APK_PATH=""
MAKE_TARGET=""
EXPECTED_MANUFACTURER=""
REMOTE_DATASET_ROOT="/sdcard/Android/data/$PKG/files/mujoco_lerobot"

if [ -t 1 ]; then
  BOLD="$(tput bold)"; GREEN="$(tput setaf 2)"; RED="$(tput setaf 1)"
  YELLOW="$(tput setaf 3)"; BLUE="$(tput setaf 4)"; DIM="$(tput dim)"; RESET="$(tput sgr0)"
else
  BOLD=""; GREEN=""; RED=""; YELLOW=""; BLUE=""; DIM=""; RESET=""
fi
step() { echo; echo "${BOLD}${BLUE}▶ $*${RESET}"; }
ok() { echo "  ${GREEN}✓${RESET} $*"; }
warn() { echo "  ${YELLOW}!${RESET} $*"; }
err() { echo "  ${RED}✗${RESET} $*" >&2; }
note() { echo "  ${DIM}$*${RESET}"; }

usage() {
  sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
  exit "${1:-0}"
}

while (("$#")); do
  case "$1" in
    --device) DEVICE_KIND="$2"; shift 2 ;;
    --duration) DURATION="$2"; shift 2 ;;
    --min-frames) MIN_FRAMES="$2"; shift 2 ;;
    --serial) ADB_SERIAL_OVERRIDE="$2"; shift 2 ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --skip-install) SKIP_INSTALL=1; shift ;;
    --skip-device) SKIP_DEVICE=1; shift ;;
    --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
    -h|--help) usage 0 ;;
    *) err "unknown arg: $1"; usage 1 ;;
  esac
done

if [ "$DEVICE_KIND" = "both" ]; then
  if [ -n "$ADB_SERIAL_OVERRIDE" ]; then
    err "--device both cannot use a single --serial/ADB_SERIAL; set PICO_SERIAL and QUEST_SERIAL instead"
    exit 1
  fi
  for kind in quest pico; do
    subdir="$OUTPUT_DIR/$kind"
    echo
    echo "▶ Running Godot MuJoCo E2E on $kind"
    DEVICE_KIND="$kind" OUTPUT_DIR="$subdir" MUJOCO_DURATION="$DURATION" MUJOCO_MIN_FRAMES="$MIN_FRAMES" \
      SKIP_BUILD="$SKIP_BUILD" SKIP_INSTALL="$SKIP_INSTALL" SKIP_DEVICE="$SKIP_DEVICE" CLEAR_APP_DATA="$CLEAR_APP_DATA" \
      ADB_SERIAL="" PICO_SERIAL="$PICO_SERIAL" QUEST_SERIAL="$QUEST_SERIAL" \
      "$0"
  done
  exit 0
fi

if [ "$MIN_FRAMES" = "0" ]; then
  MIN_FRAMES="$(awk -v duration="$DURATION" 'BEGIN { printf "%d", duration * 20 }')"
fi

configure_device_kind() {
  case "$DEVICE_KIND" in
    quest) APK_PATH="$XR_DIR/build/quest/Operator.apk"; MAKE_TARGET="build-mujoco-quest"; EXPECTED_MANUFACTURER="meta|oculus" ;;
    pico) APK_PATH="$XR_DIR/build/pico/Operator.apk"; MAKE_TARGET="build-mujoco-pico"; EXPECTED_MANUFACTURER="pico" ;;
    auto) err "internal error: DEVICE_KIND=auto must be resolved before configure_device_kind"; exit 1 ;;
    *) err "unsupported --device: $DEVICE_KIND"; exit 1 ;;
  esac
}

run_adb() {
  "$ADB" -s "$SERIAL" "$@"
}

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    err "missing tool: $1"
    exit 1
  fi
}

verify_device_kind() {
  local manufacturer model
  manufacturer="$(run_adb shell getprop ro.product.manufacturer 2>/dev/null | tr -d '\r' | tr '[:upper:]' '[:lower:]')"
  model="$(run_adb shell getprop ro.product.model 2>/dev/null | tr -d '\r')"
  note "device manufacturer=$manufacturer model=$model"
  if [ -n "$EXPECTED_MANUFACTURER" ] && ! printf '%s\n' "$manufacturer" | grep -Eq "$EXPECTED_MANUFACTURER"; then
    err "attached device does not look like --device $DEVICE_KIND (manufacturer=$manufacturer model=$model)"
    exit 1
  fi
}

detect_device_kind() {
  local manufacturer model
  manufacturer="$(run_adb shell getprop ro.product.manufacturer 2>/dev/null | tr -d '\r' | tr '[:upper:]' '[:lower:]')"
  model="$(run_adb shell getprop ro.product.model 2>/dev/null | tr -d '\r' | tr '[:upper:]' '[:lower:]')"
  if printf '%s\n' "$manufacturer" | grep -Eq 'pico|picovr'; then
    DEVICE_KIND="pico"
  elif printf '%s\n%s\n' "$manufacturer" "$model" | grep -Eq 'meta|oculus|quest'; then
    DEVICE_KIND="quest"
  else
    err "cannot auto-detect device kind from manufacturer=$manufacturer model=$model; pass --device quest|pico"
    exit 1
  fi
  ok "auto-detected device kind: $DEVICE_KIND"
}

list_devices() {
  "$ADB" devices | awk 'NR>1 && $2=="device"{print $1}'
}

device_matches_kind() {
  local serial="$1"
  local kind="$2"
  local manufacturer model haystack
  manufacturer="$("$ADB" -s "$serial" shell getprop ro.product.manufacturer 2>/dev/null | tr -d '\r' | tr '[:upper:]' '[:lower:]')"
  model="$("$ADB" -s "$serial" shell getprop ro.product.model 2>/dev/null | tr -d '\r' | tr '[:upper:]' '[:lower:]')"
  haystack="${manufacturer}
${model}"
  case "$kind" in
    pico) printf '%s\n' "$manufacturer" | grep -Eq 'pico|picovr' ;;
    quest) printf '%s\n' "$haystack" | grep -Eq 'meta|oculus|quest' ;;
    *) return 1 ;;
  esac
}

pick_device() {
  if [ -n "$ADB_SERIAL_OVERRIDE" ]; then
    echo "$ADB_SERIAL_OVERRIDE"
    return
  fi
  if [ "$DEVICE_KIND" = "pico" ] && [ -n "$PICO_SERIAL" ]; then
    echo "$PICO_SERIAL"
    return
  fi
  if [ "$DEVICE_KIND" = "quest" ] && [ -n "$QUEST_SERIAL" ]; then
    echo "$QUEST_SERIAL"
    return
  fi
  if [ "$DEVICE_KIND" = "pico" ] || [ "$DEVICE_KIND" = "quest" ]; then
    local device
    while IFS= read -r device; do
      if device_matches_kind "$device" "$DEVICE_KIND"; then
        echo "$device"
        return
      fi
    done < <(list_devices)
    return
  fi
  list_devices | head -1
}

build_apk() {
  step "Build $DEVICE_KIND APK"
  (cd "$XR_DIR" && "$MAKE" "$MAKE_TARGET")
  [ -f "$APK_PATH" ] || { err "missing APK: $APK_PATH"; exit 2; }
  ok "built $APK_PATH"
}

install_apk() {
  step "Install APK"
  run_adb install -r "$APK_PATH" >/dev/null
  ok "installed $PKG"
}

prepare_device() {
  step "Prepare device"
  run_adb logcat -c || true
  run_adb shell am force-stop "$PKG" >/dev/null 2>&1 || true
  if [ "$KEEP_DEVICE_AWAKE" = "1" ]; then
    run_adb shell svc power stayon true >/dev/null 2>&1 || true
    wake_device || true
  fi
  if [ "$CLEAR_APP_DATA" = "1" ]; then
    run_adb shell pm clear "$PKG" >/dev/null 2>&1 || true
    ok "cleared app data"
  fi
  run_adb shell rm -rf "$REMOTE_DATASET_ROOT" >/dev/null 2>&1 || true
  ok "cleared previous MuJoCo dataset"
}

wake_device() {
  local state
  state="$(run_adb shell dumpsys power 2>/dev/null | grep -m1 -E 'mWakefulness|Display Power' | tr -d '\r' || true)"
  if ! printf '%s\n' "$state" | grep -Eq 'Awake|ON'; then
    run_adb shell input keyevent 26 >/dev/null 2>&1 || true
    sleep 1
  fi
  run_adb shell input keyevent 224 >/dev/null 2>&1 || true
  run_adb shell am broadcast -a com.oculus.vrpowermanager.prox_close >/dev/null 2>&1 || true
}

launch_app() {
  step "Launch MuJoCo automation mode"
  run_adb shell am start -n "$PKG/$ACT" --es operator.mode mujoco --es mujoco.duration "$DURATION" --es mujoco.min.frames "$MIN_FRAMES" >/dev/null
  ok "launch requested"
}

logcat_dump() {
  run_adb logcat -d -v time 2>/dev/null || true
}

wait_for_start() {
  step "Wait for MuJoCo start"
  local deadline line
  deadline=$(($(date +%s) + START_TIMEOUT_SECONDS))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    line="$(logcat_dump | grep -F "[GodotMuJoCoTest] started" | tail -n1 || true)"
    if [ -n "$line" ]; then
      ok "$line"
      return
    fi
    sleep 1
  done
  err "timed out waiting for MuJoCo test start"
  logcat_dump > "$OUTPUT_DIR/logcat-start-timeout.log"
  exit 3
}

wait_for_pass() {
  step "Wait for MuJoCo PASS"
  local deadline logs pass physics_pass fail now last_wake
  deadline=$(($(date +%s) + RUN_TIMEOUT_SECONDS + DURATION))
  last_wake=0
  while [ "$(date +%s)" -lt "$deadline" ]; do
    now=$(date +%s)
    if [ "$KEEP_DEVICE_AWAKE" = "1" ] && [ $((now - last_wake)) -ge "$WAKE_INTERVAL_SECONDS" ]; then
      wake_device || true
      last_wake=$now
    fi
    logs="$(logcat_dump)"
    pass="$(printf '%s\n' "$logs" | grep -F "[GodotMuJoCoTest] PASS" | tail -n1 || true)"
    physics_pass="$(printf '%s\n' "$logs" | grep -F "[GodotMuJoCoTest] PHYSICS_PASS" | tail -n1 || true)"
    fail="$(printf '%s\n' "$logs" | grep -F "[GodotMuJoCoTest] FAIL" | tail -n1 || true)"
    if [ -n "$pass" ] && [ -n "$physics_pass" ]; then
      ok "$physics_pass"
      ok "$pass"
      return
    fi
    if [ -n "$fail" ]; then
      err "$fail"
      printf '%s\n' "$logs" > "$OUTPUT_DIR/logcat-fail.log"
      exit 4
    fi
    sleep 1
  done
  err "timed out waiting for MuJoCo PASS"
  logcat_dump > "$OUTPUT_DIR/logcat-timeout.log"
  exit 3
}

pull_and_validate() {
  step "Pull and validate dataset"
  mkdir -p "$OUTPUT_DIR/session"
  if [ "$SKIP_DEVICE" != "1" ]; then
    logcat_dump > "$OUTPUT_DIR/logcat.log"
    run_adb pull "$REMOTE_DATASET_ROOT" "$OUTPUT_DIR/session/" > "$OUTPUT_DIR/adb-pull.log" 2>&1 || {
      err "failed to pull $REMOTE_DATASET_ROOT"
      cat "$OUTPUT_DIR/adb-pull.log" >&2 || true
      exit 5
    }
  fi
  python3 - "$OUTPUT_DIR/session/mujoco_lerobot" "$MIN_FRAMES" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
min_frames = int(sys.argv[2])
episodes = sorted(root.glob('episode_*'))
if not episodes:
    raise SystemExit('no episode_* directories found')
episode = episodes[-1]
data = episode / 'data.jsonl'
metadata = episode / 'metadata.json'
summary = episode / 'summary.json'
if not data.exists() or not metadata.exists() or not summary.exists():
    raise SystemExit(f'missing episode files in {episode}')
rows = []
with data.open() as f:
    for line in f:
        line = line.strip()
        if line:
            rows.append(json.loads(line))
if len(rows) < min_frames:
    raise SystemExit(f'only {len(rows)} frames, expected >= {min_frames}')
required = {'state', 'rgb', 'depth', 'segmentation', 'contact', 'force'}
missing = [k for k in required if k not in rows[-1].get('observation', {})]
if missing:
    raise SystemExit(f'missing observation keys: {missing}')
if 'action' not in rows[-1]:
    raise SystemExit('missing action')
metadata_doc = json.loads(metadata.read_text())
if 'native_status' in metadata_doc and not metadata_doc['native_status'].get('loaded', False):
    raise SystemExit('native_status exists but is not loaded')
if metadata_doc.get('schema_version') != 'operator.mujoco.lerobot.v1':
    raise SystemExit(f'unexpected schema_version: {metadata_doc.get("schema_version")}')
if not {'state', 'rgb', 'depth', 'segmentation', 'contact', 'force', 'action'}.issubset(set(metadata_doc.get('modalities', []))):
    raise SystemExit('metadata modalities do not cover required streams')
physics_scene = metadata_doc.get('physics_scene')
if not isinstance(physics_scene, dict):
    raise SystemExit('missing physics_scene metadata')
dynamic_bodies = set(physics_scene.get('dynamic_bodies', []))
if not {'falling_box', 'ramp_ball', 'red_cube'}.issubset(dynamic_bodies):
    raise SystemExit(f'physics_scene dynamic_bodies incomplete: {sorted(dynamic_bodies)}')
physics_initial = metadata_doc.get('physics_initial')
if not isinstance(physics_initial, dict) or 'falling_box' not in physics_initial or 'ramp_ball' not in physics_initial:
    raise SystemExit('missing physics_initial body positions')
summary_doc = json.loads(summary.read_text())
if int(summary_doc.get('frames', -1)) != len(rows):
    raise SystemExit(f'summary.frames={summary_doc.get("frames")} but rows={len(rows)}')
steps = [int(row.get('simulation', {}).get('step_index', -1)) for row in rows]
if any(b < a for a, b in zip(steps, steps[1:])):
    raise SystemExit('simulation steps moved backwards')
contact_counts = []
for row in rows:
    contact = row.get('observation', {}).get('contact', {})
    if isinstance(contact, dict):
        contact_counts.append(int(contact.get('count', 0)))
if not contact_counts or max(contact_counts) <= 0:
    raise SystemExit('no MuJoCo contact events observed in recorded frames')
print(f'validated {episode} frames={len(rows)}')
PY
  ok "dataset validated in $OUTPUT_DIR/session/mujoco_lerobot"
}

main() {
  mkdir -p "$OUTPUT_DIR"
  step "Pre-flight"
  require_tool "$ADB"
  require_tool "$MAKE"
  require_tool python3
  if [ "$SKIP_DEVICE" = "1" ]; then
    ok "SKIP_DEVICE=1; validating existing pulled dataset"
    pull_and_validate
    ok "CI PASSED"
    return 0
  fi
  SERIAL="$(pick_device)"
  [ -n "$SERIAL" ] || { err "no adb device attached"; exit 1; }
  ok "adb device: $SERIAL"
  if [ "$DEVICE_KIND" = "auto" ]; then
    detect_device_kind
  fi
  configure_device_kind
  verify_device_kind
  if [ "$SKIP_BUILD" != "1" ]; then
    build_apk
  else
    warn "SKIP_BUILD=1; using $APK_PATH"
  fi
  if [ "$SKIP_INSTALL" != "1" ]; then
    install_apk
  else
    warn "SKIP_INSTALL=1; assuming $PKG is already installed"
  fi
  prepare_device
  launch_app
  wait_for_start
  wait_for_pass
  pull_and_validate
  run_adb shell am force-stop "$PKG" >/dev/null 2>&1 || true
  step "Summary"
  note "artifacts: $OUTPUT_DIR"
  ok "CI PASSED"
}

main "$@"
