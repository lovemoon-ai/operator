#!/usr/bin/env bash
# End-to-end ego data recording CI for Quest/PICO headset builds.
#
# The script builds a temporary CI APK with capture_app.gd's device-test
# auto-start harness enabled, installs it on the attached headset, launches
# the app in ego mode, waits for a recording to finalize, pulls the captured
# SpatialMP4 session, and validates the self-contained MP4 plus manifest.
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
#   ADB_SERIAL         adb serial to use for any device kind.
#   PICO_SERIAL        adb serial to use when --device pico.
#   QUEST_SERIAL       adb serial to use when --device quest. Also kept as the
#                      legacy override when ADB_SERIAL/PICO_SERIAL are unset.
#   CAPTURE_SECONDS     recording duration baked into the CI APK (default 12).
#   OUTPUT_DIR          artifact directory (default tests/logs/ego-record-<stamp>).
#   SKIP_BUILD=1        use the existing xr/build/<kind>/Operator-ci.apk
#                       (clean APK at .../Operator.apk is also reused if present).
#   SKIP_INSTALL=1      assume the correct APK is already installed.
#   SKIP_DEVICE=1       validate existing OUTPUT_DIR/session/SpatialMP4 only.
#   KEEP_CI_APK=1       do not reinstall the clean APK after the run.
#   CLEAR_APP_DATA=0    preserve app settings before launch (default clears).
#   EXPECT_AUDIO=0      disable the audio-specific CI toggle/checks
#                       (default 1: record and require AAC audio in MP4).
#   EXPECT_BODY_TRACKING=1
#   EXPECT_MOTION_TRACKERS=1
#                       opt into body/motion capture toggles and checks.
#                       Defaults are 0 because Pico body/motion tracking
#                       requires worn external trackers.
#   EXPECT_RGB_CODEC    RGB encoder to request and validate: hevc or h264
#                       (default hevc).
#   EXPECT_RGB_RESOLUTION
#                       Optional per-eye RGB resolution, e.g. 1280x960.
#   EXPECT_RGB_FPS      RGB capture FPS baked into the CI APK (default 30).
#   AUDIO_CHANNEL_LAYOUT, AUDIO_SAMPLE_RATE_HZ, AUDIO_BITRATE_BPS
#                       audio settings baked into the CI APK when EXPECT_AUDIO=1
#                       (defaults stereo, 48000, 128000).
#   ADB, PYTHON, FFPROBE, MAKE
#                       binary overrides.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
XR_DIR="$ROOT/xr"
PKG="com.lovemoon.operator"
ACT="com.godot.game.GodotApp"

ADB="${ADB:-}"
if [ -z "$ADB" ]; then
  for candidate in "$HOME/Library/Android/sdk/platform-tools/adb" \
                   "$HOME/Android/Sdk/platform-tools/adb"; do
    if [ -x "$candidate" ]; then
      ADB="$candidate"
      break
    fi
  done
fi
ADB="${ADB:-adb}"
PYTHON="${PYTHON:-python3}"
MAKE="${MAKE:-make}"
FFPROBE="${FFPROBE:-}"

ADB_SERIAL_OVERRIDE="${ADB_SERIAL:-}"
PICO_SERIAL="${PICO_SERIAL:-}"
QUEST_SERIAL="${QUEST_SERIAL:-}"
CAPTURE_SECONDS="${CAPTURE_SECONDS:-12}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT/tests/logs/ego-record-$(date +%Y%m%d-%H%M%S)}"
SKIP_BUILD="${SKIP_BUILD:-0}"
SKIP_INSTALL="${SKIP_INSTALL:-0}"
SKIP_DEVICE="${SKIP_DEVICE:-0}"
KEEP_CI_APK="${KEEP_CI_APK:-0}"
CLEAR_APP_DATA="${CLEAR_APP_DATA:-1}"
DEVICE_KIND="${DEVICE_KIND:-quest}"
EXPECT_AUDIO_WAS_SET=0
if [ "${EXPECT_AUDIO+x}" = "x" ]; then
  EXPECT_AUDIO_WAS_SET=1
fi
EXPECT_AUDIO="${EXPECT_AUDIO:-1}"
EXPECT_BODY_TRACKING="${EXPECT_BODY_TRACKING:-0}"
EXPECT_MOTION_TRACKERS="${EXPECT_MOTION_TRACKERS:-0}"
EXPECT_RGB_CODEC="${EXPECT_RGB_CODEC:-hevc}"
EXPECT_RGB_RESOLUTION="${EXPECT_RGB_RESOLUTION:-}"
EXPECT_RGB_FPS="${EXPECT_RGB_FPS:-30}"
AUDIO_CHANNEL_LAYOUT="${AUDIO_CHANNEL_LAYOUT:-stereo}"
AUDIO_SAMPLE_RATE_HZ="${AUDIO_SAMPLE_RATE_HZ:-48000}"
AUDIO_BITRATE_BPS="${AUDIO_BITRATE_BPS:-128000}"

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

APK_PATH=""           # clean (production) APK; filled in by configure_device_kind
CI_APK_PATH=""        # CI auto-record APK; filled in by configure_device_kind
MAKE_TARGET=""        # build-quest / build-pico
EXPECTED_DEVICE_PREFIX=""  # quest / pico — used by validator
CLEAN_APK_PATH="$OUTPUT_DIR/Operator-clean.apk"
CAPTURE_APP_GD="$XR_DIR/scripts/app/modes/capture_app_base.gd"
CAPTURE_APP_GD_BAK=""

configure_device_kind() {
  case "$DEVICE_KIND" in
    quest)
      APK_PATH="$XR_DIR/build/quest/Operator.apk"
      CI_APK_PATH="$XR_DIR/build/quest/Operator-ci.apk"
      MAKE_TARGET="build-quest"
      EXPECTED_DEVICE_PREFIX="quest"
      ;;
    pico)
      APK_PATH="$XR_DIR/build/pico/Operator.apk"
      CI_APK_PATH="$XR_DIR/build/pico/Operator-ci.apk"
      MAKE_TARGET="build-pico"
      EXPECTED_DEVICE_PREFIX="pico"
      ;;
    *)
      err "unsupported --device value: $DEVICE_KIND (expected quest or pico)"
      exit 1
      ;;
  esac

  if [ "$DEVICE_KIND" = "pico" ] && [ "$EXPECT_AUDIO_WAS_SET" != "1" ]; then
    # The current PICO camera path captures RGB via XR_PICO_camera_image and
    # explicitly disables Android AudioRecord in capture_app.gd.
    EXPECT_AUDIO=0
  fi
  if [ "$DEVICE_KIND" = "pico" ] && [ "${DEVICE_ROOT+x}" != "x" ]; then
    REMOTE_CAPTURE_ROOT="/sdcard/DCIM/SpatialMP4"
  fi
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
    --serial) ADB_SERIAL_OVERRIDE="$2"; shift 2 ;;
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

