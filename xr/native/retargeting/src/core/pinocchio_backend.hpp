#pragma once
#include "kinematics_backend.hpp"

#include <pinocchio/multibody/model.hpp>
#include <pinocchio/multibody/data.hpp>

// Pinocchio-based IK kinematics backend. Loads the same MuJoCo MJCF (cleaned of
// the scene-only second <worldbody>, which Pinocchio's parser duplicates) and
// reproduces MuJoCo's body-frame poses and Jacobians to machine precision.
//
// MuJoCo's qpos base is the absolute world pose, but Pinocchio folds the root
// body `pos` into jointPlacements[1], so the free-flyer q is RELATIVE to it.
// We convert at the boundary (see set_qpos) and keep qpos in MuJoCo convention
// everywhere else. Integration replicates mj_integratePos exactly so no MuJoCo
// runtime dependency remains.
class PinocchioBackend : public KinematicsBackend {
 public:
  explicit PinocchioBackend(const std::string& robot_xml);

  int nq() const override { return model_.nq; }
  int nv() const override { return model_.nv; }
  double dt() const override { return dt_; }
  Eigen::VectorXd qpos0() const override { return qpos0_; }
  int body_handle(const std::string& name) const override;
  const std::vector<LimitedDof>& limited_dofs() const override { return limited_; }
  void set_qpos(const Eigen::VectorXd& qpos) override;
  void frame_pose(int handle, Eigen::Matrix<double, 7, 1>& out7) const override;
  void frame_jacobian(int handle, Eigen::MatrixXd& jac6) const override;
  Eigen::VectorXd integrate(const Eigen::VectorXd& qpos, const Eigen::VectorXd& v,
                            double dt) const override;

 private:
  // Convert a MuJoCo-convention qpos to a Pinocchio configuration vector.
  Eigen::VectorXd mj_to_pin(const Eigen::VectorXd& qpos) const;

  pinocchio::Model model_;
  mutable pinocchio::Data data_;
  double dt_ = 0.002;
  Eigen::VectorXd qpos0_;  // MuJoCo-convention initial config

  Eigen::Matrix3d R_jp_;   // jointPlacements[1] rotation
  Eigen::Vector3d t_jp_;   // jointPlacements[1] translation

  std::vector<LimitedDof> limited_;
  // All single-DoF joints (qposadr, dofadr) for integration of hinge joints.
  std::vector<std::pair<int, int>> hinge_dofs_;
  bool has_free_base_ = true;  // free-flyer at qpos[0:7], dof[0:6]
};
