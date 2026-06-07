#include "pinocchio_data.h"

#include "eigen_godot.h"

#define PINOCCHIO_WITH_HPP_FCL 0
#define PINOCCHIO_WITH_URDFDOM 0

#include <pinocchio/multibody/model.hpp>
#include <pinocchio/multibody/data.hpp>
#include <pinocchio/algorithm/kinematics.hpp>
#include <pinocchio/algorithm/frames.hpp>
#include <pinocchio/algorithm/jacobian.hpp>
#include <pinocchio/algorithm/rnea.hpp>
#include <pinocchio/algorithm/aba.hpp>
#include <pinocchio/algorithm/crba.hpp>
#include <pinocchio/algorithm/centroidal.hpp>
#include <pinocchio/algorithm/center-of-mass.hpp>
// joint-configuration.hpp is intentionally NOT included — see the matching
// note in pinocchio_model.cpp. For 1-DOF scalar joints, integrate(q, v) is
// just element-wise q + v.
#include <pinocchio/spatial/explog.hpp>

#include <godot_cpp/core/class_db.hpp>

#include <android/log.h>

namespace operator_xr {

// Renamed from the generic `LOG_TAG` (which is what NDK samples + several
// third-party headers `#define`) so a future #include can't quietly
// override our tag. Same literal as pinocchio_model.cpp's PINO_LOG_TAG.
#define PINO_LOG_TAG "PinocchioGD"
#define LOGW(fmt, ...) \
    __android_log_print(ANDROID_LOG_WARN, PINO_LOG_TAG, fmt, ##__VA_ARGS__)

struct PinocchioData::Impl {
    // Lives in a unique_ptr because Data is heavy and has no default ctor
    // matching our "construct lazily after a model is bound" flow.
    std::unique_ptr<pinocchio::Data> data;
};

PinocchioData::PinocchioData() : impl(std::make_unique<Impl>()) {}
PinocchioData::~PinocchioData() = default;

bool PinocchioData::initialize(const godot::Ref<PinocchioModel> &model) {
    if (model.is_null()) {
        LOGW("PinocchioData.initialize: null model");
        return false;
    }
    if (model->get_njoints() <= 0) {
        LOGW("PinocchioData.initialize: model has no joints");
        return false;
    }
    model_ref = model;
    impl->data = std::make_unique<pinocchio::Data>(model->native_model());
    return true;
}

godot::Ref<PinocchioModel> PinocchioData::get_model() const { return model_ref; }

// Guard macros: return from the surrounding method if initialize() hasn't
// been called yet. Inlined here so we don't have to expose
// PinocchioData::Impl publicly just for a static helper to peek inside.
// Two flavors so we never rely on the GCC/Clang empty-macro-arg extension
// (which is non-standard pre-C++20 and emits -Wgnu-zero-variadic-macro).
#define ENSURE_READY_VOID(fn)                                          \
    do {                                                               \
        if (model_ref.is_null() || !impl->data) {                      \
            LOGW("%s called before initialize()", fn);                 \
            return;                                                    \
        }                                                              \
    } while (0)

#define ENSURE_READY(fn, ret)                                          \
    do {                                                               \
        if (model_ref.is_null() || !impl->data) {                      \
            LOGW("%s called before initialize()", fn);                 \
            return ret;                                                \
        }                                                              \
    } while (0)

// Size check for input vectors. Returns true if size matches, otherwise
// logs and returns false (caller decides how to bail).
static inline bool size_ok(int got, int want, const char *fn,
                           const char *what) {
    if (got == want) {
        return true;
    }
    LOGW("%s: %s size %d != %d", fn, what, got, want);
    return false;
}

void PinocchioData::forward_kinematics(const godot::PackedFloat64Array &q) {
    ENSURE_READY_VOID("forward_kinematics");
    const pinocchio::Model &model = model_ref->native_model();
    if (!size_ok(q.size(), model.nq, "forward_kinematics", "q")) {
        return;
    }
    pinocchio::framesForwardKinematics(model, *impl->data, to_eigen(q));
}

godot::Transform3D PinocchioData::get_frame_transform(int frame_id) const {
    ENSURE_READY("get_frame_transform", godot::Transform3D());
    const pinocchio::Model &model = model_ref->native_model();
    if (frame_id < 0 || frame_id >= static_cast<int>(model.nframes)) {
        LOGW("get_frame_transform: frame_id %d out of range", frame_id);
        return godot::Transform3D();
    }
    return to_godot(impl->data->oMf[frame_id]);
}

godot::Transform3D PinocchioData::get_joint_transform(int joint_id) const {
    ENSURE_READY("get_joint_transform", godot::Transform3D());
    const pinocchio::Model &model = model_ref->native_model();
    if (joint_id < 0 || joint_id >= model.njoints) {
        LOGW("get_joint_transform: joint_id %d out of range", joint_id);
        return godot::Transform3D();
    }
    return to_godot(impl->data->oMi[joint_id]);
}

godot::PackedFloat64Array PinocchioData::compute_frame_jacobian(
        const godot::PackedFloat64Array &q, int frame_id,
        ReferenceFrame reference_frame) const {
    ENSURE_READY("compute_frame_jacobian", {});
    const pinocchio::Model &model = model_ref->native_model();
    if (!size_ok(q.size(), model.nq, "compute_frame_jacobian", "q")) {
        return {};
    }
    // computeFrameJacobian needs joint Jacobians + frame placements
    // populated. The all-in-one variant handles both internally.
    pinocchio::ReferenceFrame rf = pinocchio::LOCAL_WORLD_ALIGNED;
    if (reference_frame == LOCAL) {
        rf = pinocchio::LOCAL;
    } else if (reference_frame == WORLD) {
        rf = pinocchio::WORLD;
    }
    Eigen::Matrix<double, 6, Eigen::Dynamic> J(6, model.nv);
    J.setZero();
    pinocchio::computeFrameJacobian(model, *impl->data, to_eigen(q),
                                    static_cast<pinocchio::FrameIndex>(frame_id),
                                    rf, J);
    return to_godot_rowmajor(J);
}

godot::Dictionary PinocchioData::solve_ik_dls(
        const godot::Transform3D &target, int frame_id,
        const godot::PackedFloat64Array &q0, int max_iters, double eps,
        double damping) const {
    godot::Dictionary result;
    result["success"] = false;
    result["q"] = godot::PackedFloat64Array();
    result["iterations"] = 0;
    result["residual"] = 0.0;
    ENSURE_READY("solve_ik_dls", result);
    const pinocchio::Model &model = model_ref->native_model();
    if (!size_ok(q0.size(), model.nq, "solve_ik_dls", "q0")) {
        // Echoing a malformed q0 back would tempt callers into using a
        // wrong-sized vector downstream; return an empty PackedFloat64Array
        // and a clearly false `success`, leaving callers to short-circuit.
        return result;
    }
    pinocchio::Data &data = *impl->data;
    Eigen::VectorXd q = to_eigen(q0);
    const pinocchio::SE3 oMf_target = to_pinocchio(target);
    const pinocchio::FrameIndex fi = static_cast<pinocchio::FrameIndex>(frame_id);

    // Damped least squares: q_{k+1} = integrate(q_k, -J^T (JJ^T + λ²I)^-1 e)
    // where e = log6(oMf^-1 · oMf_target) in the LOCAL frame.
    const double damping_sq = damping * damping;
    Eigen::Matrix<double, 6, Eigen::Dynamic> J(6, model.nv);
    Eigen::Matrix<double, 6, 6> JJt;
    Eigen::Matrix<double, 6, 6> Id;
    Id.setIdentity();

    double err_norm = 0.0;
    int it = 0;
    bool success = false;
    for (it = 0; it < max_iters; ++it) {
        pinocchio::framesForwardKinematics(model, data, q);
        const pinocchio::SE3 dMf = data.oMf[fi].actInv(oMf_target);
        const pinocchio::Motion::Vector6 err = pinocchio::log6(dMf).toVector();
        err_norm = err.norm();
        if (err_norm < eps) {
            success = true;
            break;
        }
        J.setZero();
        pinocchio::computeFrameJacobian(model, data, q, fi, pinocchio::LOCAL, J);
        JJt.noalias() = J * J.transpose();
        JJt += damping_sq * Id;
        // 6x6 dense solve. The earlier form did `JJt_inv = JJt.ldlt().solve(Id)`
        // then multiplied by `err`, which materializes a full 6x6 inverse per
        // iteration. Solving against `err` directly halves the work and skips
        // the Id-shaped temporary; mathematically identical.
        const Eigen::VectorXd dq = J.transpose() * JJt.ldlt().solve(err);
        // err = log6(current^-1 · target) is the body-frame velocity that
        // would carry the EE to the target, so the +J⁺·err direction
        // reduces err. The full Gauss-Newton step ||dq|| ≈ ||err|| can
        // overshoot (oscillation between iters) when err is large and the
        // arm is far from the linearization point, so we damp by α=0.5
        // — a standard, slightly conservative choice that doubles the
        // iteration count near singularities but converges reliably from
        // any starting q for the 2-DOF demo arm.
        //
        // V1: scalar joints only. integrate(q, αdq) ≡ q + αdq element-
        // wise; swap to pinocchio::integrate when free-floating joints
        // (quaternion in q) land.
        constexpr double kIkStepScale = 0.5;
        q.noalias() += kIkStepScale * dq;
    }
    result["q"] = to_godot(q);
    result["success"] = success;
    // On success, `it` is the loop index at which the residual check fired
    // — the iteration that VERIFIED convergence already ran the FK that
    // produced this residual. Report it as a 1-based count so logs reading
    // "iterations=N" really mean "N iterations actually executed".
    // On non-convergence (loop ran to completion), `it == max_iters`.
    result["iterations"] = success ? (it + 1) : it;
    result["residual"] = err_norm;
    return result;
}

godot::PackedFloat64Array PinocchioData::rnea(
        const godot::PackedFloat64Array &q,
        const godot::PackedFloat64Array &v,
        const godot::PackedFloat64Array &a) const {
    ENSURE_READY("rnea", {});
    const pinocchio::Model &model = model_ref->native_model();
    if (!size_ok(q.size(), model.nq, "rnea", "q") ||
        !size_ok(v.size(), model.nv, "rnea", "v") ||
        !size_ok(a.size(), model.nv, "rnea", "a")) {
        return {};
    }
    pinocchio::rnea(model, *impl->data, to_eigen(q), to_eigen(v), to_eigen(a));
    return to_godot(impl->data->tau);
}

godot::PackedFloat64Array PinocchioData::compute_generalized_gravity(
        const godot::PackedFloat64Array &q) const {
    ENSURE_READY("compute_generalized_gravity", {});
    const pinocchio::Model &model = model_ref->native_model();
    if (!size_ok(q.size(), model.nq, "compute_generalized_gravity", "q")) {
        return {};
    }
    pinocchio::computeGeneralizedGravity(model, *impl->data, to_eigen(q));
    return to_godot(impl->data->g);
}

godot::PackedFloat64Array PinocchioData::aba(
        const godot::PackedFloat64Array &q,
        const godot::PackedFloat64Array &v,
        const godot::PackedFloat64Array &tau) const {
    ENSURE_READY("aba", {});
    const pinocchio::Model &model = model_ref->native_model();
    if (!size_ok(q.size(), model.nq, "aba", "q") ||
        !size_ok(v.size(), model.nv, "aba", "v") ||
        !size_ok(tau.size(), model.nv, "aba", "tau")) {
        return {};
    }
    pinocchio::aba(model, *impl->data, to_eigen(q), to_eigen(v), to_eigen(tau));
    return to_godot(impl->data->ddq);
}

godot::PackedFloat64Array PinocchioData::crba(
        const godot::PackedFloat64Array &q) const {
    ENSURE_READY("crba", {});
    const pinocchio::Model &model = model_ref->native_model();
    if (!size_ok(q.size(), model.nq, "crba", "q")) {
        return {};
    }
    pinocchio::crba(model, *impl->data, to_eigen(q));
    // CRBA only fills the upper-triangular part — mirror it so callers see
    // a full symmetric matrix. Eigen has a specialized overload for
    // `triangularView = matrix` that handles the M=M^T aliasing safely;
    // the previous `triangularView = triangularView` form left the
    // self-assignment to LDLT's hand-rolled aliasing rules, which Eigen
    // does NOT specialize the same way.
    pinocchio::Data &data = *impl->data;
    data.M.triangularView<Eigen::StrictlyLower>() = data.M.transpose();
    return to_godot_rowmajor(data.M);
}

godot::Dictionary PinocchioData::compute_centroidal_momentum(
        const godot::PackedFloat64Array &q,
        const godot::PackedFloat64Array &v) const {
    // Populate zero defaults so callers can index the dict without a
    // pre-check on every code path. The error / not-initialized branches
    // below short-circuit but still leave the keys present.
    godot::Dictionary result;
    const godot::Vector3 zero_v3(0, 0, 0);
    godot::PackedFloat64Array zero_arr;
    zero_arr.resize(3);
    zero_arr[0] = 0.0; zero_arr[1] = 0.0; zero_arr[2] = 0.0;
    result["linear"] = zero_v3;
    result["angular"] = zero_v3;
    result["com"] = zero_v3;
    result["linear_raw"] = zero_arr;
    result["angular_raw"] = zero_arr;
    result["com_raw"] = zero_arr;
    ENSURE_READY("compute_centroidal_momentum", result);
    const pinocchio::Model &model = model_ref->native_model();
    if (!size_ok(q.size(), model.nq, "compute_centroidal_momentum", "q") ||
        !size_ok(v.size(), model.nv, "compute_centroidal_momentum", "v")) {
        return result;
    }
    pinocchio::Data &data = *impl->data;
    pinocchio::computeCentroidalMomentum(model, data, to_eigen(q), to_eigen(v));
    // pinocchio::computeCentroidalMomentum also recomputes the COM into
    // data.com[0]; reuse it instead of a second pass.
    //
    // Two flavors of each output: the Vector3 form is ergonomic for
    // visualization (mass-weighted velocity arrows, COM markers); the
    // PackedFloat64Array form preserves the underlying double precision
    // so downstream control law / IK code (and the demo's identity test)
    // doesn't get truncated to float32 by Godot's Vector3 storage.
    const Eigen::Vector3d lin = data.hg.linear();
    const Eigen::Vector3d ang = data.hg.angular();
    const Eigen::Vector3d com = data.com[0];
    result["linear"] = to_godot(lin);
    result["angular"] = to_godot(ang);
    result["com"] = to_godot(com);
    godot::PackedFloat64Array lin_raw;
    lin_raw.resize(3);
    lin_raw[0] = lin.x(); lin_raw[1] = lin.y(); lin_raw[2] = lin.z();
    godot::PackedFloat64Array ang_raw;
    ang_raw.resize(3);
    ang_raw[0] = ang.x(); ang_raw[1] = ang.y(); ang_raw[2] = ang.z();
    godot::PackedFloat64Array com_raw;
    com_raw.resize(3);
    com_raw[0] = com.x(); com_raw[1] = com.y(); com_raw[2] = com.z();
    result["linear_raw"] = lin_raw;
    result["angular_raw"] = ang_raw;
    result["com_raw"] = com_raw;
    return result;
}

void PinocchioData::_bind_methods() {
    using godot::ClassDB;
    using godot::D_METHOD;

    ClassDB::bind_method(D_METHOD("initialize", "model"),
                         &PinocchioData::initialize);
    ClassDB::bind_method(D_METHOD("get_model"), &PinocchioData::get_model);

    ClassDB::bind_method(D_METHOD("forward_kinematics", "q"),
                         &PinocchioData::forward_kinematics);
    ClassDB::bind_method(D_METHOD("get_frame_transform", "frame_id"),
                         &PinocchioData::get_frame_transform);
    ClassDB::bind_method(D_METHOD("get_joint_transform", "joint_id"),
                         &PinocchioData::get_joint_transform);
    // Defaults match the demo's tier-3 / tier-4 calls: LOCAL_WORLD_ALIGNED
    // is the world-frame variant most useful for visual debugging + Gauss-
    // Newton IK from a fresh q0. Anyone needing the body-frame J or a
    // tighter eps overrides explicitly.
    ClassDB::bind_method(
            D_METHOD("compute_frame_jacobian", "q", "frame_id", "reference_frame"),
            &PinocchioData::compute_frame_jacobian,
            DEFVAL(LOCAL_WORLD_ALIGNED));
    // Default 400 iters: with the α=0.5 step in the DLS body and
    // eps=1e-6, a near-singular starting q against a far target can run
    // 100-200 iters; doubling that gives slack so the binding default
    // doesn't silently truncate. Callers needing a hard cap pass it.
    ClassDB::bind_method(
            D_METHOD("solve_ik_dls", "target", "frame_id", "q0", "max_iters",
                     "eps", "damping"),
            &PinocchioData::solve_ik_dls,
            DEFVAL(400), DEFVAL(1e-6), DEFVAL(1e-3));
    ClassDB::bind_method(D_METHOD("rnea", "q", "v", "a"),
                         &PinocchioData::rnea);
    ClassDB::bind_method(D_METHOD("compute_generalized_gravity", "q"),
                         &PinocchioData::compute_generalized_gravity);
    ClassDB::bind_method(D_METHOD("aba", "q", "v", "tau"), &PinocchioData::aba);
    ClassDB::bind_method(D_METHOD("crba", "q"), &PinocchioData::crba);
    ClassDB::bind_method(D_METHOD("compute_centroidal_momentum", "q", "v"),
                         &PinocchioData::compute_centroidal_momentum);

    // Bind the ReferenceFrame enum so GDScript can write
    //   compute_frame_jacobian(q, fi, PinocchioData.LOCAL_WORLD_ALIGNED)
    // instead of the magic integer literal.
    BIND_ENUM_CONSTANT(LOCAL);
    BIND_ENUM_CONSTANT(WORLD);
    BIND_ENUM_CONSTANT(LOCAL_WORLD_ALIGNED);
}

} // namespace operator_xr
