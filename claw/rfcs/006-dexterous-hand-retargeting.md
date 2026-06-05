# RFC-004 OpenXR Hand Tracking to Dexterous Hand Retargeting Framework

## Status

Proposed

## Owner

TBD

## Date

2026-06-06

## Depends On

[RFC-003 Upper-Body Human-to-Humanoid Retargeting](003-upper-body-human-to-humanoid-retargeting.md)
— this RFC lifts the RFC-003 Non-Goal *"Retargeting hand or finger
articulation to Sharpa in this phase"* and slots into the four-schema
data model and adapter/retargeter pattern that RFC-003 already
established.

## Summary

Add a **dexterous-hand retargeting framework** to Operator. The input
is the platform-neutral OpenXR `XR_EXT_hand_tracking` stream (Quest,
Pico, AVP, and any compliant runtime). The output is robot-specific
finger joint positions consumed by render and control.

The design is **hand-agnostic at the framework layer, hand-specific
at the profile layer**, mirroring RFC-003's adapter / retargeter
separation. One source adapter (`OpenXRHandTrackingAdapter`)
populates the canonical Godot Humanoid finger slots. One framework
component (`HandRetargeterRegistry`) selects a per-robot
`HandProfile` and instantiates the matching retargeter algorithm.

```text
OpenXR XR_EXT_hand_tracking
  → OpenXRHandTrackingAdapter      (one adapter, all runtimes)
  → Godot Humanoid finger joints   (canonical, hand-agnostic)
  → RetargetTargets v2 hands       (robot-agnostic task layer)
  → HandRetargeterRegistry         (picks profile by robot id)
       │
       ├─ Sharpa Wave profile      (22 DoF, vector mode)
       ├─ Inspire FTP profile      (6 DoF, vector mode)
       ├─ Ability Hand profile     (6 DoF, vector mode)
       ├─ 5-DoF underactuated      (5 DoF, curl-angle mode)
       ├─ Robotiq 2F-85 profile    (1 DoF, gripper-distance mode)
       └─ ...                       (new hands added by config + URDF)
  → RobotSolution finger joint_q
```

The **first concrete profile is Sharpa Wave**. The framework is
explicitly designed so that adding the second, third, and Nth hand is
a config + URDF change — no Python class hierarchy edits, no
adapter changes, no schema bumps. A second illustrative profile
("generic 5-DoF underactuated 5-finger") and a third degenerate one
(1-DoF parallel gripper) are specified to validate the abstraction
covers the full DoF spectrum.

The one schema bump (`operator.retarget_targets.v1 → v2`) is
additive: it adds a `hands` section beside `torso` and `arms`. The
hand section is finger-count-flexible (5 / 4 / 3 / 2 / 1 fingers all
expressible) so the same schema serves five-finger anthropomorphic
hands and parallel grippers.

## Context

### What RFC-003 already gives us

- **Four-layer data model** (`RawVendorPose` → Godot Humanoid
  canonical joints → `RetargetTargets` → `RobotSolution`). Hands fit
  cleanly:
  - `RawVendorPose` accepts any vendor schema by name.
  - Godot Humanoid joint enum (`XRBodyTracker.JOINT_MAX = 87`)
    already contains finger bones. Sparsely filled today; this RFC
    fills them.
  - `RetargetTargets` is the robot-agnostic task layer; this RFC
    adds `hands.{left,right}.fingertips`.
  - `RobotSolution.joint_names` is an ordered array; appending hand
    joints preserves wire compatibility.
- **Adapter / retargeter ownership contract.** *"Each tracking
  source gets one adapter; each robot gets one retargeter."* Hands
  obey the same contract.
- **Robot identifier reservation.** RFC-003 already chose
  `robot: "unitree_h2_sharpa_upper_body"` (line 320), forward-
  compatible with Sharpa. This RFC fills the Sharpa half.
- **Quality fields**, **Pinocchio toolchain**, **in-QP smoothness
  preference** — all inherited.

### Variety of robot hands in scope

The framework must handle four orders of magnitude in DoF and large
differences in finger topology:

| Class | Example | DoF | Fingers | Retargeter mode |
|---|---|---|---|---|
| High-DoF anthropomorphic | Sharpa Wave, Shadow Hand | 22–24 | 5 | vector / position / DexPilot |
| Mid-DoF anthropomorphic | LEAP (16), Allegro (16) | 16 | 4 (no pinky) | vector / DexPilot |
| Low-DoF anthropomorphic | Inspire FTP (6), Ability (6) | 6 | 5 | vector |
| Underactuated 5-finger | "1-DoF-per-finger" prosthetic | 5 | 5 | vector or curl-angle |
| Three-finger | Unitree Dex3, BarrettHand | 3–4 | 3 | vector (subset) |
| Parallel gripper | Robotiq 2F-85, Franka gripper | 1 | 2 effective | gripper-distance |

Every entry above can be expressed by the same framework with a
different `HandProfile` YAML; the algorithmic difference is captured
by a `retargeter_type` enum.

### Why a registry / profile pattern (vs. one class per hand)

- New hands ship 2–3× per year as the market matures. A class
  hierarchy means a code review for every hand; a profile means a
  YAML review.
- Most differences between hands are quantitative (joint count,
  limits, scaling) not qualitative. Algorithms cluster around 3–4
  modes, not N.
- Configuration-driven hands let downstream tools (Foxglove
  inspectors, dataset readers) understand new hands without
  shipping a new Python wheel.

### OpenXR `XR_EXT_hand_tracking` joint set

26 joints per hand, enumerated in `XrHandJointEXT`:

