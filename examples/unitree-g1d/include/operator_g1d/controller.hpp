#pragma once

#include <chrono>
#include <mutex>
#include <string>

#include "operator_g1d/types.hpp"

namespace operator_g1d {

struct ControllerConfig {
  bool motion_authorized = false;
  std::chrono::milliseconds command_timeout{200};
  std::chrono::milliseconds odom_timeout{250};
  std::chrono::milliseconds height_timeout{500};
  double max_base_vx_mps = 0.12;
  double max_base_wz_rad_s = 0.40;
  double max_height_command = 0.20;
  double max_measured_vx_mps = 0.20;
  double max_measured_wz_rad_s = 0.75;
  double base_linear_slew_mps2 = 0.20;
  double base_angular_slew_rad_s2 = 0.50;
  double lift_slew_per_s = 1.0;
};

class CommandController {
 public:
  explicit CommandController(ControllerConfig config);

  void accept(const DeviceCommand& command, std::chrono::steady_clock::time_point now);
  void force_stop(std::string reason, bool latch_estop = false);
  ActuatorCommand resolve(
      const BackendSnapshot& feedback,
      std::chrono::steady_clock::time_point now,
      std::chrono::duration<double> elapsed);
  ControllerStatus status(std::chrono::steady_clock::time_point now) const;

 private:
  static double axis(const DeviceCommand& command, const std::string& name);
  static bool button(const DeviceCommand& command, const std::string& name);
  static bool motion_controls_neutral(const DeviceCommand& command);
  static bool command_is_neutral(const DeviceCommand& command);
  static double slew(double current, double target, double max_delta);

  ControllerConfig config_;
  mutable std::mutex mutex_;
  DeviceCommand latest_;
  bool have_command_ = false;
  std::chrono::steady_clock::time_point last_command_at_{};
  bool estop_latched_ = true;
  bool watchdog_active_ = false;
  bool release_required_ = true;
  bool control_conflict_ = false;
  MotionMode mode_ = MotionMode::Stopped;
  std::string stop_reason_ = "startup_interlock";
  double current_vx_mps_ = 0.0;
  double current_wz_rad_s_ = 0.0;
  double current_lift_ = 0.0;
};

}  // namespace operator_g1d
