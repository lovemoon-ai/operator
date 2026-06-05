# RFC-003 Upper-Body Human-to-Humanoid Retargeting

## Status

Proposed

## Owner

TBD

## Date

2026-06-06

## Summary

Add a cross-headset, cross-robot retargeting pipeline for ego data
collection and XR overlay. The first implementation targets upper-body
humanoid retargeting: torso plus two robot arms, with no hand/finger
retargeting in this phase.

The core design is a two-layer human-pose representation:

1. `RawVendorPose`: preserves Pico, Meta/Quest, Godot, hand-tracking, and
   external-tracker data with source-specific fields intact.
2. Godot Humanoid canonical joints: expose a stable Godot Humanoid semantic
   view for downstream tasks, with provenance and quality on every joint.

Retargeting does not consume vendor joints directly. It extracts task
targets from Godot Humanoid canonical joints, builds a robot-specific
IK/QP problem, solves for robot joint positions, and renders or controls
the robot using the optimized robot state. This avoids the combinatorial
`m x n` problem between `m` tracking sources and `n` robots. Each
tracking source gets one adapter; each robot gets one retargeter.

```text
Pico / Quest / Godot / tracker raw poses
        -> source adapters
        -> Godot Humanoid canonical joints
        -> task target extractor
        -> H2 upper-body IK/QP
        -> robot joint_q + residuals
        -> XR overlay / robot control / recording
```

The accompanying comparison figure is
[`../figures/body-tracking-joint-sets.svg`](../figures/body-tracking-joint-sets.svg).

![Body tracking joint set comparison](../figures/body-tracking-joint-sets.svg)

## Context

Operator is intended to be a multi-platform teleoperation and ego data
collection toolkit. The XR side may run on Pico, Quest/Meta, or other
OpenXR devices. Body tracking is not a single OpenXR core joint set:

- Godot `XRBodyTracker` exposes a Humanoid-oriented `JOINT_MAX = 87`
  semantic skeleton.
- Pico / ByteDance `XR_BD_body_tracking` exposes 24 body joints.
- Meta `XR_FB_body_tracking` exposes 70 joints: body core plus hands.
- Meta `XR_META_body_tracking_full_body` exposes 84 joints.
- Standard OpenXR hand tracking exposes 26 hand joints per hand.
- External trackers may appear as waist/chest/elbow/wrist/foot tracker
  poses rather than as a full body skeleton.

The existing XR code already has useful pieces:

- `xr/scripts/body_motion_sampler.gd` samples `XRBodyTracker` joints and
  can call `PicoOpenXRBridge.sample_body_joints()`.
- `xr/native/pico_openxr/src/pico_openxr_extension.cpp` requests
  `XR_BD_body_tracking` and `XR_PICO_body_tracking2`, and returns body
  joints plus Pico-specific status, posture, velocity, and acceleration.
- `xr/scripts/network/pose_sender.gd` currently sends legacy head,
  controller, and hand-joint tracking over the `Tracking` command, but
  does not send body joints in the teleoperation path.

The immediate product goal is ego capture with an in-headset virtual
humanoid overlay, initially H2 with upper-body motion. Hands/fingers are
not part of the first retargeting target, although raw hand data may still
be recorded for future stages.

## Goals

- Define a platform-neutral Godot Humanoid canonical joint stream for
  Operator retargeting.
- Preserve vendor-specific raw tracking data so adapter mistakes can be
  fixed offline without recapturing data.
- Use Godot Humanoid joint semantics as the canonical view consumed by
  retargeting and visualization.
- Avoid `source x robot` implementations. Require only source adapters
  and robot retargeters.
- Define the first upper-body target set: torso plus two robot arms.
- Define how H2 retargeting should build and solve a constrained IK/QP
  problem.
- Render H2 using optimized robot joint states, not direct human pose
  playback.
- Record raw input, Godot Humanoid canonical joints, task targets, robot
  solution, and residuals for evaluation and replay.

## Non-Goals

- Retargeting hand or finger articulation to Sharpa in this phase.
- Defining locomotion, footstep planning, balance, or multi-contact whole
  body control in the first implementation.
