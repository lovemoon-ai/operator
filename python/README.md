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

## Live Feed Server

`pyoperator.live_feed` contains the OLCP Live Feed server, bounded stream
queues, depth-fusion reference worker, and XR result publisher. Run it from a
checkout with:

```bash
PYTHONPATH=python python3 -m pyoperator.live_feed --print-plan
PYTHONPATH=python python3 -m pyoperator.live_feed --self-test
```

An installed editable package also provides the `pyoperator-live-feed`
command. Live Feed carries RGB/depth and result streams over OLCP; it is
separate from `pyoperator.xr_bridge`, which exposes local pose, controller,
hand, body, and tracker snapshots.

On startup the server prints its LAN address and a QR code encoding it, so the
headset can be pointed at the right host without typing an IP on a virtual
keyboard — scan it from Live Feed settings via the camera icon next to
"Server host". In Ghostty, Kitty, and WezTerm it uses terminal-native graphics:
the source is an exact square and the terminal computes its width from the
actual cell dimensions, so font aspect ratio cannot stretch it. Other terminals
fall back to high-contrast half-cell blocks. The complete QR remains the last
startup output so its quiet zone is not scrolled away. Pass `--no-qr` to
suppress the code entirely.

The QR encoder is dependency-free (`pyoperator.live_feed.qr`), so no imaging
stack is pulled in just to draw a code on a terminal.

### Building your own Live Feed app

The reference server above is one application of the package. For your own, use
the runtime API directly: `LiveFeedReceiver` owns the sockets, the reader
thread, and the bounded drop-oldest queues, and hands you typed samples.

```python
from pyoperator.live_feed import LiveFeedReceiver, ReceiverConfig

with LiveFeedReceiver(ReceiverConfig()) as receiver:
    for session in receiver.sessions():
        for sample in session.samples():
            if sample.kind == "head_pose":
                print(sample.position, sample.tracking_valid)
```

To send results back, use `session.results` (a `ResultPublisher`). It handles
the `manifest -> fragments -> commit` ordering the headset requires, and keeps
`map_version` increasing so updates are not discarded client-side.

```python
session.results.publish_points(
    map_id="my-map",
    chunk_id="my-map_chunk",   # stable id + upsert = flat headset memory
    points=[DensePoint(x, y, z, r=255, g=140, b=0)],
    operation="upsert",
)
```

| Module | Responsibility |
| --- | --- |
| `protocol.py` | OLCP framing, capability negotiation, capture planning |
| `models.py` | Typed samples, camera models, rigid transforms (no I/O) |
| `decoders.py` | Optional RGB decoding via `ffmpeg` |
| `runtime.py` | Receiver, session, bounded queues, recording |
| `results.py` | Result channel, `ResultPublisher`, `DensePoint` |
| `server.py` | The depth-fusion reference server built from the above |

### Examples

Two runnable examples in `python/examples/`:

```bash
# One-way: headset -> pyoperator, visualised live.
# Terminal dashboard by default; --viewer rerun needs `pip install rerun-sdk`.
python python/examples/live_feed_viewer.py
python python/examples/live_feed_viewer.py --viewer rerun

# Bidirectional: headset -> pyoperator -> headset.
# Turns the head-pose trail into a point cloud and streams it back for the
# headset to render. Confirm with:
#   adb logcat -s godot | grep "Live-pull rendered chunk"
python python/examples/live_feed_roundtrip.py
```

Both accept `--host` / `--push-port` / `--result-port`; start Live Feed mode on
the headset afterwards. The viewer sends one `capture_request` control message
so the XR settings panel can show its input data types, but publishes no
algorithm results, so the capture data path stays one-way.

### Testing the examples without a headset

`pyoperator.live_feed.simulator` is a synthetic headset: it speaks live-push
with the same payload shapes as the real device (walking head pose, controllers,
hands, depth, RGB packets). Run an example in one terminal and the simulator in
another:

```bash
# terminal 1
python python/examples/live_feed_viewer.py

# terminal 2
python -m pyoperator.live_feed.simulator --duration 20
```

It is a development aid, not a headset substitute: RGB packets carry dummy bytes
rather than a real HEVC bitstream, and depth is a flat synthetic plane. Anything
depending on real codec or sensor data still needs `cicd/04_live_feed_e2e.sh` on
a device.

The automated equivalents run in the normal suite:

```bash
cd python
python -m pytest -k "Viewer or HeadTrail or Roundtrip"   # example logic
python -m pytest -m loopback                             # socket round trips
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

## Robot-specific retargeting and the retargeting service

Robot-specific retargeting (Unitree G1/H2, Galbot G1, SO-101) is computed by
the separate `retargeting` library. pyoperator owns the wire protocol and calls
it; the library never learns about Operator or opens a socket.

```bash
pip install 'pyoperator[retargeting]'
pip install ./python                     # from the retargeting repository
pyoperator serve --service retargeting --host 0.0.0.0 --port 8000
```

`GET /healthz` and `GET /v1/profiles` report the profiles this host can serve
and why any are unavailable; `WS /v1/retarget` runs one warm-started, latest-only
solver session for an Inside Robot in the headset. `retargeting-service` remains
as an alias of the same command.

The same profiles drive a host-side control loop, so an Outside Robot solves
exactly what the headset would have:

```python
from pyoperator.integrations.retargeting import PyOperatorRetargeter

retargeter = PyOperatorRetargeter("unitree_g1", source="body")
# or source="controller" for end-effector profiles such as SO-101
pyoperator.control_loop.run(session, robot, retargeter)
```

## Debugging

`xr_bridge.stats()` exposes connection state, frame/parse counts, last frame and
last error. `FrameRecorder` and `ReplaySession` in `pyoperator.replay` record
and deterministically replay the same immutable `XrFrame` model.

## Existing hosted workflow

Stable Python backends can still run behind the standalone bridge with
`pyoperator.hosted.serve`. It implements the existing length-prefixed adapter
protocol; point `xr-bridge --adapter-endpoint tcp:127.0.0.1:63910` at it. This
mode is intentionally separate from the embedded `xr_bridge.start()` mode.
