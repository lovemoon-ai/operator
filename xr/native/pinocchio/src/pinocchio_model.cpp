#include "pinocchio_model.h"

#include "eigen_godot.h"

#define PINOCCHIO_WITH_HPP_FCL 0
#define PINOCCHIO_WITH_URDFDOM 0

#include <pinocchio/multibody/model.hpp>
#include <pinocchio/multibody/joint/joints.hpp>
// NB: <pinocchio/multibody/fcl.hpp> is a deprecated shim that pulls in the
// collision conversions which were disabled in the upstream build
// (BUILD_WITH_COLLISION_SUPPORT=OFF). Use the spatial header directly.
#include <pinocchio/spatial/inertia.hpp>
// joint-configuration.hpp would give us pinocchio::neutral() and ::integrate()
// for free, but its explicit-instantiation declarations for tangentMapProduct
// fail to compile against clang under the NDK r27 toolchain (Pinocchio 4.0).
// For V1 we only support 1-DOF scalar joints (revolute / prismatic) where
// neutral is just zeros and integrate is q + v — both inlined where needed.

#include <godot_cpp/core/class_db.hpp>

#include <algorithm>
#include <limits>

#include <android/log.h>

#define PINO_LOG_TAG "PinocchioGD"
#define PINO_LOGW(fmt, ...) \
    __android_log_print(ANDROID_LOG_WARN, PINO_LOG_TAG, fmt, ##__VA_ARGS__)

namespace operator_xr {

struct PinocchioModel::Impl {
    pinocchio::Model model;
};

PinocchioModel::PinocchioModel() : impl(std::make_unique<Impl>()) {}
PinocchioModel::~PinocchioModel() = default;

// Build a 1-element VectorXd from a single scalar — used for the bound
// vectors passed to pinocchio::Model::addJoint for 1-DOF joints.
static inline Eigen::VectorXd one_elem(double v) {
    Eigen::VectorXd x(1);
    x(0) = v;
    return x;
}

// Bounds check for a joint id received from GDScript. `parent_id` is `int`
// in the public API (so callers can pass 0 = universe), but gets cast to
// `pinocchio::JointIndex` (unsigned) for pinocchio's API — a negative or
// out-of-range value would silently wrap to a huge index and read past
// `model.names`/`model.joints`.
static inline bool valid_joint_id(int joint_id, int njoints, const char *fn) {
    if (joint_id < 0 || joint_id >= njoints) {
        PINO_LOGW("%s: joint id %d out of range [0, %d)", fn, joint_id, njoints);
        return false;
    }
    return true;
}

// Normalize axis safely. Returns false if `axis` is a near-zero vector
// (`.normalized()` on such would yield NaNs); callers should bail.
static inline bool normalized_axis(const godot::Vector3 &axis,
                                   Eigen::Vector3d &out, const char *fn) {
    const Eigen::Vector3d v = to_eigen(axis);
    const double n = v.norm();
    if (!std::isfinite(n) || n < 1e-12) {
        PINO_LOGW("%s: axis is zero / non-finite (%f, %f, %f); refusing",
                  fn, axis.x, axis.y, axis.z);
        return false;
    }
    out = v / n;
    return true;
}

int PinocchioModel::add_revolute_joint(int parent_id, const godot::String &name,
                                       const godot::Vector3 &axis,
                                       const godot::Transform3D &placement,
                                       double lower_q, double upper_q) {
    if (!valid_joint_id(parent_id, impl->model.njoints, "add_revolute_joint")) {
        return -1;
    }
    Eigen::Vector3d ax;
    if (!normalized_axis(axis, ax, "add_revolute_joint")) {
        return -1;
    }
    const pinocchio::SE3 P = to_pinocchio(placement);
    const pinocchio::JointModelRevoluteUnaligned jmodel(ax);

    const double inf = std::numeric_limits<double>::infinity();
    const pinocchio::JointIndex j = impl->model.addJoint(
            static_cast<pinocchio::JointIndex>(parent_id),
            jmodel,
            P,
            std::string(name.utf8().get_data()),
            one_elem(inf),       // max_effort
            one_elem(inf),       // max_velocity
            one_elem(lower_q),   // min_config
            one_elem(upper_q));  // max_config
    // Pinocchio 4 deliberately does NOT add the matching JOINT_FRAME from
    // addJoint (see model.hxx:379). Add it ourselves so `getFrameId(name)`
    // and `add_frame`'s parent lookup both work as expected; this matches
    // the convenience behavior most Pinocchio tutorials assume.
    impl->model.addJointFrame(j);
    return static_cast<int>(j);
}

int PinocchioModel::add_prismatic_joint(int parent_id, const godot::String &name,
                                        const godot::Vector3 &axis,
                                        const godot::Transform3D &placement,
                                        double lower_q, double upper_q) {
    if (!valid_joint_id(parent_id, impl->model.njoints, "add_prismatic_joint")) {
        return -1;
    }
    Eigen::Vector3d ax;
    if (!normalized_axis(axis, ax, "add_prismatic_joint")) {
        return -1;
    }
    const pinocchio::SE3 P = to_pinocchio(placement);
    const pinocchio::JointModelPrismaticUnaligned jmodel(ax);

    const double inf = std::numeric_limits<double>::infinity();
    const pinocchio::JointIndex j = impl->model.addJoint(
            static_cast<pinocchio::JointIndex>(parent_id),
            jmodel,
            P,
            std::string(name.utf8().get_data()),
            one_elem(inf),
            one_elem(inf),
            one_elem(lower_q),
            one_elem(upper_q));
    impl->model.addJointFrame(j); // see add_revolute_joint
    return static_cast<int>(j);
}

int PinocchioModel::add_frame(int parent_joint_id, const godot::String &name,
                              const godot::Transform3D &placement) {
    if (!valid_joint_id(parent_joint_id, impl->model.njoints, "add_frame")) {
        return -1;
    }
    // OP_FRAME — a user-defined operation point (end-effector, tool, IK
    // target). The Frame's `parentFrame` (in Pinocchio 4.x; older docs
    // call this `previousFrame`) must be the JOINT_FRAME id of the parent
    // joint, NOT 0 (the universe). Pinocchio's addJoint implicitly creates
    // a JOINT_FRAME named identically to the joint, which is what we look
    // up here. Walkers that traverse `frame.parentFrame` (e.g. some
    // visualizers, model-graph utilities) silently get the wrong parent
    // if we leave it at 0.
    const std::string parent_joint_name = impl->model.names[
            static_cast<pinocchio::JointIndex>(parent_joint_id)];
    const pinocchio::FrameIndex parent_frame =
            impl->model.getFrameId(parent_joint_name);
    pinocchio::Frame frame(
            std::string(name.utf8().get_data()),
            static_cast<pinocchio::JointIndex>(parent_joint_id),
            parent_frame,
            to_pinocchio(placement),
            pinocchio::FrameType::OP_FRAME);
    return static_cast<int>(impl->model.addFrame(frame));
}

void PinocchioModel::append_body_to_joint(int joint_id, double mass,
                                          const godot::Vector3 &com,
                                          const godot::Vector3 &inertia_diag) {
    if (!valid_joint_id(joint_id, impl->model.njoints, "append_body_to_joint")) {
        return;
    }
    const Eigen::Vector3d com_e = to_eigen(com);
    const Eigen::Matrix3d I = to_eigen(inertia_diag).asDiagonal();
    pinocchio::Inertia inertia(mass, com_e, I);
    // Identity placement: body's inertia frame coincides with the joint
    // frame. Mass / COM / inertia are all expressed in the joint frame.
    impl->model.appendBodyToJoint(
            static_cast<pinocchio::JointIndex>(joint_id), inertia,
            pinocchio::SE3::Identity());
}

void PinocchioModel::set_gravity(const godot::Vector3 &g) {
    impl->model.gravity.linear() = to_eigen(g);
    impl->model.gravity.angular().setZero();
}

int PinocchioModel::get_nq() const { return impl->model.nq; }
int PinocchioModel::get_nv() const { return impl->model.nv; }
int PinocchioModel::get_njoints() const { return impl->model.njoints; }
int PinocchioModel::get_nframes() const { return static_cast<int>(impl->model.nframes); }

int PinocchioModel::get_frame_id(const godot::String &name) const {
    const std::string n(name.utf8().get_data());
    if (!impl->model.existFrame(n)) {
        return -1;
    }
    return static_cast<int>(impl->model.getFrameId(n));
}

int PinocchioModel::get_joint_id(const godot::String &name) const {
    const std::string n(name.utf8().get_data());
    if (!impl->model.existJointName(n)) {
        return -1;
    }
    return static_cast<int>(impl->model.getJointId(n));
}

int PinocchioModel::get_frame_previous_frame(int frame_id) const {
    if (frame_id < 0 || frame_id >= static_cast<int>(impl->model.nframes)) {
        PINO_LOGW("get_frame_previous_frame: frame_id %d out of range [0, %d)",
                  frame_id, static_cast<int>(impl->model.nframes));
        return -1;
    }
    // Pinocchio 4.x renamed `previousFrame` → `parentFrame`; we keep the
    // Godot-side getter named "previous" because that's how the docs and
    // the existing GDScript callers talk about it.
    return static_cast<int>(impl->model.frames[frame_id].parentFrame);
}

godot::PackedFloat64Array PinocchioModel::get_neutral_q() const {
    // V1: scalar joints only. Neutral configuration is the zero vector.
    // Explicit VectorXd construction — Eigen::VectorXd::Zero(n) returns a
    // CwiseNullaryOp expression, which makes the to_godot overload set
    // ambiguous (Eigen::Vector3d vs Eigen::VectorXd).
    Eigen::VectorXd q = Eigen::VectorXd::Zero(impl->model.nq);
    return to_godot(q);
}

godot::PackedFloat64Array PinocchioModel::get_joint_lower_limits() const {
    return to_godot(impl->model.lowerPositionLimit);
}

godot::PackedFloat64Array PinocchioModel::get_joint_upper_limits() const {
    return to_godot(impl->model.upperPositionLimit);
}

godot::PackedFloat64Array PinocchioModel::project_to_joint_limits(
        const godot::PackedFloat64Array &q) const {
    godot::PackedFloat64Array out = q;
    const int nq = impl->model.nq;
    if (out.size() != nq) {
        return out;
    }
    const Eigen::VectorXd &lo = impl->model.lowerPositionLimit;
    const Eigen::VectorXd &hi = impl->model.upperPositionLimit;
    for (int i = 0; i < nq; ++i) {
        out[i] = std::clamp(static_cast<double>(out[i]), lo(i), hi(i));
    }
    return out;
}

pinocchio::Model &PinocchioModel::native_model() { return impl->model; }
const pinocchio::Model &PinocchioModel::native_model() const { return impl->model; }

void PinocchioModel::_bind_methods() {
    using godot::ClassDB;
    using godot::D_METHOD;

    ClassDB::bind_method(
            D_METHOD("add_revolute_joint", "parent_id", "name", "axis",
                     "placement", "lower_q", "upper_q"),
            &PinocchioModel::add_revolute_joint);
    ClassDB::bind_method(
            D_METHOD("add_prismatic_joint", "parent_id", "name", "axis",
                     "placement", "lower_q", "upper_q"),
            &PinocchioModel::add_prismatic_joint);
    ClassDB::bind_method(
            D_METHOD("add_frame", "parent_joint_id", "name", "placement"),
            &PinocchioModel::add_frame);
    ClassDB::bind_method(
            D_METHOD("append_body_to_joint", "joint_id", "mass", "com",
                     "inertia_diag"),
            &PinocchioModel::append_body_to_joint);
    ClassDB::bind_method(D_METHOD("set_gravity", "g"),
                         &PinocchioModel::set_gravity);

    ClassDB::bind_method(D_METHOD("get_nq"), &PinocchioModel::get_nq);
    ClassDB::bind_method(D_METHOD("get_nv"), &PinocchioModel::get_nv);
    ClassDB::bind_method(D_METHOD("get_njoints"), &PinocchioModel::get_njoints);
    ClassDB::bind_method(D_METHOD("get_nframes"), &PinocchioModel::get_nframes);
    ClassDB::bind_method(D_METHOD("get_frame_id", "name"),
                         &PinocchioModel::get_frame_id);
    ClassDB::bind_method(D_METHOD("get_joint_id", "name"),
                         &PinocchioModel::get_joint_id);
    ClassDB::bind_method(D_METHOD("get_frame_previous_frame", "frame_id"),
                         &PinocchioModel::get_frame_previous_frame);
    ClassDB::bind_method(D_METHOD("get_neutral_q"),
                         &PinocchioModel::get_neutral_q);
    ClassDB::bind_method(D_METHOD("get_joint_lower_limits"),
                         &PinocchioModel::get_joint_lower_limits);
    ClassDB::bind_method(D_METHOD("get_joint_upper_limits"),
                         &PinocchioModel::get_joint_upper_limits);
    ClassDB::bind_method(D_METHOD("project_to_joint_limits", "q"),
                         &PinocchioModel::project_to_joint_limits);
}

} // namespace operator_xr
