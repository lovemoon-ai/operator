#!/usr/bin/env bash
# End-to-end ego data recording CI for the Quest build.
#
# The script builds a temporary CI APK with capture_app.gd's device-test
# auto-start harness enabled, installs it on the attached headset, launches
# the app in ego mode, waits for a recording to finalize, pulls the captured
# SpatialMP4 session, and validates both sidecar data and the final MP4.
#
# Usage:
#   bash tests/02_ego_record.sh
#   bash tests/02_ego_record.sh --device pico
#   bash tests/02_ego_record.sh --skip-build --skip-install
#   bash tests/02_ego_record.sh --capture-seconds 15 --serial <adb-serial>
#   bash tests/02_ego_record.sh --skip-device --output-dir tests/logs/ego-record-...
#
# Flags:
#   --device quest|pico   target headset family; selects `make build-<kind>`,
#                         the matching APK output path, and the expected
#                         device_type prefix in manifest.json (default quest).
#
# Environment overrides:
#   DEVICE_KIND         same as --device; quest or pico (default quest).
#   QUEST_SERIAL        adb serial to use; defaults to the first attached device.
#   CAPTURE_SECONDS     recording duration baked into the CI APK (default 12).
#   OUTPUT_DIR          artifact directory (default tests/logs/ego-record-<stamp>).
#   SKIP_BUILD=1        use the existing xr/build/<kind>/Operator.apk.
#   SKIP_INSTALL=1      assume the correct APK is already installed.
#   SKIP_DEVICE=1       validate existing OUTPUT_DIR/session/SpatialMP4 only.
#   KEEP_CI_APK=1       do not reinstall the clean APK after the run.
#   CLEAR_APP_DATA=0    preserve app settings before launch (default clears).
#   ADB, PYTHON, FFPROBE, MAKE
#                       binary overrides.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
XR_DIR="$ROOT/xr"
PKG="com.lovemoon.operator"
ACT="com.godot.game.GodotApp"

ADB="${ADB:-adb}"
PYTHON="${PYTHON:-python3}"
MAKE="${MAKE:-make}"
FFPROBE="${FFPROBE:-}"

QUEST_SERIAL="${QUEST_SERIAL:-}"
CAPTURE_SECONDS="${CAPTURE_SECONDS:-12}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT/tests/logs/ego-record-$(date +%Y%m%d-%H%M%S)}"
SKIP_BUILD="${SKIP_BUILD:-0}"
SKIP_INSTALL="${SKIP_INSTALL:-0}"
SKIP_DEVICE="${SKIP_DEVICE:-0}"
KEEP_CI_APK="${KEEP_CI_APK:-0}"
CLEAR_APP_DATA="${CLEAR_APP_DATA:-1}"
DEVICE_KIND="${DEVICE_KIND:-quest}"

START_TIMEOUT_SECONDS="${START_TIMEOUT_SECONDS:-60}"
STOP_BUFFER_SECONDS="${STOP_BUFFER_SECONDS:-120}"
MIN_MP4_BYTES="${MIN_MP4_BYTES:-1000000}"
MIN_RGB_FRAMES="${MIN_RGB_FRAMES:-0}"
MIN_RGB_FPS="${MIN_RGB_FPS:-20}"

# The capture settings panel defaults here. The script also parses the actual
# root from logcat after start, so custom roots still work when CLEAR_APP_DATA=0.
REMOTE_CAPTURE_ROOT="${DEVICE_ROOT:-/sdcard/Movies/SpatialMP4}"
REMOTE_SESSION_DIR=""
REMOTE_FINAL_MP4=""

APK_PATH=""           # filled in by configure_device_kind
MAKE_TARGET=""        # build-quest / build-pico
EXPECTED_DEVICE_PREFIX=""  # quest / pico — used by validator
CLEAN_APK_PATH="$OUTPUT_DIR/Operator-clean.apk"
CAPTURE_APP_GD="$XR_DIR/scripts/capture_app.gd"
CAPTURE_APP_GD_BAK=""

configure_device_kind() {
  case "$DEVICE_KIND" in
    quest)
      APK_PATH="$XR_DIR/build/quest/Operator.apk"
      MAKE_TARGET="build-quest"
      EXPECTED_DEVICE_PREFIX="quest"
      ;;
    pico)
      APK_PATH="$XR_DIR/build/pico/Operator.apk"
      MAKE_TARGET="build-pico"
      EXPECTED_DEVICE_PREFIX="pico"
      ;;
    *)
      err "unsupported --device value: $DEVICE_KIND (expected quest or pico)"
      exit 1
      ;;
  esac
}

SERIAL=""
CLEAN_APK_READY=0
DEVICE_NEEDS_CLEAN=0

if [ -t 1 ]; then
  BOLD="$(tput bold)"; GREEN="$(tput setaf 2)"; RED="$(tput setaf 1)"
  YELLOW="$(tput setaf 3)"; BLUE="$(tput setaf 4)"; DIM="$(tput dim)"; RESET="$(tput sgr0)"
else
  BOLD=""; GREEN=""; RED=""; YELLOW=""; BLUE=""; DIM=""; RESET=""
fi

