# pyoperator

`pyoperator` is the Python-first, in-process entry point for Operator. Python
owns the process; the library owns headset discovery, the XR TCP session, state
framing, and shutdown. It does not launch `xr-bridge` as a subprocess.

```python
from pyoperator import xr_bridge

xr_bridge.start()
frame = xr_bridge.wait_next(timeout=5.0)
if frame:
    # One immutable, atomic frame: head/controllers/input/hands/body/trackers.
    right = frame.controllers.right
    print(frame.frame_id, frame.timestamp_ns, right.pose if right else None)
xr_bridge.stop()
```

Install from the Operator checkout:

```bash
python -m pip install -e ./python
```

For development, install the test extra and run the coverage-gated suite:

```bash
python -m pip install -e './python[test]'
cd python
python -m pytest
```

The suite includes pure-Python unit tests plus loopback integration tests for
the compiled PyO3 bridge. Coverage is measured with branch tracking and must
remain at or above 90%. Real APK-to-Python tracking still requires an Android
XR device and is intentionally kept in the repository's device-test layer.

The six native lifecycle cases that imitate the headset wire protocol are
explicitly marked `fake_headset`; the whole file is marked `loopback`. Pytest
also collects one physical-headset case, so a normal host-only report shows it
as skipped instead of silently omitting hardware coverage:

```bash
# Host-only: includes the reason for the skipped real-device case.
python -m pytest -ra

# Run only the host socket tests that imitate a headset.
python -m pytest -m fake_headset --no-cov

# Real Quest/Pico: app must already be installed, or provide --xr-apk.
python -m pytest -m xr_device --no-cov --run-device --require-device \
  --xr-device auto --adb-serial SERIAL

# CI report includes <skipped> when no device run was requested.
python -m pytest -ra --junitxml=../cicd/results/pyoperator-pytest.xml
```

The real test uses `adb reverse`, launches the normal Teleop/OpenXR path, and
requires continuous valid `XrStateFrame` samples in Python. It never substitutes
a fixture for headset tracking. Pass `--xr-apk ../xr/build/quest/Operator.apk`
or the corresponding Pico APK to install the exact build under test.

The headset connects exactly as it does to an existing bridge. The SDK
advertises itself through Operator discovery; the descriptor enables
`XrStateFrame` v1. Existing `robot-service`, standalone `xr-bridge`, and
LeRobot integrations remain unchanged.

`xr_bridge.start()` returns only after the SDK's core network listeners and
discovery resources are ready. Port conflicts and other startup failures raise
`RuntimeError` directly instead of appearing later only in bridge statistics.
Only one headset owns the SDK stream at a time; a new connection replaces the
old one. Headset reconnects and frame-id resets are handled without restarting
the Python session. Clients that do not advertise `xr_state_v1` are rejected,
with the upgrade hint available through `xr_bridge.stats().last_error`.

## Robot, retargeting, and IK

Implement the five-method `Robot` protocol (`connect`, `disconnect`,
`read_state`, `write`, `stop`). `PoseDeltaRetargeter` provides a safe deadman
and reference-capture mapping: releasing the deadman immediately calls the
robot's `stop`. Pass a custom `IKSolver`, `CallableIK`, or the generic
`DampedLeastSquaresIK` to `pyoperator.control_loop.run`.

Raw controller poses and robot EE targets are deliberately different types:
`frame.controllers.right.pose` is measured XR state;
`EndEffectorTarget.ee_pose` is retargeted robot-space state.

## Debugging

`xr_bridge.stats()` exposes connection state, frame/parse counts, last frame and
last error. `FrameRecorder` and `ReplaySession` in `pyoperator.replay` record
and deterministically replay the same immutable `XrFrame` model.

## Existing hosted workflow

Stable Python backends can still run behind the standalone bridge with
`pyoperator.hosted.serve`. It implements the existing length-prefixed adapter
protocol; point `xr-bridge --adapter-endpoint tcp:127.0.0.1:63910` at it. This
mode is intentionally separate from the embedded `xr_bridge.start()` mode.
