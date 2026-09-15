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
#include "operator_g1d/protocol.hpp"

namespace {

using namespace std::chrono_literals;
using operator_g1d::BackendSnapshot;
using operator_g1d::CommandController;
using operator_g1d::ControllerConfig;
using operator_g1d::DeviceCommand;
using operator_g1d::InboundKind;
using operator_g1d::MotionMode;

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
  std::cout << "operator-g1d tests passed\n";
  return 0;
}
