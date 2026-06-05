# RFC-004 Full-Body Human-to-Humanoid Retargeting

## Status

Proposed

## Owner

TBD

## Date

2026-06-06

## Summary

Extend RFC-003 from upper-body humanoid retargeting to full-body
retargeting. The existing representation remains valid:

```text
RawVendorPose -> OperatorHumanPose -> RetargetTargets -> RobotSolution
```

The main change is that lower-body retargeting cannot be treated as
"upper-body IK plus legs". Legs introduce contacts, support phases,
balance, footstep intent, and controller authority boundaries. The first
full-body implementation should therefore be staged:

1. Full-body canonical pose recording and replay.
2. Full-body kinematic overlay and simulation retargeting.
3. Limited real-robot whole-body behaviors such as standing, squatting,
   and weight shifting.
4. Walking only through a robot locomotion controller or whole-body
   controller that owns balance and contact handling.

For real hardware, Operator should not directly stream human leg joint
targets into robot leg position control. Operator should produce
whole-body intent and robot-specific feasible states, while the robot-side
controller remains responsible for stability, contact transitions, and
safety enforcement.

```text
Pico / Quest / Godot / waist-foot trackers
        -> source adapters
        -> OperatorHumanPose canonical joints
        -> full-body target extractor
        -> whole-body IK/QP for overlay and simulation
        -> RobotSolution + WholeBodyStatus
        -> XR overlay / sim validation / safe hardware command adapter
```

## Relationship To RFC-003

RFC-003 defines the core adapter and retargeter boundary for upper-body
humanoid retargeting. This RFC keeps that boundary and extends it.

Still valid from RFC-003:

- Preserve source-specific raw tracking data.
- Consume canonical `OperatorHumanPose`, not vendor joints.
- Keep source adapters independent from robot retargeters.
- Render the robot from optimized robot state, not direct human pose
  playback.
- Record raw input, canonical pose, task targets, robot solution, and
  residuals for offline replay.

Changed or extended:

- `RetargetTargets` needs lower-body, pelvis, foot, and contact targets.
- The solver changes from fixed-pelvis upper-body IK to whole-body IK/QP.
- Real hardware control needs a locomotion or whole-body-control boundary.
- Validation must include foot slip, contact violation, support margin,
  and balance status in addition to upper-body residuals.

## Context

The current XR side already has useful full-body inputs:

- Godot `XRBodyTracker` can expose a 87-joint humanoid skeleton.
- Pico body tracking can provide body joints, posture, velocity, and
  acceleration metadata.
- Motion trackers are already sampled separately and include likely
  waist, left-foot, and right-foot tracker roles.
- The capture path can write body joints and motion tracker JSONL
  sidecars.

These inputs are enough to start with full-body recording and overlay.
They are not enough by themselves to guarantee safe real humanoid walking.
Lower-body control must be designed around contact and balance.

## Goals

- Extend Operator's retargeting target layer to represent full-body
  motion intent.
- Support pelvis, legs, feet, support state, and contact quality.
- Use external waist and foot trackers as high-confidence lower-body
  measurements when available.
- Provide a whole-body IK/QP retargeter for XR overlay and simulation.
- Keep real hardware lower-body control behind a safety and stability
  boundary.
- Record enough data to replay and evaluate full-body retargeting
  offline.
- Make the first full-body milestone useful even without walking:
  standing, crouching, leaning, weight shifting, and foot placement
  visualization.

## Non-Goals

- Directly copying human lower-body joint angles to robot lower-body
  joints.
- Driving real robot leg joint position targets from headset body tracking
  without a balance controller.
- Implementing a final locomotion MPC or production whole-body controller
  inside this RFC.
- Guaranteeing walking from every headset's built-in body tracking alone.
- Replacing the robot vendor's native locomotion or stabilization stack.
- Treating inferred knees, ankles, or feet as safe hardware control
  targets.

## Design Principles

### Full body is contact-aware

Upper-body retargeting can often be formulated as fixed-base kinematic
IK. Full-body retargeting must model which foot is supporting the robot,
when a foot is allowed to move, and whether the center of mass remains in
a stable support region.

### Overlay and hardware are different products

