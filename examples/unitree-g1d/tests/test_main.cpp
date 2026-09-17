#ifdef NDEBUG
#undef NDEBUG
#endif

#include <cassert>
#include <chrono>
#include <cmath>
#include <iostream>
#include <string>
#include <sys/socket.h>
#include <unistd.h>

#include "operator_g1d/controller.hpp"
#include "operator_g1d/arm_ik.hpp"
#include "operator_g1d/protocol.hpp"

namespace {

using namespace std::chrono_literals;
using operator_g1d::BackendSnapshot;
using operator_g1d::CommandController;
using operator_g1d::ControllerConfig;
using operator_g1d::DeviceCommand;
using operator_g1d::InboundKind;
using operator_g1d::MotionMode;
using operator_g1d::Pose6D;

BackendSnapshot fresh_feedback() {
  BackendSnapshot feedback;
  feedback.connected = true;
  feedback.odom_fresh = true;
  feedback.height_fresh = true;
  feedback.lowstate_fresh = true;
  feedback.odom_age_ms = 0.0;
  feedback.height_age_ms = 0.0;
  feedback.lowstate_age_ms = 0.0;
  return feedback;
}

DeviceCommand neutral_reset() {
  DeviceCommand command;
  command.buttons["reset"] = true;
  return command;
}

void clear_estop(CommandController& controller, std::chrono::steady_clock::time_point start) {
  controller.accept(neutral_reset(), start);
}

void test_protocol_parses_command() {
  const auto message = operator_g1d::parse_inbound_message(
      R"({"type":"Command","axes":{"base_linear":0.5},"buttons":{},"poses":{},"timestamp_ns":7})");
  assert(message.kind == InboundKind::Command);
  assert(std::abs(message.command.axes.at("base_linear") - 0.5) < 1e-9);
  assert(message.command.buttons.empty());
  assert(message.command.timestamp_ns == 7);
}

void test_protocol_detects_blueprint_event() {
  const auto message = operator_g1d::parse_inbound_message(
      R"({"type":"BlueprintEvent","event":{"schema":"operator.blueprint_event.v1","blueprint_id":"unitree.g1d.status","blueprint_revision":1,"sequence":2,"timestamp_ns":3,"component_id":"future_control","action":"toggle"}})");
  assert(message.kind == InboundKind::BlueprintEvent);
}

void test_blueprint_values_json() {
  operator_g1d::TelemetryValues values;
  values.strings["g1d.motion_state"] = "idle";
  assert(operator_g1d::make_values_json(values).find(
             R"("g1d.motion_state":"idle")") != std::string::npos);
}

void test_framing_round_trip() {
  int sockets[2] = {-1, -1};
  assert(::socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) == 0);
  const std::string original = R"({"type":"Hello"})";
  operator_g1d::write_frame(sockets[0], original);
  operator_g1d::FrameReader reader;
  std::string decoded;
  const auto result = reader.read(sockets[1], decoded, 100ms);
  assert(result == operator_g1d::ReadFrameResult::Frame);
  assert(decoded == original);
  ::close(sockets[0]);
  ::close(sockets[1]);
}

void test_framing_preserves_partial_reads() {
  int sockets[2] = {-1, -1};
  assert(::socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) == 0);
  const std::string original = R"({"type":"Hello"})";
  const std::uint32_t length = static_cast<std::uint32_t>(original.size());
  const std::array<std::uint8_t, 4> header{
      static_cast<std::uint8_t>(length & 0xffU),
      static_cast<std::uint8_t>((length >> 8U) & 0xffU),
      static_cast<std::uint8_t>((length >> 16U) & 0xffU),
      static_cast<std::uint8_t>((length >> 24U) & 0xffU),
  };

  assert(::send(sockets[0], header.data(), 2, 0) == 2);
  operator_g1d::FrameReader reader;
  std::string decoded;
  assert(reader.read(sockets[1], decoded, 5ms) == operator_g1d::ReadFrameResult::Timeout);

  assert(::send(sockets[0], header.data() + 2, 2, 0) == 2);
  assert(::send(sockets[0], original.data(), original.size(), 0) ==
         static_cast<ssize_t>(original.size()));
  assert(reader.read(sockets[1], decoded, 100ms) == operator_g1d::ReadFrameResult::Frame);
  assert(decoded == original);

  ::close(sockets[0]);
  ::close(sockets[1]);
}