- Treating Godot Humanoid as a lossless replacement for vendor raw data.
- Requiring every source to fill all 87 canonical joints.
- Sending body tracking over the existing legacy `Tracking` JSON forever.
  The first implementation may use it for iteration, but the protocol
  should evolve toward an explicit body-pose stream.
- Choosing a final IK solver implementation. Pinocchio + Pink is the
  recommended first toolchain, but the RFC defines the data and task
  boundary rather than mandating one library.

## Design Principles

### Preserve raw, consume Godot Humanoid joints

Godot Humanoid canonical joints are a semantic view, not the only source
of truth. They are allowed to be lossy because they normalize across
hardware. The raw sidecar is the lossless record.

```text
RawVendorPose                    complete source-specific observation
Godot Humanoid canonical joints  semantic view with provenance
RetargetTargets                  robot-agnostic task objectives
RobotSolution                    robot-specific feasible approximation
```

### Retargeting is optimization, not copying

Human joints cannot be copied to robot joints without loss. Humans and
robots have different bone lengths, joint axes, DoF, limits, reachable
workspaces, and dynamics. Retargeting projects a human motion target into
the robot's feasible motion space.

### Robot changes require a robot retargeter

Changing from H2 to G1 should not change the Pico or Quest adapters.
However, it is not enough to only change task-target names. A robot
retargeter owns:

- URDF/MJCF model.
- controlled joint list.
- link/frame names.
- home posture.
- joint, velocity, acceleration, workspace, and collision constraints.
- task weights and priorities.
- render/control output mapping.

### Quality is first-class

Every pose that reaches retargeting carries `valid`, `tracked`,
`inferred`, `confidence`, `source`, and `source_joint`. The solver and UI
must account for these values. Missing or inferred joints must not be
silently treated as tracked measurements.

## Data Model

### RawVendorPose

`RawVendorPose` stores source-specific tracking data with minimal
interpretation. It should be recorded as JSONL during capture and can
also be streamed live when useful.

```json
{
  "schema": "operator.raw_vendor_pose.v1",
  "timestamp_ns": 123456789,
  "source": "pico_bd_body_tracking",
  "source_schema": "XR_BD_body_tracking",
  "space": "openxr_local_floor",
  "joints": [
    {
      "source_joint": "XR_BODY_JOINT_LEFT_WRIST_BD",
      "pose": {
        "p": [0.12, 1.21, -0.45],
        "q": [0.0, 0.0, 0.0, 1.0]
      },
      "flags": 15,
      "confidence": null,
      "extras": {
        "posture": 2,
        "linear_velocity": [0.0, 0.0, 0.0],
        "angular_velocity": [0.0, 0.0, 0.0],
        "acceleration_flags": 0
      }
    }
  ],
  "extras": {
    "body_flags": 65537,
    "tracking_status": 1,
    "tracking_message": 0,
    "all_tracked": true
  }
}
```

Rules:

- Preserve source joint names or numeric IDs.
- Preserve vendor flags and extra fields.
- Do not infer missing joints in raw frames.
- Do not collapse duplicated measurements such as body wrist and hand
  wrist. Fusion happens later.

### Godot Humanoid canonical joints

This joint frame uses Godot Humanoid joint semantics. Joint keys should
be stable lower-snake-case names derived from Godot
`XRBodyTracker.Joint` names.

```json
{
  "schema": "operator.godot_humanoid_joints.v1",
  "timestamp_ns": 123456789,
  "canonical": "godot_xrbodytracker_87",
  "space": "operator_xr_world",
  "joints": {
    "left_wrist": {
      "pose": {
        "p": [0.12, 1.21, -0.45],
        "q": [0.0, 0.0, 0.0, 1.0]
      },
      "valid": true,
      "tracked": true,
      "inferred": false,
      "confidence": 0.85,
      "source": "pico_bd_body_tracking",
      "source_joint": "XR_BODY_JOINT_LEFT_WRIST_BD"
    },
    "left_scapula": {
      "valid": false,
      "tracked": false,
      "inferred": false,
      "confidence": 0.0,
      "source": null,
      "source_joint": null
    }
  }
}
```