step() { echo; echo "${BOLD}${BLUE}=> $*${RESET}"; }
ok() { echo "  ${GREEN}OK${RESET} $*"; }
warn() { echo "  ${YELLOW}WARN${RESET} $*"; }
err() { echo "  ${RED}ERR${RESET} $*" >&2; }
note() { echo "  ${DIM}$*${RESET}"; }

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    /^$/ { print; next }
    { exit }
  ' "${BASH_SOURCE[0]}"
  exit "${1:-0}"
}

while (("$#")); do
  case "$1" in
    --capture-seconds) CAPTURE_SECONDS="$2"; shift 2 ;;
    --output-dir) OUTPUT_DIR="$2"; CLEAN_APK_PATH="$OUTPUT_DIR/Operator-clean.apk"; shift 2 ;;
    --serial) QUEST_SERIAL="$2"; shift 2 ;;
    --ffprobe) FFPROBE="$2"; shift 2 ;;
    --device) DEVICE_KIND="$2"; shift 2 ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --skip-install) SKIP_INSTALL=1; shift ;;
    --skip-device) SKIP_DEVICE=1; shift ;;
    --keep-ci-apk) KEEP_CI_APK=1; shift ;;
    --clear-app-data) CLEAR_APP_DATA=1; shift ;;
    --no-clear-app-data) CLEAR_APP_DATA=0; shift ;;
    -h|--help) usage 0 ;;
    *) err "unknown arg: $1"; usage 1 ;;
  esac
done

configure_device_kind

cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  restore_auto_start || true
  reinstall_clean_apk || true
  if [ "$rc" != "0" ]; then
    echo
    err "FAIL (exit $rc) - artifacts in $OUTPUT_DIR"
  fi
  exit "$rc"
}
trap cleanup EXIT INT TERM

run_adb() {
  "$ADB" -s "$SERIAL" "$@"
}

require_tool() {
  local tool="$1"
  if ! command -v "$tool" >/dev/null 2>&1; then
    err "missing required tool: $tool"
    exit 1
  fi
}

resolve_ffprobe() {
  if [ -n "$FFPROBE" ]; then
    return
  fi
  local candidates=(
    "$HOME/ws/spatialmp4-quest/SpatialMP4/scripts/build_ffmpeg/ffmpeg_install/bin/ffprobe"
    "$HOME/ws/SpatialMP4/scripts/build_ffmpeg/ffmpeg_install/bin/ffprobe"
    "$ROOT/../spatialmp4-quest/SpatialMP4/scripts/build_ffmpeg/ffmpeg_install/bin/ffprobe"
    "$ROOT/../SpatialMP4/scripts/build_ffmpeg/ffmpeg_install/bin/ffprobe"
  )
  local candidate
  for candidate in "${candidates[@]}"; do
    if [ -x "$candidate" ]; then
      FFPROBE="$candidate"
      ok "using patched ffprobe: $FFPROBE"
      return
    fi
  done
  if command -v ffprobe >/dev/null 2>&1; then
    FFPROBE="$(command -v ffprobe)"
    warn "using system ffprobe; patched SpatialMP4 metadata tags may be absent"
  else
    FFPROBE=""
    warn "ffprobe not found; MP4 stream validation will be skipped"
  fi
}

pick_device() {
  if [ -n "$QUEST_SERIAL" ]; then
    echo "$QUEST_SERIAL"
    return
  fi
  local devices
  devices=$("$ADB" devices | awk 'NR>1 && $2=="device" {print $1}' || true)
  if [ -z "$devices" ]; then
    err "no adb device attached; set QUEST_SERIAL to override"
    exit 1
  fi
  echo "$devices" | head -n1
}

restore_auto_start() {
  if [ -n "${CAPTURE_APP_GD_BAK:-}" ] && [ -f "$CAPTURE_APP_GD_BAK" ]; then
    cp "$CAPTURE_APP_GD_BAK" "$CAPTURE_APP_GD"
    rm -f "$CAPTURE_APP_GD_BAK"
    CAPTURE_APP_GD_BAK=""
    ok "restored xr/scripts/capture_app.gd"
  fi
}

flip_auto_start_on() {
  if [ ! -f "$CAPTURE_APP_GD" ]; then
    err "capture_app.gd not found at $CAPTURE_APP_GD"
    exit 2
  fi
  local stop_value="$CAPTURE_SECONDS"
  case "$stop_value" in
    *.*) ;;
    *) stop_value="${stop_value}.0" ;;
  esac
  CAPTURE_APP_GD_BAK="$(mktemp -t operator_capture_app_gd.XXXXXX)"
  cp "$CAPTURE_APP_GD" "$CAPTURE_APP_GD_BAK"
  sed -i.tmp -E \
    -e "s|^const AUTO_START_FOR_DEVICE_TEST := .*|const AUTO_START_FOR_DEVICE_TEST := true|" \
    -e "s|^const AUTO_STOP_AFTER_SECONDS := .*|const AUTO_STOP_AFTER_SECONDS := ${stop_value}|" \
    "$CAPTURE_APP_GD"
  rm -f "$CAPTURE_APP_GD.tmp"
  ok "enabled AUTO_START_FOR_DEVICE_TEST for ${CAPTURE_SECONDS}s"
}

