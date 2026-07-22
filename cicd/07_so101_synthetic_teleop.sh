#!/usr/bin/env bash
# Human-free Quest→SO-101 teleop device test (single OR dual arm).
#
# This is the automatable half of the old 07 (now examples/quest_so101_teleop_manual.sh,
# which needs a human in a headset). It proves the SAME vertical slice end to
# end, but with a SYNTHETIC operator instead of a person:
#
#   Quest 3 (Godot client, launched in synthetic teleop mode)
#     --TCP 63901 DeviceCommand @72Hz--> xr-bridge (in robot-service)
#         -> forward.rs (descriptor clamp + deadman watchdog)
#         -> robot-adapter: PoseMapper retarget (per arm)
#         -> lerobot_link driver (uds)               [one per arm]
#     --> lerobot-teleoperate --teleop.type=vr_operator
#         -> placo IK -> so101_follower -> Feetech bus -> arm
#     <--Telemetry 10Hz-- joint_angles --> the client self-asserts the arm moved
#
# The client's SyntheticTeleopSource (scripts/xr/synthetic_teleop_source.gd)
# replaces OpenXR tracking with a canned trajectory: squeeze the deadman, sweep a
# small bounded path, release. teleop_controller then checks — via the REAL
# telemetry stream — that the arm's joint angles actually moved, and quits
# 0 (PASS) / 2 (FAIL). We read that verdict from logcat.
#
# DUAL ARM (on the fly): set DUAL=1. Everything downstream follows the robot's
# descriptor automatically — the SAME client build drives two controllers and
# raises the PASS bar to "BOTH arms tracked" the moment it sees a dual descriptor
# (device type so101_dual_arm), so no separate client flag is needed. This script
# just launches the dual config and one lerobot-teleoperate per arm:
#
#     DUAL=1 SO101_PORT_LEFT=/dev/tty.usbmodemL SO101_PORT_RIGHT=/dev/tty.usbmodemR \
#       bash cicd/07_so101_synthetic_teleop.sh
#
# ⚠️  THE ARM(S) MOVE. On start each slews to home (bounded by
#     --robot.max_relative_target); then it tracks the synthetic sweep. Clear the
#     workspace. Ctrl-C tears everything down and de-energises every arm.
#
# ⚠️  DO NOT touch a serial bus while this runs (a second process corrupts the
#     bus and kills the teleop loop). Arm state is asserted from adapter telemetry
#     via the client, never by opening the port here.
#
# No manual configuration required for single arm: prepare_lerobot_so101.sh builds
# the venv, finds the serial port, and locates the URDF; the host IP is
# auto-detected; the client direct-connects (no discovery beacon). Dual needs the
# two ports named explicitly (auto-detect cannot tell left from right).
#
# Usage:
#   bash cicd/07_so101_synthetic_teleop.sh
#   HOST_IP=10.79.153.20 SYNTH_DURATION=30 bash cicd/07_so101_synthetic_teleop.sh
#   DUAL=1 SO101_PORT_LEFT=/dev/ttyACM0 SO101_PORT_RIGHT=/dev/ttyACM1 \
#     bash cicd/07_so101_synthetic_teleop.sh
#
# Requires: one real SO-101 on USB (two for DUAL=1), and a Quest on USB (adb) +
# the same wifi as the host (so it can reach HOST_IP:63901).
#
# For dual SO101 arm:
#   DUAL=1 \
#   SO101_PORT_LEFT=/dev/tty.usbmodem5AAF2192831 \
#   SO101_PORT_RIGHT=/dev/tty.usbmodem58FA1019921 \
#   ROBOT_ID_LEFT=so101_follower_left \
#   ROBOT_ID_RIGHT=so101_follower_right \
#   bash cicd/07_so101_synthetic_teleop.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROBOT_DIR="$ROOT/robot"

# --- arm topology: one arm, or two --------------------------------------------
#
# DUAL=1 flips this whole script to the two-arm path. Resolved BEFORE sourcing
# prepare, because prepare auto-detects a single serial port and hard-fails when
# more than one device is present — which is exactly the dual case. So in dual
# mode we require the two ports by name and hand prepare one of them, bypassing
# its detection while still letting it build the venv and locate the URDF.
DUAL="${DUAL:-0}"

