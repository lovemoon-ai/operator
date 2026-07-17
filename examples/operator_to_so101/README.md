# Operator to SO-101

This example teleoperates a **real SO-101/SO-100 follower** from Operator XR
and records the same sessions as a LeRobotDataset. Operator remains the only
owner of headset OpenXR and display; LeRobot remains the only owner of the
follower serial port.

```text
Operator APK (OpenXR + display)
    -> canonical RCTL/CTRL UDP
    -> xr-bridge UDP-to-UDS gateway
    -> OperatorControllerSource
    -> relative clutch -> EE bounds/rate limit -> Placo IK
    -> LeRobot SOFollower (/dev/ttyACM*)
    -> optional LeRobotDataset (camera + joints + executed action + XR provenance)
```

The implementation follows LeRobot's `isaac_teleop_to_so101` example at the
pinned revision documented in [UPSTREAM.md](UPSTREAM.md). It reuses the real
robot, clutch, reset slew, IK/safety and recorder code. It does **not** start
CloudXR or an IsaacTeleop LIVE session: in the upstream controller example,
that layer only returned a raw controller pose, which Operator already
provides. No NVIDIA IsaacTeleop patch/install is required for this physical-arm
example. Isaac Sim retargeting continues to use `plugins/isaac-teleop` and its
EXTERNAL session adapter.

## Prerequisites

- Linux host with the SO-101 serial device (commonly `/dev/ttyACM0`);
- Python 3.12 or newer and `uv`;
- calibrated SO-101 follower;
- built/installed Operator XR APK and a Pico/Quest/Android XR device;
- `xr-bridge` reachable from the headset;
- a trusted LAN when using the development token `0`.

Do not run `robot-adapter` against the same serial port. Do not run
`operator-isaacteleop-receive` at the same time: the SO-101 process must be the
only owner of both `/dev/ttyACM0` and `/tmp/operator-isaacteleop.sock`.

## Install and calibrate

From this directory:

```bash
uv sync --extra test

uv run lerobot-calibrate \
  --robot.type=so101_follower \
  --robot.port=/dev/ttyACM0 \
  --robot.id=so101_follower_arm
```

The first teleoperation run downloads the public SO-101 URDF and meshes into
the LeRobot cache. To replace the built-in startup pose, move the torque-free
arm by hand and save its measured pose:

```bash
uv run operator-to-so101-save-reset \
  --port=/dev/ttyACM0 --id=so101_follower_arm
```

## Start the transport

Start the existing gateway from the repository's `robot/` directory. It may
run before the UDS receiver exists and will keep accepting headset packets:

```bash
cargo run -p xr-bridge -- \
  --config configs/isaac-teleop-example.yaml --video-only
```

The example bridge config also advertises `rtsp://127.0.0.1:8554/head` for the
headset display. Supply that H.264 feed when remote video is needed; the
controller gateway itself remains active if the video source is temporarily
unavailable.

Launch the installed Operator APK with the explicit feature opt-in:

```bash
make -C xr run-isaac-teleop
```

Normal Operator launches keep the IsaacTeleop sink disabled.

## Teleoperate the follower

With the bridge running, start this command; it binds the UDS receiver and
waits up to `--teleop.wait_timeout_s` for the headset before opening the
follower serial port. Then launch the APK:

```bash
uv run operator-to-so101-teleoperate \
  --robot.type=so101_follower \
  --robot.port=/dev/ttyACM0 \
  --robot.id=so101_follower_arm \
  --robot.max_relative_target=5
```

Controls:

- A/X: arm or pause motion;
- hold Grip: deadman + relative clutch; release it to reposition your hand;
- Trigger: close the gripper;
- B/Y: disarm and re-anchor the clutch/IK at the measured robot pose;
- headset/app disconnect: send kill, disconnect the follower and disable torque.

Motion requires a fresh valid controller pose, fresh CTRL heartbeat, armed
state, held deadman and squeeze over `--teleop.clutch_threshold`. A CTRL timeout
disarms; it never replays stale motion. Use `--reset_to_origin=false` to keep the
startup pose, or `--teleop.require_run_toggle=false` for Grip-only lab testing.
The Cartesian target is additionally limited by
`--teleop.max_ee_step_m=0.03`; the required joint-space
`--robot.max_relative_target` remains the final follower-side guard.
The default `--teleop.token=0` matches the trusted-LAN example; set the minted
non-zero session token in production.

## Record a LeRobotDataset

LeRobot cameras are configured on `--robot.cameras`. This example records the
robot observation, the **actually sent** joint action after LeRobot safety
clipping, task text, and these exact Operator provenance columns:

- `operator.pose` and `operator.axes`;
- `operator.status` (tracking/control/deadman/armed/engaged/reset/kill);
- `operator.timestamps_ns` and `operator.sequence` for RCTL;
- `operator.control_timestamps_ns` and `operator.control_sequence` for CTRL.

Example with a USB camera:

```bash
uv run operator-to-so101-record \
  --robot.type=so101_follower \
  --robot.port=/dev/ttyACM0 \
  --robot.id=so101_follower_arm \
  --robot.max_relative_target=5 \
  --robot.cameras="{ front: {type: opencv, index_or_path: 0, width: 640, height: 480, fps: 30}}" \
  --dataset.repo_id=my-user/operator-so101-demo \
  --dataset.single_task="Pick up the cube" \
  --dataset.num_episodes=3 \
  --dataset.episode_time_s=20 \
  --dataset.reset_time_s=5
```

Recording shortcuts are Right/n to end and save an episode, Left/r to discard
and re-record it, and Esc/q to stop. A kill discards only the current partial
episode, promptly frees the arm, then finalizes already saved episodes.

Resume requires the exact dataset root and the same cameras/features:

```bash
uv run operator-to-so101-record \
  --resume=true \
  --dataset.root=/absolute/path/to/dataset \
  --dataset.repo_id=my-user/operator-so101-demo-YYYY-MM-DD \
  --robot.type=so101_follower \
  --robot.port=/dev/ttyACM0 \
  --robot.id=so101_follower_arm \
  --robot.max_relative_target=5
```

## Validation boundary

Run pure logic tests with `uv run pytest`. They cover coordinate composition,
fresh CTRL gating, arm/deadman/reset/kill behavior, integer timestamp capture,
and jump-free clutching. Final acceptance still requires the real headset,
SO-101 and camera; local fakes are not a substitute for device coverage.