build_clean_apk() {
  step "Build clean ${DEVICE_KIND} APK ($MAKE_TARGET)"
  (cd "$XR_DIR" && "$MAKE" "$MAKE_TARGET" 2>&1 | tee "$OUTPUT_DIR/build-clean.log")
  if [ ! -f "$APK_PATH" ]; then
    err "APK export did not produce $APK_PATH"
    exit 2
  fi
  cp -f "$APK_PATH" "$CLEAN_APK_PATH"
  CLEAN_APK_READY=1
  ok "clean APK saved to $CLEAN_APK_PATH"
}

build_ci_apk() {
  step "Build CI auto-record ${DEVICE_KIND} APK ($MAKE_TARGET)"
  flip_auto_start_on
  (cd "$XR_DIR" && "$MAKE" "$MAKE_TARGET" 2>&1 | tee "$OUTPUT_DIR/build-ci.log")
  restore_auto_start
  if [ ! -f "$APK_PATH" ]; then
    err "APK export did not produce $APK_PATH"
    exit 2
  fi
  ok "CI APK ready: $APK_PATH"
}

install_ci_apk() {
  step "Install CI APK"
  run_adb install -r -d "$APK_PATH" 2>&1 | tee "$OUTPUT_DIR/adb-install.log"
  DEVICE_NEEDS_CLEAN=1
  ok "installed $PKG on $SERIAL"
}

reinstall_clean_apk() {
  if [ "$KEEP_CI_APK" = "1" ]; then
    if [ "$DEVICE_NEEDS_CLEAN" = "1" ]; then
      warn "KEEP_CI_APK=1; leaving CI APK installed"
    fi
    return 0
  fi
  if [ "$DEVICE_NEEDS_CLEAN" != "1" ]; then
    return 0
  fi
  if [ -z "$SERIAL" ]; then
    warn "device serial unknown; skipping clean APK reinstall"
    return 0
  fi
  if [ "$CLEAN_APK_READY" != "1" ] || [ ! -f "$CLEAN_APK_PATH" ]; then
    warn "clean APK unavailable; device may still have the CI auto-record APK"
    return 0
  fi
  step "Reinstall clean APK"
  if run_adb install -r -d "$CLEAN_APK_PATH" 2>&1 | tee "$OUTPUT_DIR/adb-reinstall-clean.log"; then
    DEVICE_NEEDS_CLEAN=0
    ok "device restored to clean APK"
  else
    warn "clean APK reinstall failed; see $OUTPUT_DIR/adb-reinstall-clean.log"
  fi
}

grant_permissions() {
  local perm
  for perm in \
    android.permission.CAMERA \
    horizonos.permission.HEADSET_CAMERA \
    horizonos.permission.AVATAR_CAMERA \
    com.oculus.permission.USE_SCENE \
    horizonos.permission.USE_SCENE \
    android.permission.READ_EXTERNAL_STORAGE \
    android.permission.WRITE_EXTERNAL_STORAGE
  do
    run_adb shell pm grant "$PKG" "$perm" >/dev/null 2>&1 || true
  done
  run_adb shell appops set "$PKG" MANAGE_EXTERNAL_STORAGE allow >/dev/null 2>&1 || true
  run_adb shell cmd appops set "$PKG" MANAGE_EXTERNAL_STORAGE allow >/dev/null 2>&1 || true
  run_adb shell appops set "$PKG" LEGACY_STORAGE allow >/dev/null 2>&1 || true
  run_adb shell appops set "$PKG" USE_SCENE allow >/dev/null 2>&1 || true
  run_adb shell appops set "$PKG" HEADSET_CAMERA allow >/dev/null 2>&1 || true
  run_adb shell appops set "$PKG" AVATAR_CAMERA allow >/dev/null 2>&1 || true
}

dismiss_system_dialogs() {
  run_adb shell am broadcast -a android.intent.action.CLOSE_SYSTEM_DIALOGS >/dev/null 2>&1 || true
  run_adb shell input keyevent KEYCODE_BACK >/dev/null 2>&1 || true
  sleep 1
  run_adb shell input keyevent KEYCODE_BACK >/dev/null 2>&1 || true
}

prepare_device() {
  step "Prepare device"
  run_adb shell am force-stop "$PKG" >/dev/null 2>&1 || true
  if [ "$CLEAR_APP_DATA" = "1" ]; then
    run_adb shell pm clear "$PKG" >/dev/null 2>&1 || true
    ok "cleared app data for deterministic capture settings"
  fi
  grant_permissions
  run_adb shell "rm -rf /sdcard/Movies/SpatialMP4 /sdcard/DCIM/SpatialMP4" >/dev/null 2>&1 || true
  run_adb shell am force-stop com.oculus.guardian >/dev/null 2>&1 || true
  run_adb shell am force-stop com.android.permissioncontroller >/dev/null 2>&1 || true
  run_adb shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
  run_adb shell am broadcast -a com.oculus.vrpowermanager.prox_close >/dev/null 2>&1 || true
  dismiss_system_dialogs
  run_adb logcat -c
  ok "device prepared"
}

