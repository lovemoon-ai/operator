#pragma once

#include <array>
#include <chrono>
#include <mutex>
#include <string>

#include "operator_g1d/arm_ik.hpp"
#include "operator_g1d/types.hpp"

namespace operator_g1d {

struct ControllerConfig {
  bool motion_authorized = false;
  std::chrono::milliseconds command_timeout{750};
  std::chrono::milliseconds odom_timeout{250};
  std::chrono::milliseconds height_timeout{500};
  std::chrono::milliseconds lowstate_timeout{250};
  std::chrono::milliseconds hand_timeout{250};
  double max_base_vx_mps = 0.12;
  double max_base_wz_rad_s = 0.40;
  double max_height_command = 0.20;
  double max_measured_vx_mps = 0.20;
  double max_measured_wz_rad_s = 0.75;
  double base_linear_slew_mps2 = 0.20;
  double base_angular_slew_rad_s2 = 0.50;
  double lift_slew_per_s = 1.0;
  double arm_position_scale = 1.0;
  double max_arm_translation_m = 0.35;
  double max_arm_joint_velocity_rad_s = 1.0;
  double max_measured_arm_velocity_rad_s = 2.0;
  double max_arm_ready_joint_velocity_rad_s = 0.5;
  double max_hand_target_rate_per_s = 1.0;
  double max_measured_hand_velocity = 1.5;
  double max_abs_hand_current = 0.8;
  double revo1_grasp_target = 0.85;
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
  bool resolve_arm(
      ArmSide side,
      const char* enable_name,
      const char* pose_name,
      const BackendSnapshot& feedback,
      double max_joint_step,
      std::vector<double>& targets);
  void reset_arm_references();
  bool resolve_hand(
      bool left,
      const BackendSnapshot& feedback,
      double max_step,
      ActuatorCommand& output,
      bool force_open = false);
  bool resolve_hands(
      const BackendSnapshot& feedback,
      std::chrono::duration<double> elapsed,
      ActuatorCommand& output);
  bool resolve_hands_open(
      const BackendSnapshot& feedback,
      std::chrono::duration<double> elapsed,
      ActuatorCommand& output);
  void reset_hand_references();

  struct ArmControlState {
    bool engaged = false;
    std::uint64_t debug_cycles = 0;
    Pose6D xr_reference;
    Pose6D operator_reference;
    Pose6D robot_reference;
    std::array<double, 7> target_joints{};
    std::array<double, 7> support_offset{};
    std::array<std::array<double, 7>, 4> solution_history{};
    std::size_t solution_history_size = 0;
  };

  struct HandControlState {
    bool engaged = false;
    bool grasp_latched = false;
    std::array<double, 6> targets{};
  };

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
  ArmIkSolver left_ik_{ArmSide::Left};
  ArmIkSolver right_ik_{ArmSide::Right};
  ArmControlState left_arm_;
  ArmControlState right_arm_;
  HandControlState left_hand_;
  HandControlState right_hand_;
  bool arm_ready_active_ = false;
  bool arm_init_active_ = false;
  bool arm_ready_request_pending_ = false;
  bool arm_init_request_pending_ = false;
  bool arm_ready_button_was_pressed_ = false;
  bool arm_init_button_was_pressed_ = false;
  bool manual_arm_hold_initialized_ = false;
  std::array<double, 14> arm_ready_targets_{};
};

}  // namespace operator_g1d
