#include "operator_g1d/controller.hpp"

#include <algorithm>
#include <cmath>
#include <iostream>
#include <utility>

namespace operator_g1d {

CommandController::CommandController(ControllerConfig config) : config_(std::move(config)) {}

double CommandController::axis(const DeviceCommand& command, const std::string& name) {
  const auto found = command.axes.find(name);
  if (found == command.axes.end() || !std::isfinite(found->second)) {
    return 0.0;
  }
  return std::clamp(found->second, -1.0, 1.0);
}

bool CommandController::button(const DeviceCommand& command, const std::string& name) {
  const auto found = command.buttons.find(name);
  return found != command.buttons.end() && found->second;
}

bool CommandController::motion_controls_neutral(const DeviceCommand& command) {
  constexpr double kNeutralEpsilon = 1e-6;
  return !button(command, "base_enable") && !button(command, "lift_enable") &&
         !button(command, "lift_down") && !button(command, "lift_up") &&
         !button(command, "arm_ready") && !button(command, "arm_init") &&
         !button(command, "left_enable") && !button(command, "right_enable") &&
         std::abs(axis(command, "base_linear")) <= kNeutralEpsilon &&
         std::abs(axis(command, "base_yaw")) <= kNeutralEpsilon &&
         std::abs(axis(command, "lift_speed")) <= kNeutralEpsilon &&
         std::abs(axis(command, "revo1_left_grasp")) <= kNeutralEpsilon &&
         std::abs(axis(command, "revo1_right_grasp")) <= kNeutralEpsilon;
}

bool CommandController::command_is_neutral(const DeviceCommand& command) {
  return !button(command, "emergency_stop") && motion_controls_neutral(command);
}

double CommandController::slew(double current, double target, double max_delta) {
  return current + std::clamp(target - current, -max_delta, max_delta);
}

void CommandController::accept(
    const DeviceCommand& command,
    std::chrono::steady_clock::time_point now) {
  std::lock_guard<std::mutex> lock(mutex_);
  latest_ = command;
  have_command_ = true;
  last_command_at_ = now;
  watchdog_active_ = false;

  if (button(command, "emergency_stop")) {
    estop_latched_ = true;
    release_required_ = true;
    stop_reason_ = "operator_estop";
  }

  if (button(command, "reset") && command_is_neutral(command)) {
    estop_latched_ = false;
    release_required_ = false;
    stop_reason_.clear();
  }

  const bool arm_ready_pressed = button(command, "arm_ready");
  if (arm_ready_pressed && !arm_ready_button_was_pressed_ &&
      config_.motion_authorized && !estop_latched_) {
    arm_ready_request_pending_ = true;
  }
  arm_ready_button_was_pressed_ = arm_ready_pressed;

  const bool arm_init_pressed = button(command, "arm_init");
  if (arm_init_pressed && !arm_init_button_was_pressed_ &&
      config_.motion_authorized && !estop_latched_) {
    arm_init_request_pending_ = true;
  }
  arm_init_button_was_pressed_ = arm_init_pressed;

  if (release_required_ && motion_controls_neutral(command)) {
    release_required_ = false;
  }
}

void CommandController::force_stop(std::string reason, bool latch_estop) {
  std::lock_guard<std::mutex> lock(mutex_);
  latest_ = DeviceCommand{};
  have_command_ = false;
  watchdog_active_ = false;
  release_required_ = true;
  control_conflict_ = false;
  mode_ = MotionMode::Stopped;
  stop_reason_ = std::move(reason);
  estop_latched_ = estop_latched_ || latch_estop;
  current_vx_mps_ = 0.0;
  current_wz_rad_s_ = 0.0;
  current_lift_ = 0.0;
  arm_ready_request_pending_ = false;
  arm_init_request_pending_ = false;
  arm_ready_button_was_pressed_ = false;
  arm_init_button_was_pressed_ = false;
  reset_arm_references();
  reset_hand_references();
}

void CommandController::reset_arm_references() {
  left_arm_.engaged = false;
  right_arm_.engaged = false;
  left_arm_.debug_cycles = 0;
  right_arm_.debug_cycles = 0;
  left_arm_.solution_history_size = 0;
  right_arm_.solution_history_size = 0;
  manual_arm_hold_initialized_ = false;
  arm_ready_active_ = false;
  arm_init_active_ = false;
}

void CommandController::reset_hand_references() {
  left_hand_.engaged = false;
  left_hand_.grasp_latched = false;
  right_hand_.engaged = false;
  right_hand_.grasp_latched = false;
}

bool CommandController::resolve_hand(
    bool left,
    const BackendSnapshot& feedback,
    double max_step,
    ActuatorCommand& output,
    bool force_open) {
  const char* side = left ? "left" : "right";
  HandControlState& state = left ? left_hand_ : right_hand_;
  if (!force_open && !button(latest_, std::string(side) + "_hand_enable")) {
    state.engaged = false;
    state.grasp_latched = false;
    return true;
  }
  const bool fresh = left ? feedback.left_hand_fresh : feedback.right_hand_fresh;
  const double age_ms = left ? feedback.left_hand_age_ms : feedback.right_hand_age_ms;
  const auto& positions = left ? feedback.left_hand_positions : feedback.right_hand_positions;
  const auto& velocities = left ? feedback.left_hand_velocities : feedback.right_hand_velocities;
  const auto& currents = left ? feedback.left_hand_currents : feedback.right_hand_currents;
  if (!fresh || age_ms > config_.hand_timeout.count() || positions.size() != 6 ||
      velocities.size() != 6 || currents.size() != 6) {
    stop_reason_ = std::string(side) + "_hand_feedback_stale_or_incomplete";
    return false;
  }
  for (std::size_t motor = 0; motor < 6; ++motor) {
    if (!std::isfinite(positions[motor]) || !std::isfinite(velocities[motor]) ||
        !std::isfinite(currents[motor])) {
      stop_reason_ = std::string(side) + "_hand_feedback_non_finite";
      return false;
    }
    if (std::abs(velocities[motor]) > config_.max_measured_hand_velocity) {
      estop_latched_ = true;
      stop_reason_ = std::string(side) + "_hand_speed_limit";
      return false;
    }
    if (std::abs(currents[motor]) > config_.max_abs_hand_current) {
      estop_latched_ = true;
      stop_reason_ = std::string(side) + "_hand_current_limit";
      return false;
    }
  }

  if (!state.engaged) {
    state.engaged = true;
    std::copy_n(positions.begin(), 6, state.targets.begin());
  }
  const double grasp_input = axis(latest_, std::string("revo1_") + side + "_grasp");
  if (force_open) {
    state.grasp_latched = false;
  } else if (grasp_input >= 0.60) {
    state.grasp_latched = true;
  } else if (grasp_input < 0.40) {
    state.grasp_latched = false;
  }
  const double grasp_target = state.grasp_latched ? config_.revo1_grasp_target : 0.0;
  const std::array<double, 6> desired{
      grasp_target,
      std::clamp(positions[1], 0.0, 1.0),
      grasp_target,
      grasp_target,
      grasp_target,
      grasp_target,
  };
  for (std::size_t motor = 0; motor < 6; ++motor) {
    state.targets[motor] = slew(state.targets[motor], desired[motor], max_step);
  }
  if (left) {
    output.left_hand_active = true;
    output.left_hand_targets = state.targets;
  } else {
    output.right_hand_active = true;
    output.right_hand_targets = state.targets;
  }
  return true;
}

bool CommandController::resolve_hands(
    const BackendSnapshot& feedback,
    std::chrono::duration<double> elapsed,
    ActuatorCommand& output) {
  const double dt = std::clamp(elapsed.count(), 0.0, 0.25);
  const double max_step = config_.max_hand_target_rate_per_s * dt;
  return resolve_hand(true, feedback, max_step, output) &&
         resolve_hand(false, feedback, max_step, output);
}

bool CommandController::resolve_hands_open(
    const BackendSnapshot& feedback,
    std::chrono::duration<double> elapsed,
    ActuatorCommand& output) {
  const double dt = std::clamp(elapsed.count(), 0.0, 0.25);
  const double max_step = config_.max_hand_target_rate_per_s * dt;
  return resolve_hand(true, feedback, max_step, output, true) &&
         resolve_hand(false, feedback, max_step, output, true);
}

bool CommandController::resolve_arm(
    ArmSide side,
    const char* enable_name,
    const char* pose_name,
    const BackendSnapshot& feedback,
    double max_joint_step,
    std::vector<double>& targets) {
  if (!button(latest_, enable_name)) {
    (side == ArmSide::Left ? left_arm_ : right_arm_).engaged = false;
    return true;
  }
  const auto pose_found = latest_.poses.find(pose_name);
  if (pose_found == latest_.poses.end() || !pose_is_finite(pose_found->second)) {
    stop_reason_ = std::string(pose_name) + "_missing_or_invalid";
    return false;
  }

  ArmControlState& state = side == ArmSide::Left ? left_arm_ : right_arm_;
  ArmIkSolver& solver = side == ArmSide::Left ? left_ik_ : right_ik_;
  const std::size_t offset = side == ArmSide::Left ? 15 : 22;
  std::array<double, 7> measured{};
  for (std::size_t joint = 0; joint < measured.size(); ++joint) {
    measured[joint] = feedback.joint_positions_rad[offset + joint];
  }

  if (!state.engaged) {
    state.engaged = true;
    state.debug_cycles = 0;
    state.solution_history_size = 0;
    state.xr_reference = pose_found->second;
    const auto operator_frame = latest_.poses.find("operator_frame");
    state.operator_reference =
        operator_frame != latest_.poses.end() && pose_is_finite(operator_frame->second)
            ? operator_frame->second
            : Pose6D{};
    state.target_joints = measured;
    state.support_offset.fill(0.0);
    if (feedback.arm_command_targets_rad.size() >= offset + measured.size()) {
      constexpr double kMaxSupportOffsetRad = 0.15;
      for (std::size_t joint = 0; joint < measured.size(); ++joint) {
        const double retained = feedback.arm_command_targets_rad[offset + joint];
        if (std::isfinite(retained)) {
          state.support_offset[joint] = std::clamp(
              retained - measured[joint], -kMaxSupportOffsetRad, kMaxSupportOffsetRad);
          state.target_joints[joint] = retained;
        }
      }
    }
    state.robot_reference = solver.forward(measured);
  }
  const Pose6D target = relative_xr_target(
      state.xr_reference, pose_found->second, state.operator_reference, state.robot_reference,
      config_.arm_position_scale);
  double translation = 0.0;
  for (std::size_t axis = 0; axis < 3; ++axis) {
    const double delta = target.position[axis] - state.robot_reference.position[axis];
    translation += delta * delta;
  }
  const double translation_norm = std::sqrt(translation);
  if (translation_norm > config_.max_arm_translation_m) {
    stop_reason_ = std::string(pose_name) + "_workspace_delta_exceeded";
    return false;
  }

  ArmIkResult solved;
  bool used_position_fallback = false;
  const std::string forward_seed_name =
      side == ArmSide::Left ? "left_prefer_forward" : "right_prefer_forward";
  if (button(latest_, forward_seed_name)) {
    const double sign = side == ArmSide::Left ? 1.0 : -1.0;
    const std::array<double, 7> forward_seed{
        -1.5707963267948966, sign * 0.40, 0.0, 1.5707963267948966,
        -sign * 1.5707963267948966, 0.0, 0.0,
    };
    solved = solver.solve(target, forward_seed);
  } else {
    solved = solver.solve_robust(target, measured);
    // Controller orientation can jump or briefly become inconsistent while
    // position tracking remains valid. For small local motions, preserve
    // useful Cartesian translation instead of stopping the whole arm. Keep
    // this fallback deliberately local so it cannot select a distant posture
    // branch for a large move.
    if (!solved.converged && translation_norm <= 0.12) {
      solved = solver.solve_position(target, measured);
      used_position_fallback = solved.converged;
    }
  }
  if (!solved.converged) {
    std::cerr << "[operator-g1d] arm_ik_rejected side=" << (side == ArmSide::Left ? "left" : "right")
              << " robot_delta=" << target.position[0] - state.robot_reference.position[0]
              << ',' << target.position[1] - state.robot_reference.position[1]
              << ',' << target.position[2] - state.robot_reference.position[2]
              << " position_error=" << solved.position_error_m
              << " rotation_error=" << solved.rotation_error_rad << '\n';
    stop_reason_ = std::string(pose_name) + "_ik_not_converged";
    return false;
  }
  ++state.debug_cycles;
  if (state.debug_cycles == 1 || state.debug_cycles % 50 == 0) {
    std::cerr << "[operator-g1d] arm_ik side=" << (side == ArmSide::Left ? "left" : "right")
              << " robot_delta=" << target.position[0] - state.robot_reference.position[0]
              << ',' << target.position[1] - state.robot_reference.position[1]
              << ',' << target.position[2] - state.robot_reference.position[2]
              << " position_error=" << solved.position_error_m
              << " rotation_error=" << solved.rotation_error_rad
              << " position_fallback=" << (used_position_fallback ? "true" : "false") << '\n';
  }
  for (std::size_t sample = state.solution_history.size() - 1; sample > 0; --sample) {
    state.solution_history[sample] = state.solution_history[sample - 1];
  }
  state.solution_history[0] = solved.joints;
  state.solution_history_size = std::min(
      state.solution_history_size + 1, state.solution_history.size());
  constexpr std::array<double, 4> kFilterWeights{0.4, 0.3, 0.2, 0.1};
  for (std::size_t joint = 0; joint < state.target_joints.size(); ++joint) {
    double filtered = 0.0;
    double weight_sum = 0.0;
    for (std::size_t sample = 0; sample < state.solution_history_size; ++sample) {
      filtered += kFilterWeights[sample] * state.solution_history[sample][joint];
      weight_sum += kFilterWeights[sample];
    }
    filtered /= weight_sum;
    // Keep the backend's pre-Grip holding error while applying the Cartesian
    // IK delta around measured q.  Sending measured q on the rising edge
    // would make the PD error (and therefore its gravity-supporting torque)
    // collapse to zero, which is perceived as the arm dropping.
    const double supported_measured = measured[joint] + state.support_offset[joint];
    state.target_joints[joint] = std::clamp(
        supported_measured + std::clamp(
            filtered - measured[joint], -max_joint_step, max_joint_step),
        solver.lower_limits()[joint], solver.upper_limits()[joint]);
    targets[offset + joint] = state.target_joints[joint];
  }
  return true;
}

ActuatorCommand CommandController::resolve(
    const BackendSnapshot& feedback,
    std::chrono::steady_clock::time_point now,
    std::chrono::duration<double> elapsed) {
  std::lock_guard<std::mutex> lock(mutex_);
  ActuatorCommand output;

  if (!config_.motion_authorized) {
    mode_ = MotionMode::Stopped;
    stop_reason_ = "motion_not_authorized";
    reset_arm_references();
    reset_hand_references();
    return output;
  }
  if (estop_latched_) {
    mode_ = MotionMode::Stopped;
    reset_arm_references();
    reset_hand_references();
    return output;
  }
  if (!have_command_) {
    mode_ = MotionMode::Stopped;
    reset_arm_references();
    reset_hand_references();
    return output;
  }

  const auto age = now - last_command_at_;
  if (age > config_.command_timeout) {
    watchdog_active_ = true;
    release_required_ = true;
    mode_ = MotionMode::Stopped;
    stop_reason_ = "command_timeout";
    current_vx_mps_ = 0.0;
    current_wz_rad_s_ = 0.0;
    current_lift_ = 0.0;
    reset_arm_references();
    reset_hand_references();
    return output;
  }

  constexpr double kMotionEpsilon = 1e-6;
  const bool base_enable =
      button(latest_, "base_enable") ||
      std::abs(axis(latest_, "base_linear")) > kMotionEpsilon ||
      std::abs(axis(latest_, "base_yaw")) > kMotionEpsilon;
  const bool lift_enable =
      button(latest_, "lift_enable") ||
      button(latest_, "lift_down") ||
      button(latest_, "lift_up") ||
      std::abs(axis(latest_, "lift_speed")) > kMotionEpsilon;
  const bool arm_ready_triggered = arm_ready_request_pending_;
  arm_ready_request_pending_ = false;
  const bool arm_init_triggered = arm_init_request_pending_;
  arm_init_request_pending_ = false;
  const bool arm_enable =
      button(latest_, "left_enable") || button(latest_, "right_enable") ||
      arm_ready_triggered || arm_init_triggered || arm_ready_active_ || arm_init_active_;

  if (release_required_) {
    if (motion_controls_neutral(latest_)) {
      release_required_ = false;
    } else {
      mode_ = MotionMode::Stopped;
      stop_reason_ = "return_controls_to_neutral_after_stop";
      reset_arm_references();
      reset_hand_references();
      return output;
    }
  }

  const int active_modes = static_cast<int>(base_enable) + static_cast<int>(lift_enable) +
                           static_cast<int>(arm_enable);
  if (active_modes > 1) {
    control_conflict_ = true;
    release_required_ = true;
    mode_ = MotionMode::Conflict;
    stop_reason_ = "control_mode_conflict";
    current_vx_mps_ = 0.0;
    current_wz_rad_s_ = 0.0;
    current_lift_ = 0.0;
    reset_arm_references();
    reset_hand_references();
    return output;
  }
  control_conflict_ = false;

  const auto attach_hands = [&]() {
    if (resolve_hands(feedback, elapsed, output)) {
      return true;
    }
    release_required_ = true;
    mode_ = MotionMode::Stopped;
    output = ActuatorCommand{};
    reset_arm_references();
    reset_hand_references();
    return false;
  };

  if (arm_enable) {
    current_vx_mps_ = 0.0;
    current_wz_rad_s_ = 0.0;
    current_lift_ = 0.0;
    if (!feedback.lowstate_fresh ||
        feedback.lowstate_age_ms > config_.lowstate_timeout.count() ||
        feedback.joint_positions_rad.size() < 29 ||
        feedback.joint_velocities_rad_s.size() < 29) {
      release_required_ = true;
      reset_arm_references();
      reset_hand_references();
      mode_ = MotionMode::Stopped;
      stop_reason_ = "stale_or_incomplete_joint_feedback";
      return output;
    }
    for (std::size_t joint = 0; joint < 29; ++joint) {
      if (!std::isfinite(feedback.joint_positions_rad[joint]) ||
          !std::isfinite(feedback.joint_velocities_rad_s[joint])) {
        release_required_ = true;
        reset_arm_references();
        reset_hand_references();
        mode_ = MotionMode::Stopped;
        stop_reason_ = "non_finite_joint_feedback";
        return output;
      }
    }
    for (std::size_t joint = 15; joint < 29; ++joint) {
      if (std::abs(feedback.joint_velocities_rad_s[joint]) >
          config_.max_measured_arm_velocity_rad_s) {
        estop_latched_ = true;
        release_required_ = true;
        reset_arm_references();
        reset_hand_references();
        mode_ = MotionMode::Stopped;
        stop_reason_ = "measured_arm_speed_limit";
        return output;
      }
    }
    if (feedback.motor_fault_count > 0) {
      estop_latched_ = true;
      release_required_ = true;
      reset_arm_references();
      reset_hand_references();
      mode_ = MotionMode::Stopped;
      stop_reason_ = "upper_body_motor_fault";
      return output;
    }
    if (arm_ready_triggered || arm_init_triggered) {
      arm_ready_active_ = arm_ready_triggered;
      arm_init_active_ = arm_init_triggered && !arm_ready_triggered;
      for (std::size_t joint = 0; joint < 7; ++joint) {
        arm_ready_targets_[joint] = feedback.joint_positions_rad[15 + joint];
        arm_ready_targets_[7 + joint] = feedback.joint_positions_rad[22 + joint];
      }
      left_arm_.engaged = false;
      right_arm_.engaged = false;
    }
    if (arm_ready_active_ || arm_init_active_) {
      constexpr double kRightAngleRad = 1.5707963267948966;
      constexpr std::array<double, 14> kReadyPose{
          0.0, 0.20, 0.0, 0.0, 0.0, 0.0, 0.0,
          0.0, -0.20, 0.0, 0.0, 0.0, 0.0, 0.0,
      };
      constexpr std::array<double, 14> kInitialPose{
          0.0, 0.0, 0.0, kRightAngleRad, 0.0, 0.0, 0.0,
          0.0, 0.0, 0.0, kRightAngleRad, 0.0, 0.0, 0.0,
      };
      const auto& pose = arm_ready_active_ ? kReadyPose : kInitialPose;
      output.joint_targets_rad = feedback.joint_positions_rad;
      const double dt = std::clamp(elapsed.count(), 0.0, 0.25);
      const double max_step = config_.max_arm_ready_joint_velocity_rad_s * dt;
      double max_measured_error = 0.0;
      for (std::size_t joint = 0; joint < pose.size(); ++joint) {
        arm_ready_targets_[joint] = slew(arm_ready_targets_[joint], pose[joint], max_step);
        const std::size_t motor = joint < 7 ? 15 + joint : 22 + (joint - 7);
        output.joint_targets_rad[motor] = arm_ready_targets_[joint];
        max_measured_error = std::max(
            max_measured_error,
            std::abs(feedback.joint_positions_rad[motor] - pose[joint]));
      }
      mode_ = MotionMode::Arms;
      stop_reason_.clear();
      output.mode = mode_;
      output.arms_active = true;
      if (!resolve_hands_open(feedback, elapsed, output)) {
        release_required_ = true;
        reset_arm_references();
        reset_hand_references();
        return ActuatorCommand{};
      }
      if (max_measured_error <= 0.04) {
        arm_ready_active_ = false;
        arm_init_active_ = false;
      }
      return output;
    }
    if (!manual_arm_hold_initialized_) {
      const bool have_retained_targets = feedback.arm_command_targets_rad.size() >= 29;
      for (std::size_t joint = 0; joint < 7; ++joint) {
        left_arm_.target_joints[joint] = have_retained_targets
                                              ? feedback.arm_command_targets_rad[15 + joint]
                                              : feedback.joint_positions_rad[15 + joint];
        right_arm_.target_joints[joint] = have_retained_targets
                                               ? feedback.arm_command_targets_rad[22 + joint]
                                               : feedback.joint_positions_rad[22 + joint];
      }
      manual_arm_hold_initialized_ = true;
    }
    output.joint_targets_rad = feedback.joint_positions_rad;
    for (std::size_t joint = 0; joint < 7; ++joint) {
      output.joint_targets_rad[15 + joint] = left_arm_.target_joints[joint];
      output.joint_targets_rad[22 + joint] = right_arm_.target_joints[joint];
    }
    const double dt = std::clamp(elapsed.count(), 0.0, 0.25);
    const double max_joint_step = config_.max_arm_joint_velocity_rad_s * dt;
    const bool left_ok = resolve_arm(
        ArmSide::Left, "left_enable", "left_end_effector", feedback,
        max_joint_step, output.joint_targets_rad);
    const bool right_ok = resolve_arm(
        ArmSide::Right, "right_enable", "right_end_effector", feedback,
        max_joint_step, output.joint_targets_rad);
    if (!left_ok || !right_ok) {
      release_required_ = true;
      reset_arm_references();
      reset_hand_references();
      mode_ = MotionMode::Stopped;
      output.joint_targets_rad.clear();
      return output;
    }
    mode_ = MotionMode::Arms;
    stop_reason_.clear();
    output.mode = mode_;
    output.arms_active = true;
    if (!attach_hands()) return output;
    return output;
  }
  reset_arm_references();

  if (base_enable) {
    if (!feedback.odom_fresh || feedback.odom_age_ms > config_.odom_timeout.count()) {
      release_required_ = true;
      mode_ = MotionMode::Stopped;
      stop_reason_ = "stale_odometry";
      current_vx_mps_ = 0.0;
      current_wz_rad_s_ = 0.0;
      reset_hand_references();
      return output;
    }
    if (std::abs(feedback.measured_vx_mps) > config_.max_measured_vx_mps ||
        std::abs(feedback.measured_vy_mps) > config_.max_measured_vx_mps ||
        std::abs(feedback.measured_wz_rad_s) > config_.max_measured_wz_rad_s) {
      estop_latched_ = true;
      release_required_ = true;
      mode_ = MotionMode::Stopped;
      stop_reason_ = "measured_base_speed_limit";
      current_vx_mps_ = 0.0;
      current_wz_rad_s_ = 0.0;
      reset_hand_references();
      return output;
    }

    const double dt = std::clamp(elapsed.count(), 0.0, 0.25);
    current_vx_mps_ = slew(
        current_vx_mps_,
        axis(latest_, "base_linear") * config_.max_base_vx_mps,
        config_.base_linear_slew_mps2 * dt);
    current_wz_rad_s_ = slew(
        current_wz_rad_s_,
        axis(latest_, "base_yaw") * config_.max_base_wz_rad_s,
        config_.base_angular_slew_rad_s2 * dt);
    current_lift_ = 0.0;
    mode_ = MotionMode::Base;
    stop_reason_.clear();
    output.mode = mode_;
    output.base_active = true;
    output.base_vx_mps = current_vx_mps_;
    output.base_wz_rad_s = current_wz_rad_s_;
    if (!attach_hands()) return output;
    return output;
  }

  if (lift_enable) {
    if (!feedback.height_fresh || feedback.height_age_ms > config_.height_timeout.count()) {
      release_required_ = true;
      mode_ = MotionMode::Stopped;
      stop_reason_ = "stale_height_feedback";
      current_lift_ = 0.0;
      reset_hand_references();
      return output;
    }
    const double dt = std::clamp(elapsed.count(), 0.0, 0.25);
    const double lift_button_command =
        static_cast<double>(button(latest_, "lift_up")) -
        static_cast<double>(button(latest_, "lift_down"));
    const double lift_command = lift_button_command != 0.0
                                    ? lift_button_command
                                    : axis(latest_, "lift_speed");
    current_lift_ = slew(
        current_lift_,
        lift_command * config_.max_height_command,
        config_.lift_slew_per_s * dt);
    current_vx_mps_ = 0.0;
    current_wz_rad_s_ = 0.0;
    mode_ = MotionMode::Lift;
    stop_reason_.clear();
    output.mode = mode_;
    output.lift_active = true;
    output.lift_normalized = current_lift_;
    if (!attach_hands()) return output;
    return output;
  }

  current_vx_mps_ = 0.0;
  current_wz_rad_s_ = 0.0;
  current_lift_ = 0.0;
  mode_ = MotionMode::Idle;
  stop_reason_.clear();
  output.mode = mode_;
  if (!attach_hands()) return output;
  return output;
}

ControllerStatus CommandController::status(std::chrono::steady_clock::time_point now) const {
  std::lock_guard<std::mutex> lock(mutex_);
  ControllerStatus result;
  result.motion_authorized = config_.motion_authorized;
  result.estop_latched = estop_latched_;
  result.watchdog_active = watchdog_active_;
  result.release_required = release_required_;
  result.control_conflict = control_conflict_;
  result.mode = mode_;
  result.stop_reason = stop_reason_;
  if (have_command_) {
    result.command_age_ms =
        std::chrono::duration<double, std::milli>(now - last_command_at_).count();
  }
  return result;
}

}  // namespace operator_g1d
