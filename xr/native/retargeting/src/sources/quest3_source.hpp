// Synthetic Quest3 upper-body source frames.
//
// Reproduces general_motion_retargeting/quest3_utils.py's synthetic upper-body
// motion, used as the validation source for the upper-body demo. In a real VR
// deployment this is where headset body/hand tracking would be converted into a
// retargeting::SkeletonFrame instead.
#pragma once
#include <Eigen/Dense>

#include "retargeting/types.hpp"

namespace retargeting {
namespace sources {

// Quaternion (w,x,y,z) from extrinsic-xyz Euler angles, matching
// scipy Rotation.from_euler("xyz", angles).as_quat(scalar_first=True).
Eigen::Vector4d quat_wxyz_from_euler_xyz(double ax, double ay, double az);

// synthetic_quest3_upper_frame(frame_idx, fps): GMR-coordinate upper-body frame.
SkeletonFrame synthetic_quest3_upper_frame(int frame_idx, double fps);

}  // namespace sources
}  // namespace retargeting