if [ "$DUAL" = "1" ]; then
  SO101_PORT_LEFT="${SO101_PORT_LEFT:-}"
  SO101_PORT_RIGHT="${SO101_PORT_RIGHT:-}"
  [ -n "$SO101_PORT_LEFT" ]  || { echo "[synthetic-teleop] FAIL: DUAL=1 needs SO101_PORT_LEFT=/dev/..." >&2; exit 1; }
  [ -n "$SO101_PORT_RIGHT" ] || { echo "[synthetic-teleop] FAIL: DUAL=1 needs SO101_PORT_RIGHT=/dev/..." >&2; exit 1; }
  # Give prepare a real, present port so its single-port detection is satisfied.
  export SO101_PORT="${SO101_PORT:-$SO101_PORT_LEFT}"
fi

# Make the lerobot env READY (venv + serial port + URDF), exporting SO101_PORT /
# SO101_URDF / PYTHON and putting the venv on PATH. No env vars needed by hand
# for single arm. (Set SKIP_LEROBOT_PREPARE=1 to bypass when provisioned elsewhere.)
source "$ROOT/cicd/prepare_lerobot_so101.sh"

SO101_PORT="${SO101_PORT:-/dev/ttyACM0}"
SO101_URDF="${SO101_URDF:-}"
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

# --- per-arm parallel arrays --------------------------------------------------
#
# One entry per arm. The single-arm and dual-arm paths differ ONLY in how these
# are populated; every loop below is topology-agnostic. The dual endpoints and
# ids match configs/so101_dual_real.yaml (each arm owns a distinct uds socket and
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
QUEST_LOG="$OUTPUT_DIR/quest-logcat.log"
SERVICE_PID=""
TELEOP_PIDS=()      # one lerobot-teleoperate per arm
LOGCAT_PID=""

log()  { printf '\033[36m[synthetic-teleop]\033[0m %s\n' "$*"; }
fail() { printf '\033[31m[synthetic-teleop] FAIL:\033[0m %s\n' "$*" >&2; exit 1; }

# Count matching lines in a file, always echoing a single clean integer.
# `grep -c` prints "0" AND exits non-zero on no match, so the naive
# `$(grep -c ... || echo 0)` yields "0\n0" and blows up `[ -ge ]` with "integer
# expression expected"; a missing file yields empty. This normalises both.
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
# briefly by a lerobot process that is unwinding. Never claims success it did not
# confirm — torque left on means the arm holds at Acceleration=254.
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
  printf '\a\033[31m[synthetic-teleop] !!!!! WARNING: could not confirm arm %s is de-energised after 5 tries.\033[0m\n' "$id" >&2
  printf '\033[31m[synthetic-teleop] !!!!! The arm may still be HOLDING UNDER TORQUE. Power it off at the supply.\033[0m\n' >&2
  return 1
}

# De-energise every arm. Runs each sequentially: two processes on one bus is
# fine here (different ports), and a shared port would be a config error anyway.
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
  for pid in "${TELEOP_PIDS[@]+"${TELEOP_PIDS[@]}"}" "$SERVICE_PID" "$LOGCAT_PID"; do
    [ -n "$pid" ] && wait "$pid" 2>/dev/null || true
  done
  # Clear every uds socket we may have created.
  local ep
  for ep in "${ARM_ENDPOINTS[@]}"; do
    rm -f "${ep#uds:}" 2>/dev/null || true
  done
  # Never leave a physical arm powered.
  deenergise_all
  log "logs in $OUTPUT_DIR"
  return $rc
}
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

[ -n "$SO101_URDF" ] && [ -f "$SO101_URDF" ] || fail "URDF not found (SO101_URDF=$SO101_URDF)"

# The URDF references its mesh STLs at assets/*.stl (resolved next to the URDF).
# Those ~17MB meshes are deliberately NOT vendored; the mujoco example's
# prepare.sh fetches them into assets/so101/assets/. Without them placo aborts
# the plugin at connect() with "Mesh assets/<x>.stl could not be found" — the
# same failure for single AND dual arms. Ensure them here (fast no-op when
# present) whenever the chosen URDF is the example's own, so the test provisions
# itself instead of dying deep inside the plugin. A URDF pointed elsewhere owns
# its own meshes, so we skip the fetch for it.
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

