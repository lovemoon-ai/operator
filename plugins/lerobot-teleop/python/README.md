# lerobot-teleoperator-vr-operator

A LeRobot teleoperator plugin that drives a real SO-101 from an Operator XR
headset, with **no changes to stock lerobot**:

```bash
lerobot-teleoperate --teleop.type=vr_operator --robot.type=so101_follower --robot.port=/dev/ttyACM0
```

## How it fits together

This is the Python half of the `lerobot_link` arm driver in the Operator Rust
adapter (`robot/crates/robot-adapter/src/control/drivers/lerobot_link.rs`). Two
processes, split along a deliberate line:

| | owns |
|---|---|
| **Rust** (`robot-service`) | the operator→robot retarget (`PoseMapper`: axis remap, mirror, scale) |
| **Python** (this plugin) | IK (`RobotKinematics`/placo), the Feetech bus, calibration |

The retarget sits *above* the driver boundary, so it is shared byte-for-byte
between the MuJoCo sim and real hardware and the two cannot drift apart.
**Everything arriving here is already a robot base-frame end-effector target**,
so this plugin implements no frame/axis/mirror/scale math whatsoever. It reads
the socket, runs IK, and returns joint targets.

The adapter **listens** and this plugin **dials in**, so the two processes can
start in either order and restart independently.

## Install

Requires **Python >= 3.12** and **lerobot >= 0.6.0**. Both floors are hard:
lerobot 0.6.x needs 3.12 syntax to import at all, and `--teleop.type=vr_operator`
depends on `register_third_party_plugins()`, which older lerobot simply does not
have. Against e.g. lerobot 0.4.1 the plugin is never discovered and the flag
fails as an unknown choice with no hint as to why — so check your version first
if that is what you see:

```bash
python -c "import lerobot; print(lerobot.__version__)"
pip install -e .   # pulls lerobot[kinematics], which provides placo for IK
```

### Fetch the URDF

