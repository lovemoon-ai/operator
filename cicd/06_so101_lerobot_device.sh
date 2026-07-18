#!/usr/bin/env bash
# RELEASE STATUS: DEFERRED for v0.1.3 QA automation.
#   The real SO-101 path was verified MANUALLY on local hardware by the
#   maintainer for the v0.1.3 release; this automated device smoke was NOT run
#   as part of the v0.1.3 QA gate (no arm / lerobot in the QA environment).
# TODO(release): fold cicd/06 + cicd/07 into the standard CICD release QA flow
#   so real SO-101 teleop is covered automatically in future releases.
#
# Device smoke test for the real SO-101 path via the LeRobot `vr_operator` plugin.
#
# Replaces the deleted `robot/crates/robot-adapter/tests/so101_real_hardware.rs`,
# whose `#[ignore]`-gated tests drove the Feetech bus by spawning
# `scripts/so101_real_control.py`. That script and its Rust driver are gone: the
# hardware is now owned by LeRobot's `so101_follower`, driven by
# `lerobot-teleoperate`, so the equivalent coverage lives here rather than in a
# Rust test.
#
# This exercises the real two-process topology end to end:
#
#   robot-service (lerobot_link driver, listens)
#      <-- uds --> lerobot-teleoperate --teleop.type=vr_operator (dials in)
#                     --> so101_follower --> Feetech bus --> physical arm
#
# It asserts the handshake and the safety lifecycle, NOT teleop motion quality —
# driving the arm needs a headset streaming poses, which no script can stand in
# for.
#
# REQUIRES A PHYSICALLY CONNECTED SO-101. It enables torque and commands the arm
# to its home pose. Clear the workspace before running.
#
# Usage:
#   bash cicd/06_so101_lerobot_device.sh
#   SO101_PORT=/dev/ttyACM0 bash cicd/06_so101_lerobot_device.sh
#   SO101_URDF=/path/to/so101_new_calib.urdf bash cicd/06_so101_lerobot_device.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROBOT_DIR="$ROOT/robot"

# Make the environment READY before anything else: create/refresh the uv-managed
# lerobot venv, auto-detect the serial port, and locate the URDF. This EXPORTS
# SO101_PORT / SO101_URDF / PYTHON and puts the venv on PATH, so the defaults
# below become fallbacks and this test needs no env vars set by hand.
# (Set SKIP_LEROBOT_PREPARE=1 to bypass when the env is provisioned elsewhere.)
source "$ROOT/cicd/prepare_lerobot_so101.sh"

SO101_PORT="${SO101_PORT:-/dev/ttyACM0}"
SO101_URDF="${SO101_URDF:-}"
# MUST match `adapter.arm.lerobot.endpoint` in $CONFIG. The endpoint is
# configured in two places -- the adapter reads the YAML, the plugin takes a CLI
# flag -- and nothing cross-checks them. Mismatch is not an error: both sides sit
# there patiently waiting for a peer that is listening somewhere else. The
# preflight below verifies they agree rather than leaving you to read two logs.
ENDPOINT="${ENDPOINT:-uds:/tmp/lerobot-vr.sock}"
# LeRobot keys the follower's calibration file by id. With id unset the lookup
# lands on `<calib_dir>/None.json`, which does not exist -- so the arm reads as
# uncalibrated and `connect()` drops into the INTERACTIVE calibration routine.
ROBOT_ID="${ROBOT_ID:-so101_follower}"
PYTHON="${PYTHON:-python3}"
CONFIG="${CONFIG:-configs/so101_real.yaml}"
MAX_RELATIVE_TARGET="${MAX_RELATIVE_TARGET:-5}"
FPS="${FPS:-30}"
RUN_SECONDS="${RUN_SECONDS:-15}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT/cicd/logs/so101-lerobot-$(date +%Y%m%d-%H%M%S)}"

SERVICE_LOG="$OUTPUT_DIR/robot-service.log"
TELEOP_LOG="$OUTPUT_DIR/lerobot-teleoperate.log"
SERVICE_PID=""
TELEOP_PID=""

log() { printf '[so101-lerobot] %s\n' "$*"; }
fail() { printf '[so101-lerobot] FAIL: %s\n' "$*" >&2; exit 1; }

