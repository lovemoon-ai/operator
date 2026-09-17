#pragma once

#include <array>
#include <chrono>
#include <cstdint>
#include <map>
#include <optional>
#include <string>
#include <vector>

namespace operator_g1d {

struct Pose6D {
  std::array<double, 3> position{};
  std::array<double, 4> rotation{0.0, 0.0, 0.0, 1.0};
};

struct DeviceCommand {
  std::map<std::string, double> axes;
  std::map<std::string, bool> buttons;
  std::map<std::string, Pose6D> poses;
  std::uint64_t timestamp_ns = 0;
};

enum class InboundKind {
  Hello,
  Command,
  Stop,
  BlueprintEvent,
  Shutdown,
};

struct InboundMessage {
  InboundKind kind = InboundKind::Hello;
  DeviceCommand command;
  std::string reason;
};

struct TelemetryValues {
  std::map<std::string, double> floats;
  std::map<std::string, std::int64_t> integers;
  std::map<std::string, bool> booleans;
  std::map<std::string, std::string> strings;
  std::map<std::string, std::vector<double>> arrays;
};

struct BackendSnapshot {
  bool connected = false;
  bool odom_fresh = false;
  bool height_fresh = false;
  bool lowstate_fresh = false;
  double odom_age_ms = -1.0;
  double height_age_ms = -1.0;
  double lowstate_age_ms = -1.0;
  double odom_x_m = 0.0;
  double odom_y_m = 0.0;
  double odom_yaw_rad = 0.0;
  double measured_vx_mps = 0.0;
  double measured_vy_mps = 0.0;
  double measured_wz_rad_s = 0.0;
  double height_m = 0.0;
  std::vector<double> joint_positions_rad;
  std::vector<double> joint_velocities_rad_s;
  // Last position targets actually retained by the backend.  These may
  // intentionally differ from measured q: with tau_ff unavailable that
  // position error supplies the torque which holds an arm against gravity.
  std::vector<double> arm_command_targets_rad;
  std::int64_t motor_fault_count = 0;
  std::int64_t mode_machine = 0;
  std::int64_t last_base_result = 0;
  std::int64_t last_height_result = 0;
  bool left_hand_fresh = false;
  bool right_hand_fresh = false;
  double left_hand_age_ms = -1.0;
  double right_hand_age_ms = -1.0;
  std::vector<double> left_hand_positions;
  std::vector<double> right_hand_positions;
  std::vector<double> left_hand_velocities;
  std::vector<double> right_hand_velocities;
  std::vector<double> left_hand_currents;
  std::vector<double> right_hand_currents;
};

enum class MotionMode {
  Idle,
  Base,
  Lift,
  Arms,
  Conflict,
  Stopped,
};

struct ActuatorCommand {
  MotionMode mode = MotionMode::Idle;
  bool base_active = false;
  bool lift_active = false;
  bool arms_active = false;
  double base_vx_mps = 0.0;
  double base_wz_rad_s = 0.0;
  double lift_normalized = 0.0;
  std::vector<double> joint_targets_rad;
  bool left_hand_active = false;
  bool right_hand_active = false;
  std::array<double, 6> left_hand_targets{};
  std::array<double, 6> right_hand_targets{};
};

struct ControllerStatus {
  bool motion_authorized = false;
  bool estop_latched = true;
  bool watchdog_active = false;
  bool release_required = true;
  bool control_conflict = false;
  MotionMode mode = MotionMode::Stopped;
  double command_age_ms = -1.0;
  std::string stop_reason = "startup_interlock";
};

std::string motion_mode_name(MotionMode mode);
std::uint64_t system_time_ns();

}  // namespace operator_g1d
