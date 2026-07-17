# IsaacTeleop XR sink

This module is the Operator headset side of `IsaacTeleop-plugin`. Godot owns
OpenXR and display; this sink publishes canonical head, controller, hand,
Pico-body and control channels to the `xr-bridge` UDP gateway.

The feature is intentionally disabled in every normal export preset. To opt in
for one Android launch, start an installed Operator APK with:

```bash
cd xr
make run-isaac-teleop
```

The target sends the Android extras `operator.mode=teleop` and
`operator.isaac_teleop=true`. The same opt-in works as Godot command-line
arguments in either form:

```text
operator.isaac_teleop=true
--operator.isaac_teleop true
```

The opt-in enables `MODE_TELEOP` and `SINK_ISAAC_TELEOP` only for that process.
Without it, the original `RobotControlSink` path is unchanged.

Runtime defaults are UDP port `63904`, anonymous session token `0`, and
descriptor version `1`. They can be changed through the exported properties on
`teleop_controller.gd`. A production deployment should replace token `0` with
a token minted by the bridge control plane.

Safety defaults to requiring the right grip as a continuous deadman. The right
primary face button (A) sends a run-toggle edge; IsaacTeleop's official state
manager advances STOPPED -> PAUSED -> RUNNING, then toggles RUNNING/PAUSED.
The secondary face button (B) sends reset. Missing/expired controls stop the
Python session; disconnect and scene exit also send a best-effort kill packet.

The `BODY` wire ABI remains IsaacTeleop's Pico 24-joint schema. Pico samples
use an identity normalization; Meta/Godot 87-joint samples are projected by an
explicit topology-aware mapping before encoding. Missing target joints remain
invalid instead of shifting array positions, and a Meta pose is valid only when
both its Godot orientation-valid and position-valid flags are present.

The sink health snapshot exposes `mapped_meta_body_frames`,
`mapped_meta_body_joints`, `mapped_meta_valid_joints`, and
`dropped_unmappable_body`. The old `dropped_unsupported_body` key remains as a
compatibility alias. Meta joint positions have a reviewed semantic mapping;
their orientations remain best-effort because the Meta vendor wrapper applies
per-joint basis corrections.
