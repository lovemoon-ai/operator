#!/usr/bin/env bash
# Bring up the full Quest 3 -> real SO-101 teleop stack and hold it open.
#
# EXAMPLE / MANUAL BRING-UP — not a CI test. It needs a human wearing the headset
# to drive the arm, so it cannot run unattended. It is the teaching demo for
# "put on the headset and teleoperate a real SO-101". For the automated,
# human-free version of this same vertical slice, see
# cicd/07_so101_synthetic_teleop.sh (a synthetic operator drives the arm and the
# client self-asserts).
#
# It starts everything, proves the headset can see the host, and then tails the
# logs while you drive. Ctrl-C tears it all down and de-energises the arm.
#
#   Quest 3 (Godot client)
#     --UDP 63900 discovery--> host
#     --TCP 63901 DeviceCommand @72Hz--> xr-bridge
#         -> forward.rs (descriptor clamp + deadman watchdog)
#         -> robot-adapter: PoseMapper retarget  [the ONE retarget impl]
#         -> lerobot_link driver (uds)
#     --> lerobot-teleoperate --teleop.type=vr_operator
#         -> placo IK -> so101_follower -> Feetech bus -> arm
#
# ⚠️  THE ARM MOVES.
#   * On start it slews to home (bounded by --robot.max_relative_target). This
#     is unavoidable; see the plugin README. Clear the workspace.
#   * Once you squeeze the right grip it tracks your right controller.
#
# ⚠️  DO NOT touch the serial bus while this runs. A second process on the port
#   ("multiple access on port") corrupts reads AND kills the teleop loop with
#   "Incorrect status packet!". Read arm state from the adapter's telemetry, or
#   stop this script first.
#
# Usage:
#   bash examples/quest_so101_teleop_manual.sh
#   SO101_PORT=/dev/tty.usbmodem... QUEST_IP=10.79.153.133 bash examples/quest_so101_teleop_manual.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROBOT_DIR="$ROOT/robot"

# Make the environment READY before anything else: create/refresh the uv-managed
# lerobot venv, auto-detect the serial port, and locate the URDF. This EXPORTS
# SO101_PORT / SO101_URDF / PYTHON and puts the venv on PATH, so the defaults
# below become fallbacks and this test needs no env vars set by hand.
# (Set SKIP_LEROBOT_PREPARE=1 to bypass when the env is provisioned elsewhere.)
source "$ROOT/cicd/prepare_lerobot_so101.sh"

SO101_PORT="${SO101_PORT:-/dev/tty.usbmodem58FA1019921}"
SO101_URDF="${SO101_URDF:-$HOME/.cache/huggingface/lerobot/robot-urdfs/so101/so101_new_calib.urdf}"
ENDPOINT="${ENDPOINT:-uds:/tmp/lerobot-vr.sock}"
ROBOT_ID="${ROBOT_ID:-so101_follower}"
CONFIG="${CONFIG:-configs/so101_real.yaml}"
MAX_RELATIVE_TARGET="${MAX_RELATIVE_TARGET:-5}"
FPS="${FPS:-30}"
PKG="${PKG:-com.lovemoon.operator}"
ACT="${ACT:-com.godot.game.GodotApp}"
ADB="${ADB:-adb}"
PYTHON="${PYTHON:-python3}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT/cicd/logs/quest-teleop-$(date +%Y%m%d-%H%M%S)}"

SERVICE_LOG="$OUTPUT_DIR/robot-service.log"
TELEOP_LOG="$OUTPUT_DIR/lerobot-teleoperate.log"
QUEST_LOG="$OUTPUT_DIR/quest-logcat.log"
SERVICE_PID=""
TELEOP_PID=""
LOGCAT_PID=""
TAIL_PID=""

log()  { printf '\033[36m[quest-teleop]\033[0m %s\n' "$*"; }
fail() { printf '\033[31m[quest-teleop] FAIL:\033[0m %s\n' "$*" >&2; exit 1; }

# De-energise the arm and VERIFY it. Retries, because the port may still be held
# for a moment by a lerobot process that is unwinding. Never claims success it
# did not confirm: torque left on means the arm holds at Acceleration=254, so a
# false "de-energised" here is worse than a loud failure. Returns 0 only after
# reading back Torque_Enable == 0 on every joint.
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
  printf '\a\033[31m[quest-teleop] !!!!! WARNING: could not confirm the arm is de-energised after 5 tries.\033[0m\n' >&2
  printf '\033[31m[quest-teleop] !!!!! The arm may still be HOLDING UNDER TORQUE. Power it off at the supply.\033[0m\n' >&2
  return 1
}