start_ego_activity() {
  run_adb shell am force-stop "$PKG" >/dev/null 2>&1 || true
  run_adb shell am start -n "$PKG/$ACT" --es operator.mode ego >/dev/null
}

launch_app() {
  step "Launch ego mode"
  dismiss_system_dialogs
  start_ego_activity
  ok "launched $PKG/$ACT with operator.mode=ego"
}

logcat_dump() {
  run_adb logcat -d 2>/dev/null || true
}

logcat_contains() {
  local dump
  dump="$(logcat_dump)"
  grep -q "$1" <<< "$dump"
}

parse_started_session() {
  local line path
  line=$(logcat_dump | grep "Capture session started:" | tail -n1 || true)
  if [ -z "$line" ]; then
    return 1
  fi
  path=$(printf '%s\n' "$line" | sed -n 's/.*Capture session started: //p' | tr -d '\r')
  if [ -z "$path" ]; then
    return 1
  fi
  REMOTE_SESSION_DIR="$path"
  REMOTE_CAPTURE_ROOT="$(dirname "$path")"
  return 0
}

parse_stopped_session() {
  local line path
  line=$(logcat_dump | grep "Capture session stopped:" | tail -n1 || true)
  if [ -z "$line" ]; then
    return 1
  fi
  path=$(printf '%s\n' "$line" | sed -n 's/.*Capture session stopped: //p' | tr -d '\r')
  if [ -z "$path" ]; then
    # The app still emits the stop marker when finalization fails before it can
    # produce a saved path. Treat that as a real stop so we can pull sidecars
    # and let validation report the missing/invalid MP4 instead of timing out.
    return 0
  fi
  if printf '%s\n' "$path" | grep -q '\.mp4$'; then
    REMOTE_FINAL_MP4="$path"
    REMOTE_CAPTURE_ROOT="$(dirname "$path")"
  else
    REMOTE_SESSION_DIR="$path"
    REMOTE_CAPTURE_ROOT="$(dirname "$path")"
  fi
  return 0
}

wait_for_session_start() {
  step "Wait for recording start"
  local deadline
  deadline=$(($(date +%s) + START_TIMEOUT_SECONDS))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if parse_started_session; then
      ok "session started: $REMOTE_SESSION_DIR"
      return 0
    fi
    if logcat_contains "Launch is blocked because:"; then
      warn "system dialog blocking launch; dismissing and retrying"
      run_adb shell am force-stop com.oculus.guardian >/dev/null 2>&1 || true
      run_adb shell am broadcast -a com.oculus.vrpowermanager.prox_close >/dev/null 2>&1 || true
      dismiss_system_dialogs
      start_ego_activity || true
    fi
    sleep 1
  done
  err "timed out waiting for capture start"
  logcat_dump > "$OUTPUT_DIR/logcat-start-timeout.log"
  exit 3
}

remote_final_mp4s() {
  run_adb shell "ls '$REMOTE_CAPTURE_ROOT'/*.mp4 2>/dev/null" \
    | tr -d '\r' \
    | grep -v '\.partial\.mp4$' || true
}

wait_for_session_stop() {
  step "Wait for recording stop"
  local timeout deadline finals
  timeout=$(awk -v a="$CAPTURE_SECONDS" -v b="$STOP_BUFFER_SECONDS" 'BEGIN { printf "%d", a + b }')
  deadline=$(($(date +%s) + timeout))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if parse_stopped_session; then
      ok "session stopped via logcat: ${REMOTE_FINAL_MP4:-$REMOTE_SESSION_DIR}"
      return 0
    fi
    finals="$(remote_final_mp4s)"
    if [ -n "$finals" ]; then
      REMOTE_FINAL_MP4="$(printf '%s\n' "$finals" | head -n1)"
      ok "session stopped via final MP4: $REMOTE_FINAL_MP4"
      return 0
    fi
    sleep 1
  done
  err "timed out waiting for capture stop"
  logcat_dump > "$OUTPUT_DIR/logcat-stop-timeout.log"
  run_adb shell ls -la "$REMOTE_CAPTURE_ROOT" > "$OUTPUT_DIR/device-root-listing.txt" 2>&1 || true
  exit 3
}

wait_for_app_quit() {
  step "Wait for app exit"
  local deadline pid
  deadline=$(($(date +%s) + 20))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    pid="$(run_adb shell pidof "$PKG" 2>/dev/null | tr -d '\r' || true)"
    if [ -z "$pid" ]; then
      ok "app exited"
      return 0
    fi
    sleep 1
  done
  warn "app did not exit; force-stopping"
  run_adb shell am force-stop "$PKG" >/dev/null 2>&1 || true
}

pull_session() {
  step "Pull session"
  mkdir -p "$OUTPUT_DIR/session"
  run_adb pull "$REMOTE_CAPTURE_ROOT" "$OUTPUT_DIR/session/" > "$OUTPUT_DIR/adb-pull.log"
  logcat_dump > "$OUTPUT_DIR/logcat.log"
  ok "pulled $REMOTE_CAPTURE_ROOT to $OUTPUT_DIR/session/"
}

