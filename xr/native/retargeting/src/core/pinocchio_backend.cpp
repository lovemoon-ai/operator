#include "pinocchio_backend.hpp"

#include <cmath>
#include <fstream>
#include <limits>
#include <stdexcept>

#include <pinocchio/parsers/mjcf.hpp>
#include <pinocchio/algorithm/kinematics.hpp>
#include <pinocchio/algorithm/frames.hpp>
#include <pinocchio/algorithm/jacobian.hpp>
#include <pinocchio/algorithm/joint-configuration.hpp>

#include "lie.hpp"

namespace {
// quaternion (w,x,y,z) Hamilton product
void qmul_wxyz(double* out, const double* a, const double* b) {
  out[0] = a[0]*b[0] - a[1]*b[1] - a[2]*b[2] - a[3]*b[3];
  out[1] = a[0]*b[1] + a[1]*b[0] + a[2]*b[3] - a[3]*b[2];
  out[2] = a[0]*b[2] - a[1]*b[3] + a[2]*b[0] + a[3]*b[1];
  out[3] = a[0]*b[3] + a[1]*b[2] - a[2]*b[1] + a[3]*b[0];
}
// Replicate MuJoCo mju_quatIntegrate: quat <- normalize(quat (x) axisAngle(vel*dt)).
// vel is the body-local angular velocity; dt the timestep.
void quat_integrate(double* quat /*wxyz*/, const double* vel, double dt) {
  double n = std::sqrt(vel[0]*vel[0] + vel[1]*vel[1] + vel[2]*vel[2]);
  double angle = dt * n;
  if (angle < 1e-13) return;  // no rotation
  double axis[3] = {vel[0]/n, vel[1]/n, vel[2]/n};
  double s = std::sin(0.5 * angle), c = std::cos(0.5 * angle);
  double dq[4] = {c, s*axis[0], s*axis[1], s*axis[2]};
  double res[4];
  qmul_wxyz(res, quat, dq);
  double rn = std::sqrt(res[0]*res[0] + res[1]*res[1] + res[2]*res[2] + res[3]*res[3]);
  for (int i = 0; i < 4; ++i) quat[i] = res[i] / rn;
}
}  // namespace

PinocchioBackend::PinocchioBackend(const std::string& robot_xml) : data_(pinocchio::Model()) {
  // Clean the MJCF (drop the scene-only second <worldbody> that the parser
  // duplicates) and write it next to the original so meshdir resolves.
  std::ifstream xf(robot_xml);
  if (!xf) throw std::runtime_error("cannot open " + robot_xml);
  std::string content((std::istreambuf_iterator<char>(xf)), std::istreambuf_iterator<char>());
  const std::string close = "</worldbody>";
  size_t pos = content.find(close);
  if (pos == std::string::npos) throw std::runtime_error("no </worldbody> in MJCF");
  std::string cleaned = content.substr(0, pos + close.size()) + "\n</mujoco>";
  std::string dir = robot_xml.substr(0, robot_xml.find_last_of('/') + 1);
  std::string tmp = dir + ".g1_pinocchio_tmp.xml";
  { std::ofstream o(tmp); o << cleaned; }

  pinocchio::mjcf::buildModel(tmp, model_);
  data_ = pinocchio::Data(model_);

  R_jp_ = model_.jointPlacements[1].rotation();
  t_jp_ = model_.jointPlacements[1].translation();

  // Joint structure: free-flyer at joint 1, hinges after. Build limited + hinge
  // lists indexed by MuJoCo-convention qpos/dof addresses (== Pinocchio idx_q/idx_v).
  const double big = 1e29;
  for (int j = 1; j < model_.njoints; ++j) {
    int nqj = model_.nqs[j], nvj = model_.nvs[j];
    int idx_q = model_.idx_qs[j], idx_v = model_.idx_vs[j];
    if (nqj == 1 && nvj == 1) {
      hinge_dofs_.emplace_back(idx_q, idx_v);
      double lo = model_.lowerPositionLimit[idx_q];
      double hi = model_.upperPositionLimit[idx_q];
      if (std::abs(lo) < big && std::abs(hi) < big) {
        limited_.push_back({idx_q, idx_v, lo, hi});
      }
    }
  }

  // MuJoCo qpos0: base = world pose of the free-flyer at Pinocchio neutral
  // (= jointPlacement[1]); hinge joints = 0.
  qpos0_ = Eigen::VectorXd::Zero(model_.nq);
  qpos0_[0] = t_jp_[0]; qpos0_[1] = t_jp_[1]; qpos0_[2] = t_jp_[2];
  Eigen::Quaterniond q0(R_jp_);
  qpos0_[3] = q0.w(); qpos0_[4] = q0.x(); qpos0_[5] = q0.y(); qpos0_[6] = q0.z();

  set_qpos(qpos0_);
}

