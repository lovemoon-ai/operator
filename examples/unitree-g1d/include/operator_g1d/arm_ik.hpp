#pragma once

#include <array>

#include "operator_g1d/types.hpp"

namespace operator_g1d {

enum class ArmSide { Left, Right };

struct ArmIkResult {
  std::array<double, 7> joints{};
  double position_error_m = 0.0;
  double rotation_error_rad = 0.0;
  bool converged = false;
};

// Self-contained G1-D 7-DoF arm kinematics. The chain dimensions and limits
// match xr/assets/mujoco/g1_29dof.xml, generated from Unitree's G1 29-DoF URDF.
class ArmIkSolver {
 public:
  explicit ArmIkSolver(ArmSide side);

  Pose6D forward(const std::array<double, 7>& joints) const;
  ArmIkResult solve(const Pose6D& target, const std::array<double, 7>& seed) const;
  ArmIkResult solve_position(const Pose6D& target, const std::array<double, 7>& seed) const;
  ArmIkResult solve_robust(const Pose6D& target, const std::array<double, 7>& seed) const;
  const std::array<double, 7>& lower_limits() const;
  const std::array<double, 7>& upper_limits() const;

 private:
  ArmSide side_;
  std::array<double, 7> lower_{};
  std::array<double, 7> upper_{};
};

// Maps an XR wrist/controller pose to a robot end-effector target without a
// jump at engagement. XR uses X-right/Y-up/Z-back; G1 uses X-forward/Y-left/Z-up.
Pose6D relative_xr_target(
    const Pose6D& xr_reference,
    const Pose6D& xr_current,
    const Pose6D& operator_reference,
    const Pose6D& robot_reference,
    double position_scale);

bool pose_is_finite(const Pose6D& pose);

}  // namespace operator_g1d
