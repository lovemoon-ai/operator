# IsaacTeleop Plugin

This plugin lets Operator own the headset OpenXR runtime and display while an
Isaac Sim process reuses IsaacTeleop's standard TensorGroups, retargeting graph,
teleop state manager, and action output.

## Components

- `../../xr/scripts/sinks/isaac_teleop/`: Godot SensorFrame-to-UDP sink and
  deadman/run/reset policy.
- `../../robot/crates/xr-bridge/src/isaac_teleop_gateway.rs`: validated,
  per-channel latest-only UDP-to-Unix-datagram gateway.
- `python/`: installable host receiver and public IsaacTeleop API adapter.
- `upstream/`: pinned `SessionMode.EXTERNAL` patch, which prevents the Isaac
  process from creating a second OpenXR/DeviceIO session.
- `schema/`: checksummed NVIDIA v1.3.131 schema snapshot.

Version 1 uses the compact `operator-canonical-v1` ingress payload and converts
it immediately into IsaacTeleop's public standard TensorGroups. Direct
FlatBuffers payloads are reserved for a later codec revision.

## Quick start

1. Check out NVIDIA IsaacTeleop `v1.3.131` and apply
   `upstream/0001-teleop-session-external-mode.patch`.
2. In the Isaac Sim Python environment, install `python/` and create the real
   robot/task factory from `python/examples/session_factory_template.py`.
   Integrate `OperatorIsaacTeleopDevice` into the task's `env.step()` loop as
   shown by `python/examples/isaac_lab_loop_template.py`.
3. For a retargeting-only smoke test, start the CLI first so it binds the Unix
   datagram socket (the real task loop binds the same socket instead):

   ```bash
   operator-isaacteleop-receive \
     --session-factory /absolute/path/session_factory.py:make_session
   ```

4. Start the bridge:

   ```bash
   cd robot
   cargo run -p xr-bridge -- \
     --config configs/isaac-teleop-example.yaml --video-only
   ```

5. Start an installed Operator APK with the explicit per-process opt-in:

   ```bash
   make -C xr run-isaac-teleop
   ```

Normal APK launches and existing export presets keep this backend disabled.
The default runtime uses token `0`, which is unauthenticated and suitable only
for a trusted development network.

## Real SO-101 through LeRobot

[`examples/operator_to_so101`](../../examples/operator_to_so101/README.md)
uses the same Operator sink and gateway to control a physical SO-101 follower
and record LeRobotDataset episodes. That path reuses LeRobot's clutch/IK/safety
implementation and does not start CloudXR or a second IsaacTeleop session.
The example documents serial/socket ownership, setup commands and hardware
acceptance boundaries.

## Safety and current limits

The XR client sends a CTRL heartbeat every physics tick. Right grip is the
deadman; A emits a run-toggle edge; B emits a reset edge. The host steps at a
fixed rate even without new packets, so an expired/missing CTRL channel reaches
IsaacTeleop's `DefaultTeleopStateManager` and forces STOPPED. Disconnect also
sends a best-effort kill.

The default coordinate path preserves OpenXR xyz and XYZW values, matching the
native IsaacTeleop source nodes. BODY v1 stays wire-compatible with the Pico
24-joint layout. Pico frames pass through identity normalization; Meta/Godot
87-joint frames are mapped by explicit joint id into the same 24 semantic
slots, with missing or incomplete poses marked invalid. Meta positions use the
reviewed topology mapping, while orientations are best-effort because the
vendor wrapper applies per-joint basis corrections. A real headset plus Isaac
Sim task is required for the final device-to-simulation acceptance test.

See [the architecture document](../../claw/architecture/isaac-teleop-plugin.md)
for the full data contract and lifecycle.
