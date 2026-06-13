// GMR solver: C++ port of general_motion_retargeting.GeneralMotionRetargeting.
//
// This is the numerically-validated core (aligned with the original Python
// mink + MuJoCo pipeline to ~1e-13). It is unchanged in substance from the
// standalone GMR C++ port; the only generalizations vs. that port are:
//   * it consumes the toolkit's retargeting::SkeletonFrame instead of a
//     quest3-specific frame type, and
//   * the G1-specific "upper body only" freeze is generalized to an arbitrary
//     locked qpos prefix (lock_qpos_prefix / reset_locked_region /
//     freeze_locked_region), so the business layer drives the scenario.
//
// The IK runs on a pluggable KinematicsBackend (Pinocchio or MuJoCo); the QP
// assembly, lie ops, and box-QP solver are shared.
#pragma once
#include <Eigen/Dense>
#include <map>
#include <memory>
#include <string>
#include <vector>

#include "kinematics_backend.hpp"
#include "retargeting/types.hpp"

namespace retargeting {
namespace gmr {

class GmrSolver {
 public:
  GmrSolver(KinematicsBackendKind backend, const std::string& robot_xml,
            const std::string& ik_config_json, double actual_human_height,
            double damping = 1.0);

  // Hold the first n_qpos configuration entries fixed across solves. Snapshots
  // the current values as the held configuration. n_qpos == 0 locks nothing.
  void lock_qpos_prefix(int n_qpos);
  // Extra individual qpos entries to clamp-after (reset before the solve + held
  // after), in addition to the locked prefix. Used to hold e.g. waist roll/pitch
  // and the wrists at rest while the arms are solved freely — matching the GMR
  // spatialmp4 pipeline. Captures the current values as the held values.
  void set_clamp_qpos(const std::vector<int>& qpos_indices);
  void reset_locked_region();                       // restore held values now
  void freeze_locked_region(Eigen::VectorXd& qpos) const;  // restore into qpos
  // Pin the locked region inside the QP too (not just clamp after), so the free
  // joints alone satisfy the tasks. Keeps a locked torso upright.
  void set_freeze_locked_in_solve(bool v) { freeze_locked_in_solve_ = v; }

  Eigen::VectorXd retarget(const SkeletonFrame& human_frame,
                           bool offset_to_ground = false);

  void update_configuration(const Eigen::VectorXd& qpos);

  int nq() const { return backend_->nq(); }
  int nv() const { return backend_->nv(); }
  Eigen::VectorXd qpos0() const { return backend_->qpos0(); }
  const std::map<std::string, Pose>& scaled_human_data() const {
    return scaled_human_data_;
  }

 private:
  struct Task {
    std::string frame_name;
    std::string human_body;
    int handle = -1;
    Eigen::Matrix<double, 6, 1> cost;
    double gain = 1.0;
    double lm_damping = 1.0;
    Eigen::Matrix<double, 7, 1> target;
    bool has_target = false;
  };

  void update_targets(const SkeletonFrame& human_frame, bool offset_to_ground);
  std::map<std::string, Pose> scale_human_data(
      const std::map<std::string, Pose>& human_data) const;
  std::map<std::string, Pose> offset_human_data(
      const std::map<std::string, Pose>& human_data) const;

  double table_error(const std::vector<Task>& tasks) const;
  Eigen::VectorXd solve_ik(const std::vector<Task>& tasks) const;
  void integrate(const Eigen::VectorXd& v);
  void compute_box_bounds(Eigen::VectorXd& lb, Eigen::VectorXd& ub) const;

  std::unique_ptr<KinematicsBackend> backend_;
  Eigen::VectorXd qpos_;  // authoritative configuration (MuJoCo convention)
  double dt_ = 0.0;
  double damping_ = 1.0;

  std::string human_root_name_;
  std::map<std::string, double> human_scale_table_;
  Eigen::Vector3d ground_ = Eigen::Vector3d::Zero();
  double ground_offset_ = 0.0;

  bool use_table1_ = true, use_table2_ = true;
  std::vector<Task> tasks1_, tasks2_;
  std::map<std::string, Eigen::Vector3d> pos_offsets1_;
  std::map<std::string, Eigen::Vector4d> rot_offsets1_;

  double config_gain_ = 0.95;
  int locked_qpos_count_ = 0;
  bool freeze_locked_in_solve_ = false;
  Eigen::VectorXd locked_qpos_;  // held values of qpos[0:locked_qpos_count_]
  std::vector<int> clamp_qpos_indices_;   // extra clamp-after qpos entries
  Eigen::VectorXd clamp_qpos_values_;     // their held values

  int max_iter_ = 10;
  std::map<std::string, Pose> scaled_human_data_;
};

}  // namespace gmr
}  // namespace retargeting
