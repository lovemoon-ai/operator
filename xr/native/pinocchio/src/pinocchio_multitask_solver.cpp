#include "pinocchio_multitask_solver.h"

#include "eigen_godot.h"

#define PINOCCHIO_WITH_HPP_FCL 0
#define PINOCCHIO_WITH_URDFDOM 0

#include <pinocchio/multibody/model.hpp>
#include <pinocchio/multibody/data.hpp>
#include <pinocchio/algorithm/frames.hpp>
#include <pinocchio/algorithm/jacobian.hpp>
#include <pinocchio/algorithm/kinematics.hpp>
#include <pinocchio/spatial/explog.hpp>

#include <godot_cpp/classes/time.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/quaternion.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <Eigen/Cholesky>
#include <Eigen/Geometry>
#include <Eigen/QR>

#include <algorithm>
#include <cmath>
#include <unordered_map>
#include <vector>

#include <android/log.h>

namespace operator_xr {

// Same tag as pinocchio_data.cpp — keeps logcat filtering trivial.
#define PINO_LOG_TAG "PinocchioGD"
#define LOGW(fmt, ...) \
    __android_log_print(ANDROID_LOG_WARN, PINO_LOG_TAG, fmt, ##__VA_ARGS__)

// --- Internal types --------------------------------------------------------

namespace {

enum class TaskKind {
    Pose,         // 6 rows  — frame Jacobian top-3 (lin) + bottom-3 (ang)
    Position,     // 3 rows  — Jacobian top-3
    Orientation,  // 3 rows  — Jacobian bottom-3
    JointScalar,  // 1 row   — identity on q[joint_index]
};

struct Task {
    godot::String key;
    TaskKind kind;
    // For Pose/Position/Orientation this is the pinocchio FrameIndex; for
    // JointScalar it is the q-vector slot (== nv slot since V1 enforces
    // scalar-only joints, so nq == nv and the joint index is also a
    // velocity index).
    int frame_or_joint_id = -1;
};

// Wrap a revolute-joint angular error into [-π, π] so a 359° target
// against a 1° current state is treated as a 2° error rather than 358°.
double wrap_angle(double e) {
    constexpr double kPi = 3.14159265358979323846;
    while (e >  kPi) e -= 2.0 * kPi;
    while (e < -kPi) e += 2.0 * kPi;
    return e;
}

// Read a numeric key out of a Dictionary, returning `dflt` if missing.
double dict_get_num(const godot::Dictionary &d, const char *k, double dflt) {
    const godot::String key(k);
    if (!d.has(key)) return dflt;
    const godot::Variant v = d[key];
    switch (v.get_type()) {
        case godot::Variant::FLOAT: return double(v);
        case godot::Variant::INT:   return double(int64_t(v));
        default:                    return dflt;
    }
}

bool dict_get_bool(const godot::Dictionary &d, const char *k, bool dflt) {
    const godot::String key(k);
    if (!d.has(key)) return dflt;
    return bool(d[key]);
}

} // namespace

// --- Impl ------------------------------------------------------------------

struct PinocchioMultiTaskSolver::Impl {
    std::unique_ptr<pinocchio::Data> data;

    std::vector<Task> tasks;
    // Fast key->index lookup for duplicate-detection in add_*_task.
    std::unordered_map<std::string, size_t> task_index_by_key;

    Eigen::VectorXd q_home;     // empty → posture disabled
    Eigen::VectorXd q_lower;
    Eigen::VectorXd q_upper;

    // q-vector slot → pinocchio joint id, precomputed at initialize() so the
    // joint-limit-saturation report doesn't rely on the "1-DoF, sequentially
    // built" assumption. For 1-DoF scalar joints this happens to coincide
    // with `i + 1`, but going through joints[j].idx_q() is the proper way
    // and will still work once free-floating / multi-DoF joints land.
    std::vector<int> joint_id_for_qidx;

    int nq = 0;
    int nv = 0;

    // Hyper-parameters from initialize() config.
    double damping = 3.0e-3;
    int    max_iters = 12;
    double step = 0.6;
    double convergence_tol_m = 1.5e-3;
    double convergence_tol_rad = 3.0e-2;
    double posture_weight = 0.04;
    double smooth_weight = 0.08;
    bool   clamp_to_joint_limits = true;

    bool initialized = false;
};

PinocchioMultiTaskSolver::PinocchioMultiTaskSolver()
    : impl(std::make_unique<Impl>()) {}
PinocchioMultiTaskSolver::~PinocchioMultiTaskSolver() = default;

// Guard macro analogous to PinocchioData's; abort the surrounding method
// early when the caller forgot to initialize() (returns `ret`).
#define ENSURE_READY(fn, ret)                                          \
    do {                                                               \
        if (!impl->initialized || model_ref.is_null() || !impl->data) {\
            LOGW("%s called before initialize()", fn);                 \
            return ret;                                                \
        }                                                              \
    } while (0)

bool PinocchioMultiTaskSolver::initialize(
        const godot::Ref<PinocchioModel> &model,
        const godot::Dictionary &config) {
    if (impl->initialized) {
        LOGW("PinocchioMultiTaskSolver.initialize: already initialized");
        return false;
    }
    if (model.is_null()) {
        LOGW("PinocchioMultiTaskSolver.initialize: null model");
        return false;
    }
    if (model->get_njoints() <= 0) {
        LOGW("PinocchioMultiTaskSolver.initialize: model has no joints");
        return false;
    }
    model_ref = model;
    const pinocchio::Model &nm = model->native_model();
    impl->data = std::make_unique<pinocchio::Data>(nm);
    impl->nq = nm.nq;
    impl->nv = nm.nv;
    // V1 (and this V2) only supports 1-DoF scalar joints; if a future model
    // builder adds a free-floating root, nq != nv and the q + step·dq
    // retraction we do below is wrong (need pinocchio::integrate).
    if (impl->nq != impl->nv) {
        LOGW("PinocchioMultiTaskSolver.initialize: nq=%d != nv=%d — "
             "free-floating joints not supported in V2",
             impl->nq, impl->nv);
        impl->data.reset();
        model_ref = godot::Ref<PinocchioModel>();
        return false;
    }
    impl->q_lower = nm.lowerPositionLimit;
    impl->q_upper = nm.upperPositionLimit;

    // Build q-slot → joint-id table once. Pinocchio joint 0 is the universe
    // and contributes no q entries, so loop from 1. For 1-DoF joints the
    // inner loop runs exactly once with k=0.
    impl->joint_id_for_qidx.assign(impl->nq, 0);
    for (int j = 1; j < nm.njoints; ++j) {
        const auto &jm = nm.joints[j];
        const int idx_q = jm.idx_q();
        const int nq_j = jm.nq();
        for (int k = 0; k < nq_j; ++k) {
            const int slot = idx_q + k;
            if (slot >= 0 && slot < impl->nq) {
                impl->joint_id_for_qidx[slot] = j;
            }
        }
    }

    impl->damping = dict_get_num(config, "damping", 3.0e-3);
    impl->max_iters = int(dict_get_num(config, "max_iters", 12.0));
    impl->step = dict_get_num(config, "step", 0.6);
    impl->convergence_tol_m = dict_get_num(config, "convergence_tol_m", 1.5e-3);
    impl->convergence_tol_rad = dict_get_num(config, "convergence_tol_rad", 3.0e-2);
    impl->posture_weight = dict_get_num(config, "posture_weight", 0.04);
    impl->smooth_weight = dict_get_num(config, "smooth_weight", 0.08);
    impl->clamp_to_joint_limits = dict_get_bool(config, "clamp_to_joint_limits", true);

    impl->initialized = true;
    return true;
}

// --- Task registration ------------------------------------------------------

// Implementation note: register_task_common is a private method (declared
// at the bottom of this TU via the in-class private static helper trick
// would require touching the header). Inlining the half-dozen lines into
// each add_*_task keeps the public header surface tight and avoids
// referencing the private nested `Impl` type from anonymous-namespace free
// functions (which a previous draft did, and which C++ rejects with
// "Impl is private within this context").

#define REGISTER_TASK(FN, KIND, ID, MAX_ID)                                   \
    do {                                                                      \
        if ((ID) < 0 || (ID) >= (MAX_ID)) {                                   \
            LOGW("%s: id %d out of range [0, %d)", FN, (ID), (MAX_ID));       \
            return false;                                                     \
        }                                                                     \
        const std::string key_str = key.utf8().get_data();                    \
        if (impl->task_index_by_key.count(key_str)) {                         \
            LOGW("%s: duplicate key '%s'", FN, key_str.c_str());              \
            return false;                                                     \
        }                                                                     \
        Task t;                                                               \
        t.key = key;                                                          \
        t.kind = (KIND);                                                      \
        t.frame_or_joint_id = (ID);                                           \
        impl->task_index_by_key[key_str] = impl->tasks.size();                \
        impl->tasks.push_back(std::move(t));                                  \
        return true;                                                          \
    } while (0)

bool PinocchioMultiTaskSolver::add_pose_task(const godot::String &key,
                                             int frame_id) {
    ENSURE_READY("add_pose_task", false);
    const int max_id = static_cast<int>(model_ref->native_model().nframes);
    REGISTER_TASK("add_pose_task", TaskKind::Pose, frame_id, max_id);
}

bool PinocchioMultiTaskSolver::add_position_task(const godot::String &key,
                                                 int frame_id) {
    ENSURE_READY("add_position_task", false);
    const int max_id = static_cast<int>(model_ref->native_model().nframes);
    REGISTER_TASK("add_position_task", TaskKind::Position, frame_id, max_id);
}

bool PinocchioMultiTaskSolver::add_orientation_task(const godot::String &key,
                                                    int frame_id) {
    ENSURE_READY("add_orientation_task", false);
    const int max_id = static_cast<int>(model_ref->native_model().nframes);
    REGISTER_TASK("add_orientation_task", TaskKind::Orientation, frame_id,
                  max_id);
}

bool PinocchioMultiTaskSolver::add_joint_scalar_task(const godot::String &key,
                                                    int joint_index) {
    ENSURE_READY("add_joint_scalar_task", false);
    // Joint index here is a q-vector slot (== nv slot under the nq == nv
    // assertion in initialize()).
    REGISTER_TASK("add_joint_scalar_task", TaskKind::JointScalar, joint_index,
                  impl->nq);
}

#undef REGISTER_TASK

bool PinocchioMultiTaskSolver::set_posture(
        const godot::PackedFloat64Array &q_home) {
    ENSURE_READY("set_posture", false);
    if (q_home.size() == 0) {
        impl->q_home.resize(0);   // disables posture term
        return true;
    }
    if (q_home.size() != impl->nq) {
        LOGW("set_posture: q_home size %d != nq %d",
             int(q_home.size()), impl->nq);
        return false;
    }
    impl->q_home = to_eigen(q_home);
    return true;
}

// --- solve() helpers -------------------------------------------------------

namespace {

// Convert a Godot Variant target into an SE(3) pose. Accepts Transform3D
// directly. Returns false if the variant isn't a Transform3D.
bool variant_to_se3(const godot::Variant &v, pinocchio::SE3 &out) {
    if (v.get_type() != godot::Variant::TRANSFORM3D) {
        return false;
    }
    out = to_pinocchio(godot::Transform3D(v));
    return true;
}

// Variant → Eigen::Vector3d, accepting Vector3.
bool variant_to_vec3(const godot::Variant &v, Eigen::Vector3d &out) {
    if (v.get_type() != godot::Variant::VECTOR3) {
        return false;
    }
    const godot::Vector3 g(v);
    out = Eigen::Vector3d(g.x, g.y, g.z);
    return true;
}

// Variant → rotation matrix. Accepts Transform3D (read basis) or
// Quaternion. The basis is re-orthogonalized via the column-Gram-Schmidt
// QR that Eigen provides — Godot Basis can drift after many compositions.
bool variant_to_rot(const godot::Variant &v, Eigen::Matrix3d &out) {
    if (v.get_type() == godot::Variant::TRANSFORM3D) {
        const godot::Transform3D xf(v);
        const pinocchio::SE3 se3 = to_pinocchio(xf);
        out = se3.rotation();
    } else if (v.get_type() == godot::Variant::QUATERNION) {
        const godot::Quaternion q(v);
        Eigen::Quaterniond eq(q.w, q.x, q.y, q.z);
        eq.normalize();
        out = eq.toRotationMatrix();
    } else if (v.get_type() == godot::Variant::BASIS) {
        // Accept a bare Basis too, since some callers may pass it.
        // godot-cpp's Basis is row-major (basis[i][j] = R(i,j)).
        const godot::Basis b(v);
        out(0, 0) = b[0].x; out(0, 1) = b[0].y; out(0, 2) = b[0].z;
        out(1, 0) = b[1].x; out(1, 1) = b[1].y; out(1, 2) = b[1].z;
        out(2, 0) = b[2].x; out(2, 1) = b[2].y; out(2, 2) = b[2].z;
    } else {
        return false;
    }
    // Re-orthogonalize against drift. HouseholderQR's Q factor is *an*
    // orthogonal matrix near the input (not the Frobenius-closest one —
    // that's the polar decomposition / SVD — but for the 1e-6 drift we
    // expect from accumulated Godot Basis composes either is fine, and
    // QR is cheaper). If a caller hands us a 5° off-axis "rotation" the
    // QR-projected output is still on SO(3) but may not be the obvious
    // nearest rotation; document that upstream if it matters.
    Eigen::HouseholderQR<Eigen::Matrix3d> qr(out);
    Eigen::Matrix3d Q = qr.householderQ();
    // Fix improper rotations: if det(Q) ≈ -1 (reflection), flip the last
    // column so we land on SO(3) rather than O(3).
    if (Q.determinant() < 0.0) {
        Q.col(2) *= -1.0;
    }
    out = Q;
    return true;
}

} // namespace

godot::Dictionary PinocchioMultiTaskSolver::solve(
        const godot::PackedFloat64Array &q0,
        const godot::Dictionary &targets,
        const godot::PackedFloat64Array &dq_prev) {
    godot::Dictionary result;
    // Pre-fill defaults so the caller can unconditionally index the dict.
    result["q"] = godot::PackedFloat64Array();
    result["dq"] = godot::PackedFloat64Array();
    result["residuals"] = godot::Dictionary();
    result["iterations"] = 0;
    result["converged"] = false;
    result["joint_limit_saturation"] = godot::PackedStringArray();
    result["solve_us"] = 0;
    ENSURE_READY("solve", result);

    const pinocchio::Model &model = model_ref->native_model();
    if (int(q0.size()) != impl->nq) {
        LOGW("solve: q0 size %d != nq %d", int(q0.size()), impl->nq);
        return result;
    }
    const bool have_smooth =
            dq_prev.size() == impl->nv && impl->smooth_weight > 0.0;
    Eigen::VectorXd dq_prev_vec;
    if (have_smooth) {
        dq_prev_vec = to_eigen(dq_prev);
    }

    const uint64_t t0_us = godot::Time::get_singleton()->get_ticks_usec();

    const Eigen::VectorXd q0_vec = to_eigen(q0);
    Eigen::VectorXd q = q0_vec;
    const double lambda_sq = impl->damping * impl->damping;
    const double posture_w_sq = impl->q_home.size() == impl->nq
                                ? impl->posture_weight * impl->posture_weight
                                : 0.0;
    const double smooth_w_sq = have_smooth
                                ? impl->smooth_weight * impl->smooth_weight
                                : 0.0;
    const double diag_reg = lambda_sq + posture_w_sq + smooth_w_sq;

    godot::Dictionary residuals;
    int iters_ran = 0;
    bool converged = false;

    // Jacobian buffer reused across tasks within one iteration.
    Eigen::Matrix<double, 6, Eigen::Dynamic> J6(6, impl->nv);

    // Cache 6×nv Jacobians by frame_id so pose tasks (or a position+
    // orientation pair on the same frame) don't recompute.
    std::unordered_map<int, Eigen::Matrix<double, 6, Eigen::Dynamic>> jac_cache;

    Eigen::MatrixXd A(impl->nv, impl->nv);
    Eigen::VectorXd b(impl->nv);

    for (int iter = 0; iter < impl->max_iters; ++iter) {
        pinocchio::framesForwardKinematics(model, *impl->data, q);
        jac_cache.clear();

        A.setZero();
        A.diagonal().array() = diag_reg;
        b.setZero();
        residuals.clear();
        bool any_active_task = false;
        bool all_within_tol = true;

        for (const Task &t : impl->tasks) {
            if (!targets.has(t.key)) continue;
            const godot::Variant target_v = targets[t.key];

            // --- JointScalar -----------------------------------------------
            if (t.kind == TaskKind::JointScalar) {
                // Target may be a plain float or a Dictionary{"target":...,"weight":...}.
                double target = 0.0;
                double w = 1.0;
                if (target_v.get_type() == godot::Variant::DICTIONARY) {
                    const godot::Dictionary td(target_v);
                    target = dict_get_num(td, "target", 0.0);
                    w = dict_get_num(td, "weight", 1.0);
                } else if (target_v.get_type() == godot::Variant::FLOAT
                        || target_v.get_type() == godot::Variant::INT) {
                    target = double(target_v);
                }
                if (w <= 0.0) continue;
                any_active_task = true;
                const int idx = t.frame_or_joint_id;
                double e = wrap_angle(target - q[idx]);
                const double w2 = w * w;
                A(idx, idx) += w2;
                b(idx) += w2 * e;
                residuals[t.key + godot::String("_rad")] = std::abs(e);
                if (std::abs(e) > impl->convergence_tol_rad) {
                    all_within_tol = false;
                }
                continue;
            }

            // --- Pose / Position / Orientation -----------------------------
            // All three need (a) the frame transform, (b) the 6×nv Jacobian.
            const int fid = t.frame_or_joint_id;
            const pinocchio::SE3 &oMf = impl->data->oMf[fid];

            auto cache_it = jac_cache.find(fid);
            if (cache_it == jac_cache.end()) {
                J6.setZero();
                pinocchio::computeFrameJacobian(
                        model, *impl->data, q,
                        static_cast<pinocchio::FrameIndex>(fid),
                        pinocchio::LOCAL_WORLD_ALIGNED, J6);
                cache_it = jac_cache.emplace(fid, J6).first;
            }
            const auto &Jf = cache_it->second;

            // Defaults for missing weight keys: 1.0 for single-weight tasks.
            // For Pose the keys are weight_pos / weight_rot.
            if (target_v.get_type() != godot::Variant::DICTIONARY) {
                // Position / Orientation can also accept a bare Vector3 /
                // Transform3D / Quaternion target without wrapping in a
                // dict (handy for tests). Pose requires a dict because it
                // carries two weights.
                if (t.kind == TaskKind::Pose) {
                    LOGW("solve: pose task '%s' expects a Dictionary target",
                         std::string(t.key.utf8().get_data()).c_str());
                    continue;
                }
            }
            const godot::Dictionary td = target_v.get_type() == godot::Variant::DICTIONARY
                                              ? godot::Dictionary(target_v)
                                              : godot::Dictionary();

            // --- Position part (Pose or Position task) ----------------------
            if (t.kind == TaskKind::Pose || t.kind == TaskKind::Position) {
                double w_pos = (t.kind == TaskKind::Pose)
                                       ? dict_get_num(td, "weight_pos", 1.0)
                                       : dict_get_num(td, "weight", 1.0);
                Eigen::Vector3d p_target;
                bool have_p = false;
                if (t.kind == TaskKind::Pose) {
                    // Pose target ALWAYS lives at td["target"] (we already
                    // rejected non-Dictionary target_v above). Previously a
                    // draft passed target_v straight to variant_to_se3, which
                    // failed type-check against the wrapping Dictionary and
                    // silently zeroed the position contribution.
                    pinocchio::SE3 se3_target;
                    if (td.has("target") &&
                            variant_to_se3(td["target"], se3_target)) {
                        have_p = true;
                        p_target = se3_target.translation();
                    }
                } else {
                    // Position: bare Vector3 or dict["target"].
                    if (target_v.get_type() == godot::Variant::VECTOR3) {
                        have_p = variant_to_vec3(target_v, p_target);
                    } else if (td.has("target")) {
                        have_p = variant_to_vec3(td["target"], p_target);
                    }
                }
                if (have_p && w_pos > 0.0) {
                    any_active_task = true;
                    const Eigen::Vector3d e = p_target - oMf.translation();
                    const auto Jp = Jf.topRows(3);
                    const double w2 = w_pos * w_pos;
                    A.noalias() += w2 * (Jp.transpose() * Jp);
                    b.noalias() += w2 * (Jp.transpose() * e);
                    const double err_norm = e.norm();
                    residuals[t.key + godot::String("_pos_m")] = err_norm;
                    if (err_norm > impl->convergence_tol_m) {
                        all_within_tol = false;
                    }
                }
            }

            // --- Orientation part (Pose or Orientation task) ----------------
            if (t.kind == TaskKind::Pose || t.kind == TaskKind::Orientation) {
                double w_rot = (t.kind == TaskKind::Pose)
                                       ? dict_get_num(td, "weight_rot", 1.0)
                                       : dict_get_num(td, "weight", 1.0);
                Eigen::Matrix3d R_target;
                bool have_r = false;
                if (t.kind == TaskKind::Pose) {
                    // Same bug as the Position branch above — Pose carries
                    // its rotation inside td["target"]'s basis, not on
                    // target_v itself (target_v is the wrapping Dictionary).
                    if (td.has("target")) {
                        have_r = variant_to_rot(td["target"], R_target);
                    }
                } else {
                    if (target_v.get_type() != godot::Variant::DICTIONARY) {
                        have_r = variant_to_rot(target_v, R_target);
                    } else if (td.has("target")) {
                        have_r = variant_to_rot(td["target"], R_target);
                    }
                }
                if (have_r && w_rot > 0.0) {
                    any_active_task = true;
                    // log3 of R_target · R_currentᵀ — body-frame axis-angle
                    // mapping back to the LOCAL_WORLD_ALIGNED angular rows
                    // we asked computeFrameJacobian for.
                    Eigen::Matrix3d Rerr = R_target * oMf.rotation().transpose();
                    Eigen::Vector3d e = pinocchio::log3(Rerr);
                    const auto Jr = Jf.bottomRows(3);
                    const double w2 = w_rot * w_rot;
                    A.noalias() += w2 * (Jr.transpose() * Jr);
                    b.noalias() += w2 * (Jr.transpose() * e);
                    const double err_norm = e.norm();
                    residuals[t.key + godot::String("_rot_rad")] = err_norm;
                    if (err_norm > impl->convergence_tol_rad) {
                        all_within_tol = false;
                    }
                }
            }
        }

        // Posture regularization. Diagonal already contains posture_w_sq;
        // here we only need the right-hand side contribution. Skips
        // entirely when set_posture was never called or was called with an
        // empty array.
        if (posture_w_sq > 0.0) {
            b.noalias() += posture_w_sq * (impl->q_home - q);
        }
        // Smoothness regularization (right-hand side only — diagonal is in
        // diag_reg already). When dq_prev is empty (cold start), have_smooth
        // is false and smooth_w_sq is 0 → b contribution drops out.
        if (smooth_w_sq > 0.0) {
            b.noalias() += smooth_w_sq * dq_prev_vec;
        }

        // Solve normal equations. A is symmetric positive-definite by
        // construction (sum of JᵀJ blocks + diag_reg·I with diag_reg > 0),
        // so LDLT is the textbook pick.
        Eigen::LDLT<Eigen::MatrixXd> ldlt(A);
        if (ldlt.info() != Eigen::Success) {
            LOGW("solve: LDLT factorization failed at iter %d", iter);
            break;
        }
        Eigen::VectorXd dq = ldlt.solve(b);
        if (!dq.allFinite()) {
            LOGW("solve: non-finite dq at iter %d", iter);
            break;
        }

        // Only NOW do we count this as a completed iteration — LDLT
        // success + finite dq means we're about to take a real retract
        // step. If we'd incremented at the top of the loop, a factorization
        // failure on iter=3 would report iterations=4 with only 3 real
        // steps applied; reporting truthful counts matters because
        // downstream `converged` + `iterations` is a perf-debug signal.
        iters_ran = iter + 1;

        // Retract. V1 still: q + step·dq element-wise (nq == nv, scalar
        // joints only). Swap to pinocchio::integrate when free-floating
        // joints land.
        q.noalias() += impl->step * dq;
        if (impl->clamp_to_joint_limits) {
            q = q.cwiseMax(impl->q_lower).cwiseMin(impl->q_upper);
        }

        // Early exit only once at least one task contributed rows AND
        // every contributing task's residual is below its tolerance.
        if (any_active_task && all_within_tol) {
            converged = true;
            break;
        }
    }

    // Collect joint-limit saturation (within 1 mrad / 1e-3 m of either bound).
    // Mapping q-slot → joint id was precomputed in initialize() via
    // pinocchio::JointModel::idx_q() so we don't bake in the "1-DoF, joints
    // added in order" assumption here.
    godot::PackedStringArray sat;
    constexpr double kSatTol = 1.0e-3;
    for (int i = 0; i < impl->nq; ++i) {
        if (q[i] <= impl->q_lower[i] + kSatTol
                || q[i] >= impl->q_upper[i] - kSatTol) {
            const int joint_id = impl->joint_id_for_qidx[i];
            if (joint_id > 0 && joint_id < model.njoints) {
                sat.push_back(godot::String(model.names[joint_id].c_str()));
            }
        }
    }

    const uint64_t t1_us = godot::Time::get_singleton()->get_ticks_usec();

    // dq for the API contract is q - q0, NOT the last inner-loop step.
    // Reuse the q0_vec we already converted at the top of solve() — no
    // need to re-walk the PackedFloat64Array.
    Eigen::VectorXd dq_total = q - q0_vec;

    result["q"] = to_godot(q);
    result["dq"] = to_godot(dq_total);
    result["residuals"] = residuals;
    result["iterations"] = iters_ran;
    result["converged"] = converged;
    result["joint_limit_saturation"] = sat;
    result["solve_us"] = int64_t(t1_us - t0_us);
    return result;
}

void PinocchioMultiTaskSolver::_bind_methods() {
    using godot::ClassDB;
    using godot::D_METHOD;

    ClassDB::bind_method(D_METHOD("initialize", "model", "config"),
                         &PinocchioMultiTaskSolver::initialize);
    ClassDB::bind_method(D_METHOD("add_pose_task", "key", "frame_id"),
                         &PinocchioMultiTaskSolver::add_pose_task);
    ClassDB::bind_method(D_METHOD("add_position_task", "key", "frame_id"),
                         &PinocchioMultiTaskSolver::add_position_task);
    ClassDB::bind_method(D_METHOD("add_orientation_task", "key", "frame_id"),
                         &PinocchioMultiTaskSolver::add_orientation_task);
    ClassDB::bind_method(
            D_METHOD("add_joint_scalar_task", "key", "joint_index"),
            &PinocchioMultiTaskSolver::add_joint_scalar_task);
    ClassDB::bind_method(D_METHOD("set_posture", "q_home"),
                         &PinocchioMultiTaskSolver::set_posture);
    ClassDB::bind_method(D_METHOD("solve", "q0", "targets", "dq_prev"),
                         &PinocchioMultiTaskSolver::solve);
}

} // namespace operator_xr