case "$OUTPUT_DIR" in
  /*) ;;
  *) OUTPUT_DIR="$ROOT/$OUTPUT_DIR" ;;
esac
CLEAN_APK_PATH="$OUTPUT_DIR/Operator-clean.apk"

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
    warn "using system ffprobe; MP4 packet payloads will be validated through generic demuxing"
  else
    FFPROBE=""
    warn "ffprobe not found; self-contained MP4 metadata validation cannot run"
  fi
}

pick_device() {
  local override
  override="$ADB_SERIAL_OVERRIDE"
  if [ -z "$override" ] && [ "$DEVICE_KIND" = "pico" ]; then
    override="$PICO_SERIAL"
  fi
  if [ -z "$override" ] && [ "$DEVICE_KIND" = "quest" ]; then
    override="$QUEST_SERIAL"
  fi
  if [ -z "$override" ]; then
    # Backward compatibility for older invocations that used QUEST_SERIAL as a
    # generic serial override even when --device pico is selected.
    override="$QUEST_SERIAL"
  fi
  if [ -n "$override" ]; then
    echo "$override"
    return
  fi
  local device_lines
  device_lines=$("$ADB" devices -l | awk 'NR>1 && $2=="device" {print}' || true)
  if [ -z "$device_lines" ]; then
    err "no adb device attached; set ADB_SERIAL/PICO_SERIAL/QUEST_SERIAL to override"
    exit 1
  fi

  local matches=()
  local line serial
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    serial="$(awk '{print $1}' <<< "$line")"
    if adb_device_matches_kind "$serial" "$line"; then
      matches+=("$serial")
    fi
  done <<< "$device_lines"

  if [ "${#matches[@]}" -eq 1 ]; then
    echo "${matches[0]}"
    return
  fi
  if [ "${#matches[@]}" -gt 1 ]; then
    err "multiple adb devices match --device $DEVICE_KIND: ${matches[*]}; pass --serial"
    exit 1
  fi

  local device_count
  device_count="$(wc -l <<< "$device_lines" | tr -d ' ')"
  if [ "$device_count" = "1" ]; then
    awk '{print $1}' <<< "$device_lines"
    return
  fi

  err "no adb device matches --device $DEVICE_KIND; pass --serial"
  printf '%s\n' "$device_lines" >&2
  exit 1
}

adb_device_matches_kind() {
  local serial="$1"
  local device_line="$2"
  local props text
  props=$("$ADB" -s "$serial" shell 'printf "%s %s %s %s %s\n" "$(getprop ro.product.manufacturer)" "$(getprop ro.product.brand)" "$(getprop ro.product.model)" "$(getprop ro.product.device)" "$(getprop ro.product.name)"' </dev/null 2>/dev/null | tr -d '\r' || true)
  text="$(printf '%s %s\n' "$device_line" "$props" | tr '[:upper:]' '[:lower:]')"
  case "$DEVICE_KIND" in
    pico)
      grep -Eq 'pico|picovr' <<< "$text"
      ;;
    quest)
      grep -Eq 'quest|oculus|meta|eureka|panther|seacliff|hollywood' <<< "$text"
      ;;
    *)
      return 1
      ;;
  esac
}

log_device_identity() {
  {
    echo "serial=$SERIAL"
    run_adb shell 'printf "manufacturer=%s\nbrand=%s\nmodel=%s\ndevice=%s\nproduct=%s\n" "$(getprop ro.product.manufacturer)" "$(getprop ro.product.brand)" "$(getprop ro.product.model)" "$(getprop ro.product.device)" "$(getprop ro.product.name)"' 2>/dev/null | tr -d '\r'
  } | tee "$OUTPUT_DIR/adb-device-props.txt"
}

restore_auto_start() {
  if [ -n "${CAPTURE_APP_GD_BAK:-}" ] && [ -f "$CAPTURE_APP_GD_BAK" ]; then
    cp "$CAPTURE_APP_GD_BAK" "$CAPTURE_APP_GD"
    rm -f "$CAPTURE_APP_GD_BAK"
    CAPTURE_APP_GD_BAK=""
    ok "restored xr/scripts/app/modes/capture_app_base.gd"
  fi
}

flip_auto_start_on() {
  if [ ! -f "$CAPTURE_APP_GD" ]; then
    err "capture_app_base.gd not found at $CAPTURE_APP_GD"
    exit 2
  fi
  local stop_value="$CAPTURE_SECONDS"
  case "$stop_value" in
    *.*) ;;
    *) stop_value="${stop_value}.0" ;;
  esac
  local record_audio_value="false"
  if [ "$EXPECT_AUDIO" = "1" ]; then
    record_audio_value="true"
  fi
  local record_body_tracking_value="false"
  if [ "$EXPECT_BODY_TRACKING" = "1" ]; then
    record_body_tracking_value="true"
  fi
  local record_motion_trackers_value="false"
  if [ "$EXPECT_MOTION_TRACKERS" = "1" ]; then
    record_motion_trackers_value="true"
  fi
  CAPTURE_APP_GD_BAK="$(mktemp -t operator_capture_app_gd.XXXXXX)"
  cp "$CAPTURE_APP_GD" "$CAPTURE_APP_GD_BAK"
  "$PYTHON" - "$CAPTURE_APP_GD" "$stop_value" "$record_audio_value" "$record_body_tracking_value" "$record_motion_trackers_value" "$AUDIO_CHANNEL_LAYOUT" "$AUDIO_SAMPLE_RATE_HZ" "$AUDIO_BITRATE_BPS" "$EXPECT_RGB_CODEC" "$EXPECT_RGB_RESOLUTION" "$EXPECT_RGB_FPS" <<'PY'
from __future__ import annotations

import sys
from pathlib import Path

path = Path(sys.argv[1])
stop_value = sys.argv[2]
record_audio = sys.argv[3]
record_body_tracking = sys.argv[4]
record_motion_trackers = sys.argv[5]
layout = sys.argv[6]
sample_rate = sys.argv[7]
bitrate = sys.argv[8]
raw_rgb_codec = sys.argv[9]
raw_rgb_resolution = sys.argv[10].strip()
raw_rgb_fps = sys.argv[11]


def normalize_codec(raw: str) -> str:
    value = raw.strip().lower()
    if value in {"h264", "h.264", "avc", "video/avc"}:
        return "h264"
    if value in {"hevc", "h265", "h.265", "video/hevc"}:
        return "hevc"
    raise SystemExit(f"unsupported EXPECT_RGB_CODEC: {raw!r}")


def parse_positive_int(raw: str, name: str) -> int:
    try:
        value = int(float(raw))
    except ValueError as exc:
        raise SystemExit(f"{name} must be numeric: {raw!r}") from exc
    if value <= 0:
        raise SystemExit(f"{name} must be > 0: {raw!r}")
    return value


rgb_codec = normalize_codec(raw_rgb_codec)
rgb_fps = parse_positive_int(raw_rgb_fps, "EXPECT_RGB_FPS")
rgb_width = 0
rgb_height = 0
if raw_rgb_resolution:
    parts = raw_rgb_resolution.lower().split("x", 1)
    if len(parts) != 2:
        raise SystemExit(f"EXPECT_RGB_RESOLUTION must look like 1280x960: {raw_rgb_resolution!r}")
    rgb_width = parse_positive_int(parts[0], "EXPECT_RGB_RESOLUTION width")
    rgb_height = parse_positive_int(parts[1], "EXPECT_RGB_RESOLUTION height")
    raw_rgb_resolution = f"{rgb_width}x{rgb_height}"

text = path.read_text()
text = text.replace(
    "const AUTO_START_FOR_DEVICE_TEST := false",
    "const AUTO_START_FOR_DEVICE_TEST := true",
    1,
)
text = text.replace(
    "const AUTO_STOP_AFTER_SECONDS := 12.0",
    f"const AUTO_STOP_AFTER_SECONDS := {stop_value}",
    1,
)
needle = '\t\tcapture_options["interaction_mode"] = "head"\n'
injected = (
    needle
    + f'\t\tcapture_options["record_audio"] = {record_audio}\n'
    + f'\t\tcapture_options["record_body_tracking"] = {record_body_tracking}\n'
    + f'\t\tcapture_options["record_motion_trackers"] = {record_motion_trackers}\n'
    + f'\t\tcapture_options["audio_channel_layout"] = "{layout}"\n'
    + f'\t\tcapture_options["audio_sample_rate_hz"] = {sample_rate}\n'
    + f'\t\tcapture_options["audio_bitrate_bps"] = {bitrate}\n'
    + f'\t\tcapture_options["rgb_codec"] = "{rgb_codec}"\n'
    + f'\t\tcapture_options["rgb_fps"] = {rgb_fps}\n'
)
if raw_rgb_resolution:
    injected += (
        f'\t\tcapture_options["rgb_width"] = {rgb_width}\n'
        f'\t\tcapture_options["rgb_height"] = {rgb_height}\n'
        f'\t\tcapture_options["rgb_resolution"] = "{raw_rgb_resolution}"\n'
    )
if needle not in text:
    raise SystemExit("AUTO_START_FOR_DEVICE_TEST capture_options hook not found")
text = text.replace(needle, injected, 1)

# CI-only: defer start_capture() until Quest head-pose tracking is stable.
# In the AUTO_START_FOR_DEVICE_TEST branch _ready() fires call_deferred(
# "start_capture") within ~4s of process launch, but Quest's TrackingLostMgr
# may still be reporting "tracking lost" at that point (it typically only
# resumes ~5s post-launch). Opening the RGB camera + audio + body tracker
# while tracking is still lost causes vrshell to steal focus to show the
# guardianless-app NUX, which triggers APPLICATION_PAUSED, which the existing
# _notification PAUSE handler treats as "headset doffed -> finalize". Real
# users never hit this race because they click Record manually well after
# tracking has settled. Wait for tracking-confidence != NONE for 0.75s of
# stable readings (15s timeout fallback so the test cannot hang forever).
start_capture_needle = (
    '\t\tcall_deferred("start_capture")\n'
    '\t\t_schedule_auto_stop_for_device_test(AUTO_STOP_AFTER_SECONDS)\n'
)
start_capture_replacement = (
    '\t\t_ci_start_when_tracking_stable()\n'
    '\t\t_schedule_auto_stop_for_device_test(AUTO_STOP_AFTER_SECONDS)\n'
)
if start_capture_needle not in text:
    raise SystemExit(
        "AUTO_START_FOR_DEVICE_TEST start_capture hook not found"
    )
text = text.replace(start_capture_needle, start_capture_replacement, 1)

# CI-only: do not finalize on the first APPLICATION_PAUSED. Quest sends
# transient PAUSEs whenever vrshell steals focus (guardian NUX, system
# toasts, focus loss). Production code never enters this branch because
# AUTO_START_FOR_DEVICE_TEST defaults to false. We record the pause
# timestamp instead and only finalize on RESUMED if the pause persisted
# longer than 30s (the "headset actually doffed" case the original handler
# was guarding against).
pause_needle = (
    '\tif what == NOTIFICATION_APPLICATION_PAUSED and _recording:\n'
    '\t\tprint("AUTO_STOP_FOR_DEVICE_TEST: paused, finalizing recording")\n'
    '\t\tstop_capture()\n'
)
pause_replacement = (
    '\tif what == NOTIFICATION_APPLICATION_PAUSED and _recording:\n'
    '\t\t_ci_paused_at_unix_us = int(Time.get_unix_time_from_system() * 1000000.0)\n'
    '\t\tprint("AUTO_STOP_FOR_DEVICE_TEST: paused (deferring finalize, awaiting RESUMED)")\n'
    '\telif what == NOTIFICATION_APPLICATION_RESUMED and _recording and _ci_paused_at_unix_us > 0:\n'
    '\t\tvar paused_s := float(int(Time.get_unix_time_from_system() * 1000000.0) - _ci_paused_at_unix_us) / 1000000.0\n'
    '\t\t_ci_paused_at_unix_us = 0\n'
    '\t\tprint("AUTO_STOP_FOR_DEVICE_TEST: resumed after %.2fs pause" % paused_s)\n'
    '\t\tif paused_s > 30.0:\n'
    '\t\t\tprint("AUTO_STOP_FOR_DEVICE_TEST: pause exceeded 30s, finalizing")\n'
    '\t\t\tstop_capture()\n'
)
if pause_needle not in text:
    raise SystemExit("AUTO_STOP_FOR_DEVICE_TEST pause hook not found")
text = text.replace(pause_needle, pause_replacement, 1)

# CI-only: helper functions + state variable used by the two patches above.
# Appended at file scope so GDScript parses them as part of the class.
text += '''

# --- CI test scaffolding injected by tests/02_ego_record.sh ---

var _ci_paused_at_unix_us: int = 0


func _ci_start_when_tracking_stable() -> void:
\tprint("AUTO_START_FOR_DEVICE_TEST: waiting for XR head pose to stabilize")
\tvar wait_start_us := Time.get_ticks_usec()
\tvar stable_start_us := 0
\tvar timeout_us := 15 * 1000000
\tvar stable_us := 750 * 1000
\twhile is_inside_tree() and Time.get_ticks_usec() - wait_start_us < timeout_us:
\t\tif _ci_xr_head_pose_confident():
\t\t\tif stable_start_us <= 0:
\t\t\t\tstable_start_us = Time.get_ticks_usec()
\t\t\telif Time.get_ticks_usec() - stable_start_us >= stable_us:
\t\t\t\tvar waited_s := float(Time.get_ticks_usec() - wait_start_us) / 1000000.0
\t\t\t\tprint("AUTO_START_FOR_DEVICE_TEST: XR tracking stable after %.2fs" % waited_s)
\t\t\t\tstart_capture()
\t\t\t\treturn
\t\telse:
\t\t\tstable_start_us = 0
\t\tawait get_tree().create_timer(0.1).timeout
\tpush_warning("AUTO_START_FOR_DEVICE_TEST: tracking stability wait timed out; starting capture anyway")
\tstart_capture()


func _ci_xr_head_pose_confident() -> bool:
\tvar tracker := XRServer.get_tracker(&"head")
\tif not (tracker is XRPositionalTracker):
\t\treturn false
\tvar positional := tracker as XRPositionalTracker
\tif not positional.has_pose(&"default"):
\t\treturn false
\tvar pose := positional.get_pose(&"default")
\tif pose == null:
\t\treturn false
\treturn int(pose.get_tracking_confidence()) != XRPose.XR_TRACKING_CONFIDENCE_NONE
'''

path.write_text(text)
PY
  if [ "$EXPECT_AUDIO" = "1" ]; then
    ok "enabled AUTO_START_FOR_DEVICE_TEST for ${CAPTURE_SECONDS}s with audio ${AUDIO_CHANNEL_LAYOUT}/${AUDIO_SAMPLE_RATE_HZ}Hz, rgb=${EXPECT_RGB_CODEC}/${EXPECT_RGB_RESOLUTION:-default}/${EXPECT_RGB_FPS}fps, body=${EXPECT_BODY_TRACKING}, motion=${EXPECT_MOTION_TRACKERS}"
  else
    ok "enabled AUTO_START_FOR_DEVICE_TEST for ${CAPTURE_SECONDS}s, rgb=${EXPECT_RGB_CODEC}/${EXPECT_RGB_RESOLUTION:-default}/${EXPECT_RGB_FPS}fps, body=${EXPECT_BODY_TRACKING}, motion=${EXPECT_MOTION_TRACKERS}"
  fi
}

build_clean_apk() {
  # Reuse the cached production APK if it already exists. APK_PATH is set per
  # platform by configure_device_kind (quest: xr/build/quest/Operator.apk,
  # pico: xr/build/pico/Operator.apk), so the same check covers both. Saves
  # ~3-6 min per test run; the CI-patched build that follows always rebuilds
  # via flip_auto_start_on, so the source state on disk remains clean.
  if [ -f "$APK_PATH" ]; then
    step "Reuse existing clean ${DEVICE_KIND} APK ($APK_PATH)"
    cp -f "$APK_PATH" "$CLEAN_APK_PATH"
    CLEAN_APK_READY=1
    ok "clean APK reused from $APK_PATH"
    return 0
  fi
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
  # Move the CI-patched output to its own path so the clean APK at
  # $APK_PATH is never overwritten across runs. The next call to
  # build_clean_apk can then safely fast-path on $APK_PATH existence.
  mv -f "$APK_PATH" "$CI_APK_PATH"
  if [ "$CLEAN_APK_READY" = "1" ] && [ -f "$CLEAN_APK_PATH" ]; then
    cp -f "$CLEAN_APK_PATH" "$APK_PATH"
  fi
  ok "CI APK ready: $CI_APK_PATH"
}

install_ci_apk() {
  step "Install CI APK"
  # Native libraries are stored uncompressed and mmap'd directly from the APK.
  # A streamed/incremental reinstall over the same versionCode can leave their
  # offsets stale, making libspatialmp4_writer.so unloadable and preventing MP4
  # creation. Match xr/Makefile and always force a full APK push.
  run_adb install --no-incremental -r -d "$CI_APK_PATH" 2>&1 | tee "$OUTPUT_DIR/adb-install.log"
  DEVICE_NEEDS_CLEAN=1
  ok "installed $PKG (CI) on $SERIAL"
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
  if run_adb install --no-incremental -r -d "$CLEAN_APK_PATH" 2>&1 | tee "$OUTPUT_DIR/adb-reinstall-clean.log"; then
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
    android.permission.RECORD_AUDIO \
    horizonos.permission.HEADSET_CAMERA \
    horizonos.permission.AVATAR_CAMERA \
    com.oculus.permission.USE_SCENE \
    horizonos.permission.USE_SCENE \
	com.picovr.permission.CAMERA \
	com.picovr.permission.HAND_TRACKING \
	com.picovr.permission.HEAD_TRACKER \
    com.picovr.permission.SPATIAL_DATA \
    com.pico.permission.CAMERA_DATA \
    android.permission.READ_EXTERNAL_STORAGE \
    android.permission.WRITE_EXTERNAL_STORAGE
  do
    run_adb shell pm grant "$PKG" "$perm" >/dev/null 2>&1 || true
  done
  run_adb shell appops set "$PKG" MANAGE_EXTERNAL_STORAGE allow >/dev/null 2>&1 || true
  run_adb shell cmd appops set "$PKG" MANAGE_EXTERNAL_STORAGE allow >/dev/null 2>&1 || true
  run_adb shell appops set "$PKG" LEGACY_STORAGE allow >/dev/null 2>&1 || true
  run_adb shell appops set "$PKG" RECORD_AUDIO allow >/dev/null 2>&1 || true
  run_adb shell cmd appops set "$PKG" RECORD_AUDIO allow >/dev/null 2>&1 || true
  run_adb shell appops set "$PKG" USE_SCENE allow >/dev/null 2>&1 || true
  run_adb shell appops set "$PKG" HEADSET_CAMERA allow >/dev/null 2>&1 || true
  run_adb shell appops set "$PKG" AVATAR_CAMERA allow >/dev/null 2>&1 || true
  run_adb shell appops set "$PKG" CAMERA allow >/dev/null 2>&1 || true
  run_adb shell cmd appops set "$PKG" CAMERA allow >/dev/null 2>&1 || true
}

ensure_screen_awake() {
  local state
  run_adb shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
  run_adb shell wm dismiss-keyguard >/dev/null 2>&1 || true
  state="$(run_adb shell dumpsys power 2>/dev/null | grep -m1 -E 'Display Power|mWakefulness' || true)"
  if grep -q -E 'ON|Awake' <<< "$state"; then
    ok "screen is on"
    return
  fi
  run_adb shell input keyevent KEYCODE_POWER >/dev/null 2>&1 || true
  sleep 3
  state="$(run_adb shell dumpsys power 2>/dev/null | grep -m1 -E 'Display Power|mWakefulness' || true)"
  if grep -q -E 'ON|Awake' <<< "$state"; then
    ok "screen woke up"
  else
    warn "screen wake state is unclear: ${state:-<empty>}"
  fi
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
  # Keep the headset's Guardian and permission services alive. Force-stopping
  # them leaves current Horizon OS builds in GuardianSetupFlow, where
  # ClearActivity covers the app before Godot can start the capture scene.
  ensure_screen_awake
  run_adb shell am broadcast -a com.oculus.vrpowermanager.prox_close >/dev/null 2>&1 || true
  dismiss_system_dialogs
  run_adb logcat -c
  ok "device prepared"
}

start_ego_activity() {
  run_adb shell am force-stop "$PKG" >/dev/null 2>&1 || true
  if [ "$DEVICE_KIND" = "quest" ]; then
    # Explicit display 0 avoids Horizon OS's asynchronous VR display resolver,
    # which can otherwise leave adb launches pending until its 10s timeout.
    run_adb shell am start --display 0 -n "$PKG/$ACT" --es operator.mode ego >/dev/null
  else
    run_adb shell am start -n "$PKG/$ACT" --es operator.mode ego >/dev/null
  fi
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
    # produce a saved path. Treat that as a real stop so validation can report
    # the missing/invalid MP4 instead of timing out.
    return 0
  fi
  if printf '%s\n' "$path" | grep -q '\.mp4$'; then
    REMOTE_FINAL_MP4="$path"
    # The current layout finalizes inside REMOTE_SESSION_DIR. Keep the capture
    # root learned from the start marker; dirname(mp4) is now the session dir.
    if [ -z "$REMOTE_SESSION_DIR" ]; then
      REMOTE_SESSION_DIR="$(dirname "$path")"
      REMOTE_CAPTURE_ROOT="$(dirname "$REMOTE_SESSION_DIR")"
    fi
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
      run_adb shell am broadcast -a com.oculus.vrpowermanager.prox_close >/dev/null 2>&1 || true
      dismiss_system_dialogs
      start_ego_activity || true
    fi
    if logcat_contains "Quest passthrough Camera2 is unavailable on this Horizon OS build"; then
      err "Quest passthrough Camera2 is unavailable; update the headset to Horizon OS v76 or newer"
      logcat_dump > "$OUTPUT_DIR/logcat-start-failed.log"
      exit 3
    fi
    if logcat_contains "QuestCapturePlugin camera start failed"; then
      err "Quest camera capture failed before the MP4 writer could start"
      logcat_dump > "$OUTPUT_DIR/logcat-start-failed.log"
      exit 3
    fi
    sleep 1
  done
  err "timed out waiting for capture start"
  logcat_dump > "$OUTPUT_DIR/logcat-start-timeout.log"
  exit 3
}

remote_final_mp4s() {
  {
    if [ -n "$REMOTE_SESSION_DIR" ]; then
      run_adb shell "ls '$REMOTE_SESSION_DIR'/*.mp4 2>/dev/null" || true
    fi
    # Historical recordings stored the MP4 beside the session directory.
    run_adb shell "ls '$REMOTE_CAPTURE_ROOT'/*.mp4 2>/dev/null" || true
  } | tr -d '\r' | grep -v '\.partial\.mp4$' || true
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
  "$PYTHON" - "$local_root" "${FFPROBE:-}" "$CAPTURE_SECONDS" "$MIN_MP4_BYTES" "$MIN_RGB_FRAMES" "$MIN_RGB_FPS" "$EXPECTED_DEVICE_PREFIX" "$EXPECT_AUDIO" "$EXPECT_BODY_TRACKING" "$EXPECT_MOTION_TRACKERS" "$EXPECT_RGB_CODEC" "$EXPECT_RGB_RESOLUTION" "$EXPECT_RGB_FPS" "$SKIP_DEVICE" <<'PY'
from __future__ import annotations

import json
import re
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
expect_audio = (sys.argv[8] if len(sys.argv) > 8 else "0") == "1"
expect_body_tracking = (sys.argv[9] if len(sys.argv) > 9 else "0") == "1"
expect_motion_trackers = (sys.argv[10] if len(sys.argv) > 10 else "0") == "1"
expected_rgb_resolution = (sys.argv[12] if len(sys.argv) > 12 else "").strip().lower()
expected_rgb_fps = float(sys.argv[13] if len(sys.argv) > 13 else "30")
allow_legacy_layout = (sys.argv[14] if len(sys.argv) > 14 else "0") == "1"
dense_start_limit_us = 750_000 if expected_device_prefix == "pico" else 500_000
dense_start_limit_ms = dense_start_limit_us // 1000

checks: list[tuple[str, str, str]] = []
_FFPROBE_HEXDUMP_OFFSET_RE = re.compile(r"^\s*[0-9a-fA-F]+$")


def normalize_codec(raw: str | None) -> str:
    value = str(raw or "").strip().lower()
    if value in {"h264", "h.264", "avc", "video/avc"}:
        return "h264"
    if value in {"hevc", "h265", "h.265", "video/hevc"}:
        return "hevc"
    return value


expected_rgb_codec = normalize_codec(sys.argv[11] if len(sys.argv) > 11 else "hevc")


def rgb_codec_label(codec: str) -> str:
    return "H.264" if normalize_codec(codec) == "h264" else "HEVC"


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


def pick_latest_session(root: Path) -> tuple[Path, Path]:
    candidates: list[tuple[float, Path, Path]] = []
    for child in root.iterdir():
        if not child.is_dir():
            continue
        # Current layout first, then the historical sibling layout so old
        # pulled recordings remain inspectable by this validator.
        for mp4 in (child / f"{child.name}.mp4", root / f"{child.name}.mp4"):
            if mp4.exists():
                candidates.append((max(child.stat().st_mtime, mp4.stat().st_mtime), child, mp4))
    if not candidates:
        names = ", ".join(sorted(p.name for p in root.iterdir())) if root.exists() else "<missing>"
        raise FileNotFoundError(f"no session directory with a matching MP4 under {root}; got {names}")
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


def run_ffprobe_json(path: Path, args: list[str], context: str) -> dict[str, Any] | None:
    if not ffprobe:
        failed(f"ffprobe reads {context}", "ffprobe unavailable")
        return None
    try:
        out = subprocess.run(
            [ffprobe, "-v", "error", *args, "-of", "json", str(path)],
            check=True,
            capture_output=True,
            text=True,
            timeout=45,
        )
        return json.loads(out.stdout or "{}")
    except Exception as exc:
        failed(f"ffprobe reads {context}", str(exc))
        return None


def bytes_from_ffprobe_hexdump(dump: str) -> bytes:
    raw = bytearray()
    for line in dump.splitlines():
        if ":" not in line:
            continue
        offset, rest = line.split(":", 1)
        if _FFPROBE_HEXDUMP_OFFSET_RE.match(offset) is None:
            continue
        if rest.startswith(" "):
            rest = rest[1:]
        hex_columns = rest.split("  ", 1)[0]
        hex_text = re.sub(r"[^0-9a-fA-F]", "", hex_columns)
        if len(hex_text) % 2 == 1:
            hex_text = hex_text[:-1]
        if hex_text:
            raw.extend(bytes.fromhex(hex_text))
    return bytes(raw)


def decode_json_packet(raw: bytes) -> dict[str, Any] | None:
    text = raw.decode("utf-8-sig", errors="replace").strip("\x00 \t\r\n")
    if not text:
        return None
    start = text.find("{")
    end = text.rfind("}")
    if start < 0 or end < start:
        return None
    try:
        decoded = json.loads(text[start : end + 1])
    except json.JSONDecodeError:
        return None
    return decoded if isinstance(decoded, dict) else None


def stream_labels(stream: dict[str, Any]) -> list[str]:
    labels: list[str] = []
    tags = stream.get("tags") if isinstance(stream.get("tags"), dict) else {}
    for key in ("handler_name", "metadata_kind", "track_id", "payload_schema", "mime_type", "title", "comment"):
        value = tags.get(key)
        if value is not None:
            labels.append(str(value))
    for value in tags.values():
        if value is not None:
            labels.append(str(value))
    for key in ("codec_tag_string", "codec_name"):
        value = stream.get(key)
        if value is not None:
            labels.append(str(value))
    return labels


def find_rgb_stream(streams: list[dict[str, Any]], codec: str) -> dict[str, Any] | None:
    if normalize_codec(codec) == "h264":
        codec_names = {"h264"}
        codec_tags = {"avc1", "avc3"}
    else:
        codec_names = {"hevc"}
        codec_tags = {"hev1", "hvc1"}
    for stream in streams:
        codec_name = str(stream.get("codec_name", "")).lower()
        codec_tag = str(stream.get("codec_tag_string", "")).lower()
        if codec_name in codec_names or codec_tag in codec_tags:
            return stream
    return None


def looks_like_metadata_kind(stream: dict[str, Any], kind: str) -> bool:
    needle = kind.strip().lower()
    for label in stream_labels(stream):
        normalized = label.strip().lower()
        if normalized.startswith(f"spatialmp4:{needle}:"):
            return True
        if normalized == needle:
            return True
        if needle in normalized and ("spatialmp4" in normalized or "operator" in normalized):
            return True
    return False


def metadata_streams(mp4_info: dict[str, Any] | None, kind: str) -> list[tuple[int, str]]:
    result: list[tuple[int, str]] = []
    streams = (mp4_info or {}).get("streams") or []
    for stream in streams:
        if not isinstance(stream, dict) or not looks_like_metadata_kind(stream, kind):
            continue
        tags = stream.get("tags") if isinstance(stream.get("tags"), dict) else {}
        handler = str(tags.get("handler_name", ""))
        track_id = kind
        if handler.startswith("spatialmp4:"):
            parts = handler.split(":", 2)
            if len(parts) == 3 and parts[2]:
                track_id = parts[2]
        elif tags.get("track_id") is not None:
            track_id = str(tags.get("track_id"))
        try:
            result.append((int(stream["index"]), track_id))
        except (KeyError, TypeError, ValueError):
            continue
    return result


def load_json_metadata_frames(mp4: Path, mp4_info: dict[str, Any] | None, kind: str) -> dict[str, list[dict[str, Any]]]:
    frames_by_track: dict[str, list[dict[str, Any]]] = {}
    streams = metadata_streams(mp4_info, kind)
    if not streams:
        return frames_by_track
    for stream_index, track_id in streams:
        packets_json = run_ffprobe_json(
            mp4,
            ["-select_streams", str(stream_index), "-show_packets", "-show_data"],
            f"{kind} packets",
        )
        packets = packets_json.get("packets", []) if isinstance(packets_json, dict) else []
        frames: list[dict[str, Any]] = []
        for packet in packets:
            if not isinstance(packet, dict):
                continue
            data = packet.get("data")
            if not isinstance(data, str):
                continue
            decoded = decode_json_packet(bytes_from_ffprobe_hexdump(data))
            if decoded is None:
                continue
            try:
                decoded["_packet_pts_time"] = float(packet.get("pts_time", "0"))
            except (TypeError, ValueError):
                decoded["_packet_pts_time"] = 0.0
            frames.append(decoded)
        if frames:
            frames_by_track[track_id] = frames
    return frames_by_track


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


def audio_channel_count_for_layout(layout: str) -> int:
    if layout == "mono":
        return 1
    if layout in ("foa_acn_sn3d", "raw_4ch"):
        return 4
    return 2


def effective_audio_layout_for_request(layout: str) -> str:
    if layout in ("mono", "stereo"):
        return layout
    if layout in ("foa_acn_sn3d", "raw_4ch"):
        # Mirrors SessionSpoolWriter: the current Android AudioRecord path
        # falls back to stereo until a true 4-channel/FOA provider is wired.
        return "stereo"
    return "stereo"


def wants_depth(options: dict[str, Any]) -> bool:
    return options.get("record_depth") is True


def wants_stereo_rgb(options: dict[str, Any]) -> bool:
    return options.get("stereo_rgb", True) is True


def wants_head_pose(options: dict[str, Any]) -> bool:
    return options.get("record_head_pose", True) is True


def check_required_files(session_dir: Path, mp4: Path, options: dict[str, Any]) -> None:
    required = ["manifest.json"]
    forbidden_legacy_artifacts = [
        "android_timebase.json",
        "left_camera_characteristics.json",
        "right_camera_characteristics.json",
        "left_camera_frames.jsonl",
        "right_camera_frames.jsonl",
        "depth/frames.jsonl",
        "poses/head.jsonl",
        "poses/controllers.jsonl",
        "body_motion/body.jsonl",
        "body_motion/motion_trackers.jsonl",
    ]
    for rel in required:
        path = session_dir / rel
        if path.exists() and path.stat().st_size > 0:
            passed(f"file present: {rel}")
        else:
            failed(f"file present: {rel}", str(path))
    for rel in forbidden_legacy_artifacts:
        path = session_dir / rel
        if path.exists():
            failed(f"legacy debug artifact is not written: {rel}", str(path))
        else:
            passed(f"legacy debug artifact is not written: {rel}")
    if mp4.parent == session_dir:
        passed("MP4 co-located with session files", str(session_dir))
    elif allow_legacy_layout:
        warned("MP4 uses historical sibling layout", f"mp4={mp4} session={session_dir}")
    else:
        failed("MP4 co-located with session files", f"mp4={mp4} session={session_dir}")
    if mp4.exists() and mp4.stat().st_size >= min_mp4_bytes:
        passed("final MP4 size", f"{mp4.stat().st_size:,} bytes")
    elif mp4.exists():
        failed("final MP4 size", f"{mp4.stat().st_size:,} bytes < {min_mp4_bytes:,}")
    else:
        failed("final MP4 exists", str(mp4))


def check_manifest(manifest: dict[str, Any]) -> dict[str, Any]:
    if manifest.get("schema") == "spatialmp4.quest_capture.spool.v3":
        passed("manifest schema is spool.v3")
    else:
        failed("manifest schema is spool.v3", repr(manifest.get("schema")))
    if manifest.get("media_pts_domain") == "godot_ticks_ns":
        passed("manifest media_pts_domain is godot_ticks_ns")
    else:
        failed("manifest media_pts_domain is godot_ticks_ns", repr(manifest.get("media_pts_domain")))
    if manifest.get("media_pts_clock") == "clock_monotonic_ns":
        passed("manifest media_pts_clock is clock_monotonic_ns")
    else:
        failed("manifest media_pts_clock is clock_monotonic_ns", repr(manifest.get("media_pts_clock")))
    options = manifest.get("capture_options") or {}
    for key in ("stereo_rgb", "record_head_pose"):
        if options.get(key) is True:
            passed(f"capture option {key}=true")
        else:
            failed(f"capture option {key}=true", repr(options.get(key)))
    if expected_device_prefix == "pico":
        if options.get("record_depth") is False:
            passed("capture option record_depth=false for pico")
        elif options.get("record_depth") is True:
            passed("capture option record_depth=true")
        else:
            failed("capture option record_depth is boolean", repr(options.get("record_depth")))
    elif options.get("record_depth") is True:
        passed("capture option record_depth=true")
    else:
        failed("capture option record_depth=true", repr(options.get("record_depth")))
    for key, expected in (
        ("record_body_tracking", expect_body_tracking),
        ("record_motion_trackers", expect_motion_trackers),
    ):
        if expected:
            if options.get(key) is True:
                passed(f"capture option {key}=true")
            else:
                failed(f"capture option {key}=true", repr(options.get(key)))
        elif options.get(key) is False:
            passed(f"capture option {key}=false")
        elif options.get(key) is True:
            warned(
                f"capture option {key}=true",
                "CI tracker validation disabled; set EXPECT_BODY_TRACKING/EXPECT_MOTION_TRACKERS=1 for tracker coverage",
            )
        else:
            failed(
                f"capture option {key} is boolean",
                repr(options.get(key)),
            )
    observed_codec = normalize_codec(str(options.get("rgb_codec", "")))
    if observed_codec == expected_rgb_codec:
        passed("capture option rgb_codec", observed_codec)
    else:
        failed("capture option rgb_codec", f"{observed_codec!r} != {expected_rgb_codec!r}")
    if expected_rgb_resolution:
        requested_resolution = str(options.get("rgb_resolution", "")).strip().lower()
        if requested_resolution == expected_rgb_resolution:
            passed("capture option rgb_resolution", requested_resolution)
        else:
            failed("capture option rgb_resolution", f"{requested_resolution!r} != {expected_rgb_resolution!r}")
    try:
        requested_fps = float(options.get("rgb_fps") or 0)
    except (TypeError, ValueError):
        requested_fps = 0.0
    if abs(requested_fps - expected_rgb_fps) < 0.001:
        passed("capture option rgb_fps", f"{requested_fps:g}")
    else:
        failed("capture option rgb_fps", f"{requested_fps:g} != {expected_rgb_fps:g}")
    if expect_audio:
        if options.get("record_audio") is True:
            passed("capture option record_audio=true")
        else:
            failed("capture option record_audio=true", repr(options.get("record_audio")))
        requested_layout = str(options.get("audio_channel_layout", ""))
        if requested_layout:
            passed("capture option audio_channel_layout set", requested_layout)
        else:
            failed("capture option audio_channel_layout set", repr(requested_layout))
        if int(options.get("audio_sample_rate_hz") or 0) > 0:
            passed("capture option audio_sample_rate_hz set", str(options.get("audio_sample_rate_hz")))
        else:
            failed("capture option audio_sample_rate_hz set", repr(options.get("audio_sample_rate_hz")))
        if int(options.get("audio_bitrate_bps") or 0) > 0:
            passed("capture option audio_bitrate_bps set", str(options.get("audio_bitrate_bps")))
        else:
            failed("capture option audio_bitrate_bps set", repr(options.get("audio_bitrate_bps")))

        sources = manifest.get("sources") or {}
        audio_source = sources.get("audio")
        if isinstance(audio_source, dict):
            passed("manifest sources.audio present")
            expected_layout = effective_audio_layout_for_request(requested_layout)
            expected_channels = audio_channel_count_for_layout(expected_layout)
            if audio_source.get("codec") == "aac_lc":
                passed("manifest audio codec is aac_lc")
            else:
                failed("manifest audio codec is aac_lc", repr(audio_source.get("codec")))
            if audio_source.get("channel_layout") == expected_layout:
                passed("manifest audio channel_layout", expected_layout)
            else:
                failed("manifest audio channel_layout", repr(audio_source.get("channel_layout")))
            if int(audio_source.get("channel_count") or 0) == expected_channels:
                passed("manifest audio channel_count", str(expected_channels))
            else:
                failed("manifest audio channel_count", repr(audio_source.get("channel_count")))
        else:
            failed("manifest sources.audio present", repr(audio_source))
    return options


def check_timebase(timebase: dict[str, Any], label: str = "android_timebase") -> None:
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
            passed(f"{label} has {key}")
        else:
            failed(f"{label} has {key}")
    if timebase.get("rgb_timestamp_domain") != "godot_ticks_ns":
        failed(f"{label} rgb timestamp domain", repr(timebase.get("rgb_timestamp_domain")))
    if timebase.get("openxr_xr_time_domain") != "clock_monotonic_ns":
        failed(f"{label} OpenXR time domain", repr(timebase.get("openxr_xr_time_domain")))


def check_rgb_index_rows(rows: list[dict[str, Any]], eye: str, timebase: dict[str, Any], label: str) -> None:
    if len(rows) >= min_rgb_frames:
        passed(f"{label} count", f"{len(rows)} >= {min_rgb_frames}")
    else:
        failed(f"{label} count", f"{len(rows)} < {min_rgb_frames}")
        return
    indices = [r.get("frame_index") for r in rows]
    if indices == list(range(len(rows))):
        passed(f"{label} frame_index is contiguous")
    else:
        failed(f"{label} frame_index is contiguous")
    timestamps = [int(r["timestamp_ns"]) for r in rows if "timestamp_ns" in r]
    if len(timestamps) == len(rows) and all(b >= a for a, b in zip(timestamps, timestamps[1:])):
        passed(f"{label} timestamp_ns is monotonic")
    else:
        failed(f"{label} timestamp_ns is monotonic")
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
            passed(f"{label} sensor-to-Godot offset matches timebase")
        else:
            failed(f"{label} sensor-to-Godot offset matches timebase", f"deltas={sorted(deltas)[:3]} expected={expected}")


def check_body_tracking_source(manifest: dict[str, Any], options: dict[str, Any]) -> None:
    # session_spool_writer patches manifest.sources.body_tracking at close()
    # with the runtime info collected by body_motion_sampler.get_runtime_info():
    #   observed_runtime ∈ {"", "pico_bd", "godot_xr_body_tracker"}
    #   extension        : "pico_bd_body_tracking" | "meta_fb_body_tracking" | ""
    #   joint_set        : "pico_bd_24" | "godot_xr_body_tracker_v1" | ""
    #   joint_count      : 24 / 87 / 0
    #   runtime_body_flags (godot path only) : XRBodyTracker.body_flags bitfield
    # CI only validates runtime body source metadata when the body-tracking
    # check is explicitly enabled. The default Pico CI run does not have worn
    # external trackers, so it must not fail on absent/empty body data.
    sources = manifest.get("sources") or {}
    body = sources.get("body_tracking")
    if not expect_body_tracking:
        if body is None:
            passed("manifest.sources.body_tracking check skipped")
        else:
            warned("manifest.sources.body_tracking check skipped", repr(body))
        return
    if options.get("record_body_tracking") is not True:
        if body is None:
            passed("manifest.sources.body_tracking absent when tracking off")
        else:
            warned("manifest.sources.body_tracking present despite tracking off", repr(body))
        return
    if not isinstance(body, dict):
        failed("manifest.sources.body_tracking present", repr(body))
        return
    passed("manifest.sources.body_tracking present")

    observed = str(body.get("observed_runtime", "")).strip()
    if expected_device_prefix == "pico":
        expected_runtime = "pico_bd"
        expected_joint_set = "pico_bd_24"
        expected_extension = "pico_bd_body_tracking"
        expected_joint_count = 24
    elif expected_device_prefix == "quest":
        expected_runtime = "godot_xr_body_tracker"
        expected_joint_set = "godot_xr_body_tracker_v1"
        expected_extension = "meta_fb_body_tracking"
        expected_joint_count = 87
    else:
        expected_runtime = ""
        expected_joint_set = ""
        expected_extension = ""
        expected_joint_count = 0

    if observed == "":
        # No body sample reached the writer this session — could be transient
        # (HMT off-head briefly), runtime quirk, or a real regression in the
        # sampler / vendor AAR. We can't disambiguate from artefacts alone,
        # so flag as a WARN rather than FAIL.
        warned(
            "body_tracking.observed_runtime is non-empty",
            "sampler observed zero body frames this session; check head-mount + permission",
        )
        return

    if observed == expected_runtime:
        passed("body_tracking.observed_runtime", observed)
    else:
        failed(
            "body_tracking.observed_runtime",
            f"got {observed!r}, expected {expected_runtime!r} for --device {expected_device_prefix}",
        )
    if str(body.get("joint_set", "")) == expected_joint_set:
        passed("body_tracking.joint_set", expected_joint_set)
    else:
        failed("body_tracking.joint_set", f"got {body.get('joint_set')!r}, expected {expected_joint_set!r}")
    if str(body.get("extension", "")) == expected_extension:
        passed("body_tracking.extension", expected_extension)
    else:
        failed("body_tracking.extension", f"got {body.get('extension')!r}, expected {expected_extension!r}")
    try:
        joint_count = int(body.get("joint_count") or 0)
    except (TypeError, ValueError):
        joint_count = 0
    if joint_count == expected_joint_count:
        passed("body_tracking.joint_count", str(joint_count))
    else:
        failed("body_tracking.joint_count", f"got {joint_count}, expected {expected_joint_count}")

    if expected_device_prefix == "quest":
        # runtime_body_flags is XRBodyTracker.body_flags — at minimum we
        # require UPPER_BODY_SUPPORTED (bit 0, value 1). LOWER (2) and HANDS (4)
        # are nice-to-have and reported as WARN so a Quest 3 without IK-inferred
        # lower body (e.g. older firmware) doesn't fail CI.
        try:
            body_flags = int(body.get("runtime_body_flags") or 0)
        except (TypeError, ValueError):
            body_flags = 0
        if body_flags & 1:
            passed("body_tracking.runtime_body_flags has UPPER", f"flags={body_flags}")
        else:
            failed("body_tracking.runtime_body_flags has UPPER", f"flags={body_flags}")
        for name, bit in (("LOWER", 2), ("HANDS", 4)):
            if body_flags & bit:
                passed(f"body_tracking.runtime_body_flags has {name}", f"flags={body_flags}")
            else:
                warned(
                    f"body_tracking.runtime_body_flags has {name}",
                    f"flags={body_flags} — full-body extension may be unavailable",
                )


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
        # All PICO models use the generic vendor identity; runtime capabilities
        # distinguish camera and interaction features.
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


def check_mp4(mp4: Path, options: dict[str, Any]) -> dict[str, Any] | None:
    data = run_ffprobe(mp4)
    if data is None:
        if options.get("record_audio") is True:
            failed("MP4 audio stream inspection requires ffprobe", "record_audio=true")
        else:
            warned("MP4 stream inspection skipped", "ffprobe unavailable or failed")
        return None
    if not any(status == "FAIL" and name == "ffprobe parses MP4" for status, name, _ in checks):
        passed("ffprobe parses MP4")
    streams = data.get("streams", [])
    rgb = find_rgb_stream(streams, expected_rgb_codec)
    depth = next((s for s in streams if s.get("codec_name") in ("ffv1", "rawvideo") or s.get("codec_tag_string") == "raw1"), None)
    audio = next((s for s in streams if s.get("codec_type") == "audio" or s.get("codec_name") == "aac"), None)
    mett = [s for s in streams if s.get("codec_tag_string") == "mett"]
    if rgb:
        passed(
            f"MP4 contains {rgb_codec_label(expected_rgb_codec)} RGB stream",
            f"{rgb.get('codec_name')}/{rgb.get('codec_tag_string')} {rgb.get('width')}x{rgb.get('height')}",
        )
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
        actual = [
            f"{s.get('index')}:{s.get('codec_name')}/{s.get('codec_tag_string')}"
            for s in streams
            if s.get("codec_type") == "video"
        ]
        failed(f"MP4 contains {rgb_codec_label(expected_rgb_codec)} RGB stream", ", ".join(actual))
    if wants_depth(options):
        if depth:
            passed("MP4 contains depth stream", f"{depth.get('codec_name')}/{depth.get('codec_tag_string')}")
        else:
            failed("MP4 contains depth stream")
    # Body joints mett track is only checked in explicit tracker runs. The
    # default CI APK disables body tracking because Pico needs worn trackers.
    if expect_body_tracking and options.get("record_body_tracking") is True:
        body_mett = [
            s for s in mett
            if (s.get("tags") or {}).get("handler_name") == "spatialmp4:body_joints:body"
        ]
        if body_mett:
            passed("MP4 contains body_joints mett track")
        else:
            handlers = [str((s.get("tags") or {}).get("handler_name", "?")) for s in mett]
            failed(
                "MP4 contains body_joints mett track",
                f"handler_name list={handlers}",
            )
    if wants_head_pose(options):
        if mett:
            passed("MP4 contains timed metadata stream", f"{len(mett)} mett stream(s)")
        else:
            failed("MP4 contains timed metadata stream")
    if options.get("record_audio") is True:
        requested_layout = str(options.get("audio_channel_layout", "stereo"))
        expected_layout = effective_audio_layout_for_request(requested_layout)
        expected_channels = audio_channel_count_for_layout(expected_layout)
        expected_sample_rate = int(options.get("audio_sample_rate_hz") or 48000)
        min_audio_packets = max(10, int(capture_seconds * 8))
        if audio:
            passed("MP4 contains AAC audio stream", f"{audio.get('codec_name')}/{audio.get('codec_tag_string')}")
            if audio.get("codec_name") == "aac":
                passed("MP4 audio codec is AAC")
            else:
                failed("MP4 audio codec is AAC", repr(audio.get("codec_name")))
            try:
                sample_rate = int(audio.get("sample_rate") or 0)
            except ValueError:
                sample_rate = 0
            if sample_rate == expected_sample_rate:
                passed("MP4 audio sample_rate", str(sample_rate))
            else:
                failed("MP4 audio sample_rate", f"{sample_rate} != {expected_sample_rate}")
            try:
                channels = int(audio.get("channels") or 0)
            except ValueError:
                channels = 0
            if channels == expected_channels:
                passed("MP4 audio channel count", str(channels))
            else:
                failed("MP4 audio channel count", f"{channels} != {expected_channels}")
            packets = packet_count(audio)
            if packets >= min_audio_packets:
                passed("MP4 audio packet count", f"{packets} >= {min_audio_packets}")
            else:
                failed("MP4 audio packet count", f"{packets} < {min_audio_packets}")

            tags = {str(k).lower(): str(v) for k, v in (audio.get("tags") or {}).items()}
            spatial_format = tags.get("spatial_format")
            if spatial_format is None:
                warned("MP4 audio spatial_format tag visible", "ffprobe did not expose stream tag")
            elif spatial_format == expected_layout:
                passed("MP4 audio spatial_format tag", spatial_format)
            else:
                failed("MP4 audio spatial_format tag", f"{spatial_format} != {expected_layout}")
        else:
            failed("MP4 contains AAC audio stream")
    starts = {str(s.get("index")): stream_start_us(s) for s in streams}
    if starts:
        if any(abs(v) <= 1000 for v in starts.values()):
            passed("at least one MP4 stream starts at PTS zero", str(starts))
        else:
            failed("at least one MP4 stream starts at PTS zero", str(starts))
        dense_streams = [s for s in (rgb, depth if wants_depth(options) else None, audio if options.get("record_audio") is True else None) if s]
        dense_starts = {str(s.get("index")): stream_start_us(s) for s in dense_streams}
        worst = max(dense_starts.values()) if dense_starts else 0
        check_name = f"MP4 dense media streams start within {dense_start_limit_ms} ms"
        if worst <= dense_start_limit_us:
            passed(check_name, f"worst={worst} us")
        else:
            failed(check_name, f"starts={dense_starts} worst={worst} us")
    return data


def first_metadata_payload(frames_by_track: dict[str, list[dict[str, Any]]]) -> dict[str, Any] | None:
    for rows in frames_by_track.values():
        if rows:
            return rows[0]
    return None


def rows_for_eye(frames_by_track: dict[str, list[dict[str, Any]]], eye: str) -> list[dict[str, Any]]:
    if eye in frames_by_track:
        return frames_by_track[eye]
    for rows in frames_by_track.values():
        filtered = [r for r in rows if str(r.get("eye", "")).lower() == eye]
        if filtered:
            return filtered
    return []


def check_timestamp_rows(rows: list[dict[str, Any]], label: str, required: bool) -> None:
    if not rows:
        if required:
            failed(f"{label} metadata non-empty")
        else:
            warned(f"{label} metadata absent")
        return
    passed(f"{label} metadata non-empty", f"{len(rows)} record(s)")
    timestamps = []
    for row in rows:
        value = row.get("timestamp_ns")
        if value is None:
            value = int(float(row.get("_packet_pts_time", 0.0)) * 1_000_000_000)
        try:
            timestamps.append(int(value))
        except (TypeError, ValueError):
            pass
    if len(timestamps) == len(rows) and all(b >= a for a, b in zip(timestamps, timestamps[1:])):
        passed(f"{label} timestamp_ns is monotonic")
    else:
        failed(f"{label} timestamp_ns is monotonic")


def check_operator_static_metadata(
    mp4: Path,
    mp4_info: dict[str, Any] | None,
    options: dict[str, Any],
) -> dict[str, Any]:
    frames = load_json_metadata_frames(mp4, mp4_info, "operator_static")
    payload = first_metadata_payload(frames)
    if payload is None:
        failed("MP4 contains operator_static metadata", "no JSON packet decoded")
        return {}
    passed("MP4 contains operator_static metadata")
    pts = float(payload.get("_packet_pts_time", 0.0))
    if abs(pts) <= 0.001:
        passed("operator_static PTS is zero", f"{pts:.6f}s")
    else:
        failed("operator_static PTS is zero", f"{pts:.6f}s")
    if payload.get("schema") == "spatialmp4.operator_static.session.v1":
        passed("operator_static schema", str(payload.get("schema")))
    else:
        failed("operator_static schema", repr(payload.get("schema")))
    provider = str(payload.get("provider", "")).strip()
    if provider:
        passed("operator_static provider set", provider)
    else:
        failed("operator_static provider set")
    cameras = payload.get("camera2_characteristics")
    if not isinstance(cameras, dict):
        cameras = payload.get("cameras")
    if isinstance(cameras, dict) and isinstance(cameras.get("left"), dict):
        passed("operator_static has left Camera2 characteristics")
    else:
        failed("operator_static has left Camera2 characteristics", repr(cameras))
    if wants_stereo_rgb(options):
        if isinstance(cameras, dict) and isinstance(cameras.get("right"), dict):
            passed("operator_static has right Camera2 characteristics")
        else:
            failed("operator_static has right Camera2 characteristics", repr(cameras))
    if isinstance(payload.get("android_timebase"), dict):
        passed("operator_static has android_timebase")
    else:
        failed("operator_static has android_timebase", repr(payload.get("android_timebase")))
    return payload


def check_self_contained_mp4_metadata(
    mp4: Path,
    mp4_info: dict[str, Any] | None,
    options: dict[str, Any],
    manifest: dict[str, Any],
    timebase: dict[str, Any],
) -> None:
    if mp4_info is None:
        failed("self-contained MP4 metadata validation requires ffprobe")
        return

    operator_static = check_operator_static_metadata(mp4, mp4_info, options)
    embedded_timebase = operator_static.get("android_timebase") if isinstance(operator_static, dict) else None
    if isinstance(embedded_timebase, dict):
        check_timebase(embedded_timebase, "operator_static.android_timebase")

    rgb_frames = load_json_metadata_frames(mp4, mp4_info, "rgb_frame_index")
    check_rgb_index_rows(
        rows_for_eye(rgb_frames, "left"),
        "left",
        timebase,
        "MP4 left rgb_frame_index",
    )
    if wants_stereo_rgb(options):
        check_rgb_index_rows(
            rows_for_eye(rgb_frames, "right"),
            "right",
            timebase,
            "MP4 right rgb_frame_index",
        )

    depth_frames = load_json_metadata_frames(mp4, mp4_info, "depth_frame_meta")
    check_timestamp_rows(
        rows_for_eye(depth_frames, "left") or [r for rows in depth_frames.values() for r in rows],
        "MP4 depth_frame_meta",
        wants_depth(options),
    )

    body_frames = load_json_metadata_frames(mp4, mp4_info, "body_frame_meta")
    body_rows = [r for rows in body_frames.values() for r in rows]
    sources = manifest.get("sources") if isinstance(manifest.get("sources"), dict) else {}
    body_source = sources.get("body_tracking") if isinstance(sources, dict) else None
    observed_body = str(body_source.get("observed_runtime", "")).strip() if isinstance(body_source, dict) else ""
    check_timestamp_rows(
        body_rows,
        "MP4 body_frame_meta",
        expect_body_tracking and options.get("record_body_tracking") is True and observed_body != "",
    )

    motion_frames = load_json_metadata_frames(mp4, mp4_info, "motion_trackers")
    motion_rows = [r for rows in motion_frames.values() for r in rows]
    if expect_motion_trackers and options.get("record_motion_trackers") is True:
        if motion_rows:
            passed("MP4 motion_trackers metadata non-empty", f"{len(motion_rows)} record(s)")
        else:
            warned(
                "MP4 motion_trackers metadata absent",
                "tracker runtime may be unavailable or disabled by body-tracking mode",
            )


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
if not manifest_path.exists():
    failed("manifest.json exists", str(manifest_path))
    sys.exit(print_summary())

manifest = safe_json(manifest_path)
options = check_manifest(manifest)
check_body_tracking_source(manifest, options)
device = check_device_block(manifest)
check_required_files(session_dir, mp4, options)
mp4_info = check_mp4(mp4, options)
operator_static = first_metadata_payload(load_json_metadata_frames(mp4, mp4_info, "operator_static"))
embedded_timebase = operator_static.get("android_timebase") if isinstance(operator_static, dict) else None
if isinstance(embedded_timebase, dict):
    timebase = embedded_timebase
else:
    timebase = {}
    failed("operator_static.android_timebase usable", repr(embedded_timebase))
check_self_contained_mp4_metadata(mp4, mp4_info, options, manifest, timebase)
check_mp4_device_tags(mp4, device)

sys.exit(print_summary())
PY
}

main() {
  mkdir -p "$OUTPUT_DIR"

  step "Pre-flight"
  require_tool "$PYTHON"
  resolve_ffprobe
  if [ -z "${FFPROBE:-}" ]; then
    err "ffprobe is required to validate self-contained MP4 metadata tracks"
    exit 1
  fi
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
  log_device_identity

  if [ "$SKIP_BUILD" != "1" ]; then
    build_clean_apk
    build_ci_apk
  else
    warn "SKIP_BUILD=1; using existing $CI_APK_PATH (must already be a CI auto-record APK)"
    if [ ! -f "$CI_APK_PATH" ]; then
      err "missing CI APK: $CI_APK_PATH (run without SKIP_BUILD=1 first)"
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