validate_capture() {
  step "Validate captured data"
  local local_root
  local_root="$OUTPUT_DIR/session/$(basename "$REMOTE_CAPTURE_ROOT")"
  if [ "$SKIP_DEVICE" = "1" ]; then
    local_root="$OUTPUT_DIR/session/SpatialMP4"
  fi
  "$PYTHON" - "$local_root" "${FFPROBE:-}" "$CAPTURE_SECONDS" "$MIN_MP4_BYTES" "$MIN_RGB_FRAMES" "$MIN_RGB_FPS" "$EXPECTED_DEVICE_PREFIX" <<'PY'
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path
from typing import Any

session_root = Path(sys.argv[1])
ffprobe = sys.argv[2] or None
capture_seconds = float(sys.argv[3])
min_mp4_bytes = int(sys.argv[4])
min_rgb_frames = int(sys.argv[5]) or max(20, int(capture_seconds * 15))
min_rgb_fps = float(sys.argv[6])
expected_device_prefix = sys.argv[7] if len(sys.argv) > 7 else ""

checks: list[tuple[str, str, str]] = []


def add(status: str, name: str, detail: str = "") -> None:
    checks.append((status, name, detail))


def passed(name: str, detail: str = "") -> None:
    add("PASS", name, detail)


def warned(name: str, detail: str = "") -> None:
    add("WARN", name, detail)


def failed(name: str, detail: str = "") -> None:
    add("FAIL", name, detail)


def safe_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(errors="replace"))


def safe_jsonl(path: Path) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    if not path.exists():
        return records
    for line in path.read_text(errors="replace").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            records.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return records


def pick_latest_session(root: Path) -> tuple[Path, Path]:
    candidates: list[tuple[float, Path, Path]] = []
    for child in root.iterdir():
        if not child.is_dir():
            continue
        mp4 = root / f"{child.name}.mp4"
        if mp4.exists():
            candidates.append((max(child.stat().st_mtime, mp4.stat().st_mtime), child, mp4))
    if not candidates:
        names = ", ".join(sorted(p.name for p in root.iterdir())) if root.exists() else "<missing>"
        raise FileNotFoundError(f"no <session>/<session>.mp4 pair under {root}; got {names}")
    candidates.sort(reverse=True)
    return candidates[0][1], candidates[0][2]


def run_ffprobe(path: Path) -> dict[str, Any] | None:
    if not ffprobe:
        return None
    try:
        out = subprocess.run(
            [ffprobe, "-v", "error", "-count_packets", "-show_format", "-show_streams", "-of", "json", str(path)],
            check=True,
            capture_output=True,
            text=True,
            timeout=45,
        )
        return json.loads(out.stdout)
    except Exception as exc:
        failed("ffprobe parses MP4", str(exc))
        return None


def stream_start_us(stream: dict[str, Any]) -> int:
    raw_time = stream.get("start_time")
    if raw_time not in (None, "N/A"):
        try:
            return int(float(raw_time) * 1_000_000)
        except ValueError:
            pass
    raw_pts = stream.get("start_pts")
    if raw_pts in (None, "N/A"):
        return 0
    try:
        pts = int(raw_pts)
    except ValueError:
        return 0
    num, den = 1, 1_000_000
    time_base = stream.get("time_base")
    if isinstance(time_base, str) and "/" in time_base:
        n, d = time_base.split("/", 1)
        try:
            num, den = int(n), int(d)
        except ValueError:
            num, den = 1, 1_000_000
    return int(pts * num * 1_000_000 / den)


def packet_count(stream: dict[str, Any]) -> int:
    for key in ("nb_read_packets", "nb_frames"):
        value = stream.get(key)
        if value not in (None, "N/A"):
            try:
                return int(value)
            except ValueError:
                pass
    return 0


def check_required_files(session_dir: Path, mp4: Path, options: dict[str, Any]) -> None:
    required = [
        "manifest.json",
        "android_timebase.json",
        "left_camera_characteristics.json",
        "left_camera_frames.jsonl",
    ]
    if options.get("stereo_rgb", True):
        required += ["right_camera_characteristics.json", "right_camera_frames.jsonl"]
    if options.get("record_depth", True):
        required += ["depth/frames.jsonl"]
    for rel in required:
        path = session_dir / rel
        if path.exists() and path.stat().st_size > 0:
            passed(f"file present: {rel}")
        else:
            failed(f"file present: {rel}", str(path))
    if mp4.exists() and mp4.stat().st_size >= min_mp4_bytes:
        passed("final MP4 size", f"{mp4.stat().st_size:,} bytes")
    elif mp4.exists():
        failed("final MP4 size", f"{mp4.stat().st_size:,} bytes < {min_mp4_bytes:,}")
    else:
        failed("final MP4 exists", str(mp4))