Rules:

- The map may be sparse. Missing canonical joints are valid data.
- If a joint is inferred, set `inferred = true` and reduce confidence.
- If multiple sources can fill the same joint, keep the chosen source in
  the joint record and optionally store candidates in debug output.
- The retargeter must not assume all canonical joints exist.

### RetargetTargets

`RetargetTargets` is the robot-agnostic task layer extracted from
Godot Humanoid canonical joints.

```json
{
  "schema": "operator.retarget_targets.v1",
  "timestamp_ns": 123456789,
  "root": {
    "anchor": "hips",
    "mode": "fixed_overlay"
  },
  "torso": {
    "chest_orientation": {
      "joint": "upper_chest",
      "weight": 0.4
    },
    "head_direction": {
      "joint": "head",
      "weight": 0.15
    }
  },
  "arms": {
    "left": {
      "wrist_pose": {
        "joint": "left_wrist",
        "weight": 1.0
      },
      "elbow_position": {
        "joint": "left_lower_arm",
        "weight": 0.35
      },
      "shoulder_position": {
        "joint": "left_shoulder",
        "weight": 0.25
      }
    },
    "right": {
      "wrist_pose": {
        "joint": "right_wrist",
        "weight": 1.0
      },
      "elbow_position": {
        "joint": "right_lower_arm",
        "weight": 0.35
      },
      "shoulder_position": {
        "joint": "right_shoulder",
        "weight": 0.25
      }
    }
  }
}
```

The extractor should multiply nominal weights by tracking quality. A
tracked wrist target is high weight; an inferred elbow target should be a
soft hint or omitted.

### RobotSolution

`RobotSolution` is the robot-specific result used for rendering, optional
control, and evaluation.

