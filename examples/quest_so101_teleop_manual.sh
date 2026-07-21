#!/usr/bin/env bash
# Bring up the full Quest 3 -> real SO-101 teleop stack and hold it open (single
# OR dual arm), for a human wearing the headset to drive.
#
# EXAMPLE / MANUAL BRING-UP — not a CI test. It needs a person in the headset, so
# it cannot run unattended. For the automated, human-free version of this same
# vertical slice, see cicd/07_so101_synthetic_teleop.sh.
#
# It starts everything, proves the headset can see the host, and then tails the
# logs while you drive. Ctrl-C tears it all down and de-energises every arm.
#
#   Quest 3 (Godot client)
#     --UDP 63900 discovery--> host
#     --TCP 63901 DeviceCommand @90Hz--> xr-bridge
#         -> forward.rs (descriptor clamp + deadman watchdog)
#         -> robot-adapter: PoseMapper retarget  [per arm]
#         -> lerobot_link driver (uds)               [one per arm]
#     --> lerobot-teleoperate --teleop.type=vr_operator
#         -> placo IK -> so101_follower -> Feetech bus -> arm
#
# DUAL ARM (on the fly): set DUAL=1. The client auto-detects the dual descriptor
# (device type so101_dual_arm) and drives BOTH controllers — left controller ->
# left arm, right controller -> right arm — so no client flag is needed. This
# script just launches the dual config and one lerobot-teleoperate per arm.
#
# ⚠️  THE ARM(S) MOVE.
#   * On start each slews to home (bounded by --robot.max_relative_target). This
#     is unavoidable; see the plugin README. Clear the workspace.
#   * Squeeze a grip and that arm tracks that controller.
#
# ⚠️  DO NOT touch a serial bus while this runs. A second process on the port
#   ("multiple access on port") corrupts reads AND kills the teleop loop. Read
#   arm state from the adapter's telemetry, or stop this script first.
#
# Usage:
#   bash examples/quest_so101_teleop_manual.sh
#   SO101_PORT=/dev/tty.usbmodem... QUEST_IP=10.79.153.133 bash examples/quest_so101_teleop_manual.sh
#   DUAL=1 SO101_PORT_LEFT=/dev/tty.usbmodemL SO101_PORT_RIGHT=/dev/tty.usbmodemR \
#     ROBOT_ID_LEFT=so101_follower_left ROBOT_ID_RIGHT=so101_follower_right \
#     bash examples/quest_so101_teleop_manual.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROBOT_DIR="$ROOT/robot"

# --- arm topology: one arm, or two --------------------------------------------
#
# DUAL=1 resolves BEFORE sourcing prepare, because prepare auto-detects a single
# serial port and hard-fails when more than one device is present — exactly the
# dual case. So in dual mode we require the two ports by name and hand prepare
# one of them, bypassing its detection while still letting it build the venv and
# locate the URDF.
DUAL="${DUAL:-0}"

if [ "$DUAL" = "1" ]; then
  SO101_PORT_LEFT="${SO101_PORT_LEFT:-}"
  SO101_PORT_RIGHT="${SO101_PORT_RIGHT:-}"
  [ -n "$SO101_PORT_LEFT" ]  || { echo "[quest-teleop] FAIL: DUAL=1 needs SO101_PORT_LEFT=/dev/..." >&2; exit 1; }
  [ -n "$SO101_PORT_RIGHT" ] || { echo "[quest-teleop] FAIL: DUAL=1 needs SO101_PORT_RIGHT=/dev/..." >&2; exit 1; }
  export SO101_PORT="${SO101_PORT:-$SO101_PORT_LEFT}"
fi

# Make the environment READY: create/refresh the uv-managed lerobot venv,
# auto-detect the serial port, and locate the URDF. EXPORTS SO101_PORT /
# SO101_URDF / PYTHON and puts the venv on PATH.
# (Set SKIP_LEROBOT_PREPARE=1 to bypass when provisioned elsewhere.)
source "$ROOT/cicd/prepare_lerobot_so101.sh"

