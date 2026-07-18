#!/usr/bin/env bash
# Human-free Quest→SO-101 teleop device test.
#
# This is the automatable half of the old 07 (now examples/quest_so101_teleop_manual.sh,
# which needs a human in a headset). It proves the SAME vertical slice end to
# end, but with a SYNTHETIC operator instead of a person:
#
#   Quest 3 (Godot client, launched in synthetic teleop mode)
#     --TCP 63901 DeviceCommand @72Hz--> xr-bridge (in robot-service)
#         -> forward.rs (descriptor clamp + deadman watchdog)
#         -> robot-adapter: PoseMapper retarget
#         -> lerobot_link driver (uds)
#     --> lerobot-teleoperate --teleop.type=vr_operator
#         -> placo IK -> so101_follower -> Feetech bus -> arm
#     <--Telemetry 10Hz-- joint_angles --> the client self-asserts the arm moved
#
# The client's SyntheticTeleopSource (scripts/xr/synthetic_teleop_source.gd)
# replaces OpenXR tracking with a canned right-controller trajectory: squeeze the
# deadman, sweep a small bounded path, release. teleop_controller then checks —
# via the REAL telemetry stream — that the arm's joint angles actually moved, and
# quits 0 (PASS) / 2 (FAIL). We read that verdict from logcat.
#
# ⚠️  THE ARM MOVES. On start it slews to home (bounded by
#     --robot.max_relative_target); then it tracks the synthetic sweep. Clear the
#     workspace. Ctrl-C tears everything down and de-energises the arm.
#
# ⚠️  DO NOT touch the serial bus while this runs (a second process corrupts the
#     bus and kills the teleop loop). Arm state is asserted from adapter telemetry
#     via the client, never by opening the port here.
#
# No manual configuration required: prepare_lerobot_so101.sh builds the venv,
# finds the serial port, and locates the URDF; the host IP is auto-detected; the
# client direct-connects (no discovery beacon, so no unicast-target config).
#
# Usage:
#   bash cicd/07_so101_synthetic_teleop.sh
#   HOST_IP=10.79.153.20 SYNTH_DURATION=30 bash cicd/07_so101_synthetic_teleop.sh
#
# Requires: a real SO-101 on USB, and a Quest on USB (adb) + the same wifi as the
# host (so it can reach HOST_IP:63901).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROBOT_DIR="$ROOT/robot"

# Make the lerobot env READY (venv + serial port + URDF), exporting SO101_PORT /
# SO101_URDF / PYTHON and putting the venv on PATH. No env vars needed by hand.
# (Set SKIP_LEROBOT_PREPARE=1 to bypass when the env is provisioned elsewhere.)
source "$ROOT/cicd/prepare_lerobot_so101.sh"

SO101_PORT="${SO101_PORT:-/dev/ttyACM0}"
SO101_URDF="${SO101_URDF:-}"
ENDPOINT="${ENDPOINT:-uds:/tmp/lerobot-vr.sock}"
ROBOT_ID="${ROBOT_ID:-so101_follower}"
CONFIG="${CONFIG:-configs/so101_real.yaml}"
# Default 5 (unset => 5). This is the MEASURED-space safety floor: lerobot's
# send_action clamps each goal to +/-N of a fresh Present_Position read, so the
# arm cannot step far from where it ACTUALLY is -- the plugin's JointRateLimiter
# works in command space and cannot do this (it never reads the encoders). The
# read is ~1.3ms and the loop is fps/sleep-bound, so keeping it is effectively
# free. Setting MAX_RELATIVE_TARGET= (empty) omits it: EXPERIMENT ONLY -- it
# drops the measured-space guard, so a startup where the arm is not near home can
# slam. (`-` not `:-` so an explicit empty value is honored.)
MAX_RELATIVE_TARGET="${MAX_RELATIVE_TARGET-5}"
FPS="${FPS:-30}"
PYTHON="${PYTHON:-python3}"

# XR client / device knobs.
PKG="${PKG:-com.lovemoon.operator}"
ACT="${ACT:-com.godot.game.GodotApp}"
ADB="${ADB:-adb}"
POSE_PORT="${POSE_PORT:-63901}"
SYNTH_DURATION="${SYNTH_DURATION:-25}"
# How long to wait for the client to reach a PASS/FAIL verdict, in seconds.
# Generous: robot-service build + plugin import + home slew + the run itself.
APP_TIMEOUT="${APP_TIMEOUT:-180}"

