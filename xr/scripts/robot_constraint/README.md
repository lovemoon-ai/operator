# `xr/scripts/robot_constraint/`

In-headset ego-pose and robot-constraint visual feedback utilities.

This module takes ego pose signals such as body and hand poses, resolves
them into a canonical frame, and renders visual feedback for robot
constraint debugging.

The current runtime path is intentionally narrow:

1. `BodyPoseProvider` samples the available body source.
2. Source adapters convert Pico / Godot / fallback poses into the
   canonical Godot body-pose frame.
3. `CanonicalResolver` fuses partial frames.
4. Debug overlays render either the canonical VR body pose or a
   robot-specific constraint visualization.

There is no on-device robot IK loop in this directory.

## Modules

| File | Class | Role |
|---|---|---|
| `canonical_joints.gd` | `CanonicalJoints` | Canonical joint vocabulary and frame helpers. |
| `godot_body_adapter.gd` | `GodotBodyAdapter` | `XRBodyTracker` -> canonical frame. |
| `pico_body_adapter.gd` | `PicoBodyAdapter` | `XR_BD_body_tracking` via `PicoOpenXRBridge` -> canonical frame. |
| `fallback_body_adapter.gd` | `FallbackBodyAdapter` | HMD + controller wrists -> canonical frame with inferred torso. |
| `canonical_resolver.gd` | `CanonicalResolver` | Fuses partial frames by source priority and tracking quality. |
| `body_pose_provider.gd` | `BodyPoseProvider` | Samples adapters per physics tick and emits `canonical_frame_ready` plus raw vendor frames. |
| `body_pose_debug_overlay.gd` | `BodyPoseDebugOverlay` | World-locked stick-figure renderer for the canonical VR body pose. |
| `robot/h2_overlay.gd` | `H2Overlay` | World-locked translucent H2 rest-state GLB renderer. |

## Notes

`BodyPoseProvider` does not run calibration, task extraction, robot
constraint solving, or IK. Future robot-specific constraint modules
should live outside this provider and consume `canonical_frame_ready`
as input.
