# RFC-005 End-Effector Retargeting and SO-101 Constraint Feedback

## Status

Proposed

## Owner

TBD

## Date

2026-06-06

## Summary

Extend the RFC-003 human-to-robot retargeting pipeline with explicit
end-effector and gripper targets. The first implementation target is SO-101:
a single robot arm with a parallel two-jaw gripper used during ego data
collection.

RFC-003 defines the platform-neutral human pose and upper-body humanoid
retargeting pipeline:

```text
RawVendorPose
  -> OperatorHumanPose
  -> RetargetTargets
  -> RobotSolution
```

This RFC keeps that pipeline and adds a minimal, robot-agnostic way to express
manipulation intent:

- target TCP pose for a robot end effector.
- two-jaw gripper open/close target.
- IK residuals and constraint feedback for capture quality.

SO-101 is treated as the first robot profile and retargeter, not as a special
case in the ego capture application.

## Context

The immediate ego-capture goal is not visual fingertip-to-gripper alignment.
The goal is to introduce real robot constraints into ego collection so that the
captured data is more useful for downstream robot execution.

For SO-101 this means:

- Place the virtual robot base near the operator's body and keep it following
  the body while recording.
- Convert hand/controller motion into a SO-101 TCP target.
- Solve SO-101 IK using the robot model and joint limits.
- Drive the virtual robot from the solved joint state.
- Report residuals, limit saturation, velocity violations, and other
  constraints back to the operator and into the recording.

RFC-003 already provides the correct high-level abstraction for humanoids. This
RFC adds the end-effector/gripper task surface needed for SO-101 and future
manipulators.

## Goals

- Keep RFC-003 as the foundation.
- Add end-effector and two-jaw gripper targets to `RetargetTargets`.
- Add end-effector and gripper diagnostics to `RobotSolution`.
- Treat SO-101 as a robot profile plus a single-arm retargeter.
- Keep ego capture independent from SO-101-specific constants and frame names.
- Make the same pipeline compatible with future arms, mobile manipulators, and
  humanoids with dexterous hands.
- Record target, solution, residual, and constraint data for offline filtering
  and replay.

## Non-Goals

- Full hand or finger retargeting.
- Retargeting human fingers to dexterous robot hands.
- Whole-body humanoid locomotion, balance, or footstep planning.
- Bypassing robot-side hardware safety. XR-side constraints are capture-quality
  and operator-feedback signals; hardware control still needs robot-side safety.

## Design Principles

### End-effector intent is not finger retargeting

For the SO-101 MVP, hand data is reduced to manipulation intent:

- pinch center or controller grip pose -> TCP pose target.
- thumb-index distance or controller trigger -> gripper open fraction.
- tracking quality -> target weight/confidence.

The system does not copy human finger joints to robot gripper joints.

### Retargeting remains robot-specific

Tracking adapters produce `OperatorHumanPose`. They must not know SO-101, H2,
or any future robot.

Robot retargeters consume `RetargetTargets` and own robot-specific details:

- URDF/MJCF model.
- controlled joints.
- TCP frames and end-effector definitions.
- joint, velocity, acceleration, workspace, and collision constraints.
- task weights and priorities.

### Render solved robot state

The overlay must render `RobotSolution.joint_q`, not raw human pose. This makes
the virtual robot show what the robot can actually do.

## Pipeline

The extended pipeline is:

```text
RawVendorPose
  -> RawTrackingAdapter
  -> OperatorHumanPose
  -> TaskTargetExtractor
  -> RetargetTargets
  -> RobotRootAnchor
  -> RobotRetargeter
  -> RobotSolution
  -> RobotVisualizer / RobotFeedback / RobotRecorder
```

### RawTrackingAdapter

Converts device-specific tracking into `OperatorHumanPose`.

Examples:

- `GodotBodyAdapter`
- `PicoBodyAdapter`
- `MetaBodyAdapter`
- `ExternalTrackerAdapter`
- `HandControllerFallbackAdapter`

These adapters preserve raw observations separately as `RawVendorPose`.

### TaskTargetExtractor

Converts `OperatorHumanPose` into robot-agnostic task targets.

For SO-101:

- Extract right wrist, right hand pinch, or right controller grip as a TCP
  target source.
- Extract thumb-index distance or controller trigger as a parallel-jaw gripper
  target.

For H2 upper body:

- Extract chest orientation, head direction, left/right wrist poses, elbow
  hints, shoulder hints, and posture hints as defined by RFC-003.

### RobotRootAnchor

Computes the robot root/base transform in the XR world.

For SO-101:

```text
world_from_robot_base = world_from_body * body_from_robot_base
```

The body-relative offset is calibrated once and then follows the operator's
body during recording.

For humanoids:

```text
world_from_robot_pelvis = world_from_human_hips * hips_from_robot_pelvis
```