SO101_PORT="${SO101_PORT:-/dev/tty.usbmodem58FA1019921}"
SO101_URDF="${SO101_URDF:-$HOME/.cache/huggingface/lerobot/robot-urdfs/so101/so101_new_calib.urdf}"
# Measured-space safety floor: send_action clamps each goal to +/-N of a fresh
# Present_Position read. Keep it on -- the read is ~1.3ms and the loop is
# fps/sleep-bound, so it is effectively free, and it is the ONLY thing bounding
# motion relative to where the arm ACTUALLY is (the plugin never reads encoders).
MAX_RELATIVE_TARGET="${MAX_RELATIVE_TARGET:-5}"
# 90Hz: the teleop loop's real work is ~3-4ms, so it holds 90Hz with zero jitter.
# This is the command->motor cadence and THE dominant latency knob.
FPS="${FPS:-90}"
PKG="${PKG:-com.lovemoon.operator}"
ACT="${ACT:-com.godot.game.GodotApp}"
ADB="${ADB:-adb}"
PYTHON="${PYTHON:-python3}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT/cicd/logs/quest-teleop-$(date +%Y%m%d-%H%M%S)}"

# --- per-arm parallel arrays --------------------------------------------------
#
# One entry per arm. Single- and dual-arm paths differ ONLY in how these are
# populated; every loop below is topology-agnostic. Dual endpoints/ids match
# configs/so101_dual_real.yaml (each arm owns a distinct uds socket and
# --robot.id, since LeRobot keys calibration by id).
if [ "$DUAL" = "1" ]; then
  CONFIG="${CONFIG:-configs/so101_dual_real.yaml}"
  ARM_NAMES=("left" "right")
  ARM_PORTS=("$SO101_PORT_LEFT" "$SO101_PORT_RIGHT")
  ARM_IDS=("${ROBOT_ID_LEFT:-left}" "${ROBOT_ID_RIGHT:-right}")
  ARM_ENDPOINTS=(
    "${DUAL_ENDPOINT_LEFT:-uds:/tmp/lerobot-vr-left.sock}"
    "${DUAL_ENDPOINT_RIGHT:-uds:/tmp/lerobot-vr-right.sock}"
  )
else
  CONFIG="${CONFIG:-configs/so101_real.yaml}"
  ARM_NAMES=("arm")
  ARM_PORTS=("$SO101_PORT")
  ARM_IDS=("${ROBOT_ID:-so101_follower}")
  ARM_ENDPOINTS=("${ENDPOINT:-uds:/tmp/lerobot-vr.sock}")
fi
N_ARMS="${#ARM_NAMES[@]}"

SERVICE_LOG="$OUTPUT_DIR/robot-service.log"
QUEST_LOG="$OUTPUT_DIR/quest-logcat.log"
SERVICE_PID=""
TELEOP_PIDS=()
LOGCAT_PID=""
TAIL_PID=""

log()  { printf '\033[36m[quest-teleop]\033[0m %s\n' "$*"; }
fail() { printf '\033[31m[quest-teleop] FAIL:\033[0m %s\n' "$*" >&2; exit 1; }

# Count matching lines in a file, always echoing a single clean integer.
# `grep -c` prints "0" AND exits non-zero on no match, so `$(grep -c ... || echo 0)`
# yields "0\n0" and blows up `[ -ge ]`; a missing file yields empty.
count_lines() {
  local n
  n=$(grep -c "$1" "$2" 2>/dev/null) || n=0
  [ -n "$n" ] || n=0
  printf '%s' "$n"
}

# How many of this run's uds endpoints are bound (their socket file exists).
count_bound_sockets() {
  local ep n=0
  for ep in "${ARM_ENDPOINTS[@]}"; do
    [ -e "${ep#uds:}" ] && n=$((n + 1))
  done
  printf '%s' "$n"
}

# De-energise ONE arm and VERIFY it. Retries, because the port may still be held
# for a moment by a lerobot process that is unwinding. Never claims success it
# did not confirm: torque left on means the arm holds at Acceleration=254.
deenergise_arm() {
  local port="$1" id="$2"
  [ -e "$port" ] || { log "WARNING: $port gone; cannot confirm arm '$id' is de-energised"; return 1; }
  local attempt
  for attempt in 1 2 3 4 5; do
    if "$PYTHON" - "$port" "$id" 2>/dev/null <<'PY'
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
      log "arm '$id' de-energised (verified)"
      return 0
    fi
    sleep 0.5
  done
  printf '\a\033[31m[quest-teleop] !!!!! WARNING: could not confirm arm %s is de-energised after 5 tries.\033[0m\n' "$id" >&2
  printf '\033[31m[quest-teleop] !!!!! The arm may still be HOLDING UNDER TORQUE. Power it off at the supply.\033[0m\n' >&2
  return 1
}

