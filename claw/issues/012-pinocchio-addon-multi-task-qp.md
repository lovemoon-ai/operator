# Issue 012 — Pinocchio addon: multi-task QP solver (V2 API)

## Status

Proposed

## Owner

TBD

## Date

2026-06-07

## Summary

The Pinocchio GDExtension (`xr/addons/pinocchio`) currently exposes a
**single-end-effector** damped least-squares IK via
`PinocchioData.solve_ik_dls(target, frame_id, q0, ...)`. RFC-003 upper-body
retargeting (`xr/scripts/retargeting/h2_pinocchio_retargeter.gd`) needs a
**multi-task weighted QP** that simultaneously drives multiple
end-effectors, multiple residual kinds (position / orientation / scalar),
plus posture and smoothness regularization — all in one solve.

This issue requests a V2 addition to the addon. V1 stays untouched; V2 is
purely additive.

## Motivation

### What the H2 retargeter assembles, per inner iteration

| Task | Rows | Source |
|---|---|---|
| `left_wrist` SE(3) (position + orientation) | 6 | `compute_frame_jacobian(left_wrist_frame, LWA)` |
| `right_wrist` SE(3) | 6 | `compute_frame_jacobian(right_wrist_frame, LWA)` |
| `left_elbow` position only | 3 | rows 0..2 of `compute_frame_jacobian(left_elbow_frame, LWA)` |
| `right_elbow` position only | 3 | rows 0..2 of `compute_frame_jacobian(right_elbow_frame, LWA)` |
| `chest_yaw` scalar projection on `waist_yaw_joint` | 1 | identity row on a single joint index |
| posture regularization `q + dq → q_home` | 19 | identity diag, error = q_home - q |
| smoothness regularization `dq → dq_prev` | 19 | identity diag, error = dq_prev |

Total ~57 rows assembled into normal equations
`A = Σwᵢ²JᵢᵀJᵢ + λ²I`, `b = Σwᵢ²Jᵢᵀeᵢ`, solved with damped LDLT, then
`q ← clamp(q + step·dq)` over joint limits.

### Why V1 isn't enough

`solve_ik_dls` only takes a single `(target, frame_id)` and runs its own
inner loop. There is no way to:

- Combine left + right arm tasks into one solve (running them serially
  makes the second arm overwrite the first arm's torso joints).
- Express a scalar yaw task on a single joint.
- Apply posture / smoothness regularization with a configurable weight
  matrix.
- Mix position-only (elbow hints) with full SE(3) (wrists) in the same
  step.

So the H2 retargeter currently assembles the multi-task normal equations
**in GDScript** (`h2_pinocchio_retargeter.gd::_step`) using
`PinocchioData.compute_frame_jacobian` for the heavy lift. This works
(1.54 ms/solve, 7/7 + L7 smoke PASS at the algorithm layer) but:

- The GDScript double loop pays the script-bytecode-interpretation cost
  on every entry of the 19×19 `A` matrix. At ~1 ms per solve that's
  acceptable today; at higher rates (full-body Phase 2, multiple arms in
  one scene, dual-robot retargeting) it can become the dominant cost.
- The Gauss-elimination linear solver in GDScript
  (`_solve_linear`) is `O(n³)` with no pivoting strategy beyond partial
  pivot. Eigen's LDLT would be ~3-5× faster and numerically more stable.
- Future tasks (self-collision avoidance hint rows, manipulability
  weighting, limit-distance barriers) all add rows to the same A/b
  assembly; doing them in GDScript multiplies the script overhead.

## Proposed API surface

A new RefCounted class `PinocchioMultiTaskSolver`. Construction binds it
to a model; per-frame solves are stateful (warm-start friendly).

### Lifecycle

```gdscript
var solver := PinocchioMultiTaskSolver.new()
solver.initialize(model, {
    "damping": 3.0e-3,
    "max_iters": 12,
    "step": 0.6,
    "convergence_tol_m": 1.5e-3,
    "convergence_tol_rad": 3.0e-2,
    "posture_weight": 0.04,
    "smooth_weight": 0.08,
    "clamp_to_joint_limits": true,
})
```

### Task registration (one-time)

Tasks are registered once and addressed by string key thereafter. Each
task carries a stable Pinocchio frame or joint id; per-frame the caller
supplies the moving parts (target, weights).

```gdscript
solver.add_pose_task("left_wrist", left_wrist_frame_id)
solver.add_pose_task("right_wrist", right_wrist_frame_id)
solver.add_position_task("left_elbow", left_elbow_frame_id)
solver.add_position_task("right_elbow", right_elbow_frame_id)
solver.add_joint_scalar_task("chest_yaw", waist_yaw_joint_index)
solver.set_posture(q_home)    # PackedFloat64Array, size nq
```

Task kinds the V2 API must support:

| Constructor | Rows added per iter | Error vector form |
|---|---|---|
| `add_pose_task(key, frame_id)` | 6 | `[(p_target - p_current); log6(M_target * M_current⁻¹)]` |
| `add_position_task(key, frame_id)` | 3 | `p_target - p_current` |
| `add_orientation_task(key, frame_id)` | 3 | `log(R_target * R_current⁻¹)` |
| `add_joint_scalar_task(key, joint_index)` | 1 | `q_target - q[joint_index]`, wrapped to `[-π, π]` for revolute |

### Per-frame solve

```gdscript
var solution := solver.solve(q0, {
    "left_wrist": {
        "target": Transform3D,    # SE(3) target
        "weight_pos": 1.0,
        "weight_rot": 0.5,
    },
    "right_wrist": {
        "target": Transform3D,
        "weight_pos": 1.0,
        "weight_rot": 0.5,
    },
    "left_elbow": {
        "target": Vector3,
        "weight": 0.35,
    },
    "right_elbow": {
        "target": Vector3,
        "weight": 0.35,
    },
    "chest_yaw": {
        "target": 0.0,
        "weight": 0.4,
    },
}, dq_prev)    # PackedFloat64Array, size nv. Empty/null = zero smoothness term.
```

Returns:

```gdscript
{
    "q":                PackedFloat64Array,    # size nq, clamped to limits
    "dq":               PackedFloat64Array,    # size nv, q - q0
    "residuals": {
        "left_wrist_pos_m":  0.0023,
        "left_wrist_rot_rad": 0.011,
        "right_wrist_pos_m": 0.0021,
        "right_wrist_rot_rad": 0.012,
        "left_elbow_pos_m":  0.038,
        "right_elbow_pos_m": 0.041,
        "chest_yaw_rad":     0.005,
    },
    "iterations":       4,        # actual inner iters before early exit
    "converged":        true,     # all task residuals < tol
    "joint_limit_saturation": ["right_wrist_pitch_joint"],  # joints within tol of bound
    "solve_us":         1280,     # microseconds for this whole solve()
}
```

### Targets that drop out

If a task key from registration is **absent from the per-frame
targets dict**, that task contributes zero rows this iteration. This
lets the caller degrade gracefully when a body-tracking source loses a
joint (e.g. wrist tracked but elbow inferred → skip the elbow task that
frame).

### Weight = 0 special case

A weight of `0.0` is treated as "skip this task this frame" — useful for
quality-scaled weights without restructuring the dict each frame.

## Numerical requirements

These match what the H2 retargeter and smoke test L0–L7 already pass at
the GDScript-assembled level. The V2 solver MUST match these to within
tolerance:

| Test | Tolerance |
|---|---|
| FK matches Python reference at home posture | max position error < **5 mm** across the 8 named end-effectors of `claw/assets/robots/h2_with_sharpa/upper_body.json` |
| Jacobian column matches finite-difference probe | `‖J·δq - ΔFK‖ < 1e-5 m` for `δq = 1e-4` on `left_elbow_joint` from a non-singular `q` |
| IK convergence on a 5 cm wrist-pos offset | both wrist residuals < **5 mm** after 8 outer `solve()` calls (warm-started) |
| IK convergence on a 0.15 rad orientation offset (+ position-matched) | both wrist `pos_m` < **10 mm** AND `rot_rad` < **0.03 rad** after 10 solves |
| Joint limit projection | every component of returned `q` lies in `[joint_lower, joint_upper]` to floating-point precision |
| Performance | mean `solve_us` < **2000 μs** averaged over 60 warm-started solves of the L6 benchmark on Qualcomm Adreno 740 (Quest 3) |

## Acceptance criteria

1. `PinocchioMultiTaskSolver` class registered, callable from GDScript on
   Pico arm64-v8a and Quest arm64-v8a.
2. All V1 classes (`PinocchioRuntime`, `PinocchioModel`, `PinocchioData`)
   continue to work unchanged.
3. The H2 retargeter
   (`xr/scripts/retargeting/h2_pinocchio_retargeter.gd`) refactored to
   use `PinocchioMultiTaskSolver` instead of hand-rolled
   `_step` + `_solve_linear`. The GDScript file's line count drops by
   ~100 lines.
4. `pinocchio_smoke_test.gd` L5–L7 PASS unchanged (same tolerances), L6
   shows `solve_ms < 2.0 ms` (down from 1.54 ms — improvement, not
   regression).
5. New L8 layer added: regression check that `solve()` results match the
   GDScript-assembled implementation to within 1 mm position / 1 mrad
   orientation on a fixed seed.

## Test plan

Layers in the smoke test
(`xr/scripts/retargeting/tests/pinocchio_smoke_test.gd`) before the
refactor:

- L0 addon class registration
- L1 PinocchioRuntime probe
- L2 H2 model build
- L3 FK ground truth match
- L4 Jacobian linearisation
- L5 IK convergence (4 outer solves)
- L6 performance (60 solves bench)
- L7 SO(3) orientation convergence

After the V2 refactor, add:

- L8 V2 solver registration probe (`ClassDB.class_exists("PinocchioMultiTaskSolver")`)
- L9 V2 vs V1-assembled equivalence (`max residual diff < 1 mm / 1 mrad`
  on the L5 + L7 fixtures, run both backends in the same frame and diff)

CI: pytest in `tools/retargeting` continues to exercise the Python
reference path (no change to Python).

## Implementation notes (hints, not requirements)

This is what the C++ impl would probably look like. Owner of the addon
can ignore if a better path exists.

```cpp
namespace operator_xr {
class PinocchioMultiTaskSolver : public godot::RefCounted {
    GDCLASS(PinocchioMultiTaskSolver, godot::RefCounted)
public:
    bool initialize(const godot::Ref<PinocchioModel> &model,
                    const godot::Dictionary &config);
    void add_pose_task(const godot::String &key, int frame_id);
    void add_position_task(const godot::String &key, int frame_id);
    void add_orientation_task(const godot::String &key, int frame_id);
    void add_joint_scalar_task(const godot::String &key, int joint_index);
    void set_posture(const godot::PackedFloat64Array &q_home);
    godot::Dictionary solve(
        const godot::PackedFloat64Array &q0,
        const godot::Dictionary &targets,
        const godot::PackedFloat64Array &dq_prev);
private:
    struct Impl;
    std::unique_ptr<Impl> impl;
    godot::Ref<PinocchioModel> model_ref;
};
}
```

Inner loop sketch:

```cpp
// Per iteration:
pinocchio::forwardKinematics(model, data, q);
pinocchio::updateFramePlacements(model, data);

Eigen::MatrixXd A = lambda * lambda * Eigen::MatrixXd::Identity(nv, nv);
Eigen::VectorXd b = Eigen::VectorXd::Zero(nv);

for (auto &task : tasks) {
    if (!targets.has(task.key)) continue;
    auto &target = targets[task.key];
    double w = target.get("weight_pos", target.get("weight", 1.0));
    if (w <= 0.0) continue;

    Eigen::Matrix<double, 6, Eigen::Dynamic> J(6, nv);
    pinocchio::computeFrameJacobian(model, data, q, task.frame_id,
                                    pinocchio::LOCAL_WORLD_ALIGNED, J);
    Eigen::VectorXd e = task.error(data, target);    // 3 or 6 rows
    Eigen::MatrixXd Jrows = task.rows(J);            // 3 or 6 rows of J
    A.noalias() += w * w * (Jrows.transpose() * Jrows);
    b.noalias() += w * w * (Jrows.transpose() * e);
}

// Posture regularization
A.diagonal().array() += posture_w * posture_w;
b.noalias() += posture_w * posture_w * (q_home - q);

// Smoothness
if (!dq_prev.empty()) {
    A.diagonal().array() += smooth_w * smooth_w;
    b.noalias() += smooth_w * smooth_w * dq_prev_vec;
}

Eigen::VectorXd dq = A.ldlt().solve(b);
q = (q + step * dq).cwiseMax(q_lower).cwiseMin(q_upper);

// Check convergence, fill residuals, etc.
```

LDLT (Cholesky for indefinite-definite) is the right factorization since
`A` is positive-definite by construction (sum of `JᵀJ` plus damping `I`).
Eigen's `LDLT` is in-place, O(n³/3), and stable.

## Non-goals

- **Hierarchical QP** (priority levels, hard constraints). V2 is single
  level weighted. Hierarchical lift comes from giving safety constraints
  infinite weight (rejected for V2; if needed, add a `priority` field to
  `add_*_task` later).
- **Self-collision constraints**. Coal/FCL is off in upstream Pinocchio
  per `xr/addons/pinocchio/README.md §1`. Adding self-collision means
  either turning that back on (significant build work) or layering
  approximated capsule-pair checks above the solver.
- **Free-floating base**. V1 doesn't expose it either; H2 upper-body
  pins the pelvis.
- **Online task re-registration**. `add_*_task` is one-time at
  initialization. The dict-based targets give per-frame flexibility.

## Open questions

- **Quaternion target inside `Transform3D`** — Godot's Transform3D stores
  a Basis (3×3) not a Quaternion. The C++ binding reads the basis via
  `eigen_godot.h::to_pinocchio` and treats it as a rotation matrix; no
  extra Quaternion type plumbing needed.
- **What does "weight" mean numerically?** RFC-003 §"Objective" uses
  it as a least-squares coefficient. The current GDScript impl uses
  `w² JᵀJ` (i.e. weight applied to both sides). V2 should match. The
  caller is responsible for scaling (RFC §"Quality is first-class"
  — tracked vs inferred multiplies the nominal weight).
- **Step size adaptation**. V1's `solve_ik_dls` uses α=0.5 hard-coded;
  V2 takes `step` from config but does not auto-tune. If we want
  Levenberg-Marquardt adaptive damping later, add a follow-up.
- **Should `solve()` mutate internal state for warm-start?** The current
  GDScript impl mutates `_q` and `_dq_prev` so the next call warm-starts
  from there. The proposed V2 API instead requires the caller to thread
  `q0` and `dq_prev` explicitly — simpler contract, callers already do
  this. (Alternative: keep mutable internal state and add `reset()`. The
  pure-functional shape is preferred.)

## References

- Pinocchio addon V1: `xr/addons/pinocchio/README.md`
- Headers: `xr/native/pinocchio/src/pinocchio_model.h`, `pinocchio_data.h`
- Current consumer: `xr/scripts/retargeting/h2_pinocchio_retargeter.gd`
- Smoke test that the V2 must keep passing:
  `xr/scripts/retargeting/tests/pinocchio_smoke_test.gd`
- RFC: `claw/rfcs/003-upper-body-human-to-humanoid-retargeting.md`
  §"Retargeting Formulation" and §"Objective"
- Pinocchio `computeFrameJacobian`:
  <https://stack-of-tasks.github.io/pinocchio/master/group__joint__pinocchio.html>
- Eigen LDLT:
  <https://eigen.tuxfamily.org/dox/group__LDLT.html>
