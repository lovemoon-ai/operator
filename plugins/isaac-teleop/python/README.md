# Operator IsaacTeleop host runtime

This wheel is the host half of the Operator IsaacTeleop plugin. It receives
canonical headset samples from `xr-bridge`, maps device monotonic time into the
host clock, and drives an IsaacTeleop retargeting session through public
`external_inputs`.

The base install is dependency-free:

```bash
python -m pip install ./plugins/isaac-teleop/python
```

Run a telemetry-only receiver:

```bash
operator-isaacteleop-receive --socket /tmp/operator-isaacteleop.sock --token 0x2a
```

Run the dependency-free closed-loop smoke example:

```bash
python plugins/isaac-teleop/python/examples/fake_session.py
```

For development:

```bash
python -m pip install -e './plugins/isaac-teleop/python[test]'
pytest plugins/isaac-teleop/python
```

## Wire contract

Each Unix datagram contains the existing Operator 32-byte little-endian header
`<QQIHHHBB4s>` followed by one canonical payload. CRC-16/CCITT-FALSE covers
the payload only. Known FourCC kinds are `HEAD`, `LCTL`, `RCTL`, `LHND`,
`RHND`, `BODY`, `CTRL`, and `ANCH`. Samples are latest-only per kind; stale
samples expire rather than queueing old robot commands. The Python canonical
runtime accepts descriptor version 1 only and rejects future versions before
payload decoding; the Rust gateway remains version/payload opaque.

Tracking coordinates remain in the original OpenXR convention by default
(`+X` right, `+Y` up, `-Z` forward), exactly like IsaacTeleop's native
Head/Controllers/Hands sources. This is required for existing retargeting
graphs and anchor transforms to behave identically. The `godot_to_isaac`
utility and `LatestSampleStore(transform_coordinates=True)` are explicit
opt-ins for custom graphs that truly expect robotics axes; they are never
enabled implicitly.

## IsaacTeleop integration

`ExternalTeleopSession` is dependency injected and can wrap a fake or a real
session. `IsaacStandardInputAdapter` lazily imports NumPy and public
IsaacTeleop APIs, creates matching `ValueInput` leaves, and converts canonical
values to `HeadPose`, `ControllerInput`, `HandInput`, `FullBodyInput`, and
`TransformMatrix` TensorGroups:

```python
from isaacteleop.teleop_session_manager import (
    SessionMode, TeleopSession, TeleopSessionConfig,
)
from operator_isaacteleop import ExternalTeleopSession, IsaacStandardInputAdapter

adapter = IsaacStandardInputAdapter()
# Connect these selectors where the native graph used ControllersSource,
# HandsSource, HeadSource, or FullBodySource outputs.
pipeline = build_retargeting_pipeline(adapter.source_outputs())
control = adapter.create_default_control_pipeline()
teleop_session = TeleopSession(TeleopSessionConfig(
    app_name="OperatorIsaacTeleop",
    pipeline=pipeline,
    teleop_control_pipeline=control.pipeline,
    mode=SessionMode.EXTERNAL,
))
external = ExternalTeleopSession.for_isaacteleop(
    teleop_session,
    input_adapter=adapter,
    session_control_pipeline=True,
)
```

Missing tracking channels are passed as absent `OptionalTensorGroup` values;
the anchor defaults to a required float32 identity matrix. Missing `CTRL`
makes the official state manager's required kill/run inputs absent, which
fails safe to STOPPED. `kill` is mapped as `kill or not deadman`, while
run-toggle and reset remain pulse channels. The latest-only store latches
those two edges until one simulation snapshot consumes them, so a fast XR
heartbeat cannot overwrite a pulse between slower host ticks.

`LazyIsaacTeleopBindings.value_input()` constructs the upstream public
`ValueInput`; `graph_time()` and `execution_events()` construct upstream
`GraphTime` and `ExecutionEvents`. `action_to_torch()` uses DLPack in the same
shape as Isaac Lab (`result["action"][0]`) without importing Torch until an
action is requested.

Current upstream IsaacTeleop `LIVE` mode enters OpenXR and calls DeviceIO even
when all useful leaves are external. Production Operator use therefore needs
the pinned `SessionMode.EXTERNAL` patch described by this plugin. This package
does not monkey-patch `TeleopSession` private members; once upstream exposes
external mode, only session construction changes.

For an executable real integration, expose a zero-argument factory returning
`ExternalTeleopSession` and pass it to the CLI:

```bash
operator-isaacteleop-receive \
  --step-hz 60 \
  --session-factory /absolute/path/session_factory.py:make_session
```

Session-factory mode ticks at `--step-hz` even when no datagram arrives. This
is a safety requirement: once CTRL expires, the adapter must still send absent
bool TensorGroups through the official state manager so it transitions to
STOPPED. Telemetry-only mode remains packet-driven. The CLI prints the
retargeting result and is useful as a host smoke test; it does not choose an
Isaac Lab task or call `env.step()`.

The factory is the patch boundary: it constructs the pinned upstream
`TeleopSession` in `SessionMode.EXTERNAL`, uses `IsaacStandardInputAdapter`
to build the pipeline's standard `TensorGroup` values, then returns
`ExternalTeleopSession.for_isaacteleop(...)`. This keeps upstream-specific
configuration out of the transport package. A complete builder template is
provided in `examples/session_factory_template.py`.

For an actual Isaac Lab task, wrap the same session with
`OperatorIsaacTeleopDevice` and feed each `advance()` result to the task's
normal environment loop. `examples/isaac_lab_loop_template.py` provides the
task-neutral loop; the application still owns SimulationApp, scene/env
creation, reset policy, and shutdown.

The dependency-free `PortableStateManager` is only a fake-session/bootstrap
fallback. Production uses the three bool `ValueInput` leaves wired to upstream
`DefaultTeleopStateManager` as `teleop_control_pipeline`, and calls
`step(..., execution_events=None)` so the official pipeline creates the
`ExecutionEvents`.

The initial arrival can bootstrap raw-device to host-monotonic mapping, but a
production bridge should feed four-timestamp control exchanges into
`MonotonicOffsetEstimator.observe_exchange()` to remove one-way network delay.