For overlay and simulation, a whole-body kinematic solution is useful even
when it violates real contact or balance. For hardware, those violations
must block or degrade the command before it reaches the robot.

### The lower-body command boundary is high level

Operator may generate lower-body intent such as base velocity, desired
pelvis height, stance width, footstep candidates, or weight-shift intent.
The robot locomotion or whole-body controller should own the final joint
targets, contact schedule, and stabilization.

### Quality is more important for legs than arms

Missing or inferred lower-body joints are expected on many devices. The
target extractor must reduce or omit tasks when foot, ankle, knee, or hip
quality is low. Inferred lower-body targets may be acceptable for display
but should not unlock hardware locomotion.

## Data Model Extensions

### OperatorHumanPose

`OperatorHumanPose` can remain `operator.human_pose.v1`. It already uses
Godot Humanoid semantics and may contain lower-body joints such as:

```text
hips
left_upper_leg
left_lower_leg
left_foot
left_toes
right_upper_leg
right_lower_leg
right_foot
right_toes
```

The map remains sparse. Missing lower-body joints are valid data. Source
adapters must preserve `valid`, `tracked`, `inferred`, `confidence`,
`source`, and `source_joint` for every lower-body joint they emit.

### RetargetTargets

Full-body retargeting should extend the target schema rather than adding
robot-specific fields to `OperatorHumanPose`. A new schema version is
recommended:

```json
{
  "schema": "operator.retarget_targets.v2",
  "timestamp_ns": 123456789,
  "root": {
    "anchor": "hips",
    "mode": "full_body_overlay",
    "pelvis_pose": {
      "joint": "hips",
      "weight": 0.6
    },
    "pelvis_height": {
      "joint": "hips",
      "weight": 0.8
    }
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
      }
    }
  },
  "legs": {
    "left": {
      "foot_pose": {
        "joint": "left_foot",
        "weight": 1.0
      },
      "knee_position": {
        "joint": "left_lower_leg",
        "weight": 0.25
      },
      "contact": {
        "state": "stance",
        "confidence": 0.9
      }
    },
    "right": {
      "foot_pose": {
        "joint": "right_foot",
        "weight": 1.0
      },
      "knee_position": {
        "joint": "right_lower_leg",
        "weight": 0.25
      },
      "contact": {
        "state": "swing",
        "confidence": 0.8
      }
    }
  },
  "balance": {
    "support_phase": "left_single_support",
    "desired_com_projection": {
      "frame": "support_polygon",
      "xy": [0.02, 0.01],
      "weight": 0.5
    }
  }
}
```

Contact states:

```text
unknown
stance
swing
toe_contact
heel_contact
double_support
```

The extractor should infer contact only when there is enough evidence:
foot height, foot velocity, tracker confidence, and recent support
history. If contact confidence is low, hardware lower-body control should
degrade to a safer mode.

### RobotSolution

`RobotSolution` should be extended for full-body robots:

```json
{
  "schema": "operator.robot_solution.v2",
  "timestamp_ns": 123456789,
  "robot": "unitree_h2_full_body",
  "solver": "whole_body_ik_qp",
  "base": {
    "pose": {
      "p": [0.0, 0.0, 0.9],
      "q": [0.0, 0.0, 0.0, 1.0]
    },
    "velocity": [0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
  },
  "joint_names": [
    "waist_yaw",
    "left_hip_pitch",
    "left_knee",
    "left_ankle_pitch",
    "right_hip_pitch",
    "right_knee",
    "right_ankle_pitch"
  ],
  "joint_q": [0.0, 0.0, 0.0],
  "joint_dq": [0.0, 0.0, 0.0],
  "contacts": {
    "left_foot": {
      "state": "stance",
      "slip_mps": 0.01
    },
    "right_foot": {
      "state": "swing",
      "clearance_m": 0.04
    }
  },
  "residuals": {
    "left_foot_pos_m": 0.02,
    "right_foot_pos_m": 0.04,
    "pelvis_pos_m": 0.03,
    "chest_rot_rad": 0.05
  },
  "limits": {
    "joint_limit_saturation": [],
    "velocity_limit_saturation": [],
    "contact_violation": []
  },
  "solve_ok": true,
  "balance_ok": true,
  "hardware_control_allowed": false,
  "quality": "tracked"
}
```

