# IsaacTeleop external-session patch

Operator owns the headset OpenXR runtime, so the Isaac Sim process needs a
TeleopSession lifecycle that never creates `OpenXRSession` or
`DeviceIOSession`. Upstream `v1.3.131` has caller-provided `external_inputs`,
but its live context manager still starts DeviceIO.

Apply the pinned patch from an IsaacTeleop checkout:

```bash
git checkout v1.3.131
git apply /path/to/operator/plugins/isaac-teleop/upstream/0001-teleop-session-external-mode.patch
```

The patch adds `SessionMode.EXTERNAL`, permits external leaves in a control
pipeline, rejects accidental DeviceIO sources/configuration, and skips all
OpenXR/DeviceIO creation and polling. It deliberately rejects MCAP config in
external mode: the Operator receiver records canonical external records at the
provider boundary until upstream exposes a recorder hook for external leaves.

The patch contains upstream-style unit tests. Run them inside a built
IsaacTeleop development environment:

```bash
pytest -q src/core/teleop_session_manager_tests/python/test_teleop_session.py \
  -k ExternalMode
```