deenergise_all() {
  local i
  for i in $(seq 0 $((N_ARMS - 1))); do
    deenergise_arm "${ARM_PORTS[$i]}" "${ARM_IDS[$i]}" || true
  done
}

cleanup() {
  local rc=$?
  echo
  log "shutting down"

  # Kill the long-lived log followers FIRST. `tail -f` and the `adb logcat`
  # pipe never exit on their own, so a bare `wait` for them blocks cleanup
  # forever -- which is exactly what made Ctrl-C hang.
  [ -n "$TAIL_PID" ] && kill "$TAIL_PID" 2>/dev/null || true
  [ -n "$LOGCAT_PID" ] && kill "$LOGCAT_PID" 2>/dev/null || true

  # Stop the app so it can't keep commanding any arm.
  $ADB shell am force-stop "$PKG" >/dev/null 2>&1 || true

  # SIGINT so lerobot unwinds and releases the bus; SIGTERM skips its `finally`.
  local pid
  for pid in "${TELEOP_PIDS[@]+"${TELEOP_PIDS[@]}"}"; do
    [ -n "$pid" ] && kill -INT "$pid" 2>/dev/null || true
  done
  for _ in $(seq 1 25); do
    local alive=0
    for pid in "${TELEOP_PIDS[@]+"${TELEOP_PIDS[@]}"}"; do
      [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && alive=1
    done
    [ "$alive" = "0" ] && break
    sleep 0.2
  done
  for pid in "${TELEOP_PIDS[@]+"${TELEOP_PIDS[@]}"}"; do
    [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null || true
  done
  [ -n "$SERVICE_PID" ] && kill "$SERVICE_PID" 2>/dev/null || true
  for pid in "${TELEOP_PIDS[@]+"${TELEOP_PIDS[@]}"}" "$SERVICE_PID" "$TAIL_PID" "$LOGCAT_PID"; do
    [ -n "$pid" ] && wait "$pid" 2>/dev/null || true
  done
  local ep
  for ep in "${ARM_ENDPOINTS[@]}"; do
    rm -f "${ep#uds:}" 2>/dev/null || true
  done

  # Never leave a physical arm powered.
  deenergise_all
  log "logs in $OUTPUT_DIR"
  return $rc
}
# EXIT does the cleanup; INT/TERM just exit (which fires EXIT). Handling the
# signals via `exit` rather than running cleanup directly means a second Ctrl-C
# is not queued behind an in-progress trap.
trap cleanup EXIT
trap 'exit 130' INT TERM

mkdir -p "$OUTPUT_DIR"

# --- preflight ---------------------------------------------------------------

log "topology: ${N_ARMS} arm(s) [${ARM_NAMES[*]}] via $CONFIG"

# Every arm's serial port must be present, and no two arms may share one bus.
_seen_ports=""
for i in $(seq 0 $((N_ARMS - 1))); do
  p="${ARM_PORTS[$i]}"
  [ -e "$p" ] || fail "serial port for '${ARM_IDS[$i]}' not present: $p"
  case " $_seen_ports " in
    *" $p "*) fail "two arms are configured on the same port $p; give each arm its own USB device" ;;
  esac
  _seen_ports="$_seen_ports $p"
done

[ -f "$SO101_URDF" ] || fail "URDF not found at $SO101_URDF"

# The URDF references its mesh STLs at assets/*.stl (resolved next to the URDF).
# Those ~17MB meshes are deliberately NOT vendored; the mujoco example's
# prepare.sh fetches them. Without them placo aborts the plugin at connect().
_mesh_prep="$ROOT/examples/mujuco-arm-so101/prepare.sh"
case "$SO101_URDF" in
  "$ROOT/examples/mujuco-arm-so101/"*)
    if [ -x "$_mesh_prep" ]; then
      "$_mesh_prep" --check >/dev/null 2>&1 || {
        log "fetching SO-101 mesh STLs (needed by the URDF; ~17MB, one time)"
        "$_mesh_prep" || fail "mesh fetch failed; run examples/mujuco-arm-so101/prepare.sh by hand"
      }
    fi
    ;;
esac