| Index | Joint | Notes |
|---|---|---|
| 0 | `PALM` | virtual centroid, not on the bone chain |
| 1 | `WRIST` | chain root; same pose as the OpenXR wrist action |
| 2 | `THUMB_METACARPAL` | thumb root |
| 3 | `THUMB_PROXIMAL` | thumb MCP |
| 4 | `THUMB_DISTAL` | thumb IP |
| 5 | `THUMB_TIP` | thumb fingertip |
| 6–10 | `INDEX_{METACARPAL, PROXIMAL, INTERMEDIATE, DISTAL, TIP}` | 5 joints |
| 11–15 | `MIDDLE_*` | same shape as index |
| 16–20 | `RING_*` | same shape |
| 21–25 | `LITTLE_*` | "pinky", same shape |

Each joint carries `pose` (position + quaternion), `radius`, and
`locationFlags`. Orientation convention: `+Z` distal, `+X` radial
(thumb side), `+Y` up.

Runtime support is universal across the target devices (Quest 3,
Pico 4U, AVP, Vive XR, Magic Leap 2). Tip positions differ across
runtimes by 1–3 mm — a known calibration nuisance addressed in
§Calibration.

## Goals

- One source adapter (`OpenXRHandTrackingAdapter`) serves every
  OpenXR-compliant runtime, including future ones.
- One framework component (`HandRetargeterRegistry` +
  `HandProfile` YAML schema) supports the full hand-DoF spectrum
  enumerated in §Context, with **add-a-hand cost ≤ 1 day for the
  YAML / URDF, 0 lines of framework code**.
- Schema deltas to RFC-003 are minimal and forward-compatible:
  one optional `hands` section on `RetargetTargets v2`, additive
  `joint_names` extension on `RobotSolution`.
- First profile (Sharpa Wave) produces fingertip RMS error < 8 mm
  on a held-out grasp dataset, comparable to upstream dex-retargeting
  baselines for Inspire / LEAP / Allegro.
- Second profile ("generic 5-DoF underactuated 5-finger") and
  third profile ("1-DoF parallel gripper") ship as documented
  validation profiles — even if no hardware exists for either, they
  prove the abstraction is real.
- Online performance ≥ 30 Hz per side on a laptop-class CPU. Per-
  side solve ≤ 4 ms target, ≤ 8 ms worst-case for vector mode;
  curl-angle and gripper-distance modes are < 1 ms.
- Do not regress any RFC-003 acceptance criterion. The hand pipeline
  is additive; arm retargeting works on the same `RawVendorPose`
  even if the hand source is missing.

## Non-Goals

- Auto-detecting which robot hand is present. The active
  `HandProfile` id is part of the robot's `DeviceDescriptor`
  (already in the wire protocol).
