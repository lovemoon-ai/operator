// PinocchioMultiTaskSolver — V2 weighted-QP IK addition to the addon.
//
// Tracks issue claw/issues/012-pinocchio-addon-multi-task-qp.md.
//
// Where V1 (PinocchioData.solve_ik_dls) drives a single end-effector to a
// single SE(3) target and runs its own inner loop, this class assembles a
// multi-task weighted least-squares normal system in C++:
//
//     minimize over dq:
//         sum_i  w_i^2 || J_i(q) dq - e_i ||^2
//       + w_posture^2 || q + dq - q_home ||^2
//       + w_smooth ^2 || dq - dq_prev   ||^2
//     s.t. q_min <= q + dq <= q_max
//
// Tasks are registered once (by string key) and then activated per-frame via
// the `targets` Dictionary handed to solve(). A task whose key is absent
// from `targets` (or whose `weight` is 0) contributes zero rows that frame
// — this is how the caller degrades when a body-tracking source drops a
// joint without restructuring its registration.
//
// Contract:
//   * initialize(model, config) must be called once before any add_*_task /
//     set_posture / solve. After initialize() the model is frozen — adding
//     joints / frames to the same PinocchioModel after this point puts the
//     internal pinocchio::Data out of sync (same trap as PinocchioData).
//   * solve() is a pure function of (q0, targets, dq_prev). It returns a
//     fresh `q` and `dq = q - q0`; warm-start is the caller's job (they
//     thread `q0` and `dq_prev` from the previous call).
//   * Only 1-DOF scalar joints are supported (same V1 limit). A free-
//     floating root is rejected at add_*_task with a logcat warning.

#pragma once

#include <memory>

#include <godot_cpp/classes/ref.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/transform3d.hpp>

#include <godot_cpp/core/binder_common.hpp>

#include "pinocchio_model.h"

namespace operator_xr {

class PinocchioMultiTaskSolver : public godot::RefCounted {
    GDCLASS(PinocchioMultiTaskSolver, godot::RefCounted)

public:
    PinocchioMultiTaskSolver();
    ~PinocchioMultiTaskSolver();

    // Bind to a model and configure solver hyper-parameters. Recognised
    // config keys (all optional; defaults match RFC-003 §"Objective"):
    //   damping              double  (3e-3)   Levenberg-Marquardt λ
    //   max_iters            int     (12)     inner-loop cap
    //   step                 double  (0.6)    line-search α on dq
    //   convergence_tol_m    double  (1.5e-3) early-exit position residual
    //   convergence_tol_rad  double  (3e-2)   early-exit orientation residual
    //   posture_weight       double  (0.04)   w_posture
    //   smooth_weight        double  (0.08)   w_smooth
    //   clamp_to_joint_limits bool   (true)   element-wise clamp each iter
    //
    // Returns false on a null model, an empty model, or repeat initialize.
    bool initialize(const godot::Ref<PinocchioModel> &model,
                    const godot::Dictionary &config);

    // --- Task registration (one-time, addressed by `key` thereafter) --------
    // All four return false (and log) on bad frame_id / joint_index or if
    // initialize() hasn't run. Duplicate keys are also rejected.

    // 6-row SE(3) task. Per-frame target is a Transform3D; weights are
    // `weight_pos` (linear rows) and `weight_rot` (angular rows), each
    // defaulting to 1.0 if omitted.
    bool add_pose_task(const godot::String &key, int frame_id);

    // 3-row position-only task. Per-frame target is a Vector3; weight key
    // is `weight` (default 1.0).
    bool add_position_task(const godot::String &key, int frame_id);

    // 3-row orientation-only task. Per-frame target is a Transform3D
    // (basis read as rotation) or a Quaternion; weight key is `weight`.
    bool add_orientation_task(const godot::String &key, int frame_id);

    // 1-row scalar task on a single q index. Per-frame target is a float;
    // for revolute joints the error is wrapped to [-π, π].
    bool add_joint_scalar_task(const godot::String &key, int joint_index);

    // Posture regularization target. Empty array disables posture.
    bool set_posture(const godot::PackedFloat64Array &q_home);

    // --- Solve --------------------------------------------------------------
    // See class header for contract. `dq_prev` may be an empty array, which
    // disables the smoothness regularizer for this call.
    godot::Dictionary solve(const godot::PackedFloat64Array &q0,
                            const godot::Dictionary &targets,
                            const godot::PackedFloat64Array &dq_prev);

protected:
    static void _bind_methods();

private:
    struct Impl;
    std::unique_ptr<Impl> impl;
    godot::Ref<PinocchioModel> model_ref;
};

} // namespace operator_xr