def check_manifest(manifest: dict[str, Any]) -> dict[str, Any]:
    if manifest.get("schema") == "spatialmp4.quest_capture.spool.v2":
        passed("manifest schema is spool.v2")
    else:
        failed("manifest schema is spool.v2", repr(manifest.get("schema")))
    if manifest.get("media_pts_domain") == "godot_ticks_ns":
        passed("manifest media_pts_domain is godot_ticks_ns")
    else:
        failed("manifest media_pts_domain is godot_ticks_ns", repr(manifest.get("media_pts_domain")))
    if manifest.get("media_pts_clock") == "clock_monotonic_ns":
        passed("manifest media_pts_clock is clock_monotonic_ns")
    else:
        failed("manifest media_pts_clock is clock_monotonic_ns", repr(manifest.get("media_pts_clock")))
    options = manifest.get("capture_options") or {}
    for key in ("stereo_rgb", "record_depth", "record_head_pose"):
        if options.get(key) is True:
            passed(f"capture option {key}=true")
        else:
            failed(f"capture option {key}=true", repr(options.get(key)))
    return options


def check_timebase(timebase: dict[str, Any]) -> None:
    required = [
        "session_start_unix_us",
        "session_start_godot_ticks_us",
        "configure_godot_ticks_us",
        "configure_clock_monotonic_ns",
        "configure_elapsed_realtime_ns",
        "configure_unix_time_ms",
        "rgb_timestamp_domain",
        "godot_ticks_clock",
        "clock_monotonic_to_godot_ticks_ns_offset",
        "clock_boottime_to_godot_ticks_ns_offset",
        "openxr_xr_time_domain",
        "openxr_xr_time_to_godot_ticks_ns_offset",
        "rgb_sensor_timestamp_sources",
    ]
    for key in required:
        if key in timebase:
            passed(f"android_timebase has {key}")
        else:
            failed(f"android_timebase has {key}")
    if timebase.get("rgb_timestamp_domain") != "godot_ticks_ns":
        failed("rgb timestamp domain", repr(timebase.get("rgb_timestamp_domain")))
    if timebase.get("openxr_xr_time_domain") != "clock_monotonic_ns":
        failed("OpenXR time domain", repr(timebase.get("openxr_xr_time_domain")))


def check_rgb_index(session_dir: Path, eye: str, timebase: dict[str, Any]) -> list[dict[str, Any]]:
    path = session_dir / f"{eye}_camera_frames.jsonl"
    rows = safe_jsonl(path)
    if len(rows) >= min_rgb_frames:
        passed(f"{eye} RGB frame index count", f"{len(rows)} >= {min_rgb_frames}")
    else:
        failed(f"{eye} RGB frame index count", f"{len(rows)} < {min_rgb_frames}")
        return rows
    indices = [r.get("frame_index") for r in rows]
    if indices == list(range(len(rows))):
        passed(f"{eye} frame_index is contiguous")
    else:
        failed(f"{eye} frame_index is contiguous")
    timestamps = [int(r["timestamp_ns"]) for r in rows if "timestamp_ns" in r]
    if len(timestamps) == len(rows) and all(b >= a for a, b in zip(timestamps, timestamps[1:])):
        passed(f"{eye} timestamp_ns is monotonic")
    else:
        failed(f"{eye} timestamp_ns is monotonic")
    sensors = [int(r["camera_sensor_timestamp_ns"]) for r in rows if "camera_sensor_timestamp_ns" in r]
    if len(sensors) == len(rows) and len(timestamps) == len(rows):
        deltas = {s - t for s, t in zip(sensors, timestamps)}
        sources = timebase.get("rgb_sensor_timestamp_sources") or {}
        source = sources.get(eye)
        if source == "realtime":
            expected = -int(timebase.get("clock_boottime_to_godot_ticks_ns_offset", 0))
        else:
            expected = -int(timebase.get("clock_monotonic_to_godot_ticks_ns_offset", 0))
        if len(deltas) == 1 and next(iter(deltas)) == expected:
            passed(f"{eye} sensor-to-Godot offset matches timebase")
        else:
            failed(f"{eye} sensor-to-Godot offset matches timebase", f"deltas={sorted(deltas)[:3]} expected={expected}")
    return rows


def check_depth(session_dir: Path) -> list[dict[str, Any]]:
    rows = safe_jsonl(session_dir / "depth/frames.jsonl")
    if rows:
        passed("depth frame index non-empty", f"{len(rows)} records")
        timestamps = [int(r["timestamp_ns"]) for r in rows if "timestamp_ns" in r]
        if len(timestamps) == len(rows) and all(b >= a for a, b in zip(timestamps, timestamps[1:])):
            passed("depth timestamp_ns is monotonic")
        else:
            failed("depth timestamp_ns is monotonic")
    else:
        failed("depth frame index non-empty")
    return rows


