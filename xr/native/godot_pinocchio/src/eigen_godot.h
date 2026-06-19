// eigen_godot.h — Eigen + pinocchio::SE3 ↔ Godot type conversions.
//
// Header-only on purpose: every translation unit that touches Pinocchio
// already drags in <pinocchio/...>, so there's no incremental cost.
//
// Conventions, once and for all:
//   * Godot Basis storage is row-major and indexed as basis[i][j] = R(i, j).
//     The Basis(x_axis, y_axis, z_axis) ctor takes COLUMN vectors of the
//     rotated frame, which is what you'd intuitively reach for first;
//     using rows[i] = Vector3(...) directly avoids that ambiguity.
//   * Pinocchio SE3 stores rotation as Eigen::Matrix3d (column-major) and
//     translation as Eigen::Vector3d.
//   * Eigen vectors are dynamic-size doubles; we always copy through
//     PackedFloat64Array. The vectors involved here are O(joints), so
//     malloc-per-call is fine.

#pragma once

#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <Eigen/Core>
#include <pinocchio/spatial/se3.hpp>

namespace operator_xr {

// ---- Vector3 ----------------------------------------------------------------

inline Eigen::Vector3d to_eigen(const godot::Vector3 &v) {
    return Eigen::Vector3d(v.x, v.y, v.z);
}

inline godot::Vector3 to_godot(const Eigen::Vector3d &v) {
    return godot::Vector3(
            static_cast<real_t>(v.x()),
            static_cast<real_t>(v.y()),
            static_cast<real_t>(v.z()));
}

// ---- VectorXd <-> PackedFloat64Array ---------------------------------------

inline Eigen::VectorXd to_eigen(const godot::PackedFloat64Array &arr) {
    // PackedFloat64Array::size() is int64_t; Eigen::Index is ptrdiff_t.
    // Use Eigen::Index throughout so -Wsign-compare stays quiet and we
    // don't truncate on 64-bit indices (not realistic here, but free).
    const Eigen::Index n = static_cast<Eigen::Index>(arr.size());
    Eigen::VectorXd out(n);
    for (Eigen::Index i = 0; i < n; ++i) {
        out(i) = arr[i];
    }
    return out;
}

inline godot::PackedFloat64Array to_godot(const Eigen::VectorXd &v) {
    godot::PackedFloat64Array out;
    out.resize(v.size());
    for (Eigen::Index i = 0; i < v.size(); ++i) {
        out[i] = v(i);
    }
    return out;
}

// Flatten a row-major matrix into a 1-D PackedFloat64Array of size rows*cols.
// Used for Jacobians (6 x nv) and the mass matrix (nv x nv).
inline godot::PackedFloat64Array to_godot_rowmajor(const Eigen::MatrixXd &m) {
    godot::PackedFloat64Array out;
    out.resize(m.rows() * m.cols());
    Eigen::Index idx = 0;
    for (Eigen::Index i = 0; i < m.rows(); ++i) {
        for (Eigen::Index j = 0; j < m.cols(); ++j) {
            out[idx++] = m(i, j);
        }
    }
    return out;
}

// ---- pinocchio::SE3 <-> Godot Transform3D ---------------------------------

inline pinocchio::SE3 to_pinocchio(const godot::Transform3D &xform) {
    Eigen::Matrix3d R;
    // Godot Basis: row-major, basis[i][j] = R(i, j). godot-cpp exposes
    // rows[3] as Vector3; we read .x/.y/.z to grab each column entry.
    R(0, 0) = xform.basis[0].x; R(0, 1) = xform.basis[0].y; R(0, 2) = xform.basis[0].z;
    R(1, 0) = xform.basis[1].x; R(1, 1) = xform.basis[1].y; R(1, 2) = xform.basis[1].z;
    R(2, 0) = xform.basis[2].x; R(2, 1) = xform.basis[2].y; R(2, 2) = xform.basis[2].z;
    Eigen::Vector3d t(xform.origin.x, xform.origin.y, xform.origin.z);
    return pinocchio::SE3(R, t);
}

inline godot::Transform3D to_godot(const pinocchio::SE3 &xform) {
    const Eigen::Matrix3d &R = xform.rotation();
    const Eigen::Vector3d &t = xform.translation();
    godot::Transform3D out;
    out.basis[0] = godot::Vector3(R(0, 0), R(0, 1), R(0, 2));
    out.basis[1] = godot::Vector3(R(1, 0), R(1, 1), R(1, 2));
    out.basis[2] = godot::Vector3(R(2, 0), R(2, 1), R(2, 2));
    out.origin = godot::Vector3(t.x(), t.y(), t.z());
    return out;
}

} // namespace operator_xr