### WholeBodyStatus

For hardware and UI, publish a compact status alongside `RobotSolution`:

```json
{
  "schema": "operator.whole_body_status.v1",
  "timestamp_ns": 123456789,
  "mode": "overlay_only",
  "tracking_quality": "tracked",
  "support_phase": "double_support",
  "balance_ok": true,
  "hardware_control_allowed": false,
  "degrade_reason": "lower_body_overlay_only",
  "metrics": {
    "com_support_margin_m": 0.05,
    "left_foot_slip_mps": 0.0,
    "right_foot_slip_mps": 0.0,
    "solve_latency_ms": 3.4
  }
}
```

## Source Adapter Extensions

### GodotBodyAdapter

Map all available `XRBodyTracker` lower-body joints into
`OperatorHumanPose`. Preserve missing joints as absent or invalid rather
than inferred.

### PicoBodyAdapter

Map Pico lower-body joints when available:

| Pico / body joint | Canonical joint |
|---|---|
| `PELVIS` | `hips` |
| `LEFT_HIP` | `left_upper_leg` or hip helper |
| `LEFT_KNEE` | `left_lower_leg` / knee target |
| `LEFT_ANKLE` | `left_foot` or ankle helper |
| `LEFT_FOOT` | `left_foot` |
| right-side equivalents | right-side canonical joints |

If Pico body tracking does not expose stable foot poses, do not infer
hardware-grade foot targets from it.

### ExternalTrackerAdapter

External trackers are the preferred first source for lower-body hardware
experiments:

```text
external waist tracker > body hips > inferred hips
external left foot tracker > body left_foot > inferred left_foot
external right foot tracker > body right_foot > inferred right_foot
```

The adapter should preserve tracker role, tracker index, battery state,
tracking flags, and source-specific confidence metadata when available.

### FallbackAdapter

Fallback lower-body inference should be overlay-only. It may produce:

- pelvis height from head height and calibration.
- rough stance width from calibration.
- visually plausible knee bends.

Fallback lower-body data must set `inferred = true` and should never
enable hardware lower-body control.

## Calibration

Full-body calibration extends RFC-003 calibration:

1. User stands in neutral stance.
2. Record head, chest, hips, wrists, knees, ankles, and feet when
   available.
3. Record waist and foot tracker offsets relative to the user's body.
4. Record robot neutral pose, foot frames, pelvis frame, and link frames.
5. Estimate body dimensions:
   - shoulder width.
   - arm lengths.
   - hip width.
   - thigh length.
   - shank length.
   - foot length.
   - standing pelvis height.
6. Compute XR-world to robot-overlay transform.
7. Determine neutral support polygon and default stance.

Calibration should store whether lower-body data is tracked, tracker
based, body-tracking based, or inferred. This becomes part of the session
quality gate.

## Retargeting Formulation

### Decision variables

For overlay and simulation:

```text
q_full = [
  floating_base,
  torso joints,
  left arm joints,
  right arm joints,
  left leg joints,
  right leg joints
]
```

For real hardware, the command adapter may expose only a subset:

```text
upper_body_joint_targets
pelvis_height_intent
base_velocity_intent
weight_shift_intent
footstep_intent
stance_mode
```

The hardware command subset must be robot-specific and safety-gated.

### Tasks

Primary kinematic tasks for overlay and simulation:

- left and right wrist pose.
- chest or upper-chest orientation.
- pelvis pose, yaw, and height.
- left and right foot pose.
- stance-foot contact consistency.

Secondary tasks:

- elbow and knee pole hints.
- head direction.
- foot clearance during swing.
- posture regularization toward robot neutral.
- smoothness from previous solution.
- symmetry and natural stance width.

Balance-aware tasks and constraints:

- center-of-mass projection inside support polygon.
- stance foot zero or low velocity.
- swing foot clearance.
- contact schedule consistency.
- maximum pelvis acceleration.

### Objective

A practical whole-body differential IK/QP objective:

```text
minimize over dq:

  w_lw      || J_lw(q) dq - e_lw ||^2
+ w_rw      || J_rw(q) dq - e_rw ||^2
+ w_chest   || J_chest(q) dq - e_chest ||^2
+ w_pelvis  || J_pelvis(q) dq - e_pelvis ||^2
+ w_lfoot   || J_lfoot(q) dq - e_lfoot ||^2
+ w_rfoot   || J_rfoot(q) dq - e_rfoot ||^2
+ w_com     || J_com(q) dq - e_com ||^2
+ w_knee_l  || J_knee_l(q) dq - e_knee_l ||^2
+ w_knee_r  || J_knee_r(q) dq - e_knee_r ||^2
+ w_posture || q + dq dt - q_home ||^2
+ w_smooth  || dq - dq_prev ||^2
```

Subject to:

```text
q_min <= q + dq dt <= q_max
dq_min <= dq <= dq_max
ddq_min <= (dq - dq_prev) / dt <= ddq_max
self-collision constraints
workspace constraints
stance foot velocity constraints
foot clearance constraints
COM/support polygon constraints
robot-specific forbidden regions
```

### Task hierarchy

Recommended hierarchy:

1. Hard safety constraints: joint limits, velocity limits, acceleration
   limits, collision, forbidden regions.
2. Hardware stability constraints: stance contact, support polygon, foot
   slip, robot-specific balance limits.
3. End-effector manipulation intent: wrists and hand targets.
4. Pelvis and foot targets.
5. Torso/chest/head targets.
6. Elbow, knee, and shoulder hints.
7. Posture, smoothness, and style.

For overlay-only mode, balance violations can be visualized. For hardware
mode, balance violations must block or degrade lower-body commands.

## Hardware Control Modes

### Overlay-only

The solver may produce full-body `RobotSolution.joint_q` for rendering.
No hardware command is sent.

### Simulation-only

The solver may command a simulated humanoid if the simulator enforces
robot limits and reports contact and balance metrics. This is the first
place to test foot target extraction and contact heuristics.

### Upper-body hardware plus lower-body hold

Recommended first hardware mode:

- Send upper-body joint targets through existing safety layers.
- Keep robot lower body in vendor-supported standing mode.
- Use lower-body retargeting only for visualization and quality metrics.

### Standing whole-body behaviors

Second hardware mode:

- Allow pelvis height changes within narrow limits.
- Allow weight shifting within support-margin limits.
- Allow stance width or foot orientation only if the robot controller
  explicitly supports those commands.
- Block walking.

### Locomotion intent

Walking should be expressed as high-level intent:

```text
base_velocity
turn_rate
footstep_goal
gait_mode
stop
```

The robot locomotion controller or whole-body controller owns final joint
targets, contact timing, and recovery behavior.

## Protocol Integration

Full-body data should use explicit body-pose messages rather than the
legacy `Tracking` JSON path.

Recommended streams:

```text
RawVendorPose          optional debug/record stream
OperatorHumanPose      canonical latest-only live stream
RetargetTargets        local or robot-side derived stream
RobotSolution          retargeted robot state stream
WholeBodyStatus        compact status and safety-gate stream
LocomotionIntent       optional high-level command stream
```

The live canonical pose stream should keep latest-only semantics. Full
raw data can remain a recording/debug stream.

## Recording

Full-body sessions should record:

```text
raw_vendor_pose.jsonl
motion_trackers.jsonl
canonical_human_pose.jsonl
retarget_targets.jsonl
robot_solution.jsonl
whole_body_status.jsonl
locomotion_intent.jsonl
```

Required replay properties:

- Rebuild lower-body canonical pose after adapter fixes.
- Recompute contact phases with different heuristics.
- Re-run whole-body retargeters for H2, G1, or future humanoids.
- Compare overlay-only, simulation, and hardware-gated solutions.
- Audit every frame where lower-body hardware control was allowed.

## Implementation Plan

### Phase 1: Full-body schema and offline replay

- Extend JSON schemas for full-body `RetargetTargets`,
  `RobotSolution`, and `WholeBodyStatus`.
- Add lower-body canonical mapping tests for Godot, Pico, Meta, and
  external trackers.
- Write fixtures from recorded body and motion tracker JSONL.
- Add a replay tool that regenerates full-body canonical pose and target
  streams.

