#include "gmr_solver.hpp"

#include <cmath>
#include <cstdlib>
#include <fstream>
#include <limits>
#include <stdexcept>

#include <nlohmann/json.hpp>

#include "box_qp.hpp"
#include "lie.hpp"
#ifndef RETARGETING_NO_PINOCCHIO
#include "pinocchio_backend.hpp"
#endif
#ifndef RETARGETING_NO_MUJOCO
#include "mujoco_backend.hpp"
#endif

using json = nlohmann::json;

namespace retargeting {
namespace gmr {

namespace {
Eigen::Vector4d qmul(const Eigen::Vector4d& a, const Eigen::Vector4d& b) {
  Eigen::Vector4d r;
  r[0] = a[0]*b[0] - a[1]*b[1] - a[2]*b[2] - a[3]*b[3];
  r[1] = a[0]*b[1] + a[1]*b[0] + a[2]*b[3] - a[3]*b[2];
  r[2] = a[0]*b[2] - a[1]*b[3] + a[2]*b[0] + a[3]*b[1];
  r[3] = a[0]*b[3] + a[1]*b[2] - a[2]*b[1] + a[3]*b[0];
  return r;
}
Eigen::Vector3d quat_apply(const Eigen::Vector4d& q, const Eigen::Vector3d& v) {
  double w = q[0], x = q[1], y = q[2], z = q[3];
  double tx = 2.0 * (y*v[2] - z*v[1]);
  double ty = 2.0 * (z*v[0] - x*v[2]);
  double tz = 2.0 * (x*v[1] - y*v[0]);
  return Eigen::Vector3d(v[0] + w*tx + (y*tz - z*ty),
                         v[1] + w*ty + (z*tx - x*tz),
                         v[2] + w*tz + (x*ty - y*tx));
}
}  // namespace

GmrSolver::GmrSolver(KinematicsBackendKind backend, const std::string& robot_xml,
                     const std::string& ik_config_json,
                     double actual_human_height, double damping)
    : damping_(damping) {
  if (backend == KinematicsBackendKind::Mujoco) {
#ifdef RETARGETING_NO_MUJOCO
    throw std::runtime_error(
        "MuJoCo backend not built (RETARGETING_NO_MUJOCO); rebuild with it.");
#else
    backend_ = std::make_unique<MujocoBackend>(robot_xml);
#endif
  } else {
#ifdef RETARGETING_NO_PINOCCHIO
    throw std::runtime_error(
        "Pinocchio backend not built (RETARGETING_NO_PINOCCHIO); rebuild with it.");
#else
    backend_ = std::make_unique<PinocchioBackend>(robot_xml);
#endif
  }
  dt_ = backend_->dt();

  std::ifstream f(ik_config_json);
  if (!f) throw std::runtime_error("cannot open ik config: " + ik_config_json);
  json cfg;
  f >> cfg;

  human_root_name_ = cfg["human_root_name"].get<std::string>();
  use_table1_ = cfg["use_ik_match_table1"].get<bool>();
  use_table2_ = cfg["use_ik_match_table2"].get<bool>();
  double assumption = cfg["human_height_assumption"].get<double>();
  double ratio = (actual_human_height > 0) ? actual_human_height / assumption : 1.0;
  double ground_height = cfg["ground_height"].get<double>();
  ground_ = ground_height * Eigen::Vector3d(0, 0, 1);

  for (auto& [name, val] : cfg["human_scale_table"].items())
    human_scale_table_[name] = val.get<double>() * ratio;

  auto build_table = [&](const char* key, std::vector<Task>& tasks,
                         std::map<std::string, Eigen::Vector3d>* pos_off,
                         std::map<std::string, Eigen::Vector4d>* rot_off) {
    for (auto& [frame_name, entry] : cfg[key].items()) {
      std::string body_name = entry[0].get<std::string>();
      double pos_w = entry[1].get<double>();
      double rot_w = entry[2].get<double>();
      std::vector<double> pos_offset = entry[3].get<std::vector<double>>();
      std::vector<double> rot_offset = entry[4].get<std::vector<double>>();
      if (pos_off) {
        Eigen::Vector3d po(pos_offset[0], pos_offset[1], pos_offset[2]);
        (*pos_off)[body_name] = po - ground_;
        (*rot_off)[body_name] =
            Eigen::Vector4d(rot_offset[0], rot_offset[1], rot_offset[2], rot_offset[3]);
      }
      if (pos_w != 0.0 || rot_w != 0.0) {
        Task t;
        t.frame_name = frame_name;
        t.human_body = body_name;
        t.handle = backend_->body_handle(frame_name);
        t.cost << pos_w, pos_w, pos_w, rot_w, rot_w, rot_w;
        t.gain = 1.0;
        t.lm_damping = 1.0;
        t.target.setZero();
        tasks.push_back(t);
      }
    }
  };
  build_table("ik_match_table1", tasks1_, &pos_offsets1_, &rot_offsets1_);
  build_table("ik_match_table2", tasks2_, nullptr, nullptr);

  qpos_ = backend_->qpos0();
  backend_->set_qpos(qpos_);
}

void GmrSolver::update_configuration(const Eigen::VectorXd& qpos) {
  qpos_ = qpos;
  backend_->set_qpos(qpos_);
}

void GmrSolver::lock_qpos_prefix(int n_qpos) {
  locked_qpos_count_ = n_qpos;
  if (n_qpos > 0) locked_qpos_ = qpos_.head(n_qpos);
}

void GmrSolver::set_clamp_qpos(const std::vector<int>& qpos_indices) {
  clamp_qpos_indices_ = qpos_indices;
  clamp_qpos_values_.resize(static_cast<int>(qpos_indices.size()));
  for (size_t i = 0; i < qpos_indices.size(); ++i)
    clamp_qpos_values_[static_cast<int>(i)] = qpos_[qpos_indices[i]];
}

void GmrSolver::reset_locked_region() {
  if (locked_qpos_count_ <= 0 && clamp_qpos_indices_.empty()) return;
  Eigen::VectorXd qpos = qpos_;
  if (locked_qpos_count_ > 0) qpos.head(locked_qpos_count_) = locked_qpos_;
  for (size_t i = 0; i < clamp_qpos_indices_.size(); ++i)
    qpos[clamp_qpos_indices_[i]] = clamp_qpos_values_[static_cast<int>(i)];
  update_configuration(qpos);
}

void GmrSolver::freeze_locked_region(Eigen::VectorXd& qpos) const {
  if (locked_qpos_count_ > 0) qpos.head(locked_qpos_count_) = locked_qpos_;
  for (size_t i = 0; i < clamp_qpos_indices_.size(); ++i)
    qpos[clamp_qpos_indices_[i]] = clamp_qpos_values_[static_cast<int>(i)];
}

std::map<std::string, Pose> GmrSolver::scale_human_data(
    const std::map<std::string, Pose>& human_data) const {
  const auto& root = human_data.at(human_root_name_);
  Eigen::Vector3d root_pos = root.pos;
  double root_scale = human_scale_table_.at(human_root_name_);
  Eigen::Vector3d scaled_root_pos = root_scale * root_pos;

  std::map<std::string, Pose> out;
  out[human_root_name_] = {scaled_root_pos, root.quat};
  for (const auto& [name, pose] : human_data) {
    auto it = human_scale_table_.find(name);
    if (it == human_scale_table_.end()) continue;
    if (name == human_root_name_) continue;
    Eigen::Vector3d local = (pose.pos - root_pos) * it->second;
    out[name] = {local + scaled_root_pos, pose.quat};
  }
  return out;
}

std::map<std::string, Pose> GmrSolver::offset_human_data(
    const std::map<std::string, Pose>& human_data) const {
  std::map<std::string, Pose> out;
  for (const auto& [name, pose] : human_data) {
    Eigen::Vector4d rot_off = rot_offsets1_.at(name);
    Eigen::Vector4d updated_quat = qmul(pose.quat, rot_off);
    Eigen::Vector3d local_offset = pos_offsets1_.at(name);
    Eigen::Vector3d global_pos_offset = quat_apply(updated_quat, local_offset);
    out[name] = {pose.pos + global_pos_offset, updated_quat};
  }
  return out;
}

void GmrSolver::update_targets(const SkeletonFrame& human_frame,
                               bool offset_to_ground) {
  std::map<std::string, Pose> data;
  for (const auto& [name, pose] : human_frame) data[name] = pose;
  data = scale_human_data(data);
  data = offset_human_data(data);
  for (auto& [name, pose] : data) pose.pos -= Eigen::Vector3d(0, 0, ground_offset_);
  (void)offset_to_ground;
  scaled_human_data_ = data;

  auto set_targets = [&](std::vector<Task>& tasks) {
    for (auto& t : tasks) {
      const auto& pose = data.at(t.human_body);
      t.target << pose.quat[0], pose.quat[1], pose.quat[2], pose.quat[3], pose.pos[0],
          pose.pos[1], pose.pos[2];
      t.has_target = true;
    }
  };
  if (use_table1_) set_targets(tasks1_);
  if (use_table2_) set_targets(tasks2_);
}

double GmrSolver::table_error(const std::vector<Task>& tasks) const {
  double sumsq = 0.0;
  for (const auto& t : tasks) {
    Eigen::Matrix<double, 7, 1> frame7;
    backend_->frame_pose(t.handle, frame7);
    Eigen::Matrix<double, 6, 1> e = lie::se3_rminus(t.target, frame7);
    sumsq += e.squaredNorm();
  }
  return std::sqrt(sumsq);
}

void GmrSolver::compute_box_bounds(Eigen::VectorXd& lb, Eigen::VectorXd& ub) const {
  const int nv = backend_->nv();
  const double kInf = std::numeric_limits<double>::infinity();
  lb = Eigen::VectorXd::Constant(nv, -kInf);
  ub = Eigen::VectorXd::Constant(nv, kInf);

  // ConfigurationLimit: for each limited single-DoF joint, the increment is
  // bounded by gain*(hi - q) above and gain*(q - lo) below. This matches mink's
  // mj_differentiatePos-based bounds for hinge/slide joints.
  for (const auto& ld : backend_->limited_dofs()) {
    double q = qpos_[ld.qposadr];
    double p_max = config_gain_ * (ld.hi - q);
    double p_min = config_gain_ * (q - ld.lo);
    ub[ld.dofadr] = std::min(ub[ld.dofadr], p_max);
    lb[ld.dofadr] = std::max(lb[ld.dofadr], -p_min);
  }
  // NOTE: the original Python pipeline's FrozenTangentLimit is passed to
  // solve_ik as `safety_break`, not `limits`, so it is never applied inside the
  // QP. We replicate that: the locked region is free during the solve and only
  // clamped afterwards by freeze_locked_region(). (See README.)
  // Optionally pin the locked region DURING the solve (not just clamp it after),
  // so the IK puts all the work into the free joints. For an upper-body overlay
  // this keeps the torso/waist upright instead of letting the QP tilt it to help
  // the arms reach (which made the torso fall back when the hands were raised).
  if (freeze_locked_in_solve_ && locked_qpos_count_ > 0) {
    int n_locked_dofs = locked_qpos_count_ - 1;  // one free base joint (7 qpos, 6 dof)
    for (int d = 0; d < n_locked_dofs && d < nv; ++d) { lb[d] = 0.0; ub[d] = 0.0; }
  }
}

Eigen::VectorXd GmrSolver::solve_ik(const std::vector<Task>& tasks) const {
  const int nv = backend_->nv();
  Eigen::MatrixXd H = damping_ * Eigen::MatrixXd::Identity(nv, nv);
  Eigen::VectorXd c = Eigen::VectorXd::Zero(nv);

  for (const auto& t : tasks) {
    Eigen::Matrix<double, 7, 1> frame7;
    backend_->frame_pose(t.handle, frame7);
    Eigen::MatrixXd jac6;
    backend_->frame_jacobian(t.handle, jac6);

    Eigen::Matrix<double, 6, 1> error = lie::se3_rminus(t.target, frame7);
    double T_tb[7];
    lie::se3_inverse_multiply(t.target.data(), frame7.data(), T_tb);
    double jlog[36];
    lie::se3_jlog(T_tb, jlog);
    Eigen::Matrix<double, 6, 6> Jlog;
    for (int i = 0; i < 6; ++i)
      for (int j = 0; j < 6; ++j) Jlog(i, j) = jlog[6 * i + j];
    Eigen::MatrixXd jacobian = -(Jlog * jac6);

    Eigen::Matrix<double, 6, 1> weighted_error = t.cost.array() * (-t.gain * error).array();
    Eigen::MatrixXd weighted_jacobian = t.cost.asDiagonal() * jacobian;
    double mu = t.lm_damping * weighted_error.squaredNorm();
    H.noalias() += weighted_jacobian.transpose() * weighted_jacobian;
    if (mu > 0.0) H.diagonal().array() += mu;
    c.noalias() -= weighted_jacobian.transpose() * weighted_error;
  }

  Eigen::VectorXd lb, ub;
  compute_box_bounds(lb, ub);
  Eigen::VectorXd dq = box_qp::solve(H, c, lb, ub);
  return dq / dt_;
}

void GmrSolver::integrate(const Eigen::VectorXd& v) {
  qpos_ = backend_->integrate(qpos_, v, dt_);
  backend_->set_qpos(qpos_);
}

Eigen::VectorXd GmrSolver::retarget(const SkeletonFrame& human_frame,
                                    bool offset_to_ground) {
  update_targets(human_frame, offset_to_ground);

  auto solve_table = [&](std::vector<Task>& tasks) {
    double curr_error = table_error(tasks);
    Eigen::VectorXd v = solve_ik(tasks);
    integrate(v);
    double next_error = table_error(tasks);
    int num_iter = 0;
    while (curr_error - next_error > 0.001 && num_iter < max_iter_) {
      curr_error = next_error;
      v = solve_ik(tasks);
      integrate(v);
      next_error = table_error(tasks);
      num_iter++;
    }
  };

  if (use_table1_) solve_table(tasks1_);
  if (use_table2_) solve_table(tasks2_);

  return qpos_;
}

}  // namespace gmr
}  // namespace retargeting
