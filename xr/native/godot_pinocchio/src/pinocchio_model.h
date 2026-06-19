// PinocchioModel — Godot-bound rigid-body Model builder.
//
// V1 supports manual construction only (no URDF — upstream is built with
// BUILD_WITH_URDF_SUPPORT=OFF). Workflow from GDScript:
//
//     var m := PinocchioModel.new()
//     var j0 := m.add_revolute_joint(0, "shoulder", Vector3.FORWARD,
//                                     Transform3D(), -PI, PI)
//     m.append_body_to_joint(j0, 1.0, Vector3(0.5, 0, 0), Vector3.ONE)
//     var f_ee := m.add_frame(j0, "ee", Transform3D(Basis(), Vector3(1,0,0)))
//     m.set_gravity(Vector3(0, -9.81, 0))
//
// pImpl: we forward-declare pinocchio::Model in the header so the huge
// Pinocchio template machinery only leaks into pinocchio_model.cpp.

#pragma once

#include <memory>

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <godot_cpp/variant/vector3.hpp>

// `pinocchio::Model` is `typedef ModelTpl<context::Scalar, context::Options> Model`,
// not a class — so we can't forward-declare it. Including the real header
// loses some of the pImpl compile-time win, but it's still useful for the
// big Data side of things and the algorithm headers are kept out of .h.
#include <pinocchio/multibody/fwd.hpp>

namespace operator_xr {

class PinocchioData;                // friend access to native_model()
class PinocchioMultiTaskSolver;     // ditto — V2 multi-task QP solver

class PinocchioModel : public godot::RefCounted {
    GDCLASS(PinocchioModel, godot::RefCounted)

public:
    PinocchioModel();
    ~PinocchioModel();

    // --- Construction ------------------------------------------------------

    // Add a revolute joint that rotates around `axis` (expressed in the
    // parent joint's frame) and is placed at `placement` relative to the
    // parent. Returns the new joint id (1-based; joint 0 is the universe).
    // `lower_q` / `upper_q` define the position limits used by IK + the
    // project_to_joint_limits() helper.
    int add_revolute_joint(int parent_id, const godot::String &name,
                           const godot::Vector3 &axis,
                           const godot::Transform3D &placement,
                           double lower_q, double upper_q);

    // Same shape as add_revolute_joint but the joint translates along `axis`.
    int add_prismatic_joint(int parent_id, const godot::String &name,
                            const godot::Vector3 &axis,
                            const godot::Transform3D &placement,
                            double lower_q, double upper_q);

    // Attach an "operation frame" (typically the end-effector or tool point)
    // to a joint at `placement` relative to that joint. Returns the frame id.
    int add_frame(int parent_joint_id, const godot::String &name,
                  const godot::Transform3D &placement);

    // Attach inertia to a joint. `inertia_diag` is the diagonal of the
    // 3x3 inertia tensor expressed at `com` in the joint frame.
    void append_body_to_joint(int joint_id, double mass,
                              const godot::Vector3 &com,
                              const godot::Vector3 &inertia_diag);

    // Set the linear gravity vector (default is (0, 0, -9.81)).
    void set_gravity(const godot::Vector3 &g);

    // --- Queries -----------------------------------------------------------

    int get_nq() const;
    int get_nv() const;
    int get_njoints() const;
    int get_nframes() const;
    int get_frame_id(const godot::String &name) const;
    int get_joint_id(const godot::String &name) const;

    // The `previousFrame` field on the underlying pinocchio::Frame. Useful
    // mostly as a regression guard: add_frame() looks up the parent joint's
    // implicit JOINT_FRAME id and stores it here, so a future refactor that
    // breaks the lookup will surface immediately in the demo's T2.
    int get_frame_previous_frame(int frame_id) const;

    // Neutral configuration: zeros for scalar joints, identity quat for
    // free-floating ones. Always size nq.
    godot::PackedFloat64Array get_neutral_q() const;

    godot::PackedFloat64Array get_joint_lower_limits() const;
    godot::PackedFloat64Array get_joint_upper_limits() const;

    // Element-wise clamp of q to [lower, upper] joint limits. For joints
    // without bounded scalar params (none in V1) this is a no-op on those
    // indices. Out-of-spec q sizes return q unchanged.
    godot::PackedFloat64Array project_to_joint_limits(
            const godot::PackedFloat64Array &q) const;

protected:
    static void _bind_methods();

private:
    // --- Internal (friend access only) -------------------------------------
    // PinocchioData reaches in to pass the underlying model to algorithms.
    // Keeping these private + friend prevents callers from mutating the
    // model after a PinocchioData has been bound to it (which would
    // invalidate the Data's pre-allocated nq/nv-sized buffers).
    friend class PinocchioData;
    friend class PinocchioMultiTaskSolver;
    pinocchio::Model &native_model();
    const pinocchio::Model &native_model() const;

    struct Impl;
    std::unique_ptr<Impl> impl;
};

} // namespace operator_xr