# De-energise the arm and VERIFY it. Retries, because the port may still be held
# for a moment by a lerobot process that is unwinding. Never claims success it
# did not confirm: torque left on means the arm holds at Acceleration=254, so a
# false "de-energised" on this path is worse than a loud failure. Returns 0 only
# after reading back Torque_Enable == 0 on every joint.
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
  # This is the one message the operator must not miss.
  printf '\a[so101-lerobot] !!!!! WARNING: could not confirm the arm is de-energised after 5 tries.\n' >&2
  printf '[so101-lerobot] !!!!! The arm may still be HOLDING UNDER TORQUE. Power it off at the supply.\n' >&2
  return 1
}

cleanup() {
  local rc=$?
  # SIGINT so lerobot unwinds and disables torque; SIGTERM would skip its
  # `finally` and strand the arm energised.
  [ -n "$TELEOP_PID" ] && kill -INT "$TELEOP_PID" 2>/dev/null || true
  [ -n "$SERVICE_PID" ] && kill "$SERVICE_PID" 2>/dev/null || true
  wait 2>/dev/null || true
  rm -f "${ENDPOINT#uds:}" 2>/dev/null || true

  # Belt and braces: never leave a physical arm powered because a test failed
  # somewhere unexpected.
  deenergise_arm || true

  if [ "$rc" -ne 0 ]; then
    log "logs in $OUTPUT_DIR"
  fi
  return $rc
}
trap cleanup EXIT

mkdir -p "$OUTPUT_DIR"

# --- preflight ---------------------------------------------------------------

[ -e "$SO101_PORT" ] || fail "serial port $SO101_PORT not present; set SO101_PORT="

command -v lerobot-teleoperate >/dev/null 2>&1 \
  || fail "lerobot-teleoperate not on PATH; activate the venv with lerobot installed"

"$PYTHON" - <<'PY' || exit 1
import sys
try:
    import lerobot_teleoperator_vr_operator  # noqa: F401
except Exception as e:
    sys.exit(
        f"vr_operator plugin not importable: {e}\n"
        "install it with: pip install -e plugins/lerobot-teleop/python"
    )
PY

if [ -z "$SO101_URDF" ]; then
  fail "SO101_URDF is required (so101_new_calib.urdf from the SO-ARM100 repo; LeRobot does not vendor it)"
fi
[ -f "$SO101_URDF" ] || fail "URDF not found at $SO101_URDF"