cleanup() {
  local rc=$?
  echo
  log "shutting down"

  # Kill the long-lived log followers FIRST. `tail -f` and the `adb logcat`
  # pipe never exit on their own, so a bare `wait` for them blocks cleanup
  # forever -- which is exactly what made Ctrl-C hang: the trap ran but could
  # never finish, so every later Ctrl-C queued behind it.
  [ -n "$TAIL_PID" ] && kill "$TAIL_PID" 2>/dev/null || true
  [ -n "$LOGCAT_PID" ] && kill "$LOGCAT_PID" 2>/dev/null || true

  # SIGINT so lerobot unwinds and releases the bus; SIGTERM skips its `finally`.
  [ -n "$TELEOP_PID" ] && kill -INT "$TELEOP_PID" 2>/dev/null || true
  for _ in $(seq 1 25); do
    [ -n "$TELEOP_PID" ] && kill -0 "$TELEOP_PID" 2>/dev/null || break
    sleep 0.2
  done
  [ -n "$TELEOP_PID" ] && kill -9 "$TELEOP_PID" 2>/dev/null || true
  [ -n "$SERVICE_PID" ] && kill "$SERVICE_PID" 2>/dev/null || true
  # Reap only the processes we know about -- NOT a bare `wait`, which would also
  # wait on the (now-signalled but maybe-lingering) log followers.
  for pid in "$TELEOP_PID" "$SERVICE_PID" "$TAIL_PID" "$LOGCAT_PID"; do
    [ -n "$pid" ] && wait "$pid" 2>/dev/null || true
  done
  rm -f "${ENDPOINT#uds:}" 2>/dev/null || true

  # Never leave a physical arm powered.
  deenergise_arm || true
  log "logs in $OUTPUT_DIR"
  return $rc
}
# EXIT does the cleanup; INT/TERM just exit (which fires EXIT). Handling the
# signals via `exit` rather than running cleanup directly means a second Ctrl-C
# is not queued behind an in-progress trap, and the script actually terminates
# instead of falling back into its wait loop.
trap cleanup EXIT
trap 'exit 130' INT TERM

mkdir -p "$OUTPUT_DIR"

# --- preflight ---------------------------------------------------------------

[ -e "$SO101_PORT" ] || fail "serial port $SO101_PORT not present"
[ -f "$SO101_URDF" ] || fail "URDF not found at $SO101_URDF"
command -v lerobot-teleoperate >/dev/null 2>&1 || fail "lerobot-teleoperate not on PATH; activate the lerobot venv"
"$PYTHON" -c "import lerobot_teleoperator_vr_operator" 2>/dev/null \
  || fail "vr_operator plugin not installed: pip install -e plugins/lerobot-teleop/python"

$ADB get-state >/dev/null 2>&1 || fail "no adb device; connect the Quest over USB"
QUEST_IP="${QUEST_IP:-$($ADB shell ip -o -4 addr show wlan0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | tr -d '\r')}"
[ -n "$QUEST_IP" ] || fail "could not read the Quest's wifi IP; is wifi on?"
log "Quest wifi IP: $QUEST_IP"

# The headset finds the host by UDP broadcast, which this network drops. The
# config lists unicast beacon targets instead -- so a headset that got a new
# DHCP lease silently never discovers the host. Check rather than let the
# operator debug it from inside a headset.
if ! grep -q "$QUEST_IP" "$ROBOT_DIR/$CONFIG"; then
  fail "$CONFIG does not list this headset under bridge.discovery_unicast_targets.
  Add:
      discovery_unicast_targets:
        - $QUEST_IP
  (UDP broadcast is dropped on this network, so the beacon must be unicast.)"
fi