The root anchor policy is robot-profile driven.

### RobotRetargeter

Solves robot-specific optimization.

For SO-101:

- Single-arm IK for the configured TCP frame.
- Gripper command mapping for the parallel jaw.
- Joint limit, velocity, residual, and reachability diagnostics.

For H2:

- Torso plus two-arm IK/QP as described in RFC-003.
- Multi-task residuals for wrists, chest, elbows, and posture.

## Data Model Extensions

### RetargetTargets

Add an optional `end_effectors` section.

```json
{
  "schema": "operator.retarget_targets.v1",
  "timestamp_ns": 123456789,
  "root": {
    "anchor": "right_body_side",
    "mode": "body_follow"
  },
  "arms": {
    "right": {
      "wrist_pose": {
        "joint": "right_wrist",
        "weight": 0.5
      }
    }
  },
  "end_effectors": {
    "right_gripper": {
      "tcp_frame": "gripper_frame_link",
      "tcp_pose": {
        "source": "right_hand_pinch",
        "pose": {
          "p": [0.12, 1.21, -0.45],
          "q": [0.0, 0.0, 0.0, 1.0]
        },
        "space": "robot_root",
        "weight": 1.0,
        "confidence": 0.9
      },
      "gripper": {
        "type": "parallel_jaw",
        "open_fraction": 0.72,
        "width_m": 0.045,
        "source": "thumb_index_distance",
        "confidence": 0.9
      }
    }
  }
}
```

Rules:

- `end_effectors` is optional.
- A robot may define one or more end effectors.
- `tcp_pose.space` must be explicit.
- `gripper.open_fraction` is normalized `[0, 1]`.
- `width_m` is optional but recommended when the input source provides a
  physical distance.
- Target weights should be multiplied by input tracking quality.

### RobotSolution

Add optional `end_effectors` diagnostics.

```json
{
  "schema": "operator.robot_solution.v1",
  "timestamp_ns": 123456789,
  "robot": "so101",
  "solver": "so101_single_arm_ik",
  "joint_names": [
    "shoulder_pan",
    "shoulder_lift",
    "elbow_flex",
    "wrist_flex",
    "wrist_roll",
    "gripper"
  ],
  "joint_q": [0.0, 0.0, 0.0, 0.0, 0.0, 0.72],
  "joint_dq": [0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
  "end_effectors": {
    "right_gripper": {
      "tcp_frame": "gripper_frame_link",
      "tcp_residual_pos_m": 0.018,
      "tcp_residual_axis_deg": 6.2,
      "gripper_open_fraction": 0.72,
      "gripper_width_m": 0.045,
      "gripper_limit_saturated": false
    }
  },
  "limits": {
    "joint_limit_saturation": [],
    "velocity_limit_saturation": []
  },
  "reach_ok": true,
  "solve_ok": true,
  "quality": "tracked"
}
```

Rules:

- The overlay renders `joint_q`.
- UI feedback consumes `solve_ok`, `reach_ok`, residuals, and limit saturation.
- Recorder writes `RobotSolution` frames so sessions can be filtered offline.

## Robot Profile

SO-101 should be described as a profile, not hard-coded into ego capture.

Example profile fields:

```json
{
  "robot": "so101",
  "robot_type": "single_arm",
  "urdf_url": "assets/so101/so101_new_calib.urdf",
  "mesh_bundle_url": "assets/so101/so101.glb",
  "root_frame": "base_link",
  "root_anchor": {
    "anchor": "right_body_side",
    "mode": "body_follow",
    "default_body_from_root": {
      "p": [0.28, -0.18, -0.35],
      "q": [0.0, 0.0, 0.0, 1.0]
    }
  },
  "controlled_joints": [
    "shoulder_pan",
    "shoulder_lift",
    "elbow_flex",
    "wrist_flex",
    "wrist_roll",
    "gripper"
  ],
  "end_effectors": {
    "right_gripper": {
      "tcp_frame": "gripper_frame_link",
      "type": "parallel_jaw",
      "gripper_joint": "gripper",
      "jaw_width_range_m": [0.0, 0.09]
    }
  }
}
```

The same shape can represent future arms or humanoids by changing profile data
and retargeter implementation.

## SO-101 MVP

The first implementation should prove the architecture with SO-101.

### Inputs

- Right hand pinch pose.
- Right hand thumb-index distance.
- Right controller grip pose.
- Right controller trigger/axis.
- Body frame from body tracking, HMD fallback, or hand/controller fallback.

### Targets

- `root`: body-following right-side anchor.
- `end_effectors.right_gripper.tcp_pose`: SO-101 gripper TCP target.
- `end_effectors.right_gripper.gripper`: parallel-jaw open target.

### Retargeter

The SO-101 retargeter:

1. Converts the target TCP pose into robot-root coordinates.
2. Solves single-arm IK using SO-101 FK/Jacobian.
3. Clamps or reports joint limit saturation.
4. Maps gripper open fraction to the gripper joint.
5. Emits `RobotSolution`.

### Feedback

The overlay should show:

- Green: reachable and within limits.
- Yellow: near limits, high residual, low confidence, or high velocity.
- Red: solver failed, target unreachable, or invalid tracking.

Optional visual aids:

- Ghost target TCP.
- Residual vector from solved TCP to target TCP.
- Compact status text during calibration and recording.

## Compatibility With RFC-003 H2 Retargeting

This RFC is a strict extension of RFC-003.

SO-101 uses a small subset:

```text
Raw hand/body/controller data
  -> OperatorHumanPose
  -> right-side root + right gripper RetargetTargets
  -> SO-101 RobotSolution
```

H2 uses the full upper-body path:

```text
Raw body data
  -> OperatorHumanPose
  -> torso + two-wrist + elbow RetargetTargets
  -> H2 RobotSolution
```

Both produce `RobotSolution`. Rendering, feedback, and recording consume the
same output interface.

## Current XR Migration Plan

The current implementation has useful pieces but should be reorganized around
the RFC pipeline.

### Existing code to preserve

- `TrackingProvider.get_hand_pinch_pose()` for right-hand pinch pose and
  thumb-index distance.
- `TrackingProvider.get_body_arm_direction()` as a fallback body direction
  signal.
- `ArmOverlay` mesh loading and FK rendering.
- `ArmOverlayEgoEndPoseDrive` SO-101 IK prototype.
- `SessionSpoolWriter` sidecar and metadata write path.

### Refactoring direction

- Rename/split `ArmOverlayEgoEndPoseDrive` into:
  - `So101TaskTargetExtractor`
  - `So101Retargeter`
- Move SO-101 constants into a robot profile or parsed URDF data.
- Convert `ArmOverlay` into a generic `RobotVisualizer`.
- Add `RobotRootAnchor` so SO-101 follows the body during recording.
- Change retargeter output from `ArmOverlayJointPose` only to
  `RobotSolution`.
- Add recording of:
  - `raw_vendor_pose.jsonl`
  - `operator_human_pose.jsonl`
  - `retarget_targets.jsonl`
  - `robot_solution.jsonl`

## Implementation Plan

### Phase 1: Schemas and SO-101 profile

- Define JSON schemas for end-effector extensions.
- Add SO-101 robot profile.
- Parse joint limits from URDF or profile.
- Keep the current fallback SO-101 FK path for Android until a robust model
  loader exists on device.

### Phase 2: SO-101 retargeting API

- Add `RetargetTargets` construction for the right gripper.
- Make SO-101 IK return `RobotSolution`.
- Add residual and limit diagnostics.
- Keep the existing visual overlay working through an adapter from
  `RobotSolution` to joint transforms.

### Phase 3: Body-follow root anchor

- Store calibrated `body_from_robot_root`.
- Update `world_from_robot_root` every frame from body pose.
- Keep the robot root level unless the robot profile explicitly allows root
  roll/pitch.

### Phase 4: Feedback and recording

- Add overlay color status from `RobotSolution`.
- Add residual vectors and target TCP marker.
- Record `RetargetTargets` and `RobotSolution` sidecars.
- Add metrics for solve latency, residual, and invalid-frame rate.

### Phase 5: H2 compatibility

- Add H2 profile and retargeter behind the same interface.
- Reuse `OperatorHumanPose`, `RetargetTargets`, `RobotSolution`, visualizer,
  feedback, and recorder paths.

## Validation

Acceptance criteria for SO-101:

- Ego capture code does not hard-code SO-101 frame names or joint limits.
- Old hand/controller input still drives the SO-101 overlay.
- The SO-101 base follows the operator body while recording.
- Robot rendering uses solved joint state, not raw hand pose.
- Gripper open/close is represented in both target and solution.
- IK residuals and limit saturation are visible and recorded.

Acceptance criteria for RFC-003 compatibility:

- H2 retargeting can reuse `OperatorHumanPose`, `RetargetTargets`, and
  `RobotSolution`.
- H2 retargeter contains no Pico/Meta-specific joint names.
- SO-101 retargeter contains no Pico/Meta-specific joint names.
- Source adapter changes can regenerate canonical pose offline without
  recapturing video.

## Open Questions

- Should SO-101 IK run on-device, robot-side, or workstation-side for the final
  production path?
- What is the final body frame for SO-101 root anchoring: hips, chest, right
  shoulder, or a fused right-side body frame?
- Should gripper `width_m` be required for all parallel-jaw robots, or should
  normalized `open_fraction` be the only mandatory target?
- How much collision checking is required before SO-101 constraints are useful
  during ego-only capture?
- Should `RobotSolution` be written into the MP4 metadata stream, JSONL sidecar,
  or both?
