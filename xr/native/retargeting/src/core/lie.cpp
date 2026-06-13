// Ported verbatim from mink/lie/_lie_ops_c.c (the native code mink runs by
// default). All math is identical; only the Python/numpy glue is removed.
#include "lie.hpp"
#include <cmath>

namespace lie {
namespace {

constexpr double EPS = 1e-10;

inline double vec3_dot(const double* a, const double* b) {
  return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}
inline double vec3_norm(const double* v) { return std::sqrt(vec3_dot(v, v)); }
inline double vec3_normalize(double* v) {
  double n = vec3_norm(v);
  if (n > 0.0) {
    double inv = 1.0 / n;
    v[0] *= inv; v[1] *= inv; v[2] *= inv;
  }
  return n;
}
inline void quat_neg(double* out, const double* q) {
  out[0] = q[0]; out[1] = -q[1]; out[2] = -q[2]; out[3] = -q[3];
}
inline void quat_mul(double* out, const double* a, const double* b) {
  out[0] = a[0]*b[0] - a[1]*b[1] - a[2]*b[2] - a[3]*b[3];
  out[1] = a[0]*b[1] + a[1]*b[0] + a[2]*b[3] - a[3]*b[2];
  out[2] = a[0]*b[2] - a[1]*b[3] + a[2]*b[0] + a[3]*b[1];
  out[3] = a[0]*b[3] + a[1]*b[2] - a[2]*b[1] + a[3]*b[0];
}
inline void quat_rotate(double* out, const double* v, const double* q) {
  double w = q[0], x = q[1], y = q[2], z = q[3];
  double tx = 2.0 * (y*v[2] - z*v[1]);
  double ty = 2.0 * (z*v[0] - x*v[2]);
  double tz = 2.0 * (x*v[1] - y*v[0]);
  out[0] = v[0] + w*tx + (y*tz - z*ty);
  out[1] = v[1] + w*ty + (z*tx - x*tz);
  out[2] = v[2] + w*tz + (x*ty - y*tx);
}
inline void skew3(double* out, const double* v) {
  out[0] = 0.0;   out[1] = -v[2]; out[2] = v[1];
  out[3] = v[2];  out[4] = 0.0;   out[5] = -v[0];
  out[6] = -v[1]; out[7] = v[0];  out[8] = 0.0;
}
inline void mat33_mul(double* C, const double* A, const double* B) {
  for (int i = 0; i < 3; i++)
    for (int j = 0; j < 3; j++)
      C[3*i+j] = A[3*i+0]*B[0*3+j] + A[3*i+1]*B[1*3+j] + A[3*i+2]*B[2*3+j];
}
inline void mat33_transpose(double* out, const double* in) {
  out[0] = in[0]; out[1] = in[3]; out[2] = in[6];
  out[3] = in[1]; out[4] = in[4]; out[5] = in[7];
  out[6] = in[2]; out[7] = in[5]; out[8] = in[8];
}

void so3_log(double* omega, const double* wxyz) {
  double q[4] = {wxyz[0], wxyz[1], wxyz[2], wxyz[3]};
  if (q[0] < 0.0) { q[0] = -q[0]; q[1] = -q[1]; q[2] = -q[2]; q[3] = -q[3]; }
  double v[3] = {q[1], q[2], q[3]};
  double norm = vec3_normalize(v);
  if (norm < EPS) { omega[0] = omega[1] = omega[2] = 0.0; return; }
  double angle = 2.0 * std::atan2(norm, q[0]);
  omega[0] = angle * v[0];
  omega[1] = angle * v[1];
  omega[2] = angle * v[2];
}

void so3_ljacinv(double* out, const double* omega) {
  double theta = vec3_norm(omega);
  double t2 = theta * theta;
  double beta;
  if (theta < EPS) {
    beta = (1.0/12.0) * (1.0 + t2/60.0 * (1.0 + t2/42.0 * (1.0 + t2/40.0)));
  } else {
    beta = (1.0/t2) * (1.0 - (theta * std::sin(theta) / (2.0 * (1.0 - std::cos(theta)))));
  }
  double inner = vec3_dot(omega, omega);
  for (int i = 0; i < 3; i++)
    for (int j = 0; j < 3; j++)
      out[3*i+j] = beta * (omega[i]*omega[j] - (i == j ? inner : 0.0));
  double a[3] = {-0.5*omega[0], -0.5*omega[1], -0.5*omega[2]};
  out[0*3+1] += -a[2]; out[0*3+2] += a[1];
  out[1*3+0] += a[2];  out[1*3+2] += -a[0];
  out[2*3+0] += -a[1]; out[2*3+1] += a[0];
  out[0] += 1.0; out[4] += 1.0; out[8] += 1.0;
}

void mat33_to_quat(double* wxyz, const double* R) {
  double tr = R[0] + R[4] + R[8];
  if (tr > 0.0) {
    double s = std::sqrt(tr + 1.0) * 2.0;
    wxyz[0] = 0.25 * s;
    wxyz[1] = (R[7] - R[5]) / s;
    wxyz[2] = (R[2] - R[6]) / s;
    wxyz[3] = (R[3] - R[1]) / s;
  } else if (R[0] > R[4] && R[0] > R[8]) {
    double s = std::sqrt(1.0 + R[0] - R[4] - R[8]) * 2.0;
    wxyz[0] = (R[7] - R[5]) / s;
    wxyz[1] = 0.25 * s;
    wxyz[2] = (R[1] + R[3]) / s;
    wxyz[3] = (R[2] + R[6]) / s;
  } else if (R[4] > R[8]) {
    double s = std::sqrt(1.0 + R[4] - R[0] - R[8]) * 2.0;
    wxyz[0] = (R[2] - R[6]) / s;
    wxyz[1] = (R[1] + R[3]) / s;
    wxyz[2] = 0.25 * s;
    wxyz[3] = (R[5] + R[7]) / s;
  } else {
    double s = std::sqrt(1.0 + R[8] - R[0] - R[4]) * 2.0;
    wxyz[0] = (R[3] - R[1]) / s;
    wxyz[1] = (R[2] + R[6]) / s;
    wxyz[2] = (R[5] + R[7]) / s;
    wxyz[3] = 0.25 * s;
  }
  double n = std::sqrt(wxyz[0]*wxyz[0] + wxyz[1]*wxyz[1] + wxyz[2]*wxyz[2] + wxyz[3]*wxyz[3]);
  if (n > 0.0) {
    double inv = 1.0 / n;
    wxyz[0] *= inv; wxyz[1] *= inv; wxyz[2] *= inv; wxyz[3] *= inv;
  }
}

void se3_log_impl(double* tangent, const double* wxyz_xyz) {
  double omega[3];
  so3_log(omega, wxyz_xyz);
  double theta = vec3_norm(omega);
  double t2 = theta * theta;
  double skw[9], skw2[9], vinv[9];
  skew3(skw, omega);
  mat33_mul(skw2, skw, skw);
  if (t2 < EPS) {
    for (int i = 0; i < 9; i++) vinv[i] = -0.5 * skw[i] + skw2[i] / 12.0;
    vinv[0] += 1.0; vinv[4] += 1.0; vinv[8] += 1.0;
  } else {
    double half = 0.5 * theta;
    double coeff = (1.0 - 0.5 * theta * std::cos(half) / std::sin(half)) / t2;
    for (int i = 0; i < 9; i++) vinv[i] = -0.5 * skw[i] + coeff * skw2[i];
    vinv[0] += 1.0; vinv[4] += 1.0; vinv[8] += 1.0;
  }
  const double* t = wxyz_xyz + 4;
  tangent[0] = vinv[0]*t[0] + vinv[1]*t[1] + vinv[2]*t[2];
  tangent[1] = vinv[3]*t[0] + vinv[4]*t[1] + vinv[5]*t[2];
  tangent[2] = vinv[6]*t[0] + vinv[7]*t[1] + vinv[8]*t[2];
  tangent[3] = omega[0];
  tangent[4] = omega[1];
  tangent[5] = omega[2];
}

void se3_inverse_multiply_impl(double* out, const double* a, const double* b) {
  double inv_q[4];
  quat_neg(inv_q, a);
  double neg_t[3] = {-a[4], -a[5], -a[6]};
  double inv_t[3];
  quat_rotate(inv_t, neg_t, inv_q);
  quat_mul(out, inv_q, b);
  double rotated[3];
  quat_rotate(rotated, b + 4, inv_q);
  out[4] = rotated[0] + inv_t[0];
  out[5] = rotated[1] + inv_t[1];
  out[6] = rotated[2] + inv_t[2];
}

void getQ(double* Q, const double* c) {
  const double* v = c;
  const double* w = c + 3;
  double theta = vec3_norm(w);
  double t2 = theta * theta;
  double A = 0.5, B, C, D;
  if (t2 < EPS) {
    B = (1.0/6.0) + (1.0/120.0) * t2;
    C = -(1.0/24.0) + (1.0/720.0) * t2;
    D = -(1.0/60.0);
  } else {
    double t4 = t2 * t2;
    double st = std::sin(theta);
    double ct = std::cos(theta);
    B = (theta - st) / (t2 * theta);
    C = (1.0 - 0.5*t2 - ct) / t4;
    D = (2.0*theta - 3.0*st + theta*ct) / (2.0 * t4 * theta);
  }
  double V[9], W[9];
  skew3(V, v);
  skew3(W, w);
  double VW[9], WV[9], WVW[9], VWW[9], VWW_T[9], WVWW[9], WWVW[9];
  mat33_mul(VW, V, W);
  mat33_transpose(WV, VW);
  mat33_mul(WVW, WV, W);
  mat33_mul(VWW, VW, W);
  mat33_transpose(VWW_T, VWW);
  mat33_mul(WVWW, WVW, W);
  mat33_mul(WWVW, W, WVW);
  for (int i = 0; i < 9; i++)
    Q[i] = A*V[i] + B*(WV[i]+VW[i]+WVW[i]) - C*(VWW[i]-VWW_T[i]-3.0*WVW[i]) + D*(WVWW[i]+WWVW[i]);
}

void quat_to_mat33(double* R, const double* q) {
  double w = q[0], x = q[1], y = q[2], z = q[3];
  double x2 = x*x, y2 = y*y, z2 = z*z;
  double xy = x*y, xz = x*z, yz = y*z;
  double wx = w*x, wy = w*y, wz = w*z;
  R[0] = 1.0 - 2.0*(y2 + z2); R[1] = 2.0*(xy - wz);       R[2] = 2.0*(xz + wy);
  R[3] = 2.0*(xy + wz);       R[4] = 1.0 - 2.0*(x2 + z2); R[5] = 2.0*(yz - wx);
  R[6] = 2.0*(xz - wy);       R[7] = 2.0*(yz + wx);       R[8] = 1.0 - 2.0*(x2 + y2);
}

}  // namespace

void se3_log(const double* wxyz_xyz, double* tangent) { se3_log_impl(tangent, wxyz_xyz); }

void se3_inverse_multiply(const double* a, const double* b, double* out) {
  se3_inverse_multiply_impl(out, a, b);
}

void se3_rminus(const double* a, const double* b, double* tangent) {
  double temp[7];
  se3_inverse_multiply_impl(temp, b, a);
  se3_log_impl(tangent, temp);
}

void se3_jlog(const double* wxyz_xyz, double* jlog) {
  double tangent[6];
  se3_log_impl(tangent, wxyz_xyz);
  double neg[6] = {-tangent[0], -tangent[1], -tangent[2],
                   -tangent[3], -tangent[4], -tangent[5]};
  double theta_sq = vec3_dot(neg + 3, neg + 3);
  if (theta_sq < EPS) {
    for (int i = 0; i < 36; i++) jlog[i] = 0.0;
    for (int i = 0; i < 6; i++) jlog[7*i] = 1.0;
    return;
  }
  for (int i = 0; i < 36; i++) jlog[i] = 0.0;
  double Qmat[9];
  getQ(Qmat, neg);
  double lji[9];
  so3_ljacinv(lji, neg + 3);
  for (int i = 0; i < 3; i++)
    for (int j = 0; j < 3; j++)
      jlog[6*i+j] = lji[3*i+j];
  for (int i = 0; i < 3; i++)
    for (int j = 0; j < 3; j++)
      jlog[6*(i+3)+(j+3)] = lji[3*i+j];
  double QJ[9], JQJ[9];
  mat33_mul(QJ, Qmat, lji);
  mat33_mul(JQJ, lji, QJ);
  for (int i = 0; i < 3; i++)
    for (int j = 0; j < 3; j++)
      jlog[6*i+(j+3)] = -JQJ[3*i+j];
}

void se3_rotation_adjoint_from_xmat(const double* xmat, double* adj) {
  double Rt[9];
  mat33_transpose(Rt, xmat);
  for (int i = 0; i < 36; i++) adj[i] = 0.0;
  for (int i = 0; i < 3; i++)
    for (int j = 0; j < 3; j++) {
      adj[6*i+j] = Rt[3*i+j];
      adj[6*(i+3)+(j+3)] = Rt[3*i+j];
    }
}

void xmat_xpos_to_wxyz_xyz(const double* xmat, const double* xpos, double* out) {
  mat33_to_quat(out, xmat);
  out[4] = xpos[0];
  out[5] = xpos[1];
  out[6] = xpos[2];
}

}  // namespace lie