```json
{
  "schema": "operator.robot_solution.v1",
  "timestamp_ns": 123456789,
  "robot": "unitree_h2_sharpa_upper_body",
  "solver": "pinocchio_pink_qp",
  "joint_names": [
    "waist_yaw",
    "waist_roll",
    "waist_pitch",
    "left_shoulder_pitch",
    "left_shoulder_roll",
    "left_shoulder_yaw",
    "left_elbow",
    "left_wrist_yaw",
    "right_shoulder_pitch",
    "right_shoulder_roll",
    "right_shoulder_yaw",
    "right_elbow",
    "right_wrist_yaw"
  ],
  "joint_q": [0.0, 0.0, 0.0],
  "joint_dq": [0.0, 0.0, 0.0],
  "residuals": {
    "left_wrist_pos_m": 0.025,
    "left_wrist_rot_rad": 0.08,
    "right_wrist_pos_m": 0.031,
    "right_wrist_rot_rad": 0.12,
    "chest_rot_rad": 0.04
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

## Source Adapters

Adapters convert raw source observations into Godot Humanoid canonical
joints.

### GodotBodyAdapter

Input: Godot `XRBodyTracker` from `/user/body_tracker`.

Responsibilities:

- Iterate Godot body joints up to `XRBodyTracker.JOINT_MAX`.
- Convert Godot joint enum names into stable lower-snake-case keys.
- Copy transforms and flags.
- Set `source = "godot_xrbodytracker"`.

This is the preferred path when Godot's runtime already exposes a
complete body tracker.

### PicoBodyAdapter

Input: `PicoOpenXRBridge.sample_body_joints()` and optional standard hand
tracking.

Initial upper-body mapping:

| Pico BD joint | Canonical joint |
|---|---|
| `PELVIS` | `hips` / `root` |
| `SPINE1` | `spine` or `lower_chest` |
| `SPINE2` | `chest` |
| `SPINE3` | `upper_chest` |
| `NECK` | `neck` |
| `HEAD` | `head` |
| `LEFT_COLLAR` | `left_scapula` or low-confidence shoulder helper |
| `LEFT_SHOULDER` | `left_shoulder` |
| `LEFT_ELBOW` | `left_lower_arm` / elbow position target |
| `LEFT_WRIST` | `left_wrist` |
| `LEFT_HAND` | `left_hand` |
| right-side equivalents | right-side canonical joints |

If standard hand tracking is active, hand joints should fill Godot
Humanoid hand and finger slots separately. Pico body wrist and OpenXR
hand wrist may both exist. The resolver chooses one canonical value while
raw frames preserve both.

### MetaBodyAdapter

Input: Meta `XR_FB_body_tracking`, Meta full-body tracking, and standard
hand tracking when exposed separately.

Responsibilities:

- Map Meta body core to canonical torso and limb slots.
- Map Meta hand joints to canonical hand/finger slots.
- Map full-body extra joints to canonical lower-body slots when present.
- Mark canonical slots absent from Meta as invalid.

Meta may fill more upper-body slots than Pico, such as scapula and wrist
twist. The H2 upper-body MVP can use these as improved hints but must not
depend on them being present.

### ExternalTrackerAdapter

Input: waist, chest, elbow, wrist, ankle, or foot tracker poses.

External trackers may not form a complete body skeleton. They should be
treated as high-confidence measurements for selected canonical joints or
as extra IK constraints.

Example policy:

```text
external chest tracker > body chest > inferred chest
external wrist tracker > hand wrist > body wrist > controller wrist
```

### FallbackAdapter

Input: head pose and controller/hand wrist pose.

Used when body tracking is unavailable. It can create a minimal upper
body target set:

- `head`: tracked from HMD.
- `left_wrist` / `right_wrist`: controller or hand tracker.
- `chest`: inferred from head orientation and calibration pose.
- `shoulder` / `elbow`: inferred with low confidence from calibration
  dimensions and wrist targets.

Fallback inference is useful for UI continuity, but it should be visually
marked and recorded as inferred.

## Fusion and Quality

Multiple sources may claim the same canonical joint. A resolver should
choose the active value based on source priority and quality:

```text
head camera pose > body head
external chest tracker > body chest > inferred chest
tracked hand wrist > body wrist > controller wrist > inferred wrist
tracked body elbow > inferred elbow
```

Quality fields:

- `valid`: the pose is syntactically usable.
- `tracked`: the source reports current tracking.
- `inferred`: Operator generated this pose.
- `confidence`: normalized score from 0 to 1.
- `source`: adapter or raw source.
- `source_joint`: source-specific joint name or ID.

The task extractor should convert these into solver weights:

```text
tracked + high confidence  -> nominal weight
valid but low confidence   -> reduced weight
inferred                   -> low weight or hint only
invalid                    -> omit task
```

## Calibration and Coordinate Frames

The retargeting pipeline needs one calibration step per session:

1. User stands in a neutral or T-pose-like calibration posture.
2. Record user hips/chest/head and wrist locations in XR world.
3. Record robot neutral pose and link frames.
4. Estimate user dimensions relevant to upper-body retargeting:
   shoulder width, upper-arm length, forearm length, chest height.
5. Compute transform from XR world to robot overlay world.

Approximate Godot-to-robot axis mapping for initial implementation:

```text
robot_x = -godot_z
robot_y = -godot_x
robot_z =  godot_y
```

This constant mapping is not sufficient by itself. The session
calibration transform is the authority.

For ego overlay, the robot pelvis/base should be anchored in the XR
scene. Human wrists should be used as task targets. If the robot cannot
reach them, the solver should expose residuals rather than silently
scaling the human motion into reach.

## Retargeting Formulation

### Recommended first solver

Use a kinematic IK/QP solver backed by a real robot model:

- Pinocchio for URDF model loading, forward kinematics, and Jacobians.
- Pink or an equivalent QP-based task-space IK layer for weighted tasks
  and limits.

This is enough for the first upper-body H2 overlay/control loop.

### Upper-body decision variables

For the H2 MVP, keep the pelvis/base fixed and optimize only upper-body
joint positions or velocities:

```text
q_upper = [
  torso joints,
  left arm joints,
  right arm joints
]
```

The exact joint names come from the H2 URDF/MJCF and must live in the H2
retargeter config.

### Tasks

Primary tasks:

- left wrist pose.
- right wrist pose.
- chest or upper-chest orientation.

Secondary tasks:

- left elbow position as a pole/hint.
- right elbow position as a pole/hint.
- shoulder position or clavicle/scapula hint when reliable.
- head direction as a low-weight torso cue.
- posture regularization toward robot neutral pose.
- smoothness from previous solution.

### Objective

One practical differential IK/QP objective:

```text
minimize over dq:

  w_lw_pos   || J_lw_pos(q) dq - e_lw_pos ||^2