command -v lerobot-teleoperate >/dev/null 2>&1 || fail "lerobot-teleoperate not on PATH; activate the lerobot venv"
"$PYTHON" -c "import lerobot_teleoperator_vr_operator" 2>/dev/null \
  || fail "vr_operator plugin not installed: pip install -e plugins/lerobot-teleop/python"

# adb natively honours ANDROID_SERIAL; QUEST_SERIAL accepted as an alias.
if [ -z "${ANDROID_SERIAL:-}" ] && [ -n "${QUEST_SERIAL:-}" ]; then
  export ANDROID_SERIAL="$QUEST_SERIAL"
fi
_ndev="$($ADB devices 2>/dev/null | awk '/\tdevice$/{n++} END{print n+0}')"
if [ -z "${ANDROID_SERIAL:-}" ] && [ "$_ndev" -gt 1 ]; then
  printf '[quest-teleop] attached devices:\n' >&2
  $ADB devices -l 2>/dev/null | sed -n '2,$p' >&2
  fail "more than one adb device; set ANDROID_SERIAL=<serial> (or QUEST_SERIAL=<serial>) to pick the headset"
fi
$ADB get-state >/dev/null 2>&1 || fail "no adb device; connect the Quest over USB (or set ANDROID_SERIAL)"
QUEST_IP="${QUEST_IP:-$($ADB shell ip -o -4 addr show wlan0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | tr -d '\r')}"
[ -n "$QUEST_IP" ] || fail "could not read the Quest's wifi IP; is wifi on?"
log "Quest wifi IP: $QUEST_IP"

# The headset finds the host by UDP broadcast, which many networks drop, so the
# beacon must also go unicast to the headset's IP. That IP is per-machine and
# changes with DHCP, so instead of committing it to the config we inject THIS
# headset's current IP into a runtime copy of the config used only for this run.
# (bridge is the last section in these configs, so appending under it is valid;
# any pre-existing discovery_unicast_targets block is stripped first so we never
# emit a duplicate key.) robot-service resolves the config's relative
# descriptor_file against its CWD (robot/), not the config's own dir, so a
# runtime config living in OUTPUT_DIR still loads the right descriptor.
RUNTIME_CONFIG="$OUTPUT_DIR/$(basename "${CONFIG%.yaml}").runtime.yaml"
awk '
  /^[[:space:]]*discovery_unicast_targets:/ {
    match($0, /^[[:space:]]*/); key_indent = RLENGTH; skipping = 1; next
  }
  skipping {
    if ($0 ~ /^[[:space:]]*$/) { next }
    match($0, /^[[:space:]]*/)
    if (RLENGTH > key_indent) { next }   # a list item / child of the dropped key
    skipping = 0
  }
  { print }
' "$ROBOT_DIR/$CONFIG" > "$RUNTIME_CONFIG"
printf '  discovery_unicast_targets:\n    - %s\n' "$QUEST_IP" >> "$RUNTIME_CONFIG"
log "injected headset IP $QUEST_IP into runtime config ($(basename "$RUNTIME_CONFIG"))"

# Every endpoint this run uses must actually appear in the config the adapter
# reads, or the plugin dials a socket nobody is listening on.
for i in $(seq 0 $((N_ARMS - 1))); do
  ep="${ARM_ENDPOINTS[$i]}"
  grep -q "$ep" "$ROBOT_DIR/$CONFIG" \
    || fail "endpoint '$ep' (arm '${ARM_IDS[$i]}') not found in $CONFIG; align this run with the config"
done

$ADB shell ping -c1 -W2 "$(ipconfig getifaddr en0 2>/dev/null || echo 0.0.0.0)" >/dev/null 2>&1 \
  || log "WARNING: the Quest could not ping this host; if discovery fails, check for wifi client isolation"

# Clear any stale sockets before robot-service binds them.
for ep in "${ARM_ENDPOINTS[@]}"; do
  rm -f "${ep#uds:}" 2>/dev/null || true
done

# --- safety: neutralise the latched goal (per arm) ---------------------------
#
# A power-cycled SO-101 reads Goal_Position = raw 0, below every joint's
# calibrated range_min, and LeRobot's connect() unconditionally re-enables
# torque at max acceleration. Seeding Goal <- Present while torque is off makes
# that a no-op hold instead of a full-speed slam into the endstops.
for i in $(seq 0 $((N_ARMS - 1))); do
  port="${ARM_PORTS[$i]}"; id="${ARM_IDS[$i]}"
  log "pre-flight: seeding Goal_Position <- Present_Position on '$id' (torque off)"
  "$PYTHON" - "$port" "$id" <<'PY' || fail "goal seeding failed for '$id'"
