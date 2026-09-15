#include "operator_g1d/controller.hpp"

#include <algorithm>
#include <cmath>
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
         !button(command, "left_enable") && !button(command, "right_enable") &&
         std::abs(axis(command, "base_linear")) <= kNeutralEpsilon &&
         std::abs(axis(command, "base_yaw")) <= kNeutralEpsilon &&
         std::abs(axis(command, "lift_speed")) <= kNeutralEpsilon;
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
    return output;
  }
  if (estop_latched_) {
    mode_ = MotionMode::Stopped;
    return output;
  }
  if (!have_command_) {
    mode_ = MotionMode::Stopped;
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
  const bool arm_enable =
      button(latest_, "left_enable") || button(latest_, "right_enable");

  if (release_required_) {
    if (motion_controls_neutral(latest_)) {
      release_required_ = false;
    } else {
      mode_ = MotionMode::Stopped;
      stop_reason_ = "return_controls_to_neutral_after_stop";
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
    return output;
  }
  control_conflict_ = false;

  if (arm_enable) {
    mode_ = MotionMode::ArmsUnavailable;
    stop_reason_ = "arm_control_not_validated";
    current_vx_mps_ = 0.0;
    current_wz_rad_s_ = 0.0;
    current_lift_ = 0.0;
    return output;
  }

  if (base_enable) {
    if (!feedback.odom_fresh || feedback.odom_age_ms > config_.odom_timeout.count()) {
      release_required_ = true;
      mode_ = MotionMode::Stopped;
      stop_reason_ = "stale_odometry";
      current_vx_mps_ = 0.0;
      current_wz_rad_s_ = 0.0;
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
    return output;
  }

  if (lift_enable) {
    if (!feedback.height_fresh || feedback.height_age_ms > config_.height_timeout.count()) {
      release_required_ = true;
      mode_ = MotionMode::Stopped;
      stop_reason_ = "stale_height_feedback";
      current_lift_ = 0.0;
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
    return output;
  }

  current_vx_mps_ = 0.0;
  current_wz_rad_s_ = 0.0;
  current_lift_ = 0.0;
  mode_ = MotionMode::Idle;
  stop_reason_.clear();
  output.mode = mode_;
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