def check_device_block(manifest: dict[str, Any]) -> dict[str, Any]:
    # Manifest-side device identity introduced by the spatialmp4 device-type
    # work (DeviceIdentity.detect -> getDeviceIdentityJson -> manifest.json).
    # We assert the block is present, has every expected key with a non-empty
    # string value, and that device_type matches the family of the headset we
    # were asked to target (--device quest|pico). The raw Build.* strings
    # (model / manufacturer / build_device) are sanity-checked for the same
    # family so a Pico classified as quest3 (or vice-versa) fails loudly.
    device = manifest.get("device")
    if not isinstance(device, dict):
        failed("manifest has device block", repr(device))
        return {}
    passed("manifest has device block")

    required_keys = (
        "device_type",
        "device_model",
        "device_manufacturer",
        "device_build_device",
        "runtime_os",
    )
    for key in required_keys:
        value = device.get(key)
        if isinstance(value, str) and value.strip():
            passed(f"device.{key} non-empty", value)
        else:
            failed(f"device.{key} non-empty", repr(value))

    if expected_device_prefix:
        # Quest family: classifier returns quest3 / quest3s / questpro / quest2.
        # Pico family: pico4_ultra / pico4_pro / pico4_enterprise / pico4 / ...
        device_type = str(device.get("device_type", "")).lower()
        if device_type.startswith(expected_device_prefix):
            passed(
                f"device_type matches --device {expected_device_prefix}",
                device_type,
            )
        else:
            failed(
                f"device_type matches --device {expected_device_prefix}",
                f"got {device_type!r}",
            )

        manufacturer = str(device.get("device_manufacturer", "")).lower()
        if expected_device_prefix == "quest":
            mfg_ok = "oculus" in manufacturer or "meta" in manufacturer
        elif expected_device_prefix == "pico":
            mfg_ok = "pico" in manufacturer
        else:
            mfg_ok = True
        if mfg_ok:
            passed(
                f"device_manufacturer matches --device {expected_device_prefix}",
                manufacturer,
            )
        else:
            failed(
                f"device_manufacturer matches --device {expected_device_prefix}",
                manufacturer,
            )
    return device


def check_mp4_device_tags(mp4: Path, device: dict[str, Any]) -> None:
    # MP4 moov/udta side: the muxer's EnsureContext() writes the same device
    # strings via av_dict_set into format-level metadata. We re-query with
    # ffprobe -show_entries format_tags and confirm device_type / model / make
    # round-tripped. Skipped silently when ffprobe is unavailable so the test
    # still passes on hosts without a working ffprobe.
    if not ffprobe or not device:
        return
    try:
        out = subprocess.run(
            [
                ffprobe,
                "-v",
                "error",
                "-show_entries",
                "format_tags",
                "-of",
                "json",
                str(mp4),
            ],
            check=True,
            capture_output=True,
            text=True,
            timeout=30,
        )
        format_tags = (json.loads(out.stdout).get("format") or {}).get("tags") or {}
    except Exception as exc:
        failed("ffprobe reads MP4 format tags", str(exc))
        return

    # Tag keys are case-insensitive in mov; ffprobe usually returns lowercase
    # for the standard atoms (model, make) and the literal key for the custom
    # ones (device_type, com.android.model, ...). Normalise on read.
    norm = {k.lower(): v for k, v in format_tags.items()}

    expected = {
        "device_type": device.get("device_type"),
        "device_model": device.get("device_model"),
        "device_manufacturer": device.get("device_manufacturer"),
    }
    # Standard mov atoms: model -> ©mod, make -> ©mak. ffprobe surfaces them
    # as 'model' / 'make' in format_tags.
    standard_alias = {
        "device_model": "model",
        "device_manufacturer": "make",
    }

    for our_key, want in expected.items():
        if not want:
            continue
        candidates = [our_key, standard_alias.get(our_key, "")]
        candidates = [c for c in candidates if c]
        got = next((norm[c] for c in candidates if c in norm), None)
        if got == want:
            passed(f"MP4 udta {our_key} matches manifest", got)
        elif got is None:
            failed(
                f"MP4 udta {our_key} present",
                f"want {want!r}, none of {candidates} found in {list(norm)}",
            )
        else:
            failed(
                f"MP4 udta {our_key} matches manifest",
                f"want {want!r}, got {got!r}",
            )