void test_controller_requires_reset_then_drives() {
  ControllerConfig config;
  config.motion_authorized = true;
  CommandController controller(config);
  const auto start = std::chrono::steady_clock::now();

  clear_estop(controller, start);
  DeviceCommand drive;
  drive.axes["base_linear"] = 1.0;
  controller.accept(drive, start + 10ms);
  const auto output = controller.resolve(fresh_feedback(), start + 20ms, 20ms);
  assert(output.mode == MotionMode::Base);
  assert(output.base_active);
  assert(output.base_vx_mps > 0.0);
  assert(output.base_vx_mps <= config.max_base_vx_mps);
}

void test_controller_activates_lift_from_buttons() {
  ControllerConfig config;
  config.motion_authorized = true;
  CommandController controller(config);
  const auto start = std::chrono::steady_clock::now();

  clear_estop(controller, start);
  DeviceCommand raise;
  raise.buttons["lift_up"] = true;
  controller.accept(raise, start + 10ms);
  const auto raised = controller.resolve(fresh_feedback(), start + 20ms, 20ms);
  assert(raised.mode == MotionMode::Lift);
  assert(raised.lift_active);
  assert(raised.lift_normalized > 0.0);
  assert(raised.lift_normalized <= config.max_height_command);

  DeviceCommand lower;
  lower.buttons["lift_down"] = true;
  controller.accept(lower, start + 30ms);
  const auto lowered = controller.resolve(fresh_feedback(), start + 60ms, 40ms);
  assert(lowered.mode == MotionMode::Lift);
  assert(lowered.lift_active);
  assert(lowered.lift_normalized < 0.0);
}

void test_neutral_stick_stops_without_enable_button() {
  ControllerConfig config;
  config.motion_authorized = true;
  CommandController controller(config);
  const auto start = std::chrono::steady_clock::now();
  clear_estop(controller, start);

  DeviceCommand drive;
  drive.axes["base_yaw"] = 1.0;
  controller.accept(drive, start + 10ms);
  assert(controller.resolve(fresh_feedback(), start + 20ms, 20ms).base_active);

  controller.accept(DeviceCommand{}, start + 30ms);
  const auto stopped = controller.resolve(fresh_feedback(), start + 40ms, 20ms);
  assert(stopped.mode == MotionMode::Idle);
  assert(!stopped.base_active);
  assert(!stopped.lift_active);
}

void test_conflicting_modes_stop() {
  ControllerConfig config;
  config.motion_authorized = true;
  CommandController controller(config);
  const auto start = std::chrono::steady_clock::now();
  clear_estop(controller, start);

  DeviceCommand conflict;
  conflict.axes["base_linear"] = 0.5;
  conflict.buttons["lift_up"] = true;
  controller.accept(conflict, start + 10ms);
  const auto output = controller.resolve(fresh_feedback(), start + 20ms, 20ms);
  assert(output.mode == MotionMode::Idle);
  assert(!output.base_active);
  assert(!output.lift_active);
  assert(controller.status(start + 20ms).control_conflict);
  assert(controller.status(start + 20ms).release_required);

  DeviceCommand base_only;
  base_only.axes["base_linear"] = 0.5;
  controller.accept(base_only, start + 30ms);
  assert(!controller.resolve(fresh_feedback(), start + 40ms, 20ms).base_active);

  controller.accept(DeviceCommand{}, start + 50ms);
  controller.resolve(fresh_feedback(), start + 60ms, 20ms);
  controller.accept(base_only, start + 70ms);
  assert(controller.resolve(fresh_feedback(), start + 80ms, 20ms).base_active);
}

void test_watchdog_requires_neutral_return() {
  ControllerConfig config;
  config.motion_authorized = true;
  config.command_timeout = 50ms;
  CommandController controller(config);
  const auto start = std::chrono::steady_clock::now();
  clear_estop(controller, start);

  DeviceCommand drive;
  drive.axes["base_linear"] = 0.5;
  controller.accept(drive, start + 10ms);
  const auto stopped = controller.resolve(fresh_feedback(), start + 100ms, 90ms);
  assert(!stopped.base_active);
  assert(controller.status(start + 100ms).watchdog_active);

  controller.accept(drive, start + 110ms);
  const auto still_stopped = controller.resolve(fresh_feedback(), start + 120ms, 20ms);
  assert(!still_stopped.base_active);
  assert(controller.status(start + 120ms).release_required);

  DeviceCommand released;
  controller.accept(released, start + 130ms);
  controller.resolve(fresh_feedback(), start + 140ms, 20ms);
  controller.accept(drive, start + 150ms);
  const auto resumed = controller.resolve(fresh_feedback(), start + 160ms, 20ms);
  assert(resumed.base_active);
}