# Catch the endpoint being configured in two places and disagreeing. Without
# this both processes start happily and each waits forever for a peer on a
# different socket -- a failure that costs two logs to diagnose.
CONFIG_ENDPOINT="$(grep -A3 '^\s*lerobot:' "$ROBOT_DIR/$CONFIG" | grep -m1 'endpoint:' | sed -E 's/.*endpoint:[[:space:]]*"?([^"]*)"?.*/\1/')"
if [ -n "$CONFIG_ENDPOINT" ] && [ "$CONFIG_ENDPOINT" != "$ENDPOINT" ]; then
  fail "endpoint mismatch: $CONFIG has arm.lerobot.endpoint='$CONFIG_ENDPOINT' but this run uses ENDPOINT='$ENDPOINT'.
  They must match -- the adapter listens on the YAML value, the plugin dials the CLI value."
fi

rm -f "${ENDPOINT#uds:}" 2>/dev/null || true

# --- SAFETY: neutralise the latched goal before anything enables torque -------
#
# On a freshly powered SO-101 the servos' Goal_Position register reads raw 0,
# which is BELOW every joint's calibrated range_min. LeRobot's
# `SOFollower.connect()` -> `configure()` wraps its work in
# `bus.torque_disabled()`, whose `finally:` unconditionally re-enables torque --
# and `configure_motors()` has just set Acceleration/Maximum_Acceleration to 254
# (max). So connecting to a power-cycled arm drives every joint at full
# acceleration into its mechanical limit.
#
# `--robot.max_relative_target` does NOT protect against this: it clamps
# `send_action` steps, and this torque-enable happens before any send_action.
#
# Writing Goal_Position while torque is off causes no motion, so seeding
# Goal <- Present here makes the subsequent enable_torque a no-op hold.
log "pre-flight: seeding Goal_Position <- Present_Position (torque off)"
"$PYTHON" - "$SO101_PORT" "${ROBOT_ID:-so101_follower}" <<'PY' || fail "goal seeding failed"
import sys
from lerobot.robots.so_follower import SOFollower, SOFollowerRobotConfig

port, robot_id = sys.argv[1], sys.argv[2]
r = SOFollower(SOFollowerRobotConfig(port=port, id=robot_id))
if not r.calibration:
    sys.exit(f"no calibration for id={robot_id!r} at {r.calibration_fpath}; run lerobot-calibrate first")
r.bus.connect()
try:
    tq = r.bus.sync_read("Torque_Enable")
    if any(v != 0 for v in tq.values()):
        sys.exit(f"torque already ON ({tq}); power-cycle the arm before running this test")
    present = r.bus.sync_read("Present_Position", normalize=False)
    for m, v in present.items():
        r.bus.write("Goal_Position", m, v, normalize=False)
    goal = r.bus.sync_read("Goal_Position", normalize=False)
    pres = r.bus.sync_read("Present_Position", normalize=False)
    worst = max(abs(goal[m] - pres[m]) for m in pres)
    if worst > 5:
        sys.exit(f"seeding did not take: worst goal-present delta {worst} raw counts")
    print(f"  seeded; worst goal-present delta {worst} raw counts")
finally:
    r.bus.disconnect()
PY

# --- start robot-service (adapter listens) -----------------------------------

log "building robot-service"
(cd "$ROBOT_DIR" && cargo build --release -p robot-service) >"$OUTPUT_DIR/build.log" 2>&1 \
  || fail "cargo build failed; see $OUTPUT_DIR/build.log"

log "starting robot-service with $CONFIG"
(cd "$ROBOT_DIR" && RUST_LOG="${RUST_LOG:-info}" \
  ./target/release/robot-service --config "$CONFIG") >"$SERVICE_LOG" 2>&1 &
SERVICE_PID=$!

# The adapter binds its listener before waiting for Hello.
for _ in $(seq 1 50); do
  grep -q "LeRobot link: listening" "$SERVICE_LOG" && break
  sleep 0.2
done
grep -q "LeRobot link: listening" "$SERVICE_LOG" \
  || fail "robot-service never bound the link endpoint; see $SERVICE_LOG"
log "robot-service is listening"

# --- start the plugin (dials in) ---------------------------------------------

log "starting lerobot-teleoperate against $SO101_PORT"
# Job control on, so this background child gets its own process group and the
# DEFAULT SIGINT disposition. Without it POSIX has a non-interactive shell set
# SIGINT/SIGQUIT to SIG_IGN on background children -- `kill -INT` is then a
# silent no-op and the `wait` below blocks forever. We need SIGINT specifically:
# it is the only signal lerobot unwinds cleanly on (KeyboardInterrupt), and it
# is how an operator actually stops it.
set -m
lerobot-teleoperate \
  --teleop.type=vr_operator \
  --teleop.endpoint="$ENDPOINT" \
  --teleop.urdf_path="$SO101_URDF" \
  --robot.type=so101_follower \
  --robot.id="$ROBOT_ID" \
  --robot.port="$SO101_PORT" \
  --robot.max_relative_target="$MAX_RELATIVE_TARGET" \
  --robot.disable_torque_on_disconnect=false \
  --fps="$FPS" >"$TELEOP_LOG" 2>&1 &
TELEOP_PID=$!
set +m
# `disable_torque_on_disconnect=false` so the arm still holds when we read its
# position after shutdown -- with torque off it would sag and we would be
# measuring gravity, not the teleop chain. The EXIT trap de-energises it.

# --- assert the handshake ----------------------------------------------------

# Device connect blocks until the plugin's Hello lands: it carries the FK
# snapshot that driver-side IK mode needs to seed itself.
for _ in $(seq 1 150); do
  grep -q "LeRobot link: plugin Hello" "$SERVICE_LOG" && break
  kill -0 "$TELEOP_PID" 2>/dev/null || fail "lerobot-teleoperate exited early; see $TELEOP_LOG"
  sleep 0.2
done
grep -q "LeRobot link: plugin Hello" "$SERVICE_LOG" \
  || fail "plugin never completed the Hello handshake; see $SERVICE_LOG and $TELEOP_LOG"
log "handshake OK: plugin sent Hello with an FK snapshot"

grep -q "LeRobot link: enabled" "$SERVICE_LOG" \
  || fail "driver never reached the enabled state; see $SERVICE_LOG"
log "torque enabled"

# --- let it settle at home ---------------------------------------------------

# With no headset attached no targets flow, so the plugin holds -- and "hold"
# means re-commanding `home_joints`, because `send_action` has no no-op encoding
# and a teleoperator cannot see the follower's measured position. So the arm
# SLEWS TO HOME here (bounded per step by --robot.max_relative_target) and then
# parks. That is a real movement, not a hold: keep the workspace clear.
log "arm is slewing to home; settling for ${RUN_SECONDS}s"
sleep "$RUN_SECONDS"

kill -0 "$SERVICE_PID" 2>/dev/null || fail "robot-service died while idle; see $SERVICE_LOG"
kill -0 "$TELEOP_PID" 2>/dev/null || fail "lerobot-teleoperate died while idle; see $TELEOP_LOG"

# NOTE: must be `if ...; then`, not `grep -q ... && fail ...`. Under `set -e` the
# latter aborts the script when grep finds NOTHING (the && compound returns 1) --
# i.e. it fails precisely when the plugin is healthy.
if grep -qi "traceback\|Error:" "$TELEOP_LOG"; then
  fail "plugin logged an error while idle; see $TELEOP_LOG"
fi

log "arm settled; processes healthy"

# --- assert clean reconnect --------------------------------------------------

# Either process must survive the other restarting; that is why the adapter
# listens instead of spawning Python.
# SIGINT, not SIGTERM: Python's default SIGTERM handler exits without unwinding,
# so `teleoperate()`'s `finally: robot.disconnect()` never runs and the arm is
# left ENERGISED. SIGINT raises KeyboardInterrupt, which teleop_loop catches, so
# disconnect() runs and `disable_torque_on_disconnect` takes effect. This also
# matches how an operator actually stops it (Ctrl-C).
log "interrupting the plugin to assert the adapter survives and awaits reconnect"
kill -INT "$TELEOP_PID" 2>/dev/null || true
# Bounded wait: never block forever on a child that refuses to unwind, or a
# powered arm sits there until someone notices. Escalate to SIGTERM, then KILL.
for _ in $(seq 1 50); do
  kill -0 "$TELEOP_PID" 2>/dev/null || break
  sleep 0.2
done
if kill -0 "$TELEOP_PID" 2>/dev/null; then
  log "WARNING: plugin ignored SIGINT after 10s; escalating (torque may be left on for the trap to clear)"
  kill -TERM "$TELEOP_PID" 2>/dev/null || true
  sleep 1
  kill -9 "$TELEOP_PID" 2>/dev/null || true
fi
wait "$TELEOP_PID" 2>/dev/null || true
TELEOP_PID=""

for _ in $(seq 1 25); do
  grep -q "plugin disconnected" "$SERVICE_LOG" && break
  sleep 0.2
done
grep -q "plugin disconnected" "$SERVICE_LOG" \
  || fail "adapter did not notice the plugin disconnecting; see $SERVICE_LOG"
kill -0 "$SERVICE_PID" 2>/dev/null \
  || fail "robot-service died when the plugin disconnected; it must await reconnect"

log "adapter survived the plugin disconnect"

# --- assert the arm PHYSICALLY reached home ----------------------------------
#
# This runs only now that lerobot-teleoperate has exited and released the serial
# port. Reading mid-run would put two processes on one bus: the reads come back
# unreliable AND it breaks the follower's own shutdown (`disconnect()` raises
# "device reports readiness to read but returned no data ... multiple access on
# port?", so its disable_torque never lands).
#
# Without this assertion the test passes whenever two processes merely stay
# alive, which proves nothing about the chain driving hardware -- the entire
# point of a device test. This is the only step that exercises
# plugin -> IK -> follower -> servos end to end.
log "verifying the arm physically reached home"
"$PYTHON" - "$SO101_PORT" "$ROBOT_ID" <<'PY' || fail "arm did not reach home"
import sys
from lerobot.robots.so_follower import SOFollower, SOFollowerRobotConfig

HOME = {"shoulder_pan": 0.0, "shoulder_lift": -90.0, "elbow_flex": 90.0,
        "wrist_flex": 0.0, "wrist_roll": 0.0, "gripper": 85.0}
TOL_DEG = 5.0

port, robot_id = sys.argv[1], sys.argv[2]
r = SOFollower(SOFollowerRobotConfig(port=port, id=robot_id))
r.bus.connect()
try:
    present = r.bus.sync_read("Present_Position")
    worst, bad = 0.0, []
    for m, want in HOME.items():
        err = abs(present[m] - want)
        worst = max(worst, err)
        if err > TOL_DEG:
            bad.append(f"{m}: {present[m]:.2f} != {want} (off by {err:.2f})")
    for m, v in present.items():
        print(f"  {m:<16}{v:>8.2f}  (home {HOME[m]:>6.1f})")
    if bad:
        sys.exit("arm did not reach home:\n  " + "\n  ".join(bad))
    print(f"  -> all joints within {TOL_DEG} deg of home (worst {worst:.2f})")
finally:
    r.bus.disconnect(disable_torque=False)  # the EXIT trap owns de-energising
PY

log "PASS - logs in $OUTPUT_DIR"