def check_mp4(mp4: Path, options: dict[str, Any]) -> None:
    data = run_ffprobe(mp4)
    if data is None:
        warned("MP4 stream inspection skipped", "ffprobe unavailable or failed")
        return
    if not any(status == "FAIL" and name == "ffprobe parses MP4" for status, name, _ in checks):
        passed("ffprobe parses MP4")
    streams = data.get("streams", [])
    rgb = next((s for s in streams if s.get("codec_name") == "hevc" or s.get("codec_tag_string") in ("hev1", "hvc1")), None)
    depth = next((s for s in streams if s.get("codec_name") in ("ffv1", "rawvideo") or s.get("codec_tag_string") == "raw1"), None)
    mett = [s for s in streams if s.get("codec_tag_string") == "mett"]
    if rgb:
        passed("MP4 contains HEVC RGB stream", f"{rgb.get('width')}x{rgb.get('height')}")
        mismatched = []
        expected_color = {
            "color_range": "tv",
            "color_space": "bt709",
            "color_transfer": "bt709",
            "color_primaries": "bt709",
        }
        for key, expected in expected_color.items():
            actual = rgb.get(key)
            if actual not in (expected, None, "unknown"):
                mismatched.append(f"{key}={actual}")
        if mismatched:
            failed("RGB stream color tags are BT.709 SDR limited", ", ".join(mismatched))
        else:
            passed("RGB stream color tags are BT.709 SDR limited")
        packets = packet_count(rgb)
        if packets >= min_rgb_frames:
            passed("MP4 RGB packet count", f"{packets} >= {min_rgb_frames}")
        else:
            failed("MP4 RGB packet count", f"{packets} < {min_rgb_frames}")
        duration = float(rgb.get("duration") or (data.get("format") or {}).get("duration") or 0.0)
        if duration > 0 and packets > 0:
            fps = packets / duration
            if fps >= min_rgb_fps:
                passed("MP4 RGB frame rate", f"{fps:.1f} fps")
            else:
                failed("MP4 RGB frame rate", f"{fps:.1f} fps < {min_rgb_fps:.1f}")
    else:
        failed("MP4 contains HEVC RGB stream")
    if options.get("record_depth", True):
        if depth:
            passed("MP4 contains depth stream", f"{depth.get('codec_name')}/{depth.get('codec_tag_string')}")
        else:
            failed("MP4 contains depth stream")
    if options.get("record_head_pose", True):
        if mett:
            passed("MP4 contains timed metadata stream", f"{len(mett)} mett stream(s)")
        else:
            failed("MP4 contains timed metadata stream")
    starts = {str(s.get("index")): stream_start_us(s) for s in streams}
    if starts:
        if any(abs(v) <= 1000 for v in starts.values()):
            passed("at least one MP4 stream starts at PTS zero", str(starts))
        else:
            failed("at least one MP4 stream starts at PTS zero", str(starts))
        worst = max(starts.values())
        if worst <= 500_000:
            passed("MP4 streams start within 500 ms", f"worst={worst} us")
        else:
            failed("MP4 streams start within 500 ms", f"worst={worst} us")


def print_summary() -> int:
    for status, name, detail in checks:
        line = f"  {status:>4}  {name}"
        if detail:
            line += f"  -  {detail}"
        print(line)
    fails = sum(1 for status, _, _ in checks if status == "FAIL")
    warns = sum(1 for status, _, _ in checks if status == "WARN")
    passes = sum(1 for status, _, _ in checks if status == "PASS")
    print(f"\nsummary: {passes} pass, {warns} warn, {fails} fail")
    return 0 if fails == 0 else 1


try:
    if not session_root.exists():
        print(f"[validate] session root not found: {session_root}", file=sys.stderr)
        sys.exit(1)
    session_dir, mp4 = pick_latest_session(session_root)
except Exception as exc:
    print(f"[validate] {exc}", file=sys.stderr)
    sys.exit(1)

print(f"[validate] session={session_dir.name} mp4={mp4.name}")

manifest_path = session_dir / "manifest.json"
timebase_path = session_dir / "android_timebase.json"
if not manifest_path.exists() or not timebase_path.exists():
    if not manifest_path.exists():
        failed("manifest.json exists", str(manifest_path))
    if not timebase_path.exists():
        failed("android_timebase.json exists", str(timebase_path))
    sys.exit(print_summary())

manifest = safe_json(manifest_path)
timebase = safe_json(timebase_path)
options = check_manifest(manifest)
device = check_device_block(manifest)
check_timebase(timebase)
check_required_files(session_dir, mp4, options)
check_rgb_index(session_dir, "left", timebase)
if options.get("stereo_rgb", True):
    check_rgb_index(session_dir, "right", timebase)
if options.get("record_depth", True):
    check_depth(session_dir)
check_mp4(mp4, options)
check_mp4_device_tags(mp4, device)

sys.exit(print_summary())
PY
}

main() {
  mkdir -p "$OUTPUT_DIR"

  step "Pre-flight"
  require_tool "$PYTHON"
  resolve_ffprobe
  if [ "$SKIP_DEVICE" = "1" ]; then
    ok "SKIP_DEVICE=1; validate only"
    validate_capture
    ok "CI PASSED - artifacts in $OUTPUT_DIR"
    return 0
  fi

  require_tool "$ADB"
  require_tool "$MAKE"
  SERIAL="$(pick_device)"
  ok "adb device: $SERIAL"

  if [ "$SKIP_BUILD" != "1" ]; then
    build_clean_apk
    build_ci_apk
  else
    warn "SKIP_BUILD=1; using existing $APK_PATH (must already be a CI auto-record APK)"
    if [ ! -f "$APK_PATH" ]; then
      err "missing APK: $APK_PATH"
      exit 2
    fi
  fi

  if ! run_adb shell pm path "$PKG" >/dev/null 2>&1 && [ "$SKIP_INSTALL" = "1" ]; then
    err "$PKG is not installed and SKIP_INSTALL=1 was set"
    exit 1
  fi

  if [ "$SKIP_INSTALL" != "1" ]; then
    install_ci_apk
  else
    warn "SKIP_INSTALL=1; assuming installed APK has AUTO_START_FOR_DEVICE_TEST=true"
  fi

  prepare_device
  launch_app
  wait_for_session_start
  wait_for_session_stop
  wait_for_app_quit
  pull_session
  validate_capture

  step "Summary"
  note "artifacts: $OUTPUT_DIR"
  note "device root: $REMOTE_CAPTURE_ROOT"
  note "logcat: $OUTPUT_DIR/logcat.log"
  ok "CI PASSED"
}

main "$@"