import sys, time
from lerobot.robots.so_follower import SOFollower, SOFollowerRobotConfig
r = SOFollower(SOFollowerRobotConfig(port=sys.argv[1], id=sys.argv[2]))
if not r.calibration:
    sys.exit(f"no calibration for id={sys.argv[2]!r}; run lerobot-calibrate first")

# The Feetech bus occasionally returns "no status packet" — a single transient
# glitch, not a real fault (a retry succeeds). Reads AND writes hit it, and each
# defaults to one try, so retry both. Still torque-off, so retrying moves nothing.
def retry(fn, tries=6):
    last = None
    for _ in range(tries):
        try:
            return fn()
        except Exception as e:  # noqa: BLE001 - transient Feetech comms
            last = e
            time.sleep(0.15)
    raise last

r.bus.connect()
try:
    tq = retry(lambda: r.bus.sync_read("Torque_Enable"))
    if any(v != 0 for v in tq.values()):
        sys.exit("torque already ON; a previous run left it powered -- re-run this script "
                 "(it de-energises on exit) or power-cycle the arm")
    present = retry(lambda: r.bus.sync_read("Present_Position", normalize=False))
    for m, v in present.items():
        retry(lambda m=m, v=v: r.bus.write("Goal_Position", m, v, normalize=False))
    deg = retry(lambda: r.bus.sync_read("Present_Position"))
    print("  arm is at:", {k: round(v, 1) for k, v in deg.items()})
finally:
    r.bus.disconnect()
PY
done

# --- start the stack ---------------------------------------------------------

# Fail fast if a previous robot-service still holds its adapter port (orphaned by
# a hard kill), instead of a cryptic mid-run "Address already in use".
ADAPTER_PORT="$(grep -A3 '^adapter_link:' "$ROBOT_DIR/$CONFIG" 2>/dev/null \
  | grep -oE 'tcp:[0-9.]+:[0-9]+' | grep -oE '[0-9]+$' | head -1)"
ADAPTER_PORT="${ADAPTER_PORT:-63910}"
if command -v lsof >/dev/null 2>&1 && lsof -nP -iTCP:"$ADAPTER_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  fail "port $ADAPTER_PORT is already in use — a previous robot-service is likely still running. Clear it with:  kill \$(lsof -nP -tiTCP:$ADAPTER_PORT -sTCP:LISTEN)"
fi

log "building robot-service"
(cd "$ROBOT_DIR" && cargo build --release -p robot-service) >"$OUTPUT_DIR/build.log" 2>&1 \
  || fail "cargo build failed; see $OUTPUT_DIR/build.log"

log "starting robot-service ($CONFIG, runtime config with injected headset IP)"
# `exec` so the subshell is REPLACED by robot-service and $! is its REAL pid;
# otherwise killing the subshell on cleanup orphans robot-service still holding
# tcp:63910 / :63901, and the next run dies with "Address already in use".
# Runs against RUNTIME_CONFIG (absolute) so the injected unicast target applies;
# descriptor_file inside it is relative and resolves against CWD (robot/).
(cd "$ROBOT_DIR" && RUST_LOG="${RUST_LOG:-info}" \
  exec ./target/release/robot-service --config "$RUNTIME_CONFIG") >"$SERVICE_LOG" 2>&1 &
SERVICE_PID=$!
# Wait until every arm's uds socket is BOUND (its socket file appears), NOT for a
# per-arm "listening" log line: robot-service binds all sockets up front but then
# waits for each plugin's Hello sequentially, so gating plugin launch on N such
# lines would deadlock.
for _ in $(seq 1 100); do
  [ "$(count_bound_sockets)" -ge "$N_ARMS" ] && break
  kill -0 "$SERVICE_PID" 2>/dev/null || fail "robot-service exited before binding its sockets; see $SERVICE_LOG"
  sleep 0.2
done
[ "$(count_bound_sockets)" -ge "$N_ARMS" ] \
  || fail "robot-service did not bind all $N_ARMS uds socket(s); see $SERVICE_LOG"