- Vendor-specific finger streams (Pico BD body fingers, Meta FB body
  fingers, Manus glove, Index controllers' finger sensors). Future
  source adapters; OpenXR hand tracking is the baseline.
- Tactile sensor (Sharpa's fingertip array, OptoForce, BioTac)
  integration. Separate sensor pipeline, separate RFC.
- Force / compliance / impedance control during contact. The first
  implementation is position-only retargeting.
- Mid-flight hand swapping. Operator restarts the session if the
  robot's hands change.
- Visualizing finger trajectories in the operator's HUD. Render is
  on the robot avatar mesh only.
- Defining a new wire-protocol message for the canonical hand
  stream. Hand joints ride on the existing RFC-003 short-term path
  for the first implementation.

## Design Principles

This RFC inherits all four RFC-003 principles and adds two of its own.

### Inherited from RFC-003

1. **Preserve raw, consume Godot Humanoid joints.**
2. **Retargeting is optimization, not copying.**
3. **Robot changes require a robot retargeter.** Hand changes
   require a hand profile (a specialization of this principle).
4. **Quality is first-class.**

### Added by this RFC

5. **Hand-agnostic data model, hand-specific profile.** The
   canonical layer, the task layer, and the source adapter do not
   know how many DoF the robot hand has. Algorithmic specialization
   lives in the `retargeter_type` chosen by the profile.

6. **Configurable, not hierarchical.** Every place where a class
   hierarchy would seem natural ("`SharpaRetargeter(BaseRetargeter)`",
   "`InspireRetargeter(BaseRetargeter)`"), we use a profile YAML
   instead. The Python layer has one `HandRetargeter` per
   `retargeter_type` (currently 3 — vector, curl-angle,
   gripper-distance), not one per hand model.

## Hand Type Spectrum and Retargeter Modes

Three retargeter modes cover every hand category in scope. The mode
is declared in the profile; the same input (Godot canonical finger
joints) flows into each.

### Mode A — `vector` (default for anthropomorphic hands)

`dex-retargeting`'s vector optimizer. Cost function:

```text
sum over (origin_i, task_i) pairs of:
    || scaling * (human[task_i] - human[origin_i])
       - fk_robot(task_link_i, origin_link_i, q) ||^2
```

Translation-invariant (cancels wrist motion noise), QP-solved
(~2–4 ms per side). Handles 22-DoF Sharpa, 16-DoF LEAP, 6-DoF
Inspire identically — only `target_joint_names` and link names
differ.

Variants reachable from the same profile field:

- `vector` — base mode.
- `vector_dexpilot` — adds inter-finger pairwise costs (DexPilot).
  Cost: ~+3 ms per side. Use when thumb-index precision matters
  (Sharpa with tactile feedback, fine manipulation tasks).
- `position` — direct fingertip-in-wrist-frame position match.
  Loses translation invariance; use only for offline dataset
  retargeting where wrist pose is already canonical.

### Mode B — `curl_angle` (low-DoF underactuated hands)

Direct per-finger angle copy with an averaged MCP+PIP+DIP →
single-DoF mapping. No QP. Computed in < 1 ms total.

```text
for each robot finger that has 1 DoF (curl):
    human_curl = mean(angle(MCP), angle(PIP), angle(DIP))
                 or weighted variant from the profile
    robot_q[finger] = clip(scale_curl * (human_curl - curl_offset),
                            q_min, q_max)
```

Use cases:

- 5-DoF anthropomorphic with 1 actuator per finger (Ability-Hand
  class).
- Cheap 5-servo prosthetics.
- "Curl-and-spread" hands (5 curl DoFs + 1 thumb yaw) — handled by
  treating thumb yaw as a sixth output with its own MANO-to-robot
  map.

When the human hand makes a fist, all five robot fingers close;
when the human spreads fingers, the robot does whatever its
mechanics allow (often nothing, since most underactuated hands lack
abduction). The profile documents this loss explicitly.

### Mode C — `gripper_distance` (parallel-jaw / 1-DoF)

Reduce the entire hand to a single "openness" axis derived from
thumb-tip / index-tip distance:

```text
d = || human[INDEX_TIP] - human[THUMB_TIP] ||
robot_q[0] = clip(scale * (d - d_closed) / (d_open - d_closed),
                   q_min, q_max)
```

`d_closed` and `d_open` are captured during T-pose / fist
calibration. Computed in < 0.1 ms.

Use cases:

- Robotiq 2F-85 / 2F-140.
- Franka Hand.
- Custom servo grippers (Operator already has the SO-101 in
  `examples/mujuco-arm-so101/` — the same gripper-distance code
  can drive it from OpenXR hand tracking).

For three-finger industrial grippers (Robotiq 3F, BarrettHand), use
`vector` mode with `target_task_link_names` containing only the
three active fingertip links.

### Mode selection rule of thumb

```text
n_independent_joints >= 4 per finger   →  vector
n_independent_joints in {1, 2} per finger →  curl_angle
n_independent_joints == 1 total          →  gripper_distance
```

The profile picks the mode explicitly; nothing auto-selects.

## Data Model Deltas

### Delta 1 — new `source` values for `RawVendorPose v1`

No schema change. Two new permitted `source` values:

```json
{
  "schema": "operator.raw_vendor_pose.v1",
  "source": "openxr_hand_tracking_left",
  "source_schema": "XR_EXT_hand_tracking",
  "space": "openxr_local_floor",
  "joints": [
    {
      "source_joint": "XR_HAND_JOINT_WRIST_EXT",
      "pose": { "p": [...], "q": [...] },
      "flags": 15,
      "confidence": 0.92,
      "extras": { "radius": 0.024, "index": 1 }
    },
    "..."
  ],
  "extras": {
    "hand_side": "left",
    "runtime": "quest_3_v75",
    "joint_set": "XR_HAND_JOINT_SET_DEFAULT_EXT"
  }
}
```

The `extras.runtime` is recorded so per-device tip-offset
calibration can be applied or repaired offline.

### Delta 2 — `godot_humanoid_joints v1` finger slots

No schema change. RFC-003 already states the map may be sparse.
Slots this RFC fills:

| Side | Slots filled (15 per hand) |
|---|---|
| left | `left_thumb_metacarpal`, `left_thumb_proximal`, `left_thumb_distal`, `left_index_proximal`, `left_index_intermediate`, `left_index_distal`, `left_middle_proximal`, `left_middle_intermediate`, `left_middle_distal`, `left_ring_proximal`, `left_ring_intermediate`, `left_ring_distal`, `left_little_proximal`, `left_little_intermediate`, `left_little_distal` |
| right | mirror of left |

The hand adapter also re-emits `{side}_wrist` (already populated by
the body adapter) with `source = "openxr_hand_tracking"`; the
resolver picks the higher-confidence one per RFC-003's wrist
priority list.

OpenXR fingertip joints (indices 5/10/15/20/25) and the four long
fingers' metacarpals (6/11/16/21) have no Godot Humanoid slot.
They are preserved in `RawVendorPose`. The retargeter reads them
from there for `vector` mode; alternatives are discussed in Open
Questions.

### Delta 3 — `RetargetTargets v1 → v2`

This is the only schema version bump in this RFC. v2 adds a
`hands` section beside `torso` and `arms`:

```json
{
  "schema": "operator.retarget_targets.v2",
  "timestamp_ns": 123456789,
  "root":   { "...": "unchanged" },
  "torso":  { "...": "unchanged" },
  "arms":   { "...": "unchanged" },
  "hands": {
    "left": {
      "anchor": { "joint": "left_wrist", "weight": 1.0 },
      "fingertips": [
        { "name": "thumb",  "joint": "left_thumb_distal",  "weight": 0.8 },
        { "name": "index",  "joint": "left_index_distal",  "weight": 1.0 },
        { "name": "middle", "joint": "left_middle_distal", "weight": 0.9 },
        { "name": "ring",   "joint": "left_ring_distal",   "weight": 0.7 },
        { "name": "pinky",  "joint": "left_little_distal", "weight": 0.6 }
      ]
    },
    "right": { "...": "mirror" }
  }
}
```

Rules:

- `anchor.joint` MUST equal the canonical joint the arm task layer
  uses as `arms.{left,right}.wrist_pose.joint`. This guarantees
  fingertip vectors are measured in the same frame the arm QP
  solved for.
- `fingertips[]` order follows anatomical order
  (thumb, index, middle, ring, pinky) for deterministic logging.
- **The array is sparse-tolerant.** For a 3-finger gripper, ship
  three entries with `name` ∈ {`thumb`, `index`, `middle`}. For a
  parallel gripper, ship two (`thumb` and `index`). Hand profiles
  using fewer fingers omit the unused entries; consumers MUST NOT
  assume length 5.
- `weight` defaults reflect grasp-task priority (index/middle
  highest, pinky lowest). The extractor multiplies these by Godot
  canonical joint quality.
- If `anchor.joint` is invalid or low-confidence, the entire
  `hands` section for that side is omitted; the consuming
  retargeter keeps the previous solution per the smoothness rule.

Consumers that only understand v1 SHOULD ignore the unknown
`hands` field, matching JSON forward-compatibility convention. The
version bump is for offline tooling and dataset readers.

### Delta 4 — `RobotSolution v1` joint name extension

No schema change. `joint_names` is an ordered array; the
framework appends N entries per hand, where N is profile-specific
(0 to ~24 per side). Consumers that index by name keep working.

```json
{
  "schema": "operator.robot_solution.v1",
  "robot": "unitree_h2_sharpa_upper_body",
  "solver": "pinocchio_pink_qp + dex_retargeting_vector",
  "joint_names": [
    "..unchanged 13 upper-body joints from RFC-003..",
    "left_sharpa_<j_0>",  "..", "left_sharpa_<j_N>",
    "right_sharpa_<j_0>", "..", "right_sharpa_<j_N>"
  ],
  "joint_q":  [".. 13 + 2N floats .."],
  "joint_dq": [".. 13 + 2N floats .."],
  "residuals": {
    ".. unchanged RFC-003 residuals ..",
    "left_fingertip_pos_m_max":  0.012,
    "left_fingertip_pos_m_mean": 0.006,
    "right_fingertip_pos_m_max": 0.011,
    "right_fingertip_pos_m_mean": 0.005
  },
  "limits": {
    ".. unchanged ..",
    "hand_joint_limit_saturation": []
  },
  "reach_ok": true,
  "solve_ok": true,
  "quality": "tracked"
}
```

The exact Sharpa joint names come from the URDF audit (M0). The
number of Sharpa joints in `joint_q` per hand may be smaller than
22 if the URDF declares `<mimic>` couplings; the mimic-driven
joints are reconstructed downstream from the independent ones.

The `robot` identifier convention is **one id per body + hand
combination**: e.g. `unitree_h2_sharpa_upper_body` (Sharpa on H2),
`unitree_h2_inspire_ftp_upper_body` (Inspire on H2),
`unitree_g1_dex3_upper_body` (Dex3 on G1). RFC-003 already chose
the Sharpa one; the framework respects this and exposes the active
hand profile id under `solver` (which already names the algorithm)
and under `RobotSolution.extras.hand_profile_id` (new, optional).

## OpenXRHandTrackingAdapter

Owns the OpenXR-hand-tracking-specific input conversion. Stateless
modulo a one-frame previous-pose cache for inference fallback.

### Inputs

For each hand:

```text
26 × { p, q, flags, confidence, radius }
hand_side: "left" | "right"
runtime_id: opaque string identifying the OpenXR runtime + version
```

### Mapping table — OpenXR (26) → Godot Humanoid finger slots (15)

| OpenXR idx | OpenXR name | Godot Humanoid slot |
|---|---|---|
| 1 | `WRIST` | `{side}_wrist` (re-emit with confidence) |
| 2 | `THUMB_METACARPAL` | `{side}_thumb_metacarpal` |
| 3 | `THUMB_PROXIMAL` | `{side}_thumb_proximal` |
| 4 | `THUMB_DISTAL` | `{side}_thumb_distal` |
| 5 | `THUMB_TIP` | (no Godot bone — raw only) |
| 6 | `INDEX_METACARPAL` | (no Godot bone — raw only) |
| 7 | `INDEX_PROXIMAL` | `{side}_index_proximal` |
| 8 | `INDEX_INTERMEDIATE` | `{side}_index_intermediate` |
| 9 | `INDEX_DISTAL` | `{side}_index_distal` |
| 10 | `INDEX_TIP` | (no Godot bone — raw only) |
| 11–15 | `MIDDLE_*` | analogous |
| 16–20 | `RING_*` | analogous |
| 21–25 | `LITTLE_*` | analogous |

Godot Humanoid thumb has 3 segments (`metacarpal/proximal/distal`);
OpenXR thumb has 3 phalange joints plus tip. Direct match — no
inferred joint needed.

### Confidence policy

```text
flags & XR_SPACE_LOCATION_POSITION_VALID_BIT  →  joint.valid
flags & XR_SPACE_LOCATION_ORIENTATION_VALID_BIT → joint.tracked
runtime confidence (vendor) → joint.confidence
inferred = false (this adapter does not infer)
source = "openxr_hand_tracking_<side>"
source_joint = <OpenXR enum name>
```

If `valid` is false, the joint is omitted from the canonical layer
(do not write `valid: false` zero-pose entries — they confuse
resolvers). The previous frame's value remains the latest canonical
record until refreshed.

### Wrist re-emission and resolver hint

Per RFC-003 §"Fusion and Quality", the resolver chooses among:

```text
external wrist tracker > openxr hand wrist > body wrist > controller wrist
```

The OpenXR-hand-tracking wrist beats the body-skeleton wrist when
both are present.

## HandRetargeter Framework

### Registry

A single `HandRetargeterRegistry` is instantiated per session. It
holds:

```text
{
  "robot_id"            → string (matches DeviceDescriptor)
  "left_profile_path"   → str (YAML on disk)
  "right_profile_path"  → str (YAML on disk)
  "active_left"         → HandRetargeter instance
  "active_right"        → HandRetargeter instance
}
```

Profile paths come from the same `DeviceDescriptor.control_schema`
the robot already publishes; the descriptor gains a small extension:

```json
"control_schema": {
  ".. existing ..",
  "hand_profile": {
    "left":  "configs/hand_profiles/sharpa_wave_left.yml",
    "right": "configs/hand_profiles/sharpa_wave_right.yml"
  }
}
```

When the descriptor changes (e.g. mid-development swap from Sharpa
to Inspire), the registry reloads. Per Non-Goals, mid-session
swapping is not supported; the registry re-initializes on
descriptor change at session start.

### HandRetargeter interface

Three concrete classes implement the same interface, one per
`retargeter_type`:

```text
class HandRetargeter:
    robot_id: str
    profile_id: str
    controlled_joint_names: list[str]
    home_q: np.ndarray            # shape (N_indep,)
    joint_limits: tuple[np.ndarray, np.ndarray]

    def retarget(
        self,
        canonical_fingers: dict[str, Pose],   # 15 Godot finger slots
        raw_fingertips:    dict[str, np.ndarray] | None,  # 5 OpenXR tip positions
        anchor_pose:       Pose,              # wrist in pelvis frame
        weights:           dict[str, float],  # per-finger weight from extractor
        prev_q:            np.ndarray | None,
    ) -> tuple[np.ndarray, RetargetDiagnostics]:
        """Returns (independent joint q, diagnostics)."""

    def expand_mimic(self, q_indep: np.ndarray) -> np.ndarray:
        """Maps independent → full URDF joint vector (for render)."""

    def to_sdk_order(self, q_indep: np.ndarray) -> np.ndarray:
        """Maps independent → robot SDK joint order (for control)."""
```

Implementations:

- `VectorHandRetargeter` — wraps `dex-retargeting`'s
  `SeqRetargeting(type=vector)`. Supports the `vector`,
  `vector_dexpilot`, and `position` modes via constructor flag.
- `CurlAngleHandRetargeter` — analytical per-finger angle map; no
  QP.
- `GripperDistanceHandRetargeter` — single thumb-index distance →
  one-DoF mapping; no QP.

Adding a new retargeter mode is a new concrete class. The
expectation is that the existing three cover all in-scope hands
above; a fourth is required only if a fundamentally new hand
mechanism appears (e.g. fluidic actuators with non-monotonic
joint→tendon maps).

### HandProfile YAML schema

One schema, hand-agnostic. Mode-specific fields are at the bottom.

```yaml
# robot/configs/hand_profiles/<hand_id>_<side>.yml
hand_profile:
  # Identity
  profile_id:      sharpa_wave_v1_right    # globally unique
  display_name:    "Sharpa Wave (right)"
  hand_side:       right                    # left | right
  hand_family:     sharpa_wave              # all sides of the same hand model share this
  hand_version:    "1.0"

  # Robot model
  urdf_path:       ${OPERATOR_ASSETS}/h2_with_sharpa_wave.urdf
  wrist_origin_link: right_hand_wrist
  fingertip_target_links:
    thumb:  right_thumb_fingertip
    index:  right_index_fingertip
    middle: right_middle_fingertip
    ring:   right_ring_fingertip           # null if hand has no ring finger
    pinky:  right_pinky_fingertip          # null if hand has no pinky

  # Controlled joints (the "independent" set the algorithm solves for)
  controlled_joint_names: []                # filled by URDF audit
  home_q: []                                # length = len(controlled_joint_names)
  # joint limits are read from the URDF; no need to duplicate.

  # Mimic expansion (post-solve; for render and SDK output)
  mimic_map:
    # example: right_index_DIP_joint follows right_index_PIP_joint at 0.6:1
    # right_index_DIP_joint:
    #   source: right_index_PIP_joint
    #   multiplier: 0.6
    #   offset:     0.0

  # SDK output mapping. Maps each controlled_joint_name index → SDK channel.
  # Length = len(controlled_joint_names). Filled per-hand from SDK docs.
  # Render-only profiles may leave this empty.
  urdf_to_sdk_joint_order: []

  # Per-task weights, multiplied by RetargetTargets per-fingertip weight.
  # Keys match the fingertip names; missing finger → weight 0.
  task_weights:
    thumb:  0.8
    index:  1.0
    middle: 0.9
    ring:   0.7
    pinky:  0.6

  # Scaling and smoothness
  scaling_factor:     1.0
  smoothness_weight:  1e-3
  low_pass_alpha:     0.0      # 0.0 = off; use only as fallback when
                                # outer QP can't absorb smoothness term

  # Algorithm selection
  retargeter_type:    vector   # vector | vector_dexpilot | position
                                # | curl_angle | gripper_distance

  # --- Mode-specific fields ---------------------------------------

  # `vector` / `vector_dexpilot` / `position` (uses dex-retargeting):
  vector:
    target_link_human_indices_origin: [1, 1, 1, 1, 1]
    target_link_human_indices_task:   [5, 10, 15, 20, 25]
    # Optional: per-pair extra weight overrides task_weights.
    # Optional: dexpilot-specific finger pair constants.

  # `curl_angle`:
  # curl_angle:
  #   per_finger_curl_axis_in_urdf:
  #     thumb:  right_thumb_curl_joint
  #     index:  right_index_curl_joint
  #     middle: right_middle_curl_joint
  #     ring:   right_ring_curl_joint
  #     pinky:  right_pinky_curl_joint
  #   human_angle_aggregation: mean_mcp_pip_dip
  #   per_finger_scale: [1.0, 1.0, 1.0, 1.0, 1.0]
  #   per_finger_offset: [0.0, 0.0, 0.0, 0.0, 0.0]

  # `gripper_distance`:
  # gripper_distance:
  #   d_closed_m: 0.005        # from calibration / hardware datasheet
  #   d_open_m:   0.085
  #   output_joint: gripper_joint
  #   invert: false
```

The YAML is **declarative and validated by schema**
(`operator.hand_profile.v1`). Adding a hand is:

1. Drop the URDF (or extend the merged URDF) into the assets dir.
2. Author one YAML per side.
3. Register the profile id in the robot's `DeviceDescriptor`.

No Python edits required for hands that fit one of the three
existing retargeter types.

### Render vs. control paths

- For **render** (the ego overlay scene in `xr/`), Godot's
  Skeleton3D mimic-expands using `mimic_map`. The bone update reads
  the expanded vector (length = total URDF joints), not the
  independent vector.
- For **control** (future, when real SDK is wired), the SDK
  consumes `urdf_to_sdk_joint_order`-permuted independent
  positions. Mimic joints are not sent; the hand's mechanical
  coupling realizes them.

Both paths emit the same `RobotSolution.joint_q` (independent
vector); the consumer chooses how to interpret it.

## First Profile — Sharpa Wave (22-DoF anthropomorphic)

The canonical first instantiation. All design decisions in this
RFC must be validated against this profile.

### Status of URDF assets

`examples/unitree-g1-sharpa/merged/h2_with_sharpa_wave.urdf` is
ready (75 DoF total: H2 31 + Sharpa 22 × 2). Sharpa hand sub-trees
mount at `{left,right}_hand_flange` with `Ry(+π/2)` so palms face
down at the body's zero pose. Five fingertip links named
`{side}_{thumb,index,middle,ring,pinky}_fingertip`.

### Status of joint inventory

Unknown until M0 runs. The Sharpa Wave product page advertises
"22 DoF per hand" but industry convention usually counts mechanical
joints, not actuators. The M0 deliverable
(`inspect_sharpa_joints.py`) determines:

- Outcome A: all 22 are independent → `controlled_joint_names`
  has 22 entries, `mimic_map` is empty.
- Outcome B: a subset is mimicked → `controlled_joint_names` is
  shorter, `mimic_map` documents the coupling, `merge_g1_sharpa.py`
  is patched to emit `<mimic>` tags into the URDF.

Both outcomes are supported by the framework; the deliverables
differ only in YAML content.

### Profile sketch

```yaml
hand_profile:
  profile_id:    sharpa_wave_v1_right
  display_name:  "Sharpa Wave (right)"
  hand_family:   sharpa_wave
  retargeter_type: vector
  urdf_path:     ${OPERATOR_ASSETS}/h2_with_sharpa_wave.urdf
  wrist_origin_link: right_hand_wrist
  fingertip_target_links:
    thumb:  right_thumb_fingertip
    index:  right_index_fingertip
    middle: right_middle_fingertip
    ring:   right_ring_fingertip
    pinky:  right_pinky_fingertip
  task_weights: { thumb: 0.8, index: 1.0, middle: 0.9, ring: 0.7, pinky: 0.6 }
  scaling_factor: 1.0
  smoothness_weight: 1e-3
  low_pass_alpha: 0.0
  vector:
    target_link_human_indices_origin: [1, 1, 1, 1, 1]
    target_link_human_indices_task:   [5, 10, 15, 20, 25]

  # Filled by M0 (URDF audit):
  controlled_joint_names: []
  home_q: []
  mimic_map: {}
  urdf_to_sdk_joint_order: []
```

## Second Profile — Generic 5-DoF Underactuated 5-Finger (illustration)

Pedagogical and validation profile. Represents the class of
"cheap prosthetic" hands where each finger has a single curl axis,
no abduction, and the thumb may or may not have a separate yaw
DoF. Concrete examples that fit: Ability Hand (6 DoF), Inspire FTP
when configured in 5-DoF mode, low-cost 5-servo prosthetics.

```yaml
hand_profile:
  profile_id:    generic_5dof_underactuated_right
  display_name:  "Generic 5-DoF underactuated (right)"
  hand_family:   generic_5dof
  hand_version:  "ref-design-0"
  retargeter_type: curl_angle
  urdf_path:     ${OPERATOR_ASSETS}/generic_5dof_right.urdf   # to be authored
  wrist_origin_link: right_hand_root
  fingertip_target_links:
    thumb:  right_thumb_tip
    index:  right_index_tip
    middle: right_middle_tip
    ring:   right_ring_tip
    pinky:  right_pinky_tip
  task_weights: { thumb: 1.0, index: 1.0, middle: 1.0, ring: 1.0, pinky: 1.0 }
  scaling_factor: 1.0
  smoothness_weight: 1e-3
  low_pass_alpha: 0.2          # curl_angle has no QP smoothness
  curl_angle:
    per_finger_curl_axis_in_urdf:
      thumb:  right_thumb_curl
      index:  right_index_curl
      middle: right_middle_curl
      ring:   right_ring_curl
      pinky:  right_pinky_curl
    human_angle_aggregation: mean_mcp_pip_dip
    per_finger_scale:  [1.0, 1.0, 1.0, 1.0, 1.0]
    per_finger_offset: [0.0, 0.0, 0.0, 0.0, 0.0]
  controlled_joint_names:
    - right_thumb_curl
    - right_index_curl
    - right_middle_curl
    - right_ring_curl
    - right_pinky_curl
  home_q: [0.0, 0.0, 0.0, 0.0, 0.0]
  mimic_map: {}
  urdf_to_sdk_joint_order: [0, 1, 2, 3, 4]
```

The URDF for this profile is a placeholder; no hardware target. The
profile is shipped only to **prove framework generality** — the
identical adapter, identical canonical layer, identical
`RetargetTargets v2`, identical RobotSolution-emission path all
work with `retargeter_type = curl_angle`. Integration test in M6
exercises this profile end-to-end on a recorded OpenXR session.

## Third Profile — 1-DoF Parallel Gripper (illustration)

The degenerate case. Drives a one-DoF gripper from the operator's
thumb-index distance. Concrete fit: SO-101 gripper (already in
`examples/mujuco-arm-so101/`), Robotiq 2F-85, Franka Hand.

```yaml
hand_profile:
  profile_id:    so101_gripper_right
  display_name:  "SO-101 gripper (right)"
  hand_family:   so101
  retargeter_type: gripper_distance
  urdf_path:     ${OPERATOR_ASSETS}/so101_with_gripper.urdf
  wrist_origin_link: gripper_base
  fingertip_target_links:
    thumb: null           # gripper has no anatomical fingers,
    index: null           # only the OpenXR thumb-index distance
                          # is consumed by gripper_distance mode.
  task_weights: { thumb: 1.0, index: 1.0 }
  scaling_factor: 1.0
  smoothness_weight: 1e-3
  low_pass_alpha: 0.2
  gripper_distance:
    d_closed_m: 0.005
    d_open_m:   0.085
    output_joint: gripper_jaw_joint
    invert: false
  controlled_joint_names: [ gripper_jaw_joint ]
  home_q: [ 0.0 ]
```

Notable: `fingertip_target_links.{thumb,index}` are `null` —
gripper-distance mode ignores robot fingertip links because there
are none in the anatomical sense. The mode reads only the OpenXR
human thumb (5) and index (10) tip positions from `RawVendorPose`.

This profile is **not pedagogical only** — it is the lowest-effort
path to ship VR teleop for any existing one-DoF gripper Operator
already supports, which is a real near-term product surface.

## Calibration

Two one-shot samples, both during the existing RFC-003 T-pose
calibration step (no new UX surface).

### 1. Per-device tip offset

Record the OK-gesture frame (operator briefly touches thumb tip to
index tip) during T-pose. Stored as
`tip_offset_m = || thumb_tip - index_tip ||_T_pose`. At runtime,
each fingertip position is shrunk along the (tip − distal)
direction by this offset before retargeting. Stored under
`extras.tip_offset` in `RawVendorPose` so offline replay can
re-apply or recalibrate.

### 2. Optional per-user hand scale

Measured from T-pose as
`(middle_tip - wrist) / sharpa_middle_tip_in_neutral`. Updates the
profile's `scaling_factor` if the user opts in. Default off (factor
1.0).

### 3. Mode-specific calibration extras

- `curl_angle`: capture closed-fist and open-hand frames to derive
  `per_finger_offset` (so resting-hand curl is the URDF zero).
- `gripper_distance`: capture closed-fist and open-hand to derive
  `d_closed_m` and `d_open_m` (overriding the YAML defaults).

These extras are stored under
`extras.calibration.<profile_id>` in `RawVendorPose`, separated
per-profile so the same recording can be retargeted against
multiple profiles offline.

## Implementation Phases

Subordinate to RFC-003. M-numbers align with RFC-003's Phase 3
(H2 upper-body retargeter) completion as the gating dependency for
M4 only; everything else can run in parallel.

```
M0   0.5 d   inspect_sharpa_joints.py
              → Sharpa active-joint table (Outcome A or B)
              → patch to merge_g1_sharpa.py if Outcome B (<mimic>)
              → urdf_to_sdk_joint_order map (URDF side)
              → controlled_joint_names + home_q for Sharpa profile

M1   1.0 d   OpenXRHandTrackingAdapter
              → unit test: 100-frame OpenXR JSON in, 15 left + 15 right
                Godot Humanoid slots filled, raw stream byte-stable.

M2   1.0 d   RetargetTargets v2 schema bump + extractor
              → unit test: schema validation; v1 consumers ignore
                hands field; backward-compat smoke test.

M3   2.0 d   HandRetargeter framework + VectorHandRetargeter +
              CurlAngleHandRetargeter + GripperDistanceHandRetargeter
              → unit tests per mode against synthetic inputs
              → Sharpa Wave profile drops in, gets <8 mm fingertip
                RMS on golden grasp dataset.

M4   1.0 d   RobotSolution joint extension + Sharpa render path
              → end-to-end: mock OpenXR JSON → adapter → extractor
                → registry → Sharpa retargeter → Godot Skeleton3D.
              → visual check: OK / fist / point / thumbs-up gestures.

M5   1.0 d   Calibration: tip-offset, optional scale, mode-specific.

M6   1.0 d   Second + third profile validation
              → ship generic_5dof_right.yml and so101_gripper_right.yml
              → integration test: same recorded session retargeted to
                all three profiles; no framework code differs.
              → metric: "lines of Python required to add the
                generic_5dof profile" = 0.
```

M0–M2 are independent of any other RFC. M3 requires M0 for the
Sharpa profile content but the framework code can land first. M4
requires either RFC-003 Phase 3 complete or a stub RobotSolution
emitter. M6 is the "framework actually generalizes" gate.

## Validation

### Per-phase unit tests

Each phase ships its own pytest module.

### Sharpa golden grasp dataset

Record a 30-second OpenXR session containing:

- 5-finger flexion sequence (each finger curls in turn)
- OK gesture (thumb + index pinch)
- Fist clench / release
- Pinky-only extension
- Thumb opposition sweep (touch each fingertip with thumb in turn)

Stored as `RawVendorPose` JSONL. Targets for M3 sign-off:

| Metric | Target |
|---|---|
| Fingertip position RMS (per side) | < 8 mm |
| Fingertip position p99 (per side) | < 15 mm |
| Solver fail rate | < 0.1% of frames |
| Per-side solve latency p99 | < 8 ms (i5 desktop) |
| Joint limit saturation frames | < 5% |

### Framework generality test (M6 sign-off)

Replay the same Sharpa golden dataset against the
`generic_5dof_underactuated_right` and `so101_gripper_right`
profiles. Pass criteria:

- Zero framework code touched between profiles.
- Per-profile retarget outputs are stable across runs (deterministic).
- Each profile produces a valid `RobotSolution.joint_q` of its
  declared length.
- The `curl_angle` profile's output correlates ≥ 0.9 with the
  five-finger curl trajectories computed from the Sharpa profile's
  PIP joints (sanity check: both should "see the same fist").
- The `gripper_distance` profile's output correlates ≥ 0.95 with
  the OpenXR thumb-index distance (it should — but the test
  catches sign errors and dead-zone bugs).

### Comparison to upstream

For sanity, run the golden dataset through dex-retargeting's
shipped Inspire FTP and LEAP configs (also vector mode). Sharpa's
residual curve should be in the same range; large deltas imply
config bugs.

### Inline visual verification

Required for M4 sign-off. A human reviewer confirms qualitative
fidelity on each profile's render. Catches e.g. swapped thumb
axis that still optimizes well.

## Open Questions

1. **Mimic-vs-active split** is unknown until M0 runs. Both outcomes
   are supported; the deliverable is YAML content.

2. **Hand-profile registry location.** Proposed:
   `robot/configs/hand_profiles/<profile_id>.yml`. Alternative:
   beside the URDFs under `examples/<robot>/hand_profiles/`. Decide
   at M3 based on how the descriptor publishes profile paths.

3. **Resolver ownership for finger joints.** RFC-003's resolver
   knows wrist priority. Finger priority list (OpenXR hand vs
   vendor body fingers vs glove) belongs in RFC-003's resolver or
   a hand-specific resolver in this RFC. Vote at M3.

4. **Raw fingertip access** for `vector` mode. Two options:
   - Route fingertip positions through canonical layer's `extras`
     dict (clean, but extra hop).
   - Allow retargeter to peek at `RawVendorPose` directly when both
     are in-process (faster, breaks layering).
   Defer to M4; choose based on whether canonical-layer FK can
   reach the fingertip from `*_distal` plus joint radii.

5. **Auto-loading profiles from `DeviceDescriptor`.** The descriptor
   needs to gain a `hand_profile.{left,right}` field. Should this
   be the YAML path (filesystem) or an inline blob (wire)? Path is
   simpler; inline is more self-describing for dataset replay.
   Vote at M2 alongside the v2 schema bump.

6. **Mixed-hand bimanual.** Can the registry hold two different
   `hand_family` values, e.g. Sharpa left + Robotiq right? The
   framework permits it (per-side profiles), but no hardware
   exists. Document as supported-in-principle; do not validate.

7. **Per-user `scaling_factor` default.** Off vs prompted at first
   session. Defer to UX review.

8. **SDK joint order maps** for hands beyond Sharpa. Each hand
   ships its own SDK with its own joint order. Storing
   `urdf_to_sdk_joint_order` in the profile YAML is canonical;
   filling each requires SDK access. M0 covers Sharpa URDF side;
   each new hand spawns a follow-up ticket against its vendor.

## References

- RFC-003 Upper-Body Human-to-Humanoid Retargeting —
  [`003-upper-body-human-to-humanoid-retargeting.md`](003-upper-body-human-to-humanoid-retargeting.md)
- Merged H2 + Sharpa URDF + mount convention —
  [`examples/unitree-g1-sharpa/README.md`](../../examples/unitree-g1-sharpa/README.md)
- dex-retargeting library (Apache 2.0; Pinocchio-backed) —
  <https://github.com/dexsuite/dex-retargeting>
- AnyTeleop (Qin et al., RSS 2023) — <https://arxiv.org/abs/2307.04577>
- DexPilot (Handa et al., 2020) — <https://arxiv.org/abs/1910.03135>
- Unitree xr_teleoperate (reference Sharpa-less pipeline) —
  <https://github.com/unitreerobotics/xr_teleoperate>
- Open-TeleVision (CoRL 2024) — <https://github.com/OpenTeleVision/TeleVision>
- OpenXR `XR_EXT_hand_tracking` spec —
  <https://registry.khronos.org/OpenXR/specs/1.0/man/html/XR_EXT_hand_tracking.html>
- OpenXR `XrHandJointEXT` enum —
  <https://registry.khronos.org/OpenXR/specs/1.0/man/html/XrHandJointEXT.html>
- Godot `XRBodyTracker` (hand bones in Humanoid skeleton) —
  <https://docs.godotengine.org/en/4.5/classes/class_xrbodytracker.html>
- Pinocchio (URDF FK/Jacobians) —
  <https://docs.ros.org/en/humble/p/pinocchio/doc/Overview.html>
- Sharpa Wave product page — <https://www.sharpa.com/pages/wave>
- Inspire FTP product page — <http://www.inspire-robots.com>
- LEAP Hand — <https://github.com/leap-hand/LEAP_Hand_API>
- Ability Hand — <https://www.psyonic.io/ability-hand>
- Robotiq 2F-85 — <https://robotiq.com/products/2f85-140-adaptive-robot-gripper>
