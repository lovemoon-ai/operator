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
| `robot/unitree_h2_overlay.gd` | `UnitreeH2Overlay` | World-locked translucent Unitree H2 rest-state GLB renderer. |
| `robot/unitree_g1_overlay.gd` | `UnitreeG1Overlay` | Live-retargeted translucent Unitree G1 GLB renderer. |

## Notes

`BodyPoseProvider` does not run calibration, task extraction, robot
constraint solving, or IK. Robot-specific overlays consume
`canonical_frame_ready`; Unitree G1 and Galbot G1 delegate retargeting to the
native GDExtension, while Unitree H2 remains a static rest-pose reference.
