#include "operator_g1d/arm_ik.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <limits>

namespace operator_g1d {
namespace {

constexpr double kJacobianStep = 1e-5;
constexpr double kDamping = 0.045;
constexpr int kIterations = 64;
constexpr double kPositionToleranceM = 0.002;
constexpr double kAcceptablePositionErrorM = 0.005;
constexpr double kRotationToleranceRad = 0.10;
constexpr double kRotationWeight = 0.25;

struct Vec3 {
  double x = 0.0;
  double y = 0.0;
  double z = 0.0;
};

struct Mat3 {
  double v[3][3]{};
};

struct Transform {
  Mat3 rotation;
  Vec3 position;
};

Vec3 operator+(Vec3 a, Vec3 b) { return {a.x + b.x, a.y + b.y, a.z + b.z}; }
Vec3 operator-(Vec3 a, Vec3 b) { return {a.x - b.x, a.y - b.y, a.z - b.z}; }
Vec3 operator*(Vec3 a, double scale) { return {a.x * scale, a.y * scale, a.z * scale}; }

double norm(Vec3 value) {
  return std::sqrt(value.x * value.x + value.y * value.y + value.z * value.z);
}

Mat3 identity() {
  Mat3 result{};
  result.v[0][0] = result.v[1][1] = result.v[2][2] = 1.0;
  return result;
}

Mat3 transpose(const Mat3& a) {
  Mat3 result{};
  for (int row = 0; row < 3; ++row) {
    for (int column = 0; column < 3; ++column) {
      result.v[row][column] = a.v[column][row];
    }
  }
  return result;
}

Mat3 multiply(const Mat3& a, const Mat3& b) {
  Mat3 result{};
  for (int row = 0; row < 3; ++row) {
    for (int column = 0; column < 3; ++column) {
      for (int inner = 0; inner < 3; ++inner) {
        result.v[row][column] += a.v[row][inner] * b.v[inner][column];
      }
    }
  }
  return result;
}

Vec3 multiply(const Mat3& a, Vec3 b) {
  return {
      a.v[0][0] * b.x + a.v[0][1] * b.y + a.v[0][2] * b.z,
      a.v[1][0] * b.x + a.v[1][1] * b.y + a.v[1][2] * b.z,
      a.v[2][0] * b.x + a.v[2][1] * b.y + a.v[2][2] * b.z,
  };
}

Mat3 axis_angle(Vec3 axis, double angle) {
  const double length = norm(axis);
  if (length <= std::numeric_limits<double>::epsilon()) {
    return identity();
  }
  axis = axis * (1.0 / length);
  const double c = std::cos(angle);
  const double s = std::sin(angle);
  const double t = 1.0 - c;
  return Mat3{{
      {t * axis.x * axis.x + c, t * axis.x * axis.y - s * axis.z,
       t * axis.x * axis.z + s * axis.y},
      {t * axis.x * axis.y + s * axis.z, t * axis.y * axis.y + c,
       t * axis.y * axis.z - s * axis.x},
      {t * axis.x * axis.z - s * axis.y, t * axis.y * axis.z + s * axis.x,
       t * axis.z * axis.z + c},
  }};
}

Mat3 quaternion(double x, double y, double z, double w) {
  const double length = std::sqrt(x * x + y * y + z * z + w * w);
  if (!std::isfinite(length) || length <= std::numeric_limits<double>::epsilon()) {
    return identity();
  }
  x /= length;
  y /= length;
  z /= length;
  w /= length;
  return Mat3{{
      {1.0 - 2.0 * (y * y + z * z), 2.0 * (x * y - z * w),
       2.0 * (x * z + y * w)},
      {2.0 * (x * y + z * w), 1.0 - 2.0 * (x * x + z * z),
       2.0 * (y * z - x * w)},
      {2.0 * (x * z - y * w), 2.0 * (y * z + x * w),
       1.0 - 2.0 * (x * x + y * y)},
  }};
}

std::array<double, 4> quaternion(const Mat3& rotation) {
  std::array<double, 4> result{};
  const double trace = rotation.v[0][0] + rotation.v[1][1] + rotation.v[2][2];
  if (trace > 0.0) {
    const double scale = std::sqrt(trace + 1.0) * 2.0;
    result = {
        (rotation.v[2][1] - rotation.v[1][2]) / scale,
        (rotation.v[0][2] - rotation.v[2][0]) / scale,
        (rotation.v[1][0] - rotation.v[0][1]) / scale,
        0.25 * scale,
    };
  } else if (rotation.v[0][0] > rotation.v[1][1] &&
             rotation.v[0][0] > rotation.v[2][2]) {
    const double scale = std::sqrt(1.0 + rotation.v[0][0] - rotation.v[1][1] -
                                   rotation.v[2][2]) * 2.0;
    result = {
        0.25 * scale,
        (rotation.v[0][1] + rotation.v[1][0]) / scale,
        (rotation.v[0][2] + rotation.v[2][0]) / scale,
        (rotation.v[2][1] - rotation.v[1][2]) / scale,
    };
  } else if (rotation.v[1][1] > rotation.v[2][2]) {
    const double scale = std::sqrt(1.0 + rotation.v[1][1] - rotation.v[0][0] -
                                   rotation.v[2][2]) * 2.0;
    result = {
        (rotation.v[0][1] + rotation.v[1][0]) / scale,
        0.25 * scale,
        (rotation.v[1][2] + rotation.v[2][1]) / scale,
        (rotation.v[0][2] - rotation.v[2][0]) / scale,
    };
  } else {
    const double scale = std::sqrt(1.0 + rotation.v[2][2] - rotation.v[0][0] -
                                   rotation.v[1][1]) * 2.0;
    result = {
        (rotation.v[0][2] + rotation.v[2][0]) / scale,
        (rotation.v[1][2] + rotation.v[2][1]) / scale,
        0.25 * scale,
        (rotation.v[1][0] - rotation.v[0][1]) / scale,
    };
  }
  return result;
}

Transform compose(const Transform& a, const Transform& b) {
  return {multiply(a.rotation, b.rotation), a.position + multiply(a.rotation, b.position)};
}

Transform translated(Vec3 position) { return {identity(), position}; }
Transform rotated(const Mat3& rotation) { return {rotation, {}}; }

Vec3 rotation_vector(const Mat3& rotation) {
  const double cosine = std::clamp(
      (rotation.v[0][0] + rotation.v[1][1] + rotation.v[2][2] - 1.0) * 0.5,
      -1.0,
      1.0);
  const double angle = std::acos(cosine);
  if (angle < 1e-7) {
    return {
        (rotation.v[2][1] - rotation.v[1][2]) * 0.5,
        (rotation.v[0][2] - rotation.v[2][0]) * 0.5,
        (rotation.v[1][0] - rotation.v[0][1]) * 0.5,
    };
  }
  const double sine = std::sin(angle);
  if (std::abs(sine) < 1e-7) {
    // Near pi, the diagonal remains well-conditioned enough for an IK error.
    Vec3 axis{
        std::sqrt(std::max(0.0, (rotation.v[0][0] + 1.0) * 0.5)),
        std::sqrt(std::max(0.0, (rotation.v[1][1] + 1.0) * 0.5)),
        std::sqrt(std::max(0.0, (rotation.v[2][2] + 1.0) * 0.5)),
    };
    if (rotation.v[2][1] - rotation.v[1][2] < 0.0) axis.x = -axis.x;
    if (rotation.v[0][2] - rotation.v[2][0] < 0.0) axis.y = -axis.y;
    if (rotation.v[1][0] - rotation.v[0][1] < 0.0) axis.z = -axis.z;
    return axis * angle;
  }
  const double scale = angle / (2.0 * sine);
  return {
      (rotation.v[2][1] - rotation.v[1][2]) * scale,
      (rotation.v[0][2] - rotation.v[2][0]) * scale,
      (rotation.v[1][0] - rotation.v[0][1]) * scale,
  };
}

Pose6D to_pose(const Transform& transform) {
  Pose6D result;
  result.position = {transform.position.x, transform.position.y, transform.position.z};
  result.rotation = quaternion(transform.rotation);
  return result;
}

Transform from_pose(const Pose6D& pose) {
  return {
      quaternion(pose.rotation[0], pose.rotation[1], pose.rotation[2], pose.rotation[3]),
      {pose.position[0], pose.position[1], pose.position[2]},
  };
}

Transform arm_forward(ArmSide side, const std::array<double, 7>& q) {
  const double sign = side == ArmSide::Left ? 1.0 : -1.0;
  Transform transform{identity(), {}};
  auto append_body = [&](Vec3 position, const Mat3& fixed_rotation, Vec3 axis,
                         double angle) {
    transform = compose(transform, translated(position));
    transform = compose(transform, rotated(fixed_rotation));
    transform = compose(transform, rotated(axis_angle(axis, angle)));
  };

  append_body(
      {0.0039563, sign * 0.10022, 0.23778},
      quaternion(sign * 0.1392014837, 1.38722044e-05, -sign * 9.868683842e-05,
                 0.9902640744),
      {0.0, 1.0, 0.0}, q[0]);
  append_body(
      {0.0, sign * 0.038, -0.013831},
      quaternion(-sign * 0.1391717738, 0.0, 0.0, 0.9902682553),
      {1.0, 0.0, 0.0}, q[1]);
  append_body({0.0, sign * 0.00624, -0.1032}, identity(), {0.0, 0.0, 1.0}, q[2]);
  append_body({0.015783, 0.0, -0.080518}, identity(), {0.0, 1.0, 0.0}, q[3]);
  append_body({0.1, sign * 0.00188791, -0.01}, identity(), {1.0, 0.0, 0.0}, q[4]);
  append_body({0.038, 0.0, 0.0}, identity(), {0.0, 1.0, 0.0}, q[5]);
  append_body({0.046, 0.0, 0.0}, identity(), {0.0, 0.0, 1.0}, q[6]);
  transform = compose(transform, translated({0.0415, sign * 0.003, 0.0}));
  return transform;
}

std::array<double, 6> pose_error(const Transform& target, const Transform& current) {
  const Vec3 position = target.position - current.position;
  const Vec3 rotation = rotation_vector(multiply(target.rotation, transpose(current.rotation)));
  return {position.x, position.y, position.z, rotation.x, rotation.y, rotation.z};
}

bool solve_linear_6(double matrix[6][6], const double rhs[6], double result[6]) {
  double augmented[6][7]{};
  for (int row = 0; row < 6; ++row) {
    for (int column = 0; column < 6; ++column) {
      augmented[row][column] = matrix[row][column];
    }
    augmented[row][6] = rhs[row];
  }
  for (int pivot = 0; pivot < 6; ++pivot) {
    int best = pivot;
    for (int row = pivot + 1; row < 6; ++row) {
      if (std::abs(augmented[row][pivot]) > std::abs(augmented[best][pivot])) best = row;
    }
    if (std::abs(augmented[best][pivot]) < 1e-12) return false;
    for (int column = pivot; column < 7; ++column) {
      std::swap(augmented[pivot][column], augmented[best][column]);
    }
    const double divisor = augmented[pivot][pivot];
    for (int column = pivot; column < 7; ++column) augmented[pivot][column] /= divisor;
    for (int row = 0; row < 6; ++row) {
      if (row == pivot) continue;
      const double factor = augmented[row][pivot];
      for (int column = pivot; column < 7; ++column) {
        augmented[row][column] -= factor * augmented[pivot][column];
      }
    }
  }
  for (int row = 0; row < 6; ++row) result[row] = augmented[row][6];
  return true;
}

bool solve_linear_3(double matrix[3][3], const double rhs[3], double result[3]) {
  double augmented[3][4]{};
  for (int row = 0; row < 3; ++row) {
    for (int column = 0; column < 3; ++column) {
      augmented[row][column] = matrix[row][column];
    }
    augmented[row][3] = rhs[row];
  }
  for (int pivot = 0; pivot < 3; ++pivot) {
    int best = pivot;
    for (int row = pivot + 1; row < 3; ++row) {
      if (std::abs(augmented[row][pivot]) > std::abs(augmented[best][pivot])) best = row;
    }
    if (std::abs(augmented[best][pivot]) < 1e-12) return false;
    for (int column = pivot; column < 4; ++column) {
      std::swap(augmented[pivot][column], augmented[best][column]);
    }
    const double divisor = augmented[pivot][pivot];
    for (int column = pivot; column < 4; ++column) augmented[pivot][column] /= divisor;
    for (int row = 0; row < 3; ++row) {
      if (row == pivot) continue;
      const double factor = augmented[row][pivot];
      for (int column = pivot; column < 4; ++column) {
        augmented[row][column] -= factor * augmented[pivot][column];
      }
    }
  }
  for (int row = 0; row < 3; ++row) result[row] = augmented[row][3];
  return true;
}

}  // namespace

ArmIkSolver::ArmIkSolver(ArmSide side) : side_(side) {
  lower_ = {-3.0892, -1.5882, -2.618, -1.0472, -1.972222054, -1.614429558,
            -1.614429558};
  upper_ = {2.6704, 2.2515, 2.618, 2.0944, 1.972222054, 1.614429558,
            1.614429558};
  if (side_ == ArmSide::Right) {
    lower_[1] = -2.2515;
    upper_[1] = 1.5882;
  }
}

Pose6D ArmIkSolver::forward(const std::array<double, 7>& joints) const {
  return to_pose(arm_forward(side_, joints));
}

ArmIkResult ArmIkSolver::solve(
    const Pose6D& target_pose,
    const std::array<double, 7>& seed) const {
  ArmIkResult result;
  result.joints = seed;
  for (std::size_t joint = 0; joint < result.joints.size(); ++joint) {
    result.joints[joint] = std::clamp(result.joints[joint], lower_[joint], upper_[joint]);
  }
  if (!pose_is_finite(target_pose)) return result;
  const Transform target = from_pose(target_pose);

  for (int iteration = 0; iteration < kIterations; ++iteration) {
    const Transform current = arm_forward(side_, result.joints);
    const auto error = pose_error(target, current);
    result.position_error_m = std::sqrt(
        error[0] * error[0] + error[1] * error[1] + error[2] * error[2]);
    result.rotation_error_rad = std::sqrt(
        error[3] * error[3] + error[4] * error[4] + error[5] * error[5]);
    if (result.position_error_m <= kPositionToleranceM &&
        result.rotation_error_rad <= kRotationToleranceRad) {
      result.converged = true;
      break;
    }

    double jacobian[6][7]{};
    for (int joint = 0; joint < 7; ++joint) {
      auto perturbed = result.joints;
      perturbed[joint] += kJacobianStep;
      const Transform moved = arm_forward(side_, perturbed);
      const Vec3 dp = (moved.position - current.position) * (1.0 / kJacobianStep);
      const Vec3 dr = rotation_vector(multiply(moved.rotation, transpose(current.rotation))) *
                      (1.0 / kJacobianStep);
      jacobian[0][joint] = dp.x;
      jacobian[1][joint] = dp.y;
      jacobian[2][joint] = dp.z;
      jacobian[3][joint] = dr.x;
      jacobian[4][joint] = dr.y;
      jacobian[5][joint] = dr.z;
    }

    double weighted_error[6]{};
    for (int axis = 0; axis < 6; ++axis) {
      const double weight = axis < 3 ? 1.0 : kRotationWeight;
      weighted_error[axis] = error[axis] * weight;
      for (int joint = 0; joint < 7; ++joint) {
        jacobian[axis][joint] *= weight;
      }
    }

    double normal[6][6]{};
    for (int row = 0; row < 6; ++row) {
      for (int column = 0; column < 6; ++column) {
        for (int joint = 0; joint < 7; ++joint) {
          normal[row][column] += jacobian[row][joint] * jacobian[column][joint];
        }
      }
      normal[row][row] += kDamping * kDamping;
    }
    double task_step[6]{};
    if (!solve_linear_6(normal, weighted_error, task_step)) break;
    for (int joint = 0; joint < 7; ++joint) {
      double delta = 0.0;
      for (int axis = 0; axis < 6; ++axis) delta += jacobian[axis][joint] * task_step[axis];
      result.joints[joint] = std::clamp(
          result.joints[joint] + std::clamp(delta, -0.16, 0.16), lower_[joint], upper_[joint]);
    }
  }
  if (!result.converged) {
    const auto final_error = pose_error(target, arm_forward(side_, result.joints));
    result.position_error_m = std::sqrt(
        final_error[0] * final_error[0] + final_error[1] * final_error[1] +
        final_error[2] * final_error[2]);
    result.rotation_error_rad = std::sqrt(
        final_error[3] * final_error[3] + final_error[4] * final_error[4] +
        final_error[5] * final_error[5]);
    result.converged = result.position_error_m <= kAcceptablePositionErrorM &&
                       result.rotation_error_rad <= kRotationToleranceRad;
  }
  return result;
}

ArmIkResult ArmIkSolver::solve_position(
    const Pose6D& target_pose,
    const std::array<double, 7>& seed) const {
  ArmIkResult result;
  result.joints = seed;
  for (std::size_t joint = 0; joint < result.joints.size(); ++joint) {
    result.joints[joint] = std::clamp(result.joints[joint], lower_[joint], upper_[joint]);
  }
  if (!pose_is_finite(target_pose)) return result;
  const Transform target = from_pose(target_pose);

  for (int iteration = 0; iteration < kIterations; ++iteration) {
    const Transform current = arm_forward(side_, result.joints);
    const Vec3 error = target.position - current.position;
    result.position_error_m = norm(error);
    result.rotation_error_rad = norm(rotation_vector(
        multiply(target.rotation, transpose(current.rotation))));
    if (result.position_error_m <= kPositionToleranceM) {
      result.converged = true;
      break;
    }

    double jacobian[3][7]{};
    for (int joint = 0; joint < 7; ++joint) {
      auto perturbed = result.joints;
      perturbed[joint] += kJacobianStep;
      const Transform moved = arm_forward(side_, perturbed);
      const Vec3 dp = (moved.position - current.position) * (1.0 / kJacobianStep);
      jacobian[0][joint] = dp.x;
      jacobian[1][joint] = dp.y;
      jacobian[2][joint] = dp.z;
    }

    double normal[3][3]{};
    for (int row = 0; row < 3; ++row) {
      for (int column = 0; column < 3; ++column) {
        for (int joint = 0; joint < 7; ++joint) {
          normal[row][column] += jacobian[row][joint] * jacobian[column][joint];
        }
      }
      normal[row][row] += kDamping * kDamping;
    }
    const double rhs[3]{error.x, error.y, error.z};
    double task_step[3]{};
    if (!solve_linear_3(normal, rhs, task_step)) break;
    for (int joint = 0; joint < 7; ++joint) {
      double delta = 0.0;
      for (int axis = 0; axis < 3; ++axis) delta += jacobian[axis][joint] * task_step[axis];
      result.joints[joint] = std::clamp(
          result.joints[joint] + std::clamp(delta, -0.12, 0.12),
          lower_[joint], upper_[joint]);
    }
  }
  if (!result.converged) {
    const Transform current = arm_forward(side_, result.joints);
    result.position_error_m = norm(target.position - current.position);
    result.rotation_error_rad = norm(rotation_vector(
        multiply(target.rotation, transpose(current.rotation))));
    result.converged = result.position_error_m <= kAcceptablePositionErrorM;
  }
  return result;
}

ArmIkResult ArmIkSolver::solve_robust(
    const Pose6D& target,
    const std::array<double, 7>& seed) const {
  ArmIkResult best = solve(target, seed);
  const auto cost = [&](const ArmIkResult& candidate) {
    double value = 0.0;
    for (std::size_t joint = 0; joint < seed.size(); ++joint) {
      const double delta = candidate.joints[joint] - seed[joint];
      value += delta * delta;
      const double margin = std::min(
          candidate.joints[joint] - lower_[joint],
          upper_[joint] - candidate.joints[joint]);
      if (margin < 0.12) {
        const double violation = 0.12 - margin;
        value += 20.0 * violation * violation;
      }
    }
    return value;
  };

  bool near_limit = false;
  if (best.converged) {
    for (std::size_t joint = 0; joint < seed.size(); ++joint) {
      const double margin = std::min(
          best.joints[joint] - lower_[joint], upper_[joint] - best.joints[joint]);
      near_limit = near_limit || margin < 0.08;
    }
    if (!near_limit) return best;
  }

  const double sign = side_ == ArmSide::Left ? 1.0 : -1.0;
  const std::array<std::array<double, 7>, 3> fallback_seeds{{
      {{0.0, 0.0, 0.0, 1.40, 0.0, 0.0, 0.0}},
      {{-1.5707963267948966, sign * 0.40, 0.0, 1.5707963267948966,
        -sign * 1.5707963267948966, 0.0, 0.0}},
      {{0.0, 0.0, 0.0, 1.5707963267948966, 0.0, 0.0, 0.0}},
  }};
  double best_distance = best.converged ? cost(best) : std::numeric_limits<double>::infinity();
  for (const auto& fallback_seed : fallback_seeds) {
    ArmIkResult candidate = solve(target, fallback_seed);
    if (!candidate.converged) continue;
    const double distance = cost(candidate);
    if (distance < best_distance) {
      best_distance = distance;
      best = candidate;
    }
  }
  if (best.converged) return best;
  return best;
}

const std::array<double, 7>& ArmIkSolver::lower_limits() const { return lower_; }
const std::array<double, 7>& ArmIkSolver::upper_limits() const { return upper_; }

Pose6D relative_xr_target(
    const Pose6D& xr_reference,
    const Pose6D& xr_current,
    const Pose6D& operator_reference,
    const Pose6D& robot_reference,
    double position_scale) {
  const Transform xr_ref = from_pose(xr_reference);
  const Transform xr_now = from_pose(xr_current);
  const Transform robot_ref = from_pose(robot_reference);
  const Transform operator_ref = from_pose(operator_reference);
  // S maps XR (right, up, back) to robot (forward, left, up).
  const Mat3 basis{{{0.0, 0.0, -1.0}, {-1.0, 0.0, 0.0}, {0.0, 1.0, 0.0}}};
  // Normalize the world-space hand delta by the operator's yaw at the Grip
  // rising edge. Pitch/roll are deliberately discarded so looking down or
  // tilting the head cannot rotate the horizontal control plane.
  const Vec3 head_forward = multiply(operator_ref.rotation, Vec3{0.0, 0.0, -1.0});
  const double horizontal_length = std::hypot(head_forward.x, head_forward.z);
  const Vec3 forward = horizontal_length > 1e-8
                           ? Vec3{head_forward.x / horizontal_length, 0.0,
                                  head_forward.z / horizontal_length}
                           : Vec3{0.0, 0.0, -1.0};
  const Vec3 back = forward * -1.0;
  const Vec3 right{back.z, 0.0, -back.x};
  const Mat3 operator_frame{{
      {right.x, 0.0, back.x},
      {right.y, 1.0, back.y},
      {right.z, 0.0, back.z},
  }};
  const Vec3 xr_delta_world = xr_now.position - xr_ref.position;
  const Vec3 xr_delta_operator = multiply(transpose(operator_frame), xr_delta_world);
  const Vec3 robot_delta = multiply(basis, xr_delta_operator) * position_scale;
  const Mat3 xr_rotation_delta_world = multiply(xr_now.rotation, transpose(xr_ref.rotation));
  const Mat3 xr_rotation_delta = multiply(
      multiply(transpose(operator_frame), xr_rotation_delta_world), operator_frame);
  const Mat3 robot_rotation_delta =
      multiply(multiply(basis, xr_rotation_delta), transpose(basis));
  return to_pose({multiply(robot_rotation_delta, robot_ref.rotation),
                  robot_ref.position + robot_delta});
}

bool pose_is_finite(const Pose6D& pose) {
  double quaternion_norm = 0.0;
  for (double value : pose.position) {
    if (!std::isfinite(value)) return false;
  }
  for (double value : pose.rotation) {
    if (!std::isfinite(value)) return false;
    quaternion_norm += value * value;
  }
  return quaternion_norm > 1e-8;
}

}  // namespace operator_g1d