void test_stale_feedback_requires_neutral_return() {
  ControllerConfig config;
  config.motion_authorized = true;
  CommandController controller(config);
  const auto start = std::chrono::steady_clock::now();
  clear_estop(controller, start);

  DeviceCommand drive;
  drive.axes["base_linear"] = 0.5;
  controller.accept(drive, start + 10ms);

  BackendSnapshot stale = fresh_feedback();
  stale.odom_fresh = false;
  const auto stopped = controller.resolve(stale, start + 20ms, 20ms);
  assert(!stopped.base_active);
  assert(controller.status(start + 20ms).release_required);

  const auto still_stopped = controller.resolve(fresh_feedback(), start + 30ms, 10ms);
  assert(!still_stopped.base_active);
}

void test_lateral_speed_guard_latches_estop() {
  ControllerConfig config;
  config.motion_authorized = true;
  CommandController controller(config);
  const auto start = std::chrono::steady_clock::now();
  clear_estop(controller, start);

  DeviceCommand drive;
  drive.axes["base_linear"] = 0.5;
  controller.accept(drive, start + 10ms);
  BackendSnapshot feedback = fresh_feedback();
  feedback.measured_vy_mps = config.max_measured_vx_mps + 0.01;
  const auto stopped = controller.resolve(feedback, start + 20ms, 20ms);
  assert(!stopped.base_active);
  assert(controller.status(start + 20ms).estop_latched);
  assert(controller.status(start + 20ms).stop_reason == "measured_base_speed_limit");
}

void test_yaw_speed_guard_allows_observed_peak_then_latches() {
  ControllerConfig config;
  config.motion_authorized = true;
  CommandController controller(config);
  const auto start = std::chrono::steady_clock::now();
  clear_estop(controller, start);

  DeviceCommand turn;
  turn.axes["base_yaw"] = 1.0;
  controller.accept(turn, start + 10ms);
  BackendSnapshot feedback = fresh_feedback();
  feedback.measured_wz_rad_s = 0.659;
  const auto allowed = controller.resolve(feedback, start + 20ms, 20ms);
  assert(allowed.base_active);
  assert(!controller.status(start + 20ms).estop_latched);

  feedback.measured_wz_rad_s = config.max_measured_wz_rad_s + 0.01;
  const auto stopped = controller.resolve(feedback, start + 30ms, 10ms);
  assert(!stopped.base_active);
  assert(controller.status(start + 30ms).estop_latched);
}

void test_estop_wins_over_reset_in_same_command() {
  ControllerConfig config;
  config.motion_authorized = true;
  CommandController controller(config);
  const auto start = std::chrono::steady_clock::now();
  clear_estop(controller, start);
  assert(!controller.status(start).estop_latched);

  DeviceCommand conflicting;
  conflicting.buttons["emergency_stop"] = true;
  conflicting.buttons["reset"] = true;
  controller.accept(conflicting, start + 3ms);

  const auto status = controller.status(start + 3ms);
  assert(status.estop_latched);
  assert(status.stop_reason == "operator_estop");
}

void test_force_stop_is_not_reported_as_watchdog_timeout() {
  ControllerConfig config;
  config.motion_authorized = true;
  CommandController controller(config);
  controller.force_stop("bridge_disconnected");
  const auto status = controller.status(std::chrono::steady_clock::now());
  assert(!status.watchdog_active);
  assert(status.stop_reason == "bridge_disconnected");
}

