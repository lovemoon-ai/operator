#include "mujoco_backend.hpp"

#include <mujoco/mujoco.h>

#include <stdexcept>

#include "lie.hpp"

MujocoBackend::MujocoBackend(const std::string& robot_xml) {
  char error[1000] = "";
  m_ = mj_loadXML(robot_xml.c_str(), nullptr, error, sizeof(error));
  if (!m_) throw std::runtime_error(std::string("mj_loadXML failed: ") + error);
  d_ = mj_makeData(m_);
  dt_ = m_->opt.timestep;

  for (int j = 0; j < m_->njnt; ++j) {
    int jtype = m_->jnt_type[j];
    if (jtype == mjJNT_FREE || !m_->jnt_limited[j]) continue;
    // hinge/slide: single DoF
    LimitedDof ld;
    ld.qposadr = m_->jnt_qposadr[j];
    ld.dofadr = m_->jnt_dofadr[j];
    ld.lo = m_->jnt_range[2 * j + 0];
    ld.hi = m_->jnt_range[2 * j + 1];
    limited_.push_back(ld);
  }

  mju_copy(d_->qpos, m_->qpos0, m_->nq);
  set_qpos(qpos0());
}

MujocoBackend::~MujocoBackend() {
  if (d_) mj_deleteData(d_);
  if (m_) mj_deleteModel(m_);
}

int MujocoBackend::nq() const { return m_->nq; }
int MujocoBackend::nv() const { return m_->nv; }

Eigen::VectorXd MujocoBackend::qpos0() const {
  Eigen::VectorXd q(m_->nq);
  for (int i = 0; i < m_->nq; ++i) q[i] = m_->qpos0[i];
  return q;
}

int MujocoBackend::body_handle(const std::string& name) const {
  int id = mj_name2id(m_, mjOBJ_BODY, name.c_str());
  if (id < 0) throw std::runtime_error("unknown body: " + name);
  return id;
}

void MujocoBackend::set_qpos(const Eigen::VectorXd& qpos) {
  for (int i = 0; i < m_->nq; ++i) d_->qpos[i] = qpos[i];
  mj_kinematics(m_, d_);
  mj_comPos(m_, d_);
}

void MujocoBackend::frame_pose(int handle, Eigen::Matrix<double, 7, 1>& out7) const {
  double frame7[7];
  lie::xmat_xpos_to_wxyz_xyz(d_->xmat + 9 * handle, d_->xpos + 3 * handle, frame7);
  for (int i = 0; i < 7; ++i) out7[i] = frame7[i];
}

void MujocoBackend::frame_jacobian(int handle, Eigen::MatrixXd& jac6) const {
  const int nv = m_->nv;
  std::vector<double> jacp(3 * nv), jacr(3 * nv);
  mj_jacBody(m_, d_, jacp.data(), jacr.data(), handle);
  Eigen::MatrixXd jac(6, nv);
  for (int c = 0; c < nv; ++c) {
    for (int r = 0; r < 3; ++r) jac(r, c) = jacp[r * nv + c];
    for (int r = 0; r < 3; ++r) jac(3 + r, c) = jacr[r * nv + c];
  }
  double adj[36];
  lie::se3_rotation_adjoint_from_xmat(d_->xmat + 9 * handle, adj);
  Eigen::Matrix<double, 6, 6> A;
  for (int i = 0; i < 6; ++i)
    for (int j = 0; j < 6; ++j) A(i, j) = adj[6 * i + j];
  jac6 = A * jac;
}

Eigen::VectorXd MujocoBackend::integrate(const Eigen::VectorXd& qpos,
                                         const Eigen::VectorXd& v, double dt) const {
  std::vector<double> q(m_->nq), vel(m_->nv);
  for (int i = 0; i < m_->nq; ++i) q[i] = qpos[i];
  for (int i = 0; i < m_->nv; ++i) vel[i] = v[i];
  mj_integratePos(m_, q.data(), vel.data(), dt);
  Eigen::VectorXd out(m_->nq);
  for (int i = 0; i < m_->nq; ++i) out[i] = q[i];
  return out;
}