+ w_lw_rot   || J_lw_rot(q) dq - e_lw_rot ||^2
+ w_rw_pos   || J_rw_pos(q) dq - e_rw_pos ||^2
+ w_rw_rot   || J_rw_rot(q) dq - e_rw_rot ||^2
+ w_chest    || J_chest(q) dq - e_chest ||^2
+ w_elbow_l  || J_elbow_l(q) dq - e_elbow_l ||^2
+ w_elbow_r  || J_elbow_r(q) dq - e_elbow_r ||^2
+ w_posture  || q + dq dt - q_home ||^2
+ w_smooth   || dq - dq_prev ||^2
```

Subject to:

```text
q_min <= q + dq dt <= q_max
dq_min <= dq <= dq_max
workspace constraints, where configured
self-collision constraints, where configured
task-specific disable masks, for example position-only elbows
```

For a first overlay-only implementation, self-collision can be reported
as a warning if the solver library does not support it yet. For real
robot control, self-collision and safety limits should be non-optional.

### Task hierarchy

If using hierarchical QP, suggested priorities:

1. Hard safety constraints: joint limits, velocity limits, collision,
   forbidden regions.
2. Wrist position and orientation, because they define manipulation
   intent.
3. Torso/chest orientation.
4. Elbow hints and shoulder hints.
5. Posture and smoothness.

If using weighted QP, choose weights to approximate this hierarchy and
monitor saturation.

## Rendering and Control

The H2 overlay should render from `RobotSolution.joint_q`, not directly
from human body joints. This makes the overlay show what the robot can
actually do.

Recommended render layers:

- Solid robot mesh: optimized H2 state.
- Optional translucent ghost: human target wrists/chest/head.
- Residual vectors: lines from robot wrists to human wrist targets.
- Color status:
  - green: tracked and reachable.
  - yellow: near joint/velocity limits, low confidence, or high residual.
  - red: tracking invalid, solver failed, or target unreachable.

For real robot control, command output must pass through the robot-side
safety stack. The solver should never bypass robot-side limit checking or
watchdog behavior.

## Recording

Each capture session should record enough information to replay and
reevaluate retargeting offline:

```text
raw_vendor_pose.jsonl
godot_humanoid_joints.jsonl
retarget_targets.jsonl
robot_solution.jsonl
```

Required replay properties:

- Rebuild Godot Humanoid canonical joints from raw frames after adapter
  fixes.
- Rebuild `RetargetTargets` with different extraction weights.
- Re-run H2, G1, or future robot retargeters from the same canonical
  Godot Humanoid joint data.
- Compare residuals across source devices and robot models.

## Protocol Integration

There are two practical implementation paths.

### Short-term path

Extend the existing XR-side tracking path to include body pose data:

- Add a `Body` section beside existing `Head`, `Controller`, and `Hand`
  data in the legacy `Tracking` JSON, or send a separate command such as
  `BodyTracking`.
- Keep frame sizes modest by sending only the upper-body Godot Humanoid
  joint subset needed by the MVP.
- Record full raw body data through the existing capture/spool path.

This is easiest to validate but should not be treated as the final
wire-protocol design.

### Target path

Define explicit body-pose messages:

```text
RawVendorPose                    optional debug/record stream
Godot Humanoid canonical joints  live stream
RetargetTargets                  local or robot-side derived stream
RobotSolution                    telemetry/result stream
```

The Godot Humanoid canonical joint stream should support latest-only
semantics. Old body poses are not useful for teleoperation once a newer
pose is available.

## First Implementation Plan

### Phase 1: Offline schemas and adapter proof

- Define JSON schemas for `RawVendorPose`, Godot Humanoid canonical
  joints, `RetargetTargets`, and `RobotSolution`.
- Add a Pico raw-to-Godot-Humanoid adapter for the upper-body subset.
- Add a Godot `XRBodyTracker` raw-to-Godot-Humanoid adapter.
- Write sample JSONL fixtures from recorded Pico body data.
- Validate that Godot Humanoid canonical output marks missing and
  inferred joints explicitly.

### Phase 2: Live Godot Humanoid canonical joints in XR

- Add a `BodyPoseProvider` node that selects Godot, Pico, external
  tracker, or fallback adapters.
- Extend `PoseSender` or a new body-pose sender to publish upper-body
  Godot Humanoid canonical joints at the tracking rate.
- Add capture-side recording of both raw frames and Godot Humanoid
  canonical joint frames.

### Phase 3: H2 upper-body retargeter

- Add H2 upper-body model config: URDF/MJCF path, controlled joints,
  link frames, neutral pose, limits, and task weights.
- Implement task extraction from Godot Humanoid canonical joints.
- Implement IK/QP with Pinocchio + Pink or equivalent.
- Produce `RobotSolution` with residuals and limit saturation.

### Phase 4: XR overlay visualization

- Render H2 from `RobotSolution.joint_q`.
- Add ghost targets and residual vectors.
- Add green/yellow/red status based on tracking quality, residuals, and
  solver state.
- Record synchronized robot solution frames with video.

### Phase 5: Quest/Meta adapter

- Add Meta/Quest raw-to-Godot-Humanoid adapter.
- Reuse the same H2 task extractor and retargeter.
- Compare residuals and missing-joint patterns between Pico and Quest.

## Validation

Minimum acceptance criteria:

- H2 retargeter code contains no Pico/Meta-specific joint names.
- Pico and Quest produce the same `operator.godot_humanoid_joints.v1`
  schema.
- Every Godot Humanoid canonical joint can be traced back to a source
  joint or marked inferred/invalid.
- H2 overlay uses optimized robot `joint_q`, not human pose transforms.
- Solver residuals are visible in the UI and recorded.
- Raw vendor data is sufficient to regenerate Godot Humanoid canonical
  joints offline.

Suggested metrics:

- wrist position residual in meters.
- wrist orientation residual in radians.
- chest orientation residual in radians.
- solver latency in milliseconds.
- solve failure rate.
- percentage of frames with inferred torso/elbow/wrist targets.
- time spent near joint or velocity limits.

## Open Questions

- Exact H2 URDF/MJCF asset location and link names for torso and arms.
- Whether the first solver runs on-device, robot-side, or workstation-side
  during development.
- Final live protocol shape for the Godot Humanoid canonical joint stream.
- Whether self-collision is required before hardware control or only
  before public demos.
- How to synchronize body pose, video frame timestamps, and robot solution
  timestamps in the final capture artifact.

## References

- Godot `XRBodyTracker`:
  <https://docs.godotengine.org/en/4.5/classes/class_xrbodytracker.html>
- OpenXR `XR_FB_body_tracking` / `XrBodyJointFB`:
  <https://registry.khronos.org/OpenXR/specs/1.0/man/html/XrBodyJointFB.html>
- OpenXR `XR_META_body_tracking_full_body` / `XrFullBodyJointMETA`:
  <https://registry.khronos.org/OpenXR/specs/1.1/man/html/XrFullBodyJointMETA.html>
- OpenXR `XR_BD_body_tracking` / `XrBodyJointBD`:
  <https://registry.khronos.org/OpenXR/specs/1.1/man/html/XrBodyJointBD.html>
- OpenXR hand tracking joint count:
  <https://registry.khronos.org/OpenXR/specs/1.0/man/html/XR_HAND_JOINT_COUNT_EXT.html>
- Pinocchio documentation:
  <https://docs.ros.org/en/humble/p/pinocchio/doc/Overview.html>
- Pink documentation:
  <https://stephane-caron.github.io/pink/>
- Hierarchical quadratic programming for humanoid motion generation:
  <https://journals.sagepub.com/doi/abs/10.1177/0278364914521306>
- Multi-contact motion retargeting with whole-body optimization:
  <https://arxiv.org/abs/2206.00542>
