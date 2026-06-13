// Lie-group operations ported verbatim from mink's native _lie_ops_c.c.
// Quaternion convention is (w, x, y, z). SE3 is stored as wxyz_xyz[7].
#pragma once
#include <Eigen/Dense>

namespace lie {

// SE3 log map: wxyz_xyz[7] -> tangent[6] = [v; omega].
void se3_log(const double* wxyz_xyz, double* tangent);

// Compute (a^{-1} @ b): a[7], b[7] -> out[7].
void se3_inverse_multiply(const double* a, const double* b, double* out);

// SE3 rminus: a.rminus(b) = (b^{-1} @ a).log() -> tangent[6].
void se3_rminus(const double* a, const double* b, double* tangent);

// SE3 jlog: rjacinv(log(T)) from wxyz_xyz[7] -> 6x6 row-major.
void se3_jlog(const double* wxyz_xyz, double* jlog36);

// Adjoint of pure rotation T_fw from MuJoCo xmat[9] (row-major R_wf) -> 6x6.
void se3_rotation_adjoint_from_xmat(const double* xmat, double* adj36);

// Convert MuJoCo xmat[9] + xpos[3] to SE3 wxyz_xyz[7].
void xmat_xpos_to_wxyz_xyz(const double* xmat, const double* xpos, double* out7);

// Convenience Eigen wrappers.
inline Eigen::Matrix<double, 6, 1> se3_rminus(const Eigen::Matrix<double, 7, 1>& a,
                                              const Eigen::Matrix<double, 7, 1>& b) {
  Eigen::Matrix<double, 6, 1> t;
  se3_rminus(a.data(), b.data(), t.data());
  return t;
}

}  // namespace lie