# Every endpoint this run uses must actually appear in the config the adapter
# reads, or the plugin dials a socket nobody is listening on. (The single-arm
# guard grew a second arm; same idea, one check per side.)
for i in $(seq 0 $((N_ARMS - 1))); do
  ep="${ARM_ENDPOINTS[$i]}"
  grep -q "$ep" "$ROBOT_DIR/$CONFIG" \
    || fail "endpoint '$ep' (arm '${ARM_IDS[$i]}') not found in $CONFIG; align this run with the config"
done

# Clear any stale sockets before robot-service binds them.
for ep in "${ARM_ENDPOINTS[@]}"; do
  rm -f "${ep#uds:}" 2>/dev/null || true
done

# --- SAFETY: neutralise the latched goal before torque is enabled ------------
#
# A power-cycled SO-101 reads Goal_Position = raw 0, below every joint's
# calibrated range_min, and LeRobot's connect() unconditionally re-enables torque
# at max acceleration. Seeding Goal <- Present while torque is off makes that a
# no-op hold instead of a full-speed slam into the endstops. Done per arm.
for i in $(seq 0 $((N_ARMS - 1))); do
  port="${ARM_PORTS[$i]}"; id="${ARM_IDS[$i]}"
  log "pre-flight: seeding Goal_Position <- Present_Position on '$id' (torque off)"
  "$PYTHON" - "$port" "$id" <<'PY' || fail "goal seeding failed for '$id'"
import sys, time
from lerobot.robots.so_follower import SOFollower, SOFollowerRobotConfig
r = SOFollower(SOFollowerRobotConfig(port=sys.argv[1], id=sys.argv[2]))
if not r.calibration:
    sys.exit(f"no calibration for id={sys.argv[2]!r}; run lerobot-calibrate first")

# The Feetech sync_read occasionally returns "no status packet" — a single
# transient bus glitch, not a real fault (a re-read succeeds). The read defaults
# to one try, so an unlucky glitch used to abort the whole run before torque was
# ever touched. Retry the reads a few times; this stays read-only (torque off),
# so retrying is free of any motion risk. A dual rig doubles the buses in play,
# so it hits this roughly twice as often.
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
        sys.exit("torque already ON; re-run this script (it de-energises on exit) or power-cycle the arm")
    present = retry(lambda: r.bus.sync_read("Present_Position", normalize=False))
    # Writes hit the same transient "no status packet" as reads, so each servo's
    # Goal write is retried too — otherwise one glitched write aborts the whole
    # run. Still torque-off, so retrying moves nothing.
    for m, v in present.items():
        retry(lambda m=m, v=v: r.bus.write("Goal_Position", m, v, normalize=False))
    deg = retry(lambda: r.bus.sync_read("Present_Position"))
    print("  arm is at:", {k: round(v, 1) for k, v in deg.items()})
finally:
    r.bus.disconnect()
PY
done

# --- start the robot half ----------------------------------------------------

# Fail fast if a previous robot-service is still holding its adapter port (e.g.
# orphaned by a hard kill), instead of letting the new one die mid-run with a
# cryptic "Address already in use". Turn it into an actionable preflight error.
ADAPTER_PORT="$(grep -A3 '^adapter_link:' "$ROBOT_DIR/$CONFIG" 2>/dev/null \
  | grep -oE 'tcp:[0-9.]+:[0-9]+' | grep -oE '[0-9]+$' | head -1)"
ADAPTER_PORT="${ADAPTER_PORT:-63910}"
if command -v lsof >/dev/null 2>&1 && lsof -nP -iTCP:"$ADAPTER_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  fail "port $ADAPTER_PORT is already in use — a previous robot-service is likely still running. Clear it with:  kill \$(lsof -nP -tiTCP:$ADAPTER_PORT -sTCP:LISTEN)"
fi

log "building robot-service"
(cd "$ROBOT_DIR" && cargo build --release -p robot-service) >"$OUTPUT_DIR/build.log" 2>&1 \
  || fail "cargo build failed; see $OUTPUT_DIR/build.log"

log "starting robot-service ($CONFIG)"
# `exec` so the subshell is REPLACED by robot-service and $! is its REAL pid.
# Without it, $! is the subshell's pid; killing that on cleanup leaves the
# robot-service child orphaned and still holding tcp:63910 / :63901, so the NEXT
# run dies with "Address already in use". (That is exactly what stranded a prior
# run's service until it was killed by hand.)
(cd "$ROBOT_DIR" && RUST_LOG="${RUST_LOG:-info}" \
  exec ./target/release/robot-service --config "$CONFIG") >"$SERVICE_LOG" 2>&1 &