log "starting $N_ARMS lerobot-teleoperate process(es) (arm(s) will slew to home)"
# Job control on: POSIX makes a non-interactive shell set SIGINT to SIG_IGN on
# background children, so without this `kill -INT` is a silent no-op on cleanup.
set -m
for i in $(seq 0 $((N_ARMS - 1))); do
  name="${ARM_NAMES[$i]}"; ep="${ARM_ENDPOINTS[$i]}"; id="${ARM_IDS[$i]}"; port="${ARM_PORTS[$i]}"
  teleop_log="$OUTPUT_DIR/lerobot-teleoperate-$name.log"
  log "  arm '$id' -> endpoint=$ep port=$port (log: $(basename "$teleop_log"))"
  lerobot-teleoperate \
    --teleop.type=vr_operator \
    --teleop.endpoint="$ep" \
    --teleop.urdf_path="$SO101_URDF" \
    --robot.type=so101_follower \
    --robot.id="$id" \
    --robot.port="$port" \
    --robot.max_relative_target="$MAX_RELATIVE_TARGET" \
    --fps="$FPS" >"$teleop_log" 2>&1 &
  TELEOP_PIDS+=("$!")
done
set +m

# robot-service's connect blocks until EVERY plugin says Hello. Wait for all,
# bailing early if any teleop process dies.
for _ in $(seq 1 150); do
  [ "$(count_lines "LeRobot link: plugin Hello" "$SERVICE_LOG")" -ge "$N_ARMS" ] && break
  for pid in "${TELEOP_PIDS[@]+"${TELEOP_PIDS[@]}"}"; do
    kill -0 "$pid" 2>/dev/null || fail "a lerobot-teleoperate process exited; see $OUTPUT_DIR/lerobot-teleoperate-*.log"
  done
  sleep 0.2
done
[ "$(count_lines "LeRobot link: plugin Hello" "$SERVICE_LOG")" -ge "$N_ARMS" ] \
  || fail "not all $N_ARMS plugin(s) handshook; see $OUTPUT_DIR/lerobot-teleoperate-*.log"
log "all $N_ARMS plugin(s) handshook; arm(s) holding at home"

# --- launch the headset client ----------------------------------------------
#
# No dual flag: the client reads the robot's descriptor and drives one or two
# arms accordingly. force-stop first: the activity is
# LAUNCH_SINGLE_INSTANCE_PER_TASK, so starting it while running ignores the extra.
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
  The runtime config injected the unicast target $QUEST_IP ($RUNTIME_CONFIG);
  confirm the headset is on the same wifi/subnet as this host and that client
  isolation is not blocking host->headset UDP. See $QUEST_LOG"
fi

# --- hand over to the human --------------------------------------------------

if [ "$DUAL" = "1" ]; then
  cat <<EOF

  ------------------------------------------------------------------
  Stack is up (DUAL arm). Now, in the headset:

   1. PUT THE HEADSET ON. Quest suspends the app when it is off your
      head, and tracking reads XR_ERROR_POSE_INVALID until it is worn.
   2. PICK UP BOTH CONTROLLERS. The dual descriptor maps the LEFT
      controller to the LEFT arm and the RIGHT controller to the RIGHT
      arm; hand tracking will not drive the arms.
   3. CONFIRM THE ROBOT in the panel: Dual SO-101 Arms.
   4. SQUEEZE A GRIP -- that hand's deadman. It captures that arm's
      baseline; the arm tracks that controller only while the grip is
      held. Each side is independent -- release one and only that arm
      holds.
        - left/right trigger  = that arm's gripper (released = open)
        - button B            = reset BOTH arms to home
      Motion is relative to where you squeezed, scaled 0.5; the right
      arm is mirrored.

  ⚠️  Keep clear of BOTH arms. Ctrl-C here stops everything and de-energises.
  ------------------------------------------------------------------

EOF
else
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
fi

log "tailing (Ctrl-C to stop)"
tail -f "$QUEST_LOG" &
TAIL_PID=$!
while kill -0 "$SERVICE_PID" 2>/dev/null; do
  _dead=0
  for pid in "${TELEOP_PIDS[@]+"${TELEOP_PIDS[@]}"}"; do
    kill -0 "$pid" 2>/dev/null || _dead=1
  done
  [ "$_dead" = "1" ] && break
  sleep 1
done
fail "a process exited; see $OUTPUT_DIR/lerobot-teleoperate-*.log and $SERVICE_LOG"