The SO-101 URDF is **not vendored in lerobot**. Fetch `so101_new_calib.urdf`
(plus the meshes it references) from the
[SO-ARM100 repo](https://github.com/TheRobotStudio/SO-ARM100) and point
`--teleop.urdf_path` at it. `connect()` validates the path and fails with an
explicit message if it is missing.

If you have run LeRobot's own `isaac_teleop_to_so101` example, a copy is already
cached at `~/.cache/huggingface/lerobot/robot-urdfs/so101/so101_new_calib.urdf`
and the plugin will fall back to it when `urdf_path` is unset. Passing the path
explicitly is the supported route.

## Run

Two terminals. Start order does not matter.

**Terminal 1** — the adapter (from `robot/`):

```bash
cargo run -p robot-service -- --config configs/so101_real.yaml
```

**Terminal 2** — LeRobot, in the venv where this plugin is installed:

```bash
lerobot-teleoperate \
  --teleop.type=vr_operator \
  --teleop.endpoint=uds:/tmp/lerobot-vr.sock \
  --teleop.urdf_path=/path/to/so101_new_calib.urdf \
  --robot.type=so101_follower \
  --robot.port=/dev/ttyACM0 \
  --robot.max_relative_target=5 \
  --fps=60
```

`--teleop.endpoint` must match `adapter.arm.lerobot.endpoint` in the YAML (both
default to `uds:/tmp/lerobot-vr.sock`).

`robot-service`'s device connect **blocks until the plugin sends `Hello`**,
because `Hello` carries the forward-kinematics snapshot that driver-side IK mode
needs to seed itself — the Rust side has no FK of its own.

## ⚠️ Starting teleop MOVES the arm to home

**The arm slews to `home_joints` the moment `lerobot-teleoperate` starts**, before
you touch the headset. Verified on hardware: from a resting pose this was ~90° of
wrist_roll travel. Clear the workspace first.

This is unavoidable rather than a choice. `SOFollower.send_action` has no no-op
encoding — an empty action is a crash, not a hold (see below) — so *every* tick
must command some pose, including the first. And a teleoperator cannot read the
follower's measured position: `get_action()` takes no arguments, and the stock
loop only routes observations to `send_feedback` for `unitree_g1`. `home_joints`
is the only pose the plugin knows. `--robot.max_relative_target` bounds each step
of the slew, so it creeps rather than lunges — **keep it set**.

The same fact makes `Hello` honest only after that slew: it reports
**FK(`home_joints`)**, i.e. it *claims* the arm is at home, and nothing verifies
it. Once the startup slew completes the claim is true. Pressing reset (XR button
B) re-establishes it at any time; reset is honoured even while disabled, and keeps
commanding home until you start driving (a single home command would strand the
arm mid-slew, since `max_relative_target` caps each step).

### Separately: a power-cycled arm slams on connect

Not this plugin's doing, but it will bite you on the same hardware. A freshly
powered SO-101 reads `Goal_Position` = raw 0, which is below every joint's
calibrated `range_min`. `SOFollower.connect()` → `configure()` wraps its work in
`bus.torque_disabled()`, whose `finally:` unconditionally **re-enables torque** —
having just set `Acceleration`/`Maximum_Acceleration` to 254 (max). So connecting
to a power-cycled arm drives every joint into its mechanical stop at full
acceleration. `--robot.max_relative_target` does **not** help: it clamps
`send_action`, and this happens before any `send_action`.

Seed `Goal_Position` ← `Present_Position` while torque is off first (writing a
goal with torque disabled causes no motion, and makes the subsequent
`enable_torque` a no-op hold). `cicd/06_single_so101_lerobot_device.sh` does this as a
pre-flight; copy it.

## Safety contract

`get_action()` **always returns a full six-key action, never `{}`.** Whenever the
link is not positively commanding motion it re-commands the last setpoint, which
is the only way to express "no change":

- nothing received yet (unseeded → `home_joints`; see above)
- `Control.enabled` is false (deadman released)
- `Control.stopped` is true (e-stop; outranks a pending reset, and does *not*
  inherit the reset's home target)
- the latest target is older than `command_timeout_ms` (default 500 ms)
- IK did not converge (an `Error` frame is also sent to the adapter)

> `{}` is **not** a safe no-op in LeRobot — it is a crash.
> `SOFollower.send_action({})` filters to an empty `goal_pos`, and
> `MotorsBus.sync_write("Goal_Position", {})` then calls `next(iter(models))` on
> an empty list → `StopIteration`, killing the teleop loop. This is an upstream
> bug (LeRobot's own `phone` teleoperator returns `{}` and takes the same crash
> against an SO-101 follower), and it would fire here **every time the operator
> released the deadman**, so it is worked around in this plugin.

An adapter restart does **not** tear down the teleop loop: the link reconnects on
its own, and reverts to the safe (disabled) state in the meantime so a stale
`enabled=true` cannot keep driving the arm.

## Units (the #1 bug in this plugin)

`get_action()` returns:

| key | unit |
|---|---|
| `shoulder_pan.pos`, `shoulder_lift.pos`, `elbow_flex.pos`, `wrist_flex.pos`, `wrist_roll.pos` | **degrees** |
| `gripper.pos` | **0–100 (`RANGE_0_100`), never degrees** |

The gripper scale comes from `so_follower`, which registers the gripper motor as
`MotorNormMode.RANGE_0_100` while the five arm joints use `MotorNormMode.DEGREES`
(`use_degrees=True` by default). The adapter sends a normalized `0..1` gripper on
the wire; the plugin maps it to `0..100`. Hence `home_gripper=85.0` means
*85% open*, not 85 degrees.

## Configuration

| field | default | meaning |
|---|---|---|
| `endpoint` | `uds:/tmp/lerobot-vr.sock` | where the adapter listens; `uds:<path>` or `tcp:<host>:<port>` |
| `urdf_path` | `""` | path to `so101_new_calib.urdf` (see above) |
| `target_frame` | `gripper_frame_link` | URDF frame IK targets |
| `home_joints` | `[0, -90, 90, 0, 0]` | 5 arm joints, **degrees**; used for `Hello` FK and reset |
| `home_gripper` | `85.0` | **`RANGE_0_100`**, not degrees |
| `command_timeout_ms` | `500` | targets older than this are stale → hold |
| `connect_timeout_ms` | `30000` | how long `connect()` waits for the adapter |
| `state_report_hz` | `20.0` | upper bound on `State` frames back to the adapter |
| `ik_position_weight` | `1.0` | IK soft-task weight |
| `ik_orientation_weight` | `0.01` | small but nonzero: the 5-DoF arm cannot hit arbitrary orientations |
| `ik_position_tolerance` | `0.02` | max IK residual, **meters**; above this → non-convergent |
| `ik_max_iterations` | `10` | see below |

### A note on the IK loop

`RobotKinematics.inverse_kinematics` runs **one** differential-IK (QP) step per
call rather than solving to convergence — a 5 cm target jump lands ~2.3 cm away
after a single call. It also exposes no convergence flag (the frame task is
*soft*, so it always "succeeds"), so the position residual is the only honest
signal.

This plugin therefore iterates the solver, feeding each solution back as the next
initial guess, until the residual is inside `ik_position_tolerance`. Reachable
targets settle in 2–4 steps and `get_action()` costs ~0.1–0.3 ms, well inside a
60 fps budget. Without the loop, any jump larger than the tolerance would be
judged unreachable and rejected forever — `_last_q` never advances on failure, so
the arm would deadlock.

## Threading

`get_action()` must not block: the stock `teleop_loop` is single-threaded and
sleeps `1/fps - dt` with no drift compensation, so a blocking read would directly
stretch the control loop period. A background daemon thread owns the socket and
writes the latest sample into a lock-guarded slot; `get_action()` does a
non-blocking read of that slot. Targets are latest-wins — the XR client pushes at
~72 Hz while the LeRobot loop pulls at its own `--fps`, and stale frames are
dropped rather than queued.

## Wire protocol

Framing is `[4B len LE][JSON]`, mirroring the Rust `LinkCodec`.

**adapter → plugin**

```jsonc
{"type":"Target","ee_pose":{"position":[x,y,z],"rotation":[qx,qy,qz,qw]},"gripper":0.5,"seq":N,"ts_ns":N}
{"type":"Target","positions":[5 floats deg],"gripper":0.5,"seq":N,"ts_ns":N}   // direct, no IK
{"type":"Control","enabled":bool,"stopped":bool,"reset_epoch":N}
```

A `Target` carries **either** `ee_pose` (IK mode) **or** `positions` (direct
passthrough) **or** neither (gripper-only update); `gripper` may be absent.
Quaternions are **xyzw**; positions are **meters**. `reset_epoch` is a monotonic
counter rather than an event, so a reconnecting plugin resynchronises rather than
missing or replaying the edge.

**plugin → adapter**

```jsonc
{"type":"Hello","joint_names":[...],"positions":[6 floats],"ee":{"position":[..],"rotation":[..]}}
{"type":"State","positions":[6 floats],"ee":{...},"ik_error":0.001,"ts_ns":N}
{"type":"Error","msg":"..."}
```

`positions` is 5 arm joints in degrees followed by the gripper in `RANGE_0_100`.
`Hello` is sent immediately on every (re)connect; after the first one it reports
current commanded state rather than home, since that is the truth by then.

## Tests

Pure protocol/unit tests — no headset, no adapter, no hardware, no placo:

```bash
pip install -e '.[test]'
pytest
```

They cover the codec against byte-exact frames matching the Rust `LinkCodec`, the
gripper `0..1 → 0..100` mapping, the `{}` safe-hold contract, and
`action_features`/`get_action()` key agreement. Real motion coverage belongs on
the device.