### Phase 2: XR full-body live stream

- Add a `BodyPoseProvider` that emits full-body canonical pose when
  available.
- Include waist and foot trackers in source fusion.
- Publish canonical full-body pose over an explicit latest-only stream.
- Record raw and canonical pose together with video timestamps.

### Phase 3: Overlay-only whole-body retargeter

- Add a full-body humanoid retargeter config:
  - URDF/MJCF path.
  - controlled joints.
  - pelvis, feet, hands, torso link frames.
  - neutral stance.
  - joint, velocity, and acceleration limits.
  - task weights.
- Implement whole-body IK/QP.
- Render from `RobotSolution.joint_q`.
- Display foot residuals, contact state, and balance status.

### Phase 4: Simulation validation

- Run the retargeted full-body solution in simulation.
- Measure foot slip, contact violation, COM support margin, and solve
  latency.
- Validate standing, crouching, leaning, weight shifting, and stepping
  in place before any hardware lower-body command.

### Phase 5: Hardware-gated standing behaviors

- Keep lower body in a vendor-supported standing or stabilization mode.
- Allow upper-body hardware control as in RFC-003.
- Add narrowly bounded pelvis height and weight-shift commands only if
  the robot controller exposes safe interfaces.
- Publish `WholeBodyStatus.hardware_control_allowed` for every frame.

### Phase 6: Locomotion intent

- Add high-level locomotion commands only after simulation metrics are
  stable.
- Use robot-native locomotion or a dedicated whole-body controller.
- Keep direct leg joint streaming out of scope for normal operation.

## Validation

Minimum acceptance criteria:

- Full-body adapters do not leak Pico, Meta, or tracker-specific names
  into robot retargeters.
- Every lower-body canonical joint can be traced to a source, marked
  inferred, or marked invalid.
- Overlay renders robot state from `RobotSolution`, not human pose
  transforms.
- Solver residuals include pelvis and both feet.
- UI shows support phase, contact confidence, and balance status.
- Hardware lower-body commands are blocked when contact or balance
  quality is low.
- Every hardware-enabled frame records the reason it was allowed.

Suggested metrics:

- pelvis position and yaw residual.
- foot position and orientation residual.
- foot slip velocity during stance.
- swing foot clearance.
- contact classification confidence.
- center-of-mass support margin.
- joint, velocity, and acceleration saturation.
- self-collision or forbidden-region violations.
- solve latency.
- percentage of frames using inferred lower-body targets.
- percentage of frames where hardware lower-body control was allowed.

## Open Questions

- Which humanoid model should be the first full-body target: H2, G1, or a
  simulation-only model?
- Where should the first whole-body solver run: headset, robot-side
  adapter, workstation, or simulation server?
- What lower-body control APIs are available on the target robot:
  position targets, base velocity, gait commands, footstep goals, pelvis
  height, or weight shift?
- What hardware safety evidence is required before enabling standing
  whole-body behaviors?
- Which contact estimator is sufficient for the first pass: foot height
  and velocity, tracker status, force/torque feedback, or simulator
  contacts?
- How should video, body pose, contact state, solver result, and robot
  telemetry be synchronized in the final capture artifact?

## References

- RFC-003 Upper-Body Human-to-Humanoid Retargeting:
  `claw/rfcs/003-upper-body-human-to-humanoid-retargeting.md`
- Godot `XRBodyTracker`:
  <https://docs.godotengine.org/en/4.5/classes/class_xrbodytracker.html>
- OpenXR `XR_META_body_tracking_full_body` / `XrFullBodyJointMETA`:
  <https://registry.khronos.org/OpenXR/specs/1.1/man/html/XrFullBodyJointMETA.html>
- OpenXR `XR_BD_body_tracking` / `XrBodyJointBD`:
  <https://registry.khronos.org/OpenXR/specs/1.1/man/html/XrBodyJointBD.html>
- Pinocchio documentation:
  <https://docs.ros.org/en/humble/p/pinocchio/doc/Overview.html>
- Pink documentation:
  <https://stephane-caron.github.io/pink/>
- Multi-contact motion retargeting with whole-body optimization:
  <https://arxiv.org/abs/2206.00542>
