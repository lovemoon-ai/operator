#include "quest3_source.hpp"

#include <cmath>

namespace retargeting {
namespace sources {

namespace {
// Hamilton product (w,x,y,z).
Eigen::Vector4d qmul(const Eigen::Vector4d& a, const Eigen::Vector4d& b) {
  Eigen::Vector4d r;
  r[0] = a[0]*b[0] - a[1]*b[1] - a[2]*b[2] - a[3]*b[3];
  r[1] = a[0]*b[1] + a[1]*b[0] + a[2]*b[3] - a[3]*b[2];
  r[2] = a[0]*b[2] - a[1]*b[3] + a[2]*b[0] + a[3]*b[1];
  r[3] = a[0]*b[3] + a[1]*b[2] - a[2]*b[1] + a[3]*b[0];
  return r;
}
}  // namespace

Eigen::Vector4d quat_wxyz_from_euler_xyz(double ax, double ay, double az) {
  // Extrinsic xyz: rotate about x, then (fixed) y, then (fixed) z.
  // Composed rotation R = Rz * Ry * Rx  =>  q = qz (x) qy (x) qx.
  Eigen::Vector4d qx(std::cos(ax/2), std::sin(ax/2), 0, 0);
  Eigen::Vector4d qy(std::cos(ay/2), 0, std::sin(ay/2), 0);
  Eigen::Vector4d qz(std::cos(az/2), 0, 0, std::sin(az/2));
  return qmul(qz, qmul(qy, qx));
}

SkeletonFrame synthetic_quest3_upper_frame(int frame_idx, double fps) {
  const double PI = 3.14159265358979323846;
  double t = frame_idx / fps;
  double phase = 2.0 * PI * 0.45 * t;
  double torso_yaw = 0.18 * std::sin(phase * 0.5);
  double torso_pitch = 0.08 * std::sin(phase);
  double arm_raise = 0.18 + 0.16 * std::sin(phase);

  Eigen::Vector3d hips(0.02 * std::sin(phase), 0.0, 0.95);
  Eigen::Vector3d chest = hips + Eigen::Vector3d(0.02 * std::sin(phase), 0.0, 0.48);
  Eigen::Vector3d neck = chest + Eigen::Vector3d(0.0, 0.0, 0.16);
  Eigen::Vector3d head = neck + Eigen::Vector3d(0.02 * std::sin(phase * 0.7), 0.0, 0.16);

  Eigen::Vector3d left_shoulder = chest + Eigen::Vector3d(0.02, 0.24, 0.04);
  Eigen::Vector3d right_shoulder = chest + Eigen::Vector3d(0.02, -0.24, 0.04);
  Eigen::Vector3d left_elbow = left_shoulder + Eigen::Vector3d(0.10, 0.18, -0.22 + arm_raise);
  Eigen::Vector3d right_elbow = right_shoulder + Eigen::Vector3d(0.10, -0.18, -0.22 - arm_raise * 0.25);
  Eigen::Vector3d left_wrist = left_elbow + Eigen::Vector3d(0.12, 0.12, -0.22 + arm_raise * 0.35);
  Eigen::Vector3d right_wrist = right_elbow + Eigen::Vector3d(0.12, -0.12, -0.24);

  Eigen::Vector4d torso_quat = quat_wxyz_from_euler_xyz(0.0, torso_pitch, torso_yaw);
  Eigen::Vector4d left_arm_quat = quat_wxyz_from_euler_xyz(0.0, -0.25 + arm_raise, torso_yaw);
  Eigen::Vector4d right_arm_quat = quat_wxyz_from_euler_xyz(0.0, 0.10 * std::sin(phase), torso_yaw);
  Eigen::Vector4d head_quat = quat_wxyz_from_euler_xyz(0.0, 0.04 * std::sin(phase), torso_yaw);

  SkeletonFrame f;
  f["Hips"] = {hips, torso_quat};
  f["Chest"] = {chest, torso_quat};
  f["Neck"] = {neck, torso_quat};
  f["Head"] = {head, head_quat};
  f["LeftShoulder"] = {left_shoulder, torso_quat};
  f["LeftArmUpper"] = {left_shoulder, left_arm_quat};
  f["LeftArmLower"] = {left_elbow, left_arm_quat};
  f["LeftWrist"] = {left_wrist, left_arm_quat};
  f["RightShoulder"] = {right_shoulder, torso_quat};
  f["RightArmUpper"] = {right_shoulder, right_arm_quat};
  f["RightArmLower"] = {right_elbow, right_arm_quat};
  f["RightWrist"] = {right_wrist, right_arm_quat};
  return f;
}

}  // namespace sources
}  // namespace retargeting