void test_arm_ik_round_trip_and_limits() {
  operator_g1d::ArmIkSolver solver(operator_g1d::ArmSide::Left);
  const std::array<double, 7> expected{0.25, 0.35, -0.20, 0.75, 0.10, -0.15, 0.20};
  const Pose6D target = solver.forward(expected);
  const auto solved = solver.solve(target, {0.20, 0.30, -0.15, 0.70, 0.05, -0.10, 0.15});
  assert(solved.converged);
  assert(solved.position_error_m < 0.002);
  assert(solved.rotation_error_rad < 0.10);
  for (std::size_t joint = 0; joint < solved.joints.size(); ++joint) {
    assert(solved.joints[joint] >= solver.lower_limits()[joint]);
    assert(solved.joints[joint] <= solver.upper_limits()[joint]);
  }
}

void test_arm_ik_reaches_left_straight_forward_pose_from_ready_region() {
  operator_g1d::ArmIkSolver solver(operator_g1d::ArmSide::Left);
  const std::array<double, 7> straight_forward{
      -1.5707963267948966, 0.40, 0.0, 1.5707963267948966,
      -1.5707963267948966, 0.0, 0.0,
  };
  const std::array<double, 7> start{
      -0.04, -0.03, 0.03, 1.79, -0.01, -0.24, -0.01,
  };
  std::array<double, 7> seed = start;
  for (int stage = 1; stage <= 20; ++stage) {
    std::array<double, 7> waypoint{};
    const double alpha = static_cast<double>(stage) / 20.0;
    for (std::size_t joint = 0; joint < waypoint.size(); ++joint) {
      waypoint[joint] = start[joint] + alpha * (straight_forward[joint] - start[joint]);
    }
    const auto solved = solver.solve_robust(solver.forward(waypoint), seed);
    if (!solved.converged) {
      std::cerr << "straight-forward IK stage=" << stage
                << " position_error=" << solved.position_error_m
                << " rotation_error=" << solved.rotation_error_rad << '\n';
    }
    assert(solved.converged);
    assert(solved.position_error_m < 0.002);
    assert(solved.joints[4] > solver.lower_limits()[4] + 0.05);
    seed = solved.joints;
  }
}

void test_ready_pose_really_places_forearm_forward() {
  operator_g1d::ArmIkSolver solver(operator_g1d::ArmSide::Left);
  const std::array<double, 7> ready{0.0, 0.20, 0.0, 0.0, 0.0, 0.0, 0.0};
  const std::array<double, 7> initial{
      0.0, 0.0, 0.0, 1.5707963267948966, 0.0, 0.0, 0.0,
  };
  const Pose6D ready_pose = solver.forward(ready);
  const Pose6D initial_pose = solver.forward(initial);
  assert(ready_pose.position[0] > initial_pose.position[0] + 0.08);
  assert(ready_pose.position[2] > initial_pose.position[2] + 0.05);
}

void test_relative_xr_target_axis_mapping() {
  Pose6D xr_reference;
  Pose6D xr_current;
  xr_current.position = {0.1, 0.2, -0.3};
  Pose6D robot_reference;
  robot_reference.position = {0.4, -0.2, 0.5};
  Pose6D operator_reference;
  const Pose6D target = operator_g1d::relative_xr_target(
      xr_reference, xr_current, operator_reference, robot_reference, 0.5);
  assert(std::abs(target.position[0] - 0.55) < 1e-9);  // XR forward -> robot +X
  assert(std::abs(target.position[1] + 0.25) < 1e-9);  // XR right -> robot -Y
  assert(std::abs(target.position[2] - 0.60) < 1e-9);  // XR up -> robot +Z
}

void test_relative_xr_target_uses_operator_yaw_frame() {
  Pose6D xr_reference;
  Pose6D xr_current;
  xr_current.position = {-0.2, 0.0, 0.0};
  Pose6D operator_reference;
  const double half_sqrt = std::sqrt(0.5);
  operator_reference.rotation = {0.0, half_sqrt, 0.0, half_sqrt};
  Pose6D robot_reference;
  robot_reference.position = {1.0, 2.0, 3.0};

  const Pose6D target = operator_g1d::relative_xr_target(
      xr_reference, xr_current, operator_reference, robot_reference, 1.0);
  assert(std::abs(target.position[0] - 1.2) < 1e-9);
  assert(std::abs(target.position[1] - 2.0) < 1e-9);
  assert(std::abs(target.position[2] - 3.0) < 1e-9);
}