CONFIG_ENDPOINT="$(grep -A3 '^\s*lerobot:' "$ROBOT_DIR/$CONFIG" | grep -m1 'endpoint:' | sed -E 's/.*endpoint:[[:space:]]*"?([^"]*)"?.*/\1/')"
[ "$CONFIG_ENDPOINT" = "$ENDPOINT" ] \
  || fail "endpoint mismatch: $CONFIG has '$CONFIG_ENDPOINT', this run uses '$ENDPOINT'"

$ADB shell ping -c1 -W2 "$(ipconfig getifaddr en0 2>/dev/null || echo 0.0.0.0)" >/dev/null 2>&1 \
  || log "WARNING: the Quest could not ping this host; if discovery fails, check for wifi client isolation"

# --- safety: neutralise the latched goal -------------------------------------
#
# A power-cycled SO-101 reads Goal_Position = raw 0, below every joint's
# calibrated range_min, and LeRobot's connect() unconditionally re-enables
# torque at max acceleration. Seeding Goal <- Present while torque is off makes
# that a no-op hold instead of a full-speed slam into the endstops.
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
        sys.exit("torque already ON; a previous run left it powered -- re-run this script "
                 "(it de-energises on exit) or power-cycle the arm")
    present = r.bus.sync_read("Present_Position", normalize=False)
    for m, v in present.items():
        r.bus.write("Goal_Position", m, v, normalize=False)
    deg = r.bus.sync_read("Present_Position")
    print("  arm is at:", {k: round(v, 1) for k, v in deg.items()})
finally:
    r.bus.disconnect()
PY

# --- start the stack ---------------------------------------------------------

log "building robot-service"
(cd "$ROBOT_DIR" && cargo build --release -p robot-service) >"$OUTPUT_DIR/build.log" 2>&1 \
  || fail "cargo build failed; see $OUTPUT_DIR/build.log"

log "starting robot-service ($CONFIG)"
(cd "$ROBOT_DIR" && RUST_LOG="${RUST_LOG:-info}" \
  ./target/release/robot-service --config "$CONFIG") >"$SERVICE_LOG" 2>&1 &
SERVICE_PID=$!
for _ in $(seq 1 50); do grep -q "LeRobot link: listening" "$SERVICE_LOG" && break; sleep 0.2; done
grep -q "LeRobot link: listening" "$SERVICE_LOG" || fail "robot-service never bound; see $SERVICE_LOG"

log "starting lerobot-teleoperate (arm will slew to home)"
# Job control on: POSIX makes a non-interactive shell set SIGINT to SIG_IGN on
# background children, so without this `kill -INT` is a silent no-op on cleanup.
set -m
lerobot-teleoperate \
  --teleop.type=vr_operator \
  --teleop.endpoint="$ENDPOINT" \
  --teleop.urdf_path="$SO101_URDF" \
  --robot.type=so101_follower \
  --robot.id="$ROBOT_ID" \
  --robot.port="$SO101_PORT" \
  --robot.max_relative_target="$MAX_RELATIVE_TARGET" \
  --fps="$FPS" >"$TELEOP_LOG" 2>&1 &
TELEOP_PID=$!
set +m

for _ in $(seq 1 150); do
  grep -q "LeRobot link: plugin Hello" "$SERVICE_LOG" && break
  kill -0 "$TELEOP_PID" 2>/dev/null || fail "lerobot-teleoperate exited; see $TELEOP_LOG"
  sleep 0.2
done
grep -q "LeRobot link: plugin Hello" "$SERVICE_LOG" || fail "plugin never handshook; see $TELEOP_LOG"
log "handshake OK; arm holding at home"

# --- launch the headset client ----------------------------------------------

# force-stop first: the activity is LAUNCH_SINGLE_INSTANCE_PER_TASK, so starting
# it while already running just resumes it and the operator.mode extra is ignored.
log "launching the Quest client in teleop mode"
$ADB shell am force-stop "$PKG" >/dev/null 2>&1 || true
sleep 2
$ADB logcat -c >/dev/null 2>&1 || true
$ADB shell am start -n "$PKG/$ACT" --es operator.mode teleop >/dev/null 2>&1 \
  || fail "could not start $PKG"

($ADB logcat 2>/dev/null | grep --line-buffered -aE "godot *:.*\[(Operator|Discovery|CommandSender|Teleop)" \
  > "$QUEST_LOG") &
LOGCAT_PID=$!

for _ in $(seq 1 50); do grep -q "Robot found" "$QUEST_LOG" 2>/dev/null && break; sleep 0.4; done
if grep -q "Robot found" "$QUEST_LOG" 2>/dev/null; then
  log "headset discovered the host: $(grep -m1 -o 'Robot found.*' "$QUEST_LOG")"
else
  fail "the headset never discovered the host in 20s.
  Check bridge.discovery_unicast_targets in $CONFIG matches $QUEST_IP, and that
  the headset is on the same wifi. See $QUEST_LOG"
fi

# --- hand over to the human --------------------------------------------------

cat <<EOF

  ------------------------------------------------------------------
  Stack is up. Now, in the headset:

   1. PUT THE HEADSET ON. Quest suspends the app when it is off your
      head, and tracking reads XR_ERROR_POSE_INVALID until it is worn.
   2. PICK UP THE CONTROLLERS. The client boots in hand-tracking mode,
      but the SO-101 descriptor maps right_controller_pose / right_grip
      / right_trigger -- hand tracking will not drive this arm.
   3. CONFIRM THE ROBOT in the panel: so101-real. It asks because the
      last host you used has a different IP, so it will not auto-connect.
   4. SQUEEZE THE RIGHT GRIP -- that is the deadman. It captures the
      baseline; the arm tracks your controller only while it is held.
        - right trigger  = gripper (released = open)
        - button B       = reset to home
        - release grip   = arm holds where it is
      Motion is relative to where you squeezed, scaled 0.5, mirrored.

  ⚠️  Keep clear of the arm. Ctrl-C here stops everything and de-energises.
  ------------------------------------------------------------------

EOF

log "tailing (Ctrl-C to stop)"
tail -f "$QUEST_LOG" &
TAIL_PID=$!
while kill -0 "$TELEOP_PID" 2>/dev/null && kill -0 "$SERVICE_PID" 2>/dev/null; do
  sleep 1
done
fail "a process exited; see $TELEOP_LOG and $SERVICE_LOG"