OUTPUT_DIR="${OUTPUT_DIR:-$ROOT/cicd/logs/synthetic-teleop-$(date +%Y%m%d-%H%M%S)}"
SERVICE_LOG="$OUTPUT_DIR/robot-service.log"
TELEOP_LOG="$OUTPUT_DIR/lerobot-teleoperate.log"
QUEST_LOG="$OUTPUT_DIR/quest-logcat.log"
SERVICE_PID=""
TELEOP_PID=""
LOGCAT_PID=""

log()  { printf '\033[36m[synthetic-teleop]\033[0m %s\n' "$*"; }
fail() { printf '\033[31m[synthetic-teleop] FAIL:\033[0m %s\n' "$*" >&2; exit 1; }

# De-energise the arm and VERIFY it. Retries, because the port may still be held
# briefly by a lerobot process that is unwinding. Never claims success it did not
# confirm — torque left on means the arm holds at Acceleration=254.
deenergise_arm() {
  [ -e "$SO101_PORT" ] || { log "WARNING: $SO101_PORT gone; cannot confirm the arm is de-energised"; return 1; }
  local attempt
  for attempt in 1 2 3 4 5; do
    if "$PYTHON" - "$SO101_PORT" "$ROBOT_ID" 2>/dev/null <<'PY'
import sys
from lerobot.robots.so_follower import SOFollower, SOFollowerRobotConfig
r = SOFollower(SOFollowerRobotConfig(port=sys.argv[1], id=sys.argv[2]))
r.bus.connect()
try:
    r.bus.disable_torque()
    tq = r.bus.sync_read("Torque_Enable")
    sys.exit(0 if all(v == 0 for v in tq.values()) else 1)
finally:
    r.bus.disconnect()
PY
    then
      log "arm de-energised (verified)"
      return 0
    fi
    sleep 0.5
  done
  printf '\a\033[31m[synthetic-teleop] !!!!! WARNING: could not confirm the arm is de-energised after 5 tries.\033[0m\n' >&2
  printf '\033[31m[synthetic-teleop] !!!!! The arm may still be HOLDING UNDER TORQUE. Power it off at the supply.\033[0m\n' >&2
  return 1
}

cleanup() {
  local rc=$?
  echo
  log "shutting down"
  [ -n "$LOGCAT_PID" ] && kill "$LOGCAT_PID" 2>/dev/null || true
  # Stop the app so it can't keep commanding the arm.
  $ADB shell am force-stop "$PKG" >/dev/null 2>&1 || true
  # SIGINT so lerobot unwinds and releases the bus; SIGTERM skips its `finally`.
  [ -n "$TELEOP_PID" ] && kill -INT "$TELEOP_PID" 2>/dev/null || true
  for _ in $(seq 1 25); do
    [ -n "$TELEOP_PID" ] && kill -0 "$TELEOP_PID" 2>/dev/null || break
    sleep 0.2
  done
  [ -n "$TELEOP_PID" ] && kill -9 "$TELEOP_PID" 2>/dev/null || true
  [ -n "$SERVICE_PID" ] && kill "$SERVICE_PID" 2>/dev/null || true
  for pid in "$TELEOP_PID" "$SERVICE_PID" "$LOGCAT_PID"; do
    [ -n "$pid" ] && wait "$pid" 2>/dev/null || true
  done
  rm -f "${ENDPOINT#uds:}" 2>/dev/null || true
  # Never leave a physical arm powered.
  deenergise_arm || true
  log "logs in $OUTPUT_DIR"
  return $rc
}
trap cleanup EXIT
trap 'exit 130' INT TERM

mkdir -p "$OUTPUT_DIR"

# --- preflight ---------------------------------------------------------------

[ -e "$SO101_PORT" ] || fail "serial port $SO101_PORT not present"
[ -n "$SO101_URDF" ] && [ -f "$SO101_URDF" ] || fail "URDF not found (SO101_URDF=$SO101_URDF)"
command -v lerobot-teleoperate >/dev/null 2>&1 || fail "lerobot-teleoperate not on PATH (prepare failed?)"
"$PYTHON" -c "import lerobot_teleoperator_vr_operator" 2>/dev/null \
  || fail "vr_operator plugin not importable (prepare failed?)"

# Pick the target headset. adb natively honours ANDROID_SERIAL, so exporting it
# is all that's needed when more than one device is attached (e.g. a Quest and a
# Pico both on USB). QUEST_SERIAL is accepted as an alias for convenience.
if [ -z "${ANDROID_SERIAL:-}" ] && [ -n "${QUEST_SERIAL:-}" ]; then
  export ANDROID_SERIAL="$QUEST_SERIAL"