void test_controller_drives_both_arms_from_pose_targets() {
  ControllerConfig config;
  config.motion_authorized = true;
  CommandController controller(config);
  const auto start = std::chrono::steady_clock::now();
  clear_estop(controller, start);

  BackendSnapshot feedback = fresh_feedback();
  feedback.joint_positions_rad.assign(29, 0.0);
  feedback.joint_velocities_rad_s.assign(29, 0.0);
  DeviceCommand arms;
  arms.buttons["left_enable"] = true;
  arms.buttons["right_enable"] = true;
  arms.poses["left_end_effector"] = Pose6D{};
  arms.poses["right_end_effector"] = Pose6D{};
  controller.accept(arms, start + 10ms);
  const auto acquired = controller.resolve(feedback, start + 20ms, 20ms);
  assert(acquired.mode == MotionMode::Arms);
  assert(acquired.arms_active);
  assert(acquired.joint_targets_rad.size() == 29);

  arms.poses["left_end_effector"].position[1] = 0.005;  // XR up
  controller.accept(arms, start + 30ms);
  const auto moved = controller.resolve(feedback, start + 50ms, 30ms);
  assert(moved.arms_active);
  bool left_changed = false;
  for (std::size_t joint = 15; joint <= 21; ++joint) {
    left_changed = left_changed || std::abs(moved.joint_targets_rad[joint]) > 1e-7;
    assert(std::abs(moved.joint_targets_rad[joint]) <=
           config.max_arm_joint_velocity_rad_s * 0.03 + 1e-9);
  }
  assert(left_changed);
}

void test_single_arm_control_holds_inactive_arm_at_engagement_pose() {
  ControllerConfig config;
  config.motion_authorized = true;
  CommandController controller(config);
  const auto start = std::chrono::steady_clock::now();
  clear_estop(controller, start);

  BackendSnapshot feedback = fresh_feedback();
  feedback.joint_positions_rad.assign(29, 0.0);
  feedback.joint_positions_rad[22] = 0.40;
  feedback.joint_velocities_rad_s.assign(29, 0.0);
  DeviceCommand command;
  command.buttons["left_enable"] = true;
  command.poses["left_end_effector"] = Pose6D{};
  controller.accept(command, start + 10ms);
  const auto engaged = controller.resolve(feedback, start + 20ms, 10ms);
  assert(engaged.arms_active);
  assert(std::abs(engaged.joint_targets_rad[22] - 0.40) < 1e-9);

  feedback.joint_positions_rad[22] = 0.20;
  controller.accept(command, start + 30ms);
  const auto held = controller.resolve(feedback, start + 40ms, 10ms);
  assert(held.arms_active);
  assert(std::abs(held.joint_targets_rad[22] - 0.40) < 1e-9);
}

void test_grip_preserves_backend_arm_support_targets() {
  ControllerConfig config;
  config.motion_authorized = true;
  CommandController controller(config);
  const auto start = std::chrono::steady_clock::now();
  clear_estop(controller, start);

  BackendSnapshot feedback = fresh_feedback();
  feedback.joint_positions_rad.assign(29, 0.0);
  feedback.joint_velocities_rad_s.assign(29, 0.0);
  feedback.joint_positions_rad[18] = 0.40;
  feedback.joint_positions_rad[25] = 0.40;
  feedback.arm_command_targets_rad = feedback.joint_positions_rad;
  feedback.arm_command_targets_rad[18] = 0.48;
  feedback.arm_command_targets_rad[25] = 0.46;

  DeviceCommand command;
  command.buttons["left_enable"] = true;
  command.poses["left_end_effector"] = Pose6D{};
  controller.accept(command, start + 10ms);
  const auto engaged = controller.resolve(feedback, start + 20ms, 10ms);

  assert(engaged.arms_active);
  assert(std::abs(engaged.joint_targets_rad[18] - 0.48) < 1e-9);
  assert(std::abs(engaged.joint_targets_rad[25] - 0.46) < 1e-9);
}

