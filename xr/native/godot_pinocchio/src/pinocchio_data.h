// PinocchioData — algorithm surface bound to GDScript.
//
// Holds a Ref<PinocchioModel> plus its matching pinocchio::Data. All
// methods are pure functions of (model, q[, v, a, tau]) — Data is just
// the algorithm's scratch space. Algorithms are exposed as instance
// methods because:
//   * each call mutates the internal pinocchio::Data anyway
//   * the model reference is captured once, so call sites stay terse
//
// Contract:
//   * The Model passed to initialize() must NOT have new joints / frames
//     added after this point — Data sizes are baked in at construction.
//   * IK and the dynamics algorithms always re-run forward kinematics
//     under the hood, so q passed to e.g. compute_frame_jacobian also
//     primes the internal frame placements for a subsequent
//     get_frame_transform() call.

#pragma once

#include <memory>

#include <godot_cpp/classes/ref.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/transform3d.hpp>

#include <godot_cpp/core/binder_common.hpp>

#include "pinocchio_model.h"

namespace operator_xr {

class PinocchioData : public godot::RefCounted {
    GDCLASS(PinocchioData, godot::RefCounted)

public:
    // Reference-frame selector for compute_frame_jacobian. Mirrors
    // pinocchio::ReferenceFrame; LOCAL_WORLD_ALIGNED is the most common
    // pick for visualization / world-frame IK targets.
    enum ReferenceFrame {
        LOCAL = 0,
        WORLD = 1,
        LOCAL_WORLD_ALIGNED = 2,
    };

    PinocchioData();
    ~PinocchioData();

    // Bind to a model. Must be called once before any other method;
    // returns false if model is null or empty.
    bool initialize(const godot::Ref<PinocchioModel> &model);

    godot::Ref<PinocchioModel> get_model() const;

    // --- Kinematics --------------------------------------------------------

    // Forward kinematics + frame placement update in one shot. Mutates the
    // internal pinocchio::Data so subsequent get_frame_transform() returns
    // the freshly computed pose.
    void forward_kinematics(const godot::PackedFloat64Array &q);

    // Returns oMf — frame transform expressed in the world frame. Requires
    // forward_kinematics() (or any algorithm that also runs FK) to have run.
    godot::Transform3D get_frame_transform(int frame_id) const;
    godot::Transform3D get_joint_transform(int joint_id) const;

    // --- Jacobian ----------------------------------------------------------

    // 6 x nv frame Jacobian, flattened row-major into a PackedFloat64Array
    // of length 6*nv. `reference_frame` is one of `LOCAL`, `WORLD`,
    // `LOCAL_WORLD_ALIGNED` (the last is the most useful for IK + visual
    // debugging and is the binding default via DEFVAL).
    godot::PackedFloat64Array compute_frame_jacobian(
            const godot::PackedFloat64Array &q, int frame_id,
            ReferenceFrame reference_frame) const;

    // --- IK (damped least squares) -----------------------------------------

    // Iteratively drives the `frame_id` pose toward `target` starting from
    // `q0`. Returns a Dictionary with keys:
    //   "q"          : PackedFloat64Array (best q so far)
    //   "success"    : bool  (residual norm < eps)
    //   "iterations" : int
    //   "residual"   : float (final ||log6(oMf^-1 * target)||)
    godot::Dictionary solve_ik_dls(const godot::Transform3D &target,
                                   int frame_id,
                                   const godot::PackedFloat64Array &q0,
                                   int max_iters, double eps,
                                   double damping) const;

    // --- Dynamics ----------------------------------------------------------

    // Inverse dynamics: τ = M(q)·a + C(q,v)·v + g(q). Returns size-nv τ.
    godot::PackedFloat64Array rnea(const godot::PackedFloat64Array &q,
                                   const godot::PackedFloat64Array &v,
                                   const godot::PackedFloat64Array &a) const;

    // Just the gravity term g(q) — RNEA with v=0, a=0.
    godot::PackedFloat64Array compute_generalized_gravity(
            const godot::PackedFloat64Array &q) const;

    // Forward dynamics (articulated body algorithm): a = M(q)^-1 (τ - h(q,v)).
    godot::PackedFloat64Array aba(const godot::PackedFloat64Array &q,
                                  const godot::PackedFloat64Array &v,
                                  const godot::PackedFloat64Array &tau) const;

    // Joint-space mass matrix M(q), flattened row-major (nv * nv).
    godot::PackedFloat64Array crba(const godot::PackedFloat64Array &q) const;

    // --- Centroidal --------------------------------------------------------

    // Centroidal momentum h_G = (linear, angular) expressed at the center
    // of mass in the world frame. Returns Dictionary {"linear": Vector3,
    // "angular": Vector3, "com": Vector3} for the supplied (q, v).
    godot::Dictionary compute_centroidal_momentum(
            const godot::PackedFloat64Array &q,
            const godot::PackedFloat64Array &v) const;

protected:
    static void _bind_methods();

private:
    struct Impl;
    std::unique_ptr<Impl> impl;
    godot::Ref<PinocchioModel> model_ref;
};

} // namespace operator_xr

// Required so the enum can be marshalled as a Variant integer to GDScript.
VARIANT_ENUM_CAST(operator_xr::PinocchioData::ReferenceFrame)
