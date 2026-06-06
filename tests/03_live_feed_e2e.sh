#!/usr/bin/env bash
# End-to-end Live Feed test for a Quest headset and the example cloud server.
#
# Components:
#
#   examples/live-feed-demo/operator_live_feed_server.py
#       - listens for live-push on 127.0.0.1:63910
#       - listens for live-pull on 127.0.0.1:63912
#       - reconstructs a simple global point cloud from depth + head pose
#       - publishes dense-map deltas to live-pull
#       ▲                  ▲
#       │ adb reverse      │ adb reverse
#       ▼                  ▼
#   Quest app, Live Feed mode
#       - live-push sends RGB HEVC packets, depth frames, and head poses
#       - live-pull receives dense-map chunks and renders point meshes
#
# Pass criteria:
#   - server receives session_start/session_end, RGB, depth, and head-pose
#     frames through live-push
#   - server writes a non-empty global_pointcloud.bin and dense-map result
#     frames
#   - headset logcat reports live-pull connected and
#     `Live-pull rendered chunk: ... points=N`
#
# Usage:
#   bash tests/03_live_feed_e2e.sh
#   bash tests/03_live_feed_e2e.sh --skip-build --skip-install
#   bash tests/03_live_feed_e2e.sh --serial <adb-serial>
#   bash tests/03_live_feed_e2e.sh --capture-seconds 25 --result-wait 60
#
# Environment overrides:
#   ADB, PYTHON, MAKE              binary overrides
#   ADB_SERIAL, QUEST_SERIAL       Quest serial selection
#   OUTPUT_DIR                     artifact directory
#   CAPTURE_SECONDS                Live Feed recording duration (default 20)
#   RESULT_WAIT_SECONDS            wait for server/XR results (default 45)
#   PUSH_PORT, PULL_PORT           host ports, adb-reversed to the headset
#   SKIP_BUILD=1, SKIP_INSTALL=1   reuse existing APK / installed app
#   CLEAR_APP_DATA=0               keep app settings before launch
#   EXPECT_RGB_COLOR=0|1|auto       require RGB-colored points when ffmpeg exists

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
XR_DIR="$ROOT/xr"
SERVER_SCRIPT="$ROOT/examples/live-feed-demo/operator_live_feed_server.py"
PKG="com.lovemoon.operator"
ACT="com.godot.game.GodotApp"

ADB="${ADB:-adb}"
PYTHON="${PYTHON:-python3}"
MAKE="${MAKE:-make}"
ADB_SERIAL_OVERRIDE="${ADB_SERIAL:-${QUEST_SERIAL:-}}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT/tests/logs/live-feed-$(date +%Y%m%d-%H%M%S)}"
CAPTURE_SECONDS="${CAPTURE_SECONDS:-20}"
RESULT_WAIT_SECONDS="${RESULT_WAIT_SECONDS:-45}"
START_TIMEOUT_SECONDS="${START_TIMEOUT_SECONDS:-60}"
PUSH_PORT="${PUSH_PORT:-63910}"
PULL_PORT="${PULL_PORT:-63912}"
SKIP_BUILD="${SKIP_BUILD:-0}"
SKIP_INSTALL="${SKIP_INSTALL:-0}"
CLEAR_APP_DATA="${CLEAR_APP_DATA:-1}"
KEEP_SERVER="${KEEP_SERVER:-0}"
MIN_RGB_PACKETS="${MIN_RGB_PACKETS:-1}"
MIN_DEPTH_FRAMES="${MIN_DEPTH_FRAMES:-1}"
MIN_HEAD_POSES="${MIN_HEAD_POSES:-5}"
MIN_RENDERED_POINTS="${MIN_RENDERED_POINTS:-1}"
EXPECT_RGB_COLOR="${EXPECT_RGB_COLOR:-auto}"
LAUNCH_RETRY_INTERVAL_SECONDS="${LAUNCH_RETRY_INTERVAL_SECONDS:-5}"
POINT_STRIDE="${POINT_STRIDE:-4}"
PUBLISH_INTERVAL_S="${PUBLISH_INTERVAL_S:-1.0}"
MAX_POINTS_PER_UPDATE="${MAX_POINTS_PER_UPDATE:-80000}"
RESULT_FRAGMENT_BYTES="${RESULT_FRAGMENT_BYTES:-262144}"
GUARDIAN_KEEPALIVE_SECONDS="${GUARDIAN_KEEPALIVE_SECONDS:-2}"