void test_controller_uses_position_fallback_for_small_orientation_jump() {
  ControllerConfig config;
  config.motion_authorized = true;
  CommandController controller(config);
  const auto start = std::chrono::steady_clock::now();
  clear_estop(controller, start);

  BackendSnapshot feedback = fresh_feedback();
  feedback.joint_positions_rad.assign(29, 0.0);
  feedback.joint_velocities_rad_s.assign(29, 0.0);
  DeviceCommand command;
  command.buttons["left_enable"] = true;
  command.poses["left_end_effector"] = Pose6D{};
  controller.accept(command, start + 10ms);
  assert(controller.resolve(feedback, start + 20ms, 10ms).arms_active);

  command.poses["left_end_effector"].position[1] = 0.01;
  command.poses["left_end_effector"].rotation = {1.0, 0.0, 0.0, 0.0};
  controller.accept(command, start + 30ms);
  const auto moved = controller.resolve(feedback, start + 40ms, 10ms);
  assert(moved.arms_active);
  assert(!controller.status(start + 40ms).release_required);
}

void test_arm_rate_limit_is_relative_to_measured_state() {
  ControllerConfig config;
  config.motion_authorized = true;
  config.max_arm_joint_velocity_rad_s = 0.5;
  CommandController controller(config);
  const auto start = std::chrono::steady_clock::now();
  clear_estop(controller, start);

  BackendSnapshot feedback = fresh_feedback();
  feedback.joint_positions_rad.assign(29, 0.0);
  feedback.joint_velocities_rad_s.assign(29, 0.0);
  DeviceCommand command;
  command.buttons["left_enable"] = true;
  command.poses["left_end_effector"] = Pose6D{};
  controller.accept(command, start + 10ms);
  controller.resolve(feedback, start + 20ms, 10ms);

  command.poses["left_end_effector"].position[1] = 0.02;
  controller.accept(command, start + 30ms);
  const auto first = controller.resolve(feedback, start + 50ms, 20ms);
  const auto second = controller.resolve(feedback, start + 70ms, 20ms);
  for (std::size_t joint = 15; joint < 22; ++joint) {
    assert(std::abs(first.joint_targets_rad[joint] - feedback.joint_positions_rad[joint]) <=
           0.0100001);
    assert(std::abs(second.joint_targets_rad[joint] - feedback.joint_positions_rad[joint]) <=
           0.0100001);
  }
}

void test_arm_tracking_loss_requires_release() {
  ControllerConfig config;
  config.motion_authorized = true;
  CommandController controller(config);
  const auto start = std::chrono::steady_clock::now();
  clear_estop(controller, start);
  BackendSnapshot feedback = fresh_feedback();
  feedback.joint_positions_rad.assign(29, 0.0);
  feedback.joint_velocities_rad_s.assign(29, 0.0);

  DeviceCommand command;
  command.buttons["left_enable"] = true;
  controller.accept(command, start + 10ms);
  const auto output = controller.resolve(feedback, start + 20ms, 20ms);
  assert(!output.arms_active);
  assert(controller.status(start + 20ms).release_required);
  assert(controller.status(start + 20ms).stop_reason ==
         "left_end_effector_missing_or_invalid");
}

void test_arm_speed_guard_latches_estop() {
  ControllerConfig config;
  config.motion_authorized = true;
  CommandController controller(config);
  const auto start = std::chrono::steady_clock::now();
  clear_estop(controller, start);
  BackendSnapshot feedback = fresh_feedback();
  feedback.joint_positions_rad.assign(29, 0.0);
  feedback.joint_velocities_rad_s.assign(29, 0.0);
  feedback.joint_velocities_rad_s[15] = config.max_measured_arm_velocity_rad_s + 0.01;

  DeviceCommand command;
  command.buttons["left_enable"] = true;
  command.poses["left_end_effector"] = Pose6D{};
  controller.accept(command, start + 10ms);
  const auto output = controller.resolve(feedback, start + 20ms, 20ms);
  assert(!output.arms_active);
  assert(controller.status(start + 20ms).estop_latched);
  assert(controller.status(start + 20ms).stop_reason == "measured_arm_speed_limit");
}

