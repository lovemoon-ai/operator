// Public, dependency-light types for the retargeting toolkit.
//
// These types are the contract between the *business layer* (whole-body /
// upper-body / hand scenarios) and the *algorithm layer* (GMR and, later, other
// retargeting algorithms). They are intentionally free of any robot-kinematics
// or Godot dependency so the same headers can be consumed from a CLI demo, a
// unit test, or a future Godot GDExtension that feeds VR body/hand poses in.
#pragma once
#include <Eigen/Dense>
#include <map>
#include <string>

namespace retargeting {

// A rigid pose: position + quaternion (w, x, y, z), in the source ("human" /
// VR-tracked) coordinate convention expected by the configured algorithm.
struct Pose {
  Eigen::Vector3d pos = Eigen::Vector3d::Zero();
  Eigen::Vector4d quat = Eigen::Vector4d(1, 0, 0, 0);  // (w, x, y, z)
};

// One frame of tracked source skeleton, keyed by joint/landmark name
// (e.g. "Hips", "Head", "LeftWrist", "LeftHandIndexTip"). In VR this is built
// from the headset's body/hand tracking; in tests it comes from a synthetic or
// recorded source.
using SkeletonFrame = std::map<std::string, Pose>;

// Which retargeting backend the algorithm should use for kinematics, where it
// supports a choice. GMR can run on either Pinocchio (no MuJoCo runtime needed,
// the Android/VR target) or MuJoCo (desktop reference cross-check).
enum class KinematicsBackendKind { Pinocchio, Mujoco };

// Everything an algorithm needs to bind to a specific robot + mapping.
struct RetargetConfig {
  std::string robot_xml;        // MJCF describing the target robot.
  std::string ik_config_json;   // algorithm-specific mapping/config (GMR ik_config).
  double human_height = 1.75;   // actual source-subject height, for scaling.
  double damping = 1.0;         // solver damping (algorithm-specific meaning).
  KinematicsBackendKind backend = KinematicsBackendKind::Pinocchio;
};

}  // namespace retargeting