fi
_ndev="$($ADB devices 2>/dev/null | awk '/\tdevice$/{n++} END{print n+0}')"
if [ -z "${ANDROID_SERIAL:-}" ] && [ "$_ndev" -gt 1 ]; then
  printf '[synthetic-teleop] attached devices:\n' >&2
  $ADB devices -l 2>/dev/null | sed -n '2,$p' >&2
  fail "more than one adb device; set ANDROID_SERIAL=<serial> (or QUEST_SERIAL=<serial>) to pick the headset"
fi
$ADB get-state >/dev/null 2>&1 || fail "no adb device; connect the Quest over USB (or set ANDROID_SERIAL)"

# Host IP the headset dials. Auto-detect the wifi/LAN address; override HOST_IP
# if detection picks the wrong interface.
if [ -z "${HOST_IP:-}" ]; then
  HOST_IP="$(ipconfig getifaddr en0 2>/dev/null || true)"
  [ -z "$HOST_IP" ] && HOST_IP="$(ipconfig getifaddr en1 2>/dev/null || true)"
  [ -z "$HOST_IP" ] && HOST_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
fi
[ -n "$HOST_IP" ] || fail "could not auto-detect the host IP; set HOST_IP=..."
log "host IP the headset will dial: $HOST_IP:$POSE_PORT"

# Sanity: can the headset even reach this host? A failure here is the usual
# "wifi client isolation" gotcha — warn rather than hard-fail (routing can still
# work even when ICMP is filtered).
$ADB shell ping -c1 -W2 "$HOST_IP" >/dev/null 2>&1 \
  || log "WARNING: the Quest could not ping $HOST_IP; if connect fails, check wifi client isolation / firewall"