void test_revo1_controller_targets_are_rate_limited_and_hold_thumb_aux() {
  ControllerConfig config;
  config.motion_authorized = true;
  config.max_hand_target_rate_per_s = 1.0;
  config.revo1_grasp_target = 0.8;
  CommandController controller(config);
  const auto start = std::chrono::steady_clock::now();
  clear_estop(controller, start);
  BackendSnapshot feedback = fresh_feedback();
  feedback.left_hand_fresh = true;
  feedback.left_hand_age_ms = 0.0;
  feedback.left_hand_positions = {0.0, 0.02, 0.0, 0.0, 0.0, 0.0};
  feedback.left_hand_velocities.assign(6, 0.0);
  feedback.left_hand_currents.assign(6, 0.0);

  DeviceCommand command;
  command.buttons["left_hand_enable"] = true;
  command.axes["revo1_left_grasp"] = 1.0;
  controller.accept(command, start + 10ms);
  const auto output = controller.resolve(feedback, start + 110ms, 100ms);
  assert(output.left_hand_active);
  assert(!output.right_hand_active);
  assert(!output.arms_active);
  assert(std::abs(output.left_hand_targets[0] - 0.1) < 1e-9);
  assert(std::abs(output.left_hand_targets[1] - 0.02) < 1e-9);
  assert(std::abs(output.left_hand_targets[2] - 0.1) < 1e-9);
  assert(std::abs(output.left_hand_targets[3] - 0.1) < 1e-9);

  command.axes["revo1_left_grasp"] = 0.0;
  controller.accept(command, start + 120ms);
  const auto opened = controller.resolve(feedback, start + 220ms, 100ms);
  assert(opened.left_hand_active);
  assert(std::abs(opened.left_hand_targets[0]) < 1e-9);
  assert(std::abs(opened.left_hand_targets[2]) < 1e-9);

  controller.accept(DeviceCommand{}, start + 230ms);
  const auto released = controller.resolve(feedback, start + 240ms, 20ms);
  assert(!released.left_hand_active);
}

void test_revo1_current_guard_latches_estop() {
  ControllerConfig config;
  config.motion_authorized = true;
  CommandController controller(config);
  const auto start = std::chrono::steady_clock::now();
  clear_estop(controller, start);
  BackendSnapshot feedback = fresh_feedback();
  feedback.left_hand_fresh = true;
  feedback.left_hand_age_ms = 0.0;
  feedback.left_hand_positions.assign(6, 0.0);
  feedback.left_hand_velocities.assign(6, 0.0);
  feedback.left_hand_currents.assign(6, 0.0);
  feedback.left_hand_currents[2] = config.max_abs_hand_current + 0.01;

  DeviceCommand command;
  command.buttons["left_hand_enable"] = true;
  controller.accept(command, start + 10ms);
  const auto output = controller.resolve(feedback, start + 20ms, 20ms);
  assert(!output.left_hand_active);
  assert(controller.status(start + 20ms).estop_latched);
  assert(controller.status(start + 20ms).stop_reason == "left_hand_current_limit");
}

void test_arm_ready_button_latches_rate_limited_pose_and_opens_hands() {
  ControllerConfig config;
  config.motion_authorized = true;
  config.max_arm_ready_joint_velocity_rad_s = 0.5;
  CommandController controller(config);
  const auto start = std::chrono::steady_clock::now();
  clear_estop(controller, start);
  BackendSnapshot feedback = fresh_feedback();
  feedback.joint_positions_rad.assign(29, 0.0);
  feedback.joint_positions_rad[18] = 1.5707963267948966;
  feedback.joint_positions_rad[25] = 1.5707963267948966;
  feedback.joint_velocities_rad_s.assign(29, 0.0);
  feedback.left_hand_fresh = true;
  feedback.right_hand_fresh = true;
  feedback.left_hand_age_ms = 0.0;
  feedback.right_hand_age_ms = 0.0;
  feedback.left_hand_positions = {0.2, 0.01, 0.2, 0.2, 0.2, 0.2};
  feedback.right_hand_positions = {0.2, 0.02, 0.2, 0.2, 0.2, 0.2};
  feedback.left_hand_velocities.assign(6, 0.0);
  feedback.right_hand_velocities.assign(6, 0.0);
  feedback.left_hand_currents.assign(6, 0.0);
  feedback.right_hand_currents.assign(6, 0.0);

  DeviceCommand ready;
  ready.buttons["arm_ready"] = true;
  controller.accept(ready, start + 10ms);
  const auto first = controller.resolve(feedback, start + 110ms, 100ms);
  assert(first.arms_active);
  assert(first.left_hand_active && first.right_hand_active);
  assert(std::abs(first.joint_targets_rad[16] - 0.05) < 1e-9);
  assert(std::abs(first.joint_targets_rad[23] + 0.05) < 1e-9);
  assert(std::abs(first.joint_targets_rad[18] - (1.5707963267948966 - 0.05)) < 1e-9);
  assert(std::abs(first.joint_targets_rad[25] - (1.5707963267948966 - 0.05)) < 1e-9);
  assert(std::abs(first.left_hand_targets[0] - 0.1) < 1e-9);
  assert(std::abs(first.left_hand_targets[1] - 0.01) < 1e-9);

  controller.accept(DeviceCommand{}, start + 120ms);
  const auto latched = controller.resolve(feedback, start + 220ms, 100ms);
  assert(latched.arms_active);
  assert(latched.left_hand_active && latched.right_hand_active);
}