APK_PATH="$XR_DIR/build/quest/Operator.apk"
MAKE_TARGET="build-quest"
SERIAL=""
SERVER_PID=""
SERVER_OUT=""
SERVER_LOG=""
LIVE_FEED_LAUNCHED=0
LAST_LAUNCH_RETRY_TS=0
LOGCAT_PID=""
GUARDIAN_KEEPALIVE_PID=""
LOGCAT_LIVE=""

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
    --result-wait) RESULT_WAIT_SECONDS="$2"; shift 2 ;;
    --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
    --serial) ADB_SERIAL_OVERRIDE="$2"; shift 2 ;;
    --push-port) PUSH_PORT="$2"; shift 2 ;;
    --pull-port) PULL_PORT="$2"; shift 2 ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --skip-install) SKIP_INSTALL=1; shift ;;
    --keep-server) KEEP_SERVER=1; shift ;;
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
SERVER_OUT="$OUTPUT_DIR/server-out"
SERVER_LOG="$OUTPUT_DIR/server.log"
LOGCAT_LIVE="$OUTPUT_DIR/logcat-live.log"

cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  if [ -n "${SERIAL:-}" ]; then
    if [ -n "${LOGCAT_PID:-}" ] && kill -0 "$LOGCAT_PID" 2>/dev/null; then
      kill "$LOGCAT_PID" >/dev/null 2>&1 || true
      wait "$LOGCAT_PID" >/dev/null 2>&1 || true
    fi
    pkill -f "$ADB -s $SERIAL logcat -v time" >/dev/null 2>&1 || true
    if [ -n "${GUARDIAN_KEEPALIVE_PID:-}" ] && kill -0 "$GUARDIAN_KEEPALIVE_PID" 2>/dev/null; then
      kill "$GUARDIAN_KEEPALIVE_PID" >/dev/null 2>&1 || true
      wait "$GUARDIAN_KEEPALIVE_PID" >/dev/null 2>&1 || true
    fi
    "$ADB" -s "$SERIAL" logcat -d > "$OUTPUT_DIR/logcat-final.log" 2>/dev/null || true
    "$ADB" -s "$SERIAL" reverse --remove "tcp:$PUSH_PORT" >/dev/null 2>&1 || true
    "$ADB" -s "$SERIAL" reverse --remove "tcp:$PULL_PORT" >/dev/null 2>&1 || true
    "$ADB" -s "$SERIAL" shell am force-stop "$PKG" >/dev/null 2>&1 || true
  fi
  if [ -n "${SERVER_PID:-}" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
    if [ "$KEEP_SERVER" = "1" ] && [ "$rc" = "0" ]; then
      warn "KEEP_SERVER=1; leaving server running pid=$SERVER_PID"
    else
      kill "$SERVER_PID" >/dev/null 2>&1 || true
      wait "$SERVER_PID" >/dev/null 2>&1 || true
    fi
  fi
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

adb_device_matches_quest() {
  local serial="$1"
  local device_line="$2"
  local props text
  props=$("$ADB" -s "$serial" shell 'printf "%s %s %s %s %s\n" "$(getprop ro.product.manufacturer)" "$(getprop ro.product.brand)" "$(getprop ro.product.model)" "$(getprop ro.product.device)" "$(getprop ro.product.name)"' </dev/null 2>/dev/null | tr -d '\r' || true)
  text="$(printf '%s %s\n' "$device_line" "$props" | tr '[:upper:]' '[:lower:]')"
  grep -Eq 'quest|oculus|meta|eureka|panther|seacliff|hollywood' <<< "$text"
}

pick_quest_device() {
  if [ -n "$ADB_SERIAL_OVERRIDE" ]; then
    echo "$ADB_SERIAL_OVERRIDE"
    return
  fi
  local device_lines
  device_lines=$("$ADB" devices -l | awk 'NR>1 && $2=="device" {print}' || true)
  if [ -z "$device_lines" ]; then
    err "no adb device attached; set ADB_SERIAL or QUEST_SERIAL"
    exit 1
  fi
  local matches=()
  local line serial
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    serial="$(awk '{print $1}' <<< "$line")"
    if adb_device_matches_quest "$serial" "$line"; then
      matches+=("$serial")
    fi
  done <<< "$device_lines"
  if [ "${#matches[@]}" -eq 1 ]; then
    echo "${matches[0]}"
    return
  fi
  if [ "${#matches[@]}" -gt 1 ]; then
    err "multiple Quest-like adb devices: ${matches[*]}; pass --serial"
    exit 1
  fi
  local device_count
  device_count="$(wc -l <<< "$device_lines" | tr -d ' ')"
  if [ "$device_count" = "1" ]; then
    awk '{print $1}' <<< "$device_lines"
    return
  fi
  err "no Quest-like adb device found; pass --serial"
  printf '%s\n' "$device_lines" >&2
  exit 1
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
    android.permission.READ_EXTERNAL_STORAGE \
    android.permission.WRITE_EXTERNAL_STORAGE
  do
    run_adb shell pm grant "$PKG" "$perm" >/dev/null 2>&1 || true
  done
  run_adb shell appops set "$PKG" CAMERA allow >/dev/null 2>&1 || true
  run_adb shell cmd appops set "$PKG" CAMERA allow >/dev/null 2>&1 || true
  run_adb shell appops set "$PKG" RECORD_AUDIO allow >/dev/null 2>&1 || true
  run_adb shell cmd appops set "$PKG" RECORD_AUDIO allow >/dev/null 2>&1 || true
  run_adb shell appops set "$PKG" HEADSET_CAMERA allow >/dev/null 2>&1 || true
  run_adb shell appops set "$PKG" USE_SCENE allow >/dev/null 2>&1 || true
}

dismiss_system_dialogs() {
  run_adb shell am broadcast -a android.intent.action.CLOSE_SYSTEM_DIALOGS >/dev/null 2>&1 || true
  run_adb shell input keyevent KEYCODE_BACK >/dev/null 2>&1 || true
  sleep 1
  run_adb shell input keyevent KEYCODE_BACK >/dev/null 2>&1 || true
}

stop_guardian_surfaces() {
  run_adb shell am force-stop com.oculus.guardian >/dev/null 2>&1 || true
  run_adb shell am force-stop com.android.permissioncontroller >/dev/null 2>&1 || true
  run_adb shell am broadcast -a com.oculus.vrpowermanager.prox_close >/dev/null 2>&1 || true
}

ensure_screen_awake() {
  local state
  run_adb shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
  run_adb shell wm dismiss-keyguard >/dev/null 2>&1 || true
  state="$(run_adb shell dumpsys power 2>/dev/null | grep -m1 -E 'Display Power|mWakefulness' || true)"
  if grep -q -E 'ON|Awake' <<< "$state"; then
    return
  fi
  run_adb shell input keyevent KEYCODE_POWER >/dev/null 2>&1 || true
  sleep 2
}

start_logcat_capture() {
  : > "$LOGCAT_LIVE"
  run_adb logcat -v time > "$LOGCAT_LIVE" 2>&1 &
  LOGCAT_PID=$!
}

start_guardian_keepalive() {
  (
    while true; do
      "$ADB" -s "$SERIAL" shell am force-stop com.oculus.guardian >/dev/null 2>&1 || true
      "$ADB" -s "$SERIAL" shell am broadcast -a com.oculus.vrpowermanager.prox_close >/dev/null 2>&1 || true
      sleep "$GUARDIAN_KEEPALIVE_SECONDS"
    done
  ) &
  GUARDIAN_KEEPALIVE_PID=$!
}

prepare_device() {
  step "Prepare Quest device"
  run_adb shell am force-stop "$PKG" >/dev/null 2>&1 || true
  if [ "$CLEAR_APP_DATA" = "1" ]; then
    run_adb shell pm clear "$PKG" >/dev/null 2>&1 || true
    ok "cleared app data"
  fi
  grant_permissions
  run_adb reverse "tcp:$PUSH_PORT" "tcp:$PUSH_PORT"
  run_adb reverse "tcp:$PULL_PORT" "tcp:$PULL_PORT"
  stop_guardian_surfaces
  ensure_screen_awake
  dismiss_system_dialogs
  run_adb logcat -c
  start_logcat_capture
  start_guardian_keepalive
  ok "adb reverse tcp:$PUSH_PORT and tcp:$PULL_PORT configured"
}

wait_for_port() {
  local port="$1"
  local deadline
  deadline=$(($(date +%s) + 10))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if nc -z 127.0.0.1 "$port" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.25
  done
  return 1
}

start_server() {
  step "Start Live Feed example server"
  mkdir -p "$SERVER_OUT"
  pkill -f "operator_live_feed_server.py.*--push-port ${PUSH_PORT}" >/dev/null 2>&1 || true
  "$PYTHON" "$SERVER_SCRIPT" \
    --host 127.0.0.1 \
    --push-port "$PUSH_PORT" \
    --pull-host 127.0.0.1 \
    --pull-port "$PULL_PORT" \
    --out "$SERVER_OUT" \
    --algorithm depth_fusion_pointcloud \
    --publish-interval-s "$PUBLISH_INTERVAL_S" \
    --point-stride "$POINT_STRIDE" \
    --max-points-per-update "$MAX_POINTS_PER_UPDATE" \
    --result-fragment-bytes "$RESULT_FRAGMENT_BYTES" \
    > "$SERVER_LOG" 2>&1 &
  SERVER_PID=$!
  if ! wait_for_port "$PUSH_PORT"; then
    err "server did not listen on push port $PUSH_PORT"
    tail -80 "$SERVER_LOG" >&2 || true
    exit 2
  fi
  if ! wait_for_port "$PULL_PORT"; then
    err "server did not listen on pull port $PULL_PORT"
    tail -80 "$SERVER_LOG" >&2 || true
    exit 2
  fi
  ok "server pid=$SERVER_PID push=$PUSH_PORT pull=$PULL_PORT"
}

build_and_install() {
  if [ "$SKIP_BUILD" = "0" ]; then
    step "Build Quest APK ($MAKE_TARGET)"
    (cd "$XR_DIR" && "$MAKE" "$MAKE_TARGET" 2>&1 | tee "$OUTPUT_DIR/build.log")
    if [ ! -f "$APK_PATH" ]; then
      err "APK not found: $APK_PATH"
      exit 2
    fi
    ok "built $APK_PATH"
  else
    note "SKIP_BUILD=1; using existing APK"
  fi

  if [ "$SKIP_INSTALL" = "0" ]; then
    step "Install Quest APK"
    run_adb install -r -d "$APK_PATH" 2>&1 | tee "$OUTPUT_DIR/adb-install.log"
    ok "installed $PKG"
  else
    if ! run_adb shell pm path "$PKG" >/dev/null 2>&1; then
      err "$PKG is not installed; remove --skip-install"
      exit 2
    fi
    note "SKIP_INSTALL=1; using installed app"
  fi
}

send_live_feed_start_intent() {
  run_adb shell am start \
    -n "$PKG/$ACT" \
    --es operator.mode live_feed \
    --ez operator.capture.auto_start true \
    --es operator.capture.auto_stop_seconds "$CAPTURE_SECONDS" \
    --es operator.capture.interaction_mode head \
    2>&1 | tee -a "$OUTPUT_DIR/adb-start.log"
}

start_live_feed_activity() {
  run_adb shell am force-stop "$PKG" >/dev/null 2>&1 || true
  send_live_feed_start_intent
}

resume_live_feed_activity() {
  send_live_feed_start_intent
}

launch_live_feed() {
  step "Launch Live Feed auto-capture"
  dismiss_system_dialogs
  start_live_feed_activity
  LIVE_FEED_LAUNCHED=1
  LAST_LAUNCH_RETRY_TS="$(date +%s)"
  ok "launched live_feed for ${CAPTURE_SECONDS}s"
}

logcat_dump() {
  if [ -f "$LOGCAT_LIVE" ]; then
    cat "$LOGCAT_LIVE"
    return
  fi
  run_adb logcat -d 2>/dev/null || true
}

logcat_contains() {
  if [ -f "$LOGCAT_LIVE" ]; then
    grep -a -q "$1" "$LOGCAT_LIVE"
    return
  fi
  local dump
  dump="$(run_adb logcat -d 2>/dev/null || true)"
  grep -a -q "$1" <<< "$dump"
}

retry_blocked_launch_if_needed() {
  local now
  if [ "$LIVE_FEED_LAUNCHED" != "1" ]; then
    return 0
  fi
  if ! logcat_contains "Launch is blocked because:" \
    && ! logcat_contains "Timeout while requesting window placement" \
    && ! logcat_contains "nativeOnActivityPaused: $PKG/$ACT" \
    && ! logcat_contains "onActivityStopped"; then
    return 0
  fi
  now="$(date +%s)"
  if [ $((now - LAST_LAUNCH_RETRY_TS)) -lt "$LAUNCH_RETRY_INTERVAL_SECONDS" ]; then
    return 0
  fi
  LAST_LAUNCH_RETRY_TS="$now"
  warn "system dialog blocking launch; dismissing and retrying"
  stop_guardian_surfaces
  ensure_screen_awake
  dismiss_system_dialogs
  resume_live_feed_activity >/dev/null || true
}

wait_for_log() {
  local pattern="$1"
  local timeout="$2"
  local label="$3"
  local deadline
  deadline=$(($(date +%s) + timeout))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if logcat_contains "$pattern"; then
      ok "$label"
      return 0
    fi
    retry_blocked_launch_if_needed
    sleep 1
  done
  err "timed out waiting for log: $label ($pattern)"
  logcat_dump > "$OUTPUT_DIR/logcat-timeout.log"
  exit 3
}

wait_for_outputs() {
  step "Wait for push/pull/render markers"
  wait_for_log "Live feed push connected:" "$START_TIMEOUT_SECONDS" "live-push connected"
  wait_for_log "Capture session started:" "$START_TIMEOUT_SECONDS" "capture session started"
  wait_for_log "Live-pull connected:" "$START_TIMEOUT_SECONDS" "live-pull connected"
  wait_for_log "Live-pull rendered chunk:" "$RESULT_WAIT_SECONDS" "live-pull rendered dense-map chunk"

  local deadline
  deadline=$(($(date +%s) + RESULT_WAIT_SECONDS))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if find "$SERVER_OUT" -path '*/results/global_pointcloud.bin' -size +0c | grep -q .; then
      ok "server global pointcloud produced"
      return
    fi
    sleep 1
  done
  err "timed out waiting for server global pointcloud"
  exit 3
}

wait_for_auto_stop() {
  step "Wait for Live Feed auto-stop"
  local timeout deadline
  timeout=$(awk -v a="$CAPTURE_SECONDS" 'BEGIN { printf "%d", a + 30 }')
  deadline=$(($(date +%s) + timeout))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if logcat_contains "AUTO_STOP_FOR_DEVICE_TEST: quitting" \
      || logcat_contains "Live feed push stopped; live-pull remains connected"; then
      ok "auto-stop completed"
      return
    fi
    sleep 1
  done
  warn "auto-stop did not quit before timeout; forcing app stop"
  run_adb shell am force-stop "$PKG" >/dev/null 2>&1 || true
}

validate_results() {
  step "Validate Live Feed artifacts"
  logcat_dump > "$OUTPUT_DIR/logcat.log"
  "$PYTHON" - "$SERVER_OUT" "$OUTPUT_DIR/logcat.log" "$SERVER_LOG" \
    "$MIN_RGB_PACKETS" "$MIN_DEPTH_FRAMES" "$MIN_HEAD_POSES" "$MIN_RENDERED_POINTS" "$EXPECT_RGB_COLOR" <<'PY'
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

server_out = Path(sys.argv[1])
logcat_path = Path(sys.argv[2])
server_log_path = Path(sys.argv[3])
min_rgb_packets = int(sys.argv[4])
min_depth_frames = int(sys.argv[5])
min_head_poses = int(sys.argv[6])
min_rendered_points = int(sys.argv[7])
expect_rgb_color = sys.argv[8] == "1"

names = {
    1: "session_start",
    2: "rgb_csd",
    3: "rgb_packet",
    4: "depth_metadata",
    5: "depth_frame",
    6: "head_pose",
    10: "session_end",
    110: "algorithm_status",
    112: "dense_map_manifest",
    113: "dense_map_fragment",
    114: "dense_map_commit",
    115: "camera_trajectory",
    116: "map_transform",
}

checks: list[tuple[str, str, str]] = []


def add(status: str, name: str, detail: str = "") -> None:
    checks.append((status, name, detail))


def passed(name: str, detail: str = "") -> None:
    add("PASS", name, detail)


def failed(name: str, detail: str = "") -> None:
    add("FAIL", name, detail)


def count_events(path: Path) -> dict[int, int]:
    counts: dict[int, int] = {}
    for line in path.read_text(errors="replace").splitlines():
        if not line.strip():
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        frame_type = int(row.get("frame_type", -1))
        counts[frame_type] = counts.get(frame_type, 0) + 1
    return counts


def payloads_for(path: Path, frame_type: int) -> list[dict]:
    payloads: list[dict] = []
    for line in path.read_text(errors="replace").splitlines():
        if not line.strip():
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        if int(row.get("frame_type", -1)) != frame_type:
            continue
        payload = row.get("payload", {})
        if isinstance(payload, dict):
            payloads.append(payload)
    return payloads


def latest_session_dir(root: Path) -> Path | None:
    sessions = [p for p in root.glob("session_*") if p.is_dir()]
    if not sessions:
        return None
    sessions.sort(key=lambda p: p.stat().st_mtime, reverse=True)
    return sessions[0]


session_dir = latest_session_dir(server_out)
if session_dir is None:
    failed("server session directory exists", str(server_out))
else:
    passed("server session directory exists", str(session_dir))
    events_path = session_dir / "events.ndjson"
    if events_path.exists() and events_path.stat().st_size > 0:
        passed("events.ndjson non-empty", f"{events_path.stat().st_size} bytes")
        counts = count_events(events_path)
        for frame_type, minimum in (
            (1, 1),
            (2, 1),
            (3, min_rgb_packets),
            (5, min_depth_frames),
            (6, min_head_poses),
            (10, 1),
        ):
            actual = counts.get(frame_type, 0)
            label = names.get(frame_type, str(frame_type))
            if actual >= minimum:
                passed(f"push {label}", f"{actual} >= {minimum}")
            else:
                failed(f"push {label}", f"{actual} < {minimum}")
    else:
        failed("events.ndjson non-empty", str(events_path))

    results_path = session_dir / "results" / "results.ndjson"
    if results_path.exists() and results_path.stat().st_size > 0:
        passed("results.ndjson non-empty", f"{results_path.stat().st_size} bytes")
        result_counts = count_events(results_path)
        for frame_type in (110, 112, 113, 114, 115, 116):
            actual = result_counts.get(frame_type, 0)
            label = names.get(frame_type, str(frame_type))
            if actual > 0:
                passed(f"result {label}", str(actual))
            else:
                failed(f"result {label}", "0")
        statuses = payloads_for(results_path, 110)
        rgb_frames_decoded = max((int(status.get("rgb_frames_decoded", 0)) for status in statuses), default=0)
        rgb_colored_points = max((int(status.get("rgb_colored_points", 0)) for status in statuses), default=0)
        color_sources = {str(status.get("color_source", "")) for status in statuses}
        if expect_rgb_color:
            if rgb_frames_decoded > 0:
                passed("server RGB frames decoded", str(rgb_frames_decoded))
            else:
                failed("server RGB frames decoded", "0")
            if rgb_colored_points > 0 and "rgb" in color_sources:
                passed("server RGB-colored points", f"{rgb_colored_points} points")
            else:
                failed("server RGB-colored points", f"points={rgb_colored_points} sources={sorted(color_sources)}")
        elif rgb_colored_points > 0:
            passed("server RGB-colored points", f"{rgb_colored_points} points")
    else:
        failed("results.ndjson non-empty", str(results_path))

    pointcloud = session_dir / "results" / "global_pointcloud.bin"
    if pointcloud.exists() and pointcloud.stat().st_size > 0:
        passed("global_pointcloud.bin non-empty", f"{pointcloud.stat().st_size} bytes")
    else:
        failed("global_pointcloud.bin non-empty", str(pointcloud))

logcat = logcat_path.read_text(errors="replace") if logcat_path.exists() else ""
for pattern, label in (
    ("Live feed push connected:", "XR live-push connected"),
    ("Live-pull connected:", "XR live-pull connected"),
    ("Live-pull manifest", "XR live-pull manifest received"),
    ("Live-pull commit", "XR live-pull commit received"),
):
    if pattern in logcat:
        passed(label)
    else:
        failed(label, pattern)

rendered_points = [int(value) for value in re.findall(r"Live-pull rendered chunk: .*? points=(\d+)", logcat)]
total_rendered = sum(rendered_points)
if total_rendered >= min_rendered_points:
    passed("XR rendered dense-map points", f"{total_rendered} >= {min_rendered_points}")
else:
    failed("XR rendered dense-map points", f"{total_rendered} < {min_rendered_points}")

server_log = server_log_path.read_text(errors="replace") if server_log_path.exists() else ""
for pattern, label in (
    ("push accepted", "server accepted live-push"),
    ("result accepted", "server accepted live-pull"),
    ("algorithm status state=running", "server algorithm status running log"),
    ("algorithm status state=stopped", "server algorithm status stopped log"),
):
    if pattern in server_log:
        passed(label)
    else:
        failed(label, pattern)

width = max((len(name) for _, name, _ in checks), default=10)
for status, name, detail in checks:
    suffix = f" - {detail}" if detail else ""
    print(f"{status:4} {name:<{width}}{suffix}")

failed_checks = [c for c in checks if c[0] == "FAIL"]
if failed_checks:
    raise SystemExit(1)
PY
  ok "validated push, pull, reconstruction, and headset render logs"
}

step "Pre-flight"
mkdir -p "$OUTPUT_DIR"
for tool in "$ADB" "$PYTHON" "$MAKE" nc; do
  require_tool "$tool"
done
if [ ! -f "$SERVER_SCRIPT" ]; then
  err "server script not found: $SERVER_SCRIPT"
  exit 2
fi
"$PYTHON" "$SERVER_SCRIPT" --self-test > "$OUTPUT_DIR/server-self-test.log"
ok "server self-test passed"
if [ "$EXPECT_RGB_COLOR" = "auto" ]; then
  if command -v ffmpeg >/dev/null 2>&1; then
    EXPECT_RGB_COLOR=1
  else
    EXPECT_RGB_COLOR=0
  fi
fi
note "EXPECT_RGB_COLOR=$EXPECT_RGB_COLOR"

SERIAL="$(pick_quest_device)"
ok "Quest adb device: $SERIAL"
{
  echo "serial=$SERIAL"
  run_adb shell 'printf "manufacturer=%s\nbrand=%s\nmodel=%s\ndevice=%s\nproduct=%s\n" "$(getprop ro.product.manufacturer)" "$(getprop ro.product.brand)" "$(getprop ro.product.model)" "$(getprop ro.product.device)" "$(getprop ro.product.name)"' 2>/dev/null | tr -d '\r'
} | tee "$OUTPUT_DIR/adb-device-props.txt" >/dev/null

build_and_install
prepare_device
start_server
launch_live_feed
wait_for_outputs
wait_for_auto_stop
validate_results

echo
ok "Live Feed E2E passed; artifacts in $OUTPUT_DIR"
