#pragma once
#include "kinematics_backend.hpp"

struct mjModel_;
struct mjData_;

class MujocoBackend : public KinematicsBackend {
 public:
  explicit MujocoBackend(const std::string& robot_xml);
  ~MujocoBackend() override;

  int nq() const override;
  int nv() const override;
  double dt() const override { return dt_; }
  Eigen::VectorXd qpos0() const override;
  int body_handle(const std::string& name) const override;
  const std::vector<LimitedDof>& limited_dofs() const override { return limited_; }
  void set_qpos(const Eigen::VectorXd& qpos) override;
  void frame_pose(int handle, Eigen::Matrix<double, 7, 1>& out7) const override;
  void frame_jacobian(int handle, Eigen::MatrixXd& jac6) const override;
  Eigen::VectorXd integrate(const Eigen::VectorXd& qpos, const Eigen::VectorXd& v,
                            double dt) const override;

 private:
  mjModel_* m_ = nullptr;
  mjData_* d_ = nullptr;
  double dt_ = 0.0;
  std::vector<LimitedDof> limited_;
};