void test_arm_init_button_latches_straight_down_pose() {
  ControllerConfig config;
  config.motion_authorized = true;
  config.max_arm_ready_joint_velocity_rad_s = 0.5;
  CommandController controller(config);
  const auto start = std::chrono::steady_clock::now();
  clear_estop(controller, start);
  BackendSnapshot feedback = fresh_feedback();
  feedback.joint_positions_rad.assign(29, 0.0);
  feedback.joint_positions_rad[16] = 0.20;
  feedback.joint_positions_rad[23] = -0.20;
  feedback.joint_velocities_rad_s.assign(29, 0.0);
  feedback.left_hand_fresh = true;
  feedback.right_hand_fresh = true;
  feedback.left_hand_age_ms = 0.0;
  feedback.right_hand_age_ms = 0.0;
  feedback.left_hand_positions.assign(6, 0.0);
  feedback.right_hand_positions.assign(6, 0.0);
  feedback.left_hand_velocities.assign(6, 0.0);
  feedback.right_hand_velocities.assign(6, 0.0);
  feedback.left_hand_currents.assign(6, 0.0);
  feedback.right_hand_currents.assign(6, 0.0);

  DeviceCommand init;
  init.buttons["arm_init"] = true;
  controller.accept(init, start + 10ms);
  const auto first = controller.resolve(feedback, start + 110ms, 100ms);
  assert(first.arms_active);
  assert(std::abs(first.joint_targets_rad[16] - 0.15) < 1e-9);
  assert(std::abs(first.joint_targets_rad[23] + 0.15) < 1e-9);
  assert(std::abs(first.joint_targets_rad[18] - 0.05) < 1e-9);
  assert(std::abs(first.joint_targets_rad[25] - 0.05) < 1e-9);
}

}  // namespace

int main() {
  test_protocol_parses_command();
  test_protocol_detects_blueprint_event();
  test_blueprint_values_json();
  test_framing_round_trip();
  test_framing_preserves_partial_reads();
  test_controller_requires_reset_then_drives();
  test_controller_activates_lift_from_buttons();
  test_neutral_stick_stops_without_enable_button();
  test_conflicting_modes_stop();
  test_watchdog_requires_neutral_return();
  test_stale_feedback_requires_neutral_return();
  test_lateral_speed_guard_latches_estop();
  test_yaw_speed_guard_allows_observed_peak_then_latches();
  test_estop_wins_over_reset_in_same_command();
  test_force_stop_is_not_reported_as_watchdog_timeout();
  test_arm_ik_round_trip_and_limits();
  test_arm_ik_reaches_left_straight_forward_pose_from_ready_region();
  test_ready_pose_really_places_forearm_forward();
  test_relative_xr_target_axis_mapping();
  test_relative_xr_target_uses_operator_yaw_frame();
  test_controller_drives_both_arms_from_pose_targets();
  test_single_arm_control_holds_inactive_arm_at_engagement_pose();
  test_grip_preserves_backend_arm_support_targets();
  test_controller_uses_position_fallback_for_small_orientation_jump();
  test_arm_rate_limit_is_relative_to_measured_state();
  test_arm_tracking_loss_requires_release();
  test_arm_speed_guard_latches_estop();
  test_revo1_controller_targets_are_rate_limited_and_hold_thumb_aux();
  test_revo1_current_guard_latches_estop();
  test_arm_ready_button_latches_rate_limited_pose_and_opens_hands();
  test_arm_init_button_latches_straight_down_pose();
  std::cout << "operator-g1d tests passed\n";
  return 0;
}