CONFIG_ENDPOINT="$(grep -A3 '^\s*lerobot:' "$ROBOT_DIR/$CONFIG" | grep -m1 'endpoint:' | sed -E 's/.*endpoint:[[:space:]]*"?([^"]*)"?.*/\1/')"
[ -n "$CONFIG_ENDPOINT" ] && [ "$CONFIG_ENDPOINT" != "$ENDPOINT" ] \
  && fail "endpoint mismatch: $CONFIG has '$CONFIG_ENDPOINT', this run uses '$ENDPOINT'" || true

rm -f "${ENDPOINT#uds:}" 2>/dev/null || true

# --- SAFETY: neutralise the latched goal before torque is enabled ------------
#
# A power-cycled SO-101 reads Goal_Position = raw 0, below every joint's
# calibrated range_min, and LeRobot's connect() unconditionally re-enables torque
# at max acceleration. Seeding Goal <- Present while torque is off makes that a
# no-op hold instead of a full-speed slam into the endstops.
log "pre-flight: seeding Goal_Position <- Present_Position (torque off)"
"$PYTHON" - "$SO101_PORT" "$ROBOT_ID" <<'PY' || fail "goal seeding failed"
import sys
from lerobot.robots.so_follower import SOFollower, SOFollowerRobotConfig
r = SOFollower(SOFollowerRobotConfig(port=sys.argv[1], id=sys.argv[2]))
if not r.calibration:
    sys.exit(f"no calibration for id={sys.argv[2]!r}; run lerobot-calibrate first")
r.bus.connect()
try:
    tq = r.bus.sync_read("Torque_Enable")
    if any(v != 0 for v in tq.values()):
        sys.exit("torque already ON; re-run this script (it de-energises on exit) or power-cycle the arm")
    present = r.bus.sync_read("Present_Position", normalize=False)
    for m, v in present.items():
        r.bus.write("Goal_Position", m, v, normalize=False)
    deg = r.bus.sync_read("Present_Position")
    print("  arm is at:", {k: round(v, 1) for k, v in deg.items()})
finally:
    r.bus.disconnect()
PY

# --- start the robot half ----------------------------------------------------

log "building robot-service"
(cd "$ROBOT_DIR" && cargo build --release -p robot-service) >"$OUTPUT_DIR/build.log" 2>&1 \
  || fail "cargo build failed; see $OUTPUT_DIR/build.log"

log "starting robot-service ($CONFIG)"
(cd "$ROBOT_DIR" && RUST_LOG="${RUST_LOG:-info}" \
  ./target/release/robot-service --config "$CONFIG") >"$SERVICE_LOG" 2>&1 &
SERVICE_PID=$!
for _ in $(seq 1 50); do grep -q "LeRobot link: listening" "$SERVICE_LOG" && break; sleep 0.2; done
grep -q "LeRobot link: listening" "$SERVICE_LOG" || fail "robot-service never bound; see $SERVICE_LOG"

mrt_flag=""
if [ -n "$MAX_RELATIVE_TARGET" ]; then
  mrt_flag="--robot.max_relative_target=$MAX_RELATIVE_TARGET"
  log "starting lerobot-teleoperate (arm will slew to home; max_relative_target=$MAX_RELATIVE_TARGET)"
else
  log "starting lerobot-teleoperate (arm will slew to home; max_relative_target OMITTED — plugin JointRateLimiter bounds slew, no Present read)"
fi
set -m
# shellcheck disable=SC2086  # mrt_flag is intentionally word-split (empty => omitted)
lerobot-teleoperate \
  --teleop.type=vr_operator \
  --teleop.endpoint="$ENDPOINT" \
  --teleop.urdf_path="$SO101_URDF" \
  --robot.type=so101_follower \
  --robot.id="$ROBOT_ID" \
  --robot.port="$SO101_PORT" \
  $mrt_flag \
  --fps="$FPS" >"$TELEOP_LOG" 2>&1 &
TELEOP_PID=$!
set +m

for _ in $(seq 1 150); do
  grep -q "LeRobot link: plugin Hello" "$SERVICE_LOG" && break
  kill -0 "$TELEOP_PID" 2>/dev/null || fail "lerobot-teleoperate exited; see $TELEOP_LOG"
  sleep 0.2
done
grep -q "LeRobot link: plugin Hello" "$SERVICE_LOG" || fail "plugin never handshook; see $TELEOP_LOG"
log "plugin handshook; arm holding at home"

# --- launch the headset client in SYNTHETIC teleop mode ----------------------

log "keeping the headset awake with the screen off (proximity override)"
$ADB shell am broadcast -a com.oculus.vrpowermanager.prox_close >/dev/null 2>&1 || true

log "launching the Quest client: operator.mode=teleop synthetic host=$HOST_IP dur=${SYNTH_DURATION}s"
# force-stop first: the activity is LAUNCH_SINGLE_INSTANCE_PER_TASK, so starting
# it while already running just resumes it and the extras are ignored.
$ADB shell am force-stop "$PKG" >/dev/null 2>&1 || true
sleep 2
$ADB logcat -c >/dev/null 2>&1 || true
$ADB shell am start -n "$PKG/$ACT" \
  --es operator.mode teleop \
  --es operator.teleop.synthetic true \
  --es operator.teleop.host "$HOST_IP" \
  --es operator.teleop.port "$POSE_PORT" \
  --es operator.teleop.duration "$SYNTH_DURATION" >/dev/null 2>&1 \
  || fail "could not start $PKG"

# Stream the client's teleop logs to a file we poll for the verdict.
($ADB logcat 2>/dev/null \
  | grep --line-buffered -aE "godot *:.*(\[TeleopSynthetic\]|\[Operator\]|\[CommandSender\])" \
  > "$QUEST_LOG") &
LOGCAT_PID=$!

# --- wait for the client's self-asserted verdict -----------------------------

log "waiting up to ${APP_TIMEOUT}s for the client's PASS/FAIL verdict"
verdict=""
for _ in $(seq 1 "$APP_TIMEOUT"); do
  if grep -q "\[TeleopSynthetic\] PASS" "$QUEST_LOG" 2>/dev/null; then verdict="PASS"; break; fi
  if grep -q "\[TeleopSynthetic\] FAIL" "$QUEST_LOG" 2>/dev/null; then verdict="FAIL"; break; fi
  # The plugin dying is a hard stop — no point waiting out the timeout.
  kill -0 "$TELEOP_PID" 2>/dev/null || { log "lerobot-teleoperate exited early"; break; }
  kill -0 "$SERVICE_PID" 2>/dev/null || { log "robot-service exited early"; break; }
  sleep 1
done

echo
log "---- client teleop log ----"
grep -aE "\[TeleopSynthetic\]|Connected to|Auto-connecting|Connecting to" "$QUEST_LOG" 2>/dev/null | tail -20 || true
log "---------------------------"

case "$verdict" in
  PASS)
    # Corroborate host-side that the plugin stayed up through the run.
    grep -q "LeRobot link: enabled" "$SERVICE_LOG" || log "note: adapter never logged 'enabled' (check $SERVICE_LOG)"
    log "PASS — synthetic operator drove the real arm; logs in $OUTPUT_DIR"
    ;;
  FAIL)
    fail "client reported FAIL; see $QUEST_LOG (and $SERVICE_LOG / $TELEOP_LOG)"
    ;;
  *)
    fail "no verdict within ${APP_TIMEOUT}s; see $QUEST_LOG, $SERVICE_LOG, $TELEOP_LOG"
    ;;
esac