int PinocchioBackend::body_handle(const std::string& name) const {
  if (!model_.existFrame(name, pinocchio::BODY))
    throw std::runtime_error("unknown body: " + name);
  return static_cast<int>(model_.getFrameId(name, pinocchio::BODY));
}

Eigen::VectorXd PinocchioBackend::mj_to_pin(const Eigen::VectorXd& qpos) const {
  Eigen::VectorXd q(model_.nq);
  Eigen::Vector3d mj_pos = qpos.segment<3>(0);
  Eigen::Quaterniond mj_q(qpos[3], qpos[4], qpos[5], qpos[6]);  // wxyz
  Eigen::Vector3d qb = R_jp_.transpose() * (mj_pos - t_jp_);
  Eigen::Quaterniond qq(R_jp_.transpose() * mj_q.toRotationMatrix());
  q[0] = qb[0]; q[1] = qb[1]; q[2] = qb[2];
  q[3] = qq.x(); q[4] = qq.y(); q[5] = qq.z(); q[6] = qq.w();  // xyzw
  for (int i = 7; i < model_.nq; ++i) q[i] = qpos[i];
  return q;
}

void PinocchioBackend::set_qpos(const Eigen::VectorXd& qpos) {
  Eigen::VectorXd q = mj_to_pin(qpos);
  pinocchio::forwardKinematics(model_, data_, q);
  pinocchio::updateFramePlacements(model_, data_);
  pinocchio::computeJointJacobians(model_, data_, q);
}

void PinocchioBackend::frame_pose(int handle, Eigen::Matrix<double, 7, 1>& out7) const {
  const auto& oMf = data_.oMf[handle];
  const Eigen::Matrix3d& R = oMf.rotation();
  Eigen::Vector3d t = oMf.translation();
  double rm[9];  // row-major rotation, like MuJoCo xmat
  for (int i = 0; i < 3; ++i)
    for (int j = 0; j < 3; ++j) rm[3 * i + j] = R(i, j);
  double xpos[3] = {t[0], t[1], t[2]};
  double frame7[7];
  lie::xmat_xpos_to_wxyz_xyz(rm, xpos, frame7);  // same quat extraction as MuJoCo path
  for (int i = 0; i < 7; ++i) out7[i] = frame7[i];
}

void PinocchioBackend::frame_jacobian(int handle, Eigen::MatrixXd& jac6) const {
  pinocchio::Data::Matrix6x J(6, model_.nv);
  J.setZero();
  pinocchio::getFrameJacobian(model_, data_, handle, pinocchio::LOCAL, J);
  // MuJoCo's free-joint linear velocity (qvel[0:3]) is in the WORLD frame, while
  // Pinocchio's free-flyer linear velocity is in the joint-local frame. The two
  // differ by the base world rotation, so re-express the 3 base-linear columns
  // in world coordinates: J_world[:,0:3] = J_local[:,0:3] * R_base^T.
  if (has_free_base_) {
    const Eigen::Matrix3d& R_base = data_.oMi[1].rotation();
    J.leftCols<3>() = J.leftCols<3>() * R_base.transpose();
  }
  jac6 = J;
}

Eigen::VectorXd PinocchioBackend::integrate(const Eigen::VectorXd& qpos,
                                            const Eigen::VectorXd& v, double dt) const {
  Eigen::VectorXd out = qpos;
  if (has_free_base_) {
    out[0] = qpos[0] + dt * v[0];  // global linear velocity
    out[1] = qpos[1] + dt * v[1];
    out[2] = qpos[2] + dt * v[2];
    double quat[4] = {qpos[3], qpos[4], qpos[5], qpos[6]};
    double w[3] = {v[3], v[4], v[5]};  // local angular velocity
    quat_integrate(quat, w, dt);
    out[3] = quat[0]; out[4] = quat[1]; out[5] = quat[2]; out[6] = quat[3];
  }
  for (auto& [qadr, dadr] : hinge_dofs_) out[qadr] = qpos[qadr] + dt * v[dadr];
  return out;
}