SERVICE_PID=$!
# Wait until every arm's uds socket is BOUND (its socket file appears), NOT for a
# per-arm "listening" log line. robot-service binds all sockets up front but then
# waits for each plugin's Hello sequentially — the second arm's "listening" line
# only prints AFTER the first plugin connects. Gating plugin launch on N such
# lines would therefore deadlock (plugins wait for the log, the log waits for the
# plugins). The socket files existing is the real "ready for a plugin to dial"
# signal, and both are bound within a millisecond of startup.
for _ in $(seq 1 100); do
  [ "$(count_bound_sockets)" -ge "$N_ARMS" ] && break
  kill -0 "$SERVICE_PID" 2>/dev/null || fail "robot-service exited before binding its sockets; see $SERVICE_LOG"
  sleep 0.2
done
[ "$(count_bound_sockets)" -ge "$N_ARMS" ] \
  || fail "robot-service did not bind all $N_ARMS uds socket(s); see $SERVICE_LOG"

mrt_flag=""
if [ -n "$MAX_RELATIVE_TARGET" ]; then
  mrt_flag="--robot.max_relative_target=$MAX_RELATIVE_TARGET"
  log "starting $N_ARMS lerobot-teleoperate process(es) (arms slew to home; max_relative_target=$MAX_RELATIVE_TARGET)"
else
  log "starting $N_ARMS lerobot-teleoperate process(es) (arms slew to home; max_relative_target OMITTED — plugin JointRateLimiter bounds slew)"
fi

# One lerobot-teleoperate per arm: the plugin drives exactly one follower, so a
# dual rig is two processes, each on its own endpoint / id / port.
set -m
for i in $(seq 0 $((N_ARMS - 1))); do
  name="${ARM_NAMES[$i]}"; ep="${ARM_ENDPOINTS[$i]}"; id="${ARM_IDS[$i]}"; port="${ARM_PORTS[$i]}"
  teleop_log="$OUTPUT_DIR/lerobot-teleoperate-$name.log"
  log "  arm '$id' -> endpoint=$ep port=$port (log: $(basename "$teleop_log"))"
  # shellcheck disable=SC2086  # mrt_flag is intentionally word-split (empty => omitted)
  lerobot-teleoperate \
    --teleop.type=vr_operator \
    --teleop.endpoint="$ep" \
    --teleop.urdf_path="$SO101_URDF" \
    --robot.type=so101_follower \
    --robot.id="$id" \
    --robot.port="$port" \
    $mrt_flag \
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

# --- launch the headset client in SYNTHETIC teleop mode ----------------------
#
# No dual flag is passed: the client reads the robot's descriptor and switches to
# two-handed drive + a both-arms-moved verdict on its own when the device type is
# a dual arm. That keeps "on the fly" honest — the same launch command drives one
# or two arms depending purely on what robot-service advertises.

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
  # A plugin dying is a hard stop — no point waiting out the timeout.
  for pid in "${TELEOP_PIDS[@]+"${TELEOP_PIDS[@]}"}"; do
    kill -0 "$pid" 2>/dev/null || { log "a lerobot-teleoperate process exited early"; break 2; }
  done
  kill -0 "$SERVICE_PID" 2>/dev/null || { log "robot-service exited early"; break; }
  sleep 1
done

echo
log "---- client teleop log ----"
grep -aE "\[TeleopSynthetic\]|Connected to|Auto-connecting|Connecting to" "$QUEST_LOG" 2>/dev/null | tail -20 || true
log "---------------------------"

case "$verdict" in
  PASS)
    # Corroborate host-side that the plugin(s) stayed up through the run.
    [ "$(count_lines "LeRobot link: enabled" "$SERVICE_LOG")" -ge "$N_ARMS" ] \
      || log "note: adapter logged 'enabled' fewer than $N_ARMS times (check $SERVICE_LOG)"
    log "PASS — synthetic operator drove $N_ARMS arm(s); logs in $OUTPUT_DIR"
    ;;
  FAIL)
    fail "client reported FAIL; see $QUEST_LOG (and $SERVICE_LOG / $OUTPUT_DIR/lerobot-teleoperate-*.log)"
    ;;
  *)
    fail "no verdict within ${APP_TIMEOUT}s; see $QUEST_LOG, $SERVICE_LOG, $OUTPUT_DIR/lerobot-teleoperate-*.log"
    ;;
esac
