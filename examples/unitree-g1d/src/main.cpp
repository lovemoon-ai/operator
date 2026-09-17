#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <csignal>
#include <cstdlib>
#include <exception>
#include <fstream>
#include <iostream>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>

#include <sys/socket.h>
#include <unistd.h>

#include "operator_g1d/backend.hpp"
#include "operator_g1d/controller.hpp"
#include "operator_g1d/protocol.hpp"
#include "operator_g1d/socket_server.hpp"
#include <operator/operator.hpp>

namespace {

using operator_g1d::Backend;
using operator_g1d::BackendSnapshot;
using operator_g1d::CommandController;
using operator_g1d::ControllerConfig;
using operator_g1d::ControllerStatus;
using operator_g1d::InboundKind;
using operator_g1d::Listener;
using operator_g1d::ReadFrameResult;
using operator_g1d::TelemetryValues;
using operator_g1d::UnitreeBackendConfig;

std::atomic<bool> g_running{true};

void handle_signal(int) {
  g_running.store(false);
}

struct Options {
  std::string listen = "uds:/tmp/operator-g1d.sock";
  std::string descriptor;
  std::string blueprint;
  std::string backend = "mock";
  std::string network_interface = "eth0";
  int domain_id = 0;
  int telemetry_hz = 10;
  int control_hz = 200;
  bool allow_motion = false;
  ControllerConfig controller;
};

void print_usage(const char* program) {
  std::cout
      << "Usage: " << program << " --descriptor PATH [options]\n"
      << "  --listen ENDPOINT             uds:/path or tcp:IPv4:port\n"
      << "  --blueprint PATH              default: descriptor directory/unitree_g1d_blueprint.json\n"
      << "  --backend mock|unitree        default: mock\n"
      << "  --network-interface NAME      Unitree DDS interface, default: eth0\n"
      << "  --domain ID                   DDS domain, default: 0\n"
      << "  --allow-motion                explicit hardware motion authorization\n"
      << "  --command-timeout-ms N        local watchdog, default: 750\n"
      << "  --telemetry-hz N              default: 10\n"
      << "  --control-hz N                default: 200\n"
      << "  --max-base-vx MPS             default: 0.12\n"
      << "  --max-base-wz RAD_S           default: 0.40\n"
      << "  --max-lift-command VALUE      normalized, default: 0.20\n"
      << "  --max-measured-vx MPS         default: 0.20\n"
      << "  --max-measured-wz RAD_S       default: 0.75\n"
      << "  --arm-position-scale VALUE    XR-to-robot translation scale, default: 1.0\n"
      << "  --max-arm-translation M       per-engagement workspace radius, default: 0.35\n"
      << "  --max-arm-joint-velocity RPS  target rate limit, default: 1.0\n"
      << "  --max-measured-arm-velocity RPS  safety limit, default: 2.0\n"
      << "  --max-arm-ready-velocity RPS  ready-pose rate limit, default: 0.5\n"
      << "  --max-hand-rate PER_S         normalized target rate, default: 1.0\n"
      << "  --max-measured-hand-speed VALUE  normalized safety limit, default: 1.5\n"
      << "  --max-hand-current VALUE      filtered normalized limit, default: 0.8\n"
      << "  --revo1-grasp-target VALUE    fixed grasp position, default: 0.85\n";
}

std::string require_value(int argc, char** argv, int& index, const std::string& flag) {
  if (index + 1 >= argc) {
    throw std::runtime_error(flag + " requires a value");
  }
  return argv[++index];
}

Options parse_options(int argc, char** argv) {
  Options options;
  for (int index = 1; index < argc; ++index) {
    const std::string argument = argv[index];
    if (argument == "--help" || argument == "-h") {
      print_usage(argv[0]);
      std::exit(0);
    } else if (argument == "--listen") {
      options.listen = require_value(argc, argv, index, argument);
    } else if (argument == "--descriptor") {
      options.descriptor = require_value(argc, argv, index, argument);
    } else if (argument == "--blueprint") {
      options.blueprint = require_value(argc, argv, index, argument);
    } else if (argument == "--backend") {
      options.backend = require_value(argc, argv, index, argument);
    } else if (argument == "--network-interface") {
      options.network_interface = require_value(argc, argv, index, argument);
    } else if (argument == "--domain") {
      options.domain_id = std::stoi(require_value(argc, argv, index, argument));
    } else if (argument == "--allow-motion") {
      options.allow_motion = true;
    } else if (argument == "--command-timeout-ms") {
      options.controller.command_timeout = std::chrono::milliseconds(
          std::stoi(require_value(argc, argv, index, argument)));
    } else if (argument == "--telemetry-hz") {
      options.telemetry_hz = std::stoi(require_value(argc, argv, index, argument));
    } else if (argument == "--control-hz") {
      options.control_hz = std::stoi(require_value(argc, argv, index, argument));
    } else if (argument == "--max-base-vx") {
      options.controller.max_base_vx_mps =
          std::stod(require_value(argc, argv, index, argument));
    } else if (argument == "--max-base-wz") {
      options.controller.max_base_wz_rad_s =
          std::stod(require_value(argc, argv, index, argument));
    } else if (argument == "--max-lift-command") {
      options.controller.max_height_command =
          std::stod(require_value(argc, argv, index, argument));
    } else if (argument == "--max-measured-vx") {
      options.controller.max_measured_vx_mps =
          std::stod(require_value(argc, argv, index, argument));
    } else if (argument == "--max-measured-wz") {
      options.controller.max_measured_wz_rad_s =
          std::stod(require_value(argc, argv, index, argument));
    } else if (argument == "--arm-position-scale") {
      options.controller.arm_position_scale =
          std::stod(require_value(argc, argv, index, argument));
    } else if (argument == "--max-arm-translation") {
      options.controller.max_arm_translation_m =
          std::stod(require_value(argc, argv, index, argument));
    } else if (argument == "--max-arm-joint-velocity") {
      options.controller.max_arm_joint_velocity_rad_s =
          std::stod(require_value(argc, argv, index, argument));
    } else if (argument == "--max-measured-arm-velocity") {
      options.controller.max_measured_arm_velocity_rad_s =
          std::stod(require_value(argc, argv, index, argument));
    } else if (argument == "--max-arm-ready-velocity") {
      options.controller.max_arm_ready_joint_velocity_rad_s =
          std::stod(require_value(argc, argv, index, argument));
    } else if (argument == "--max-hand-rate") {
      options.controller.max_hand_target_rate_per_s =
          std::stod(require_value(argc, argv, index, argument));
    } else if (argument == "--max-measured-hand-speed") {
      options.controller.max_measured_hand_velocity =
          std::stod(require_value(argc, argv, index, argument));
    } else if (argument == "--max-hand-current") {
      options.controller.max_abs_hand_current =
          std::stod(require_value(argc, argv, index, argument));
    } else if (argument == "--revo1-grasp-target") {
      options.controller.revo1_grasp_target =
          std::stod(require_value(argc, argv, index, argument));
    } else {
      throw std::runtime_error("unknown argument: " + argument);
    }
  }

  if (options.descriptor.empty()) {
    throw std::runtime_error("--descriptor is required");
  }
  if (options.blueprint.empty()) {
    const auto separator = options.descriptor.find_last_of("/\\");
    const std::string directory = separator == std::string::npos
                                      ? std::string()
                                      : options.descriptor.substr(0, separator + 1);
    options.blueprint = directory + "unitree_g1d_blueprint.json";
  }
  if (options.backend != "mock" && options.backend != "unitree") {
    throw std::runtime_error("--backend must be mock or unitree");
  }
  if (options.telemetry_hz <= 0 || options.control_hz <= 0) {
    throw std::runtime_error("telemetry and control rates must be positive");
  }
  if (options.telemetry_hz > 1000 || options.control_hz > 1000) {
    throw std::runtime_error("telemetry and control rates must not exceed 1000 Hz");
  }
  if (options.controller.command_timeout.count() <= 0) {
    throw std::runtime_error("command timeout must be positive");
  }
  const auto require_positive_finite = [](double value, const char* name) {
    if (!std::isfinite(value) || value <= 0.0) {
      throw std::runtime_error(std::string(name) + " must be finite and positive");
    }
  };
  require_positive_finite(options.controller.max_base_vx_mps, "max base vx");
  require_positive_finite(options.controller.max_base_wz_rad_s, "max base wz");
  require_positive_finite(options.controller.max_height_command, "max lift command");
  require_positive_finite(options.controller.max_measured_vx_mps, "max measured vx");
  require_positive_finite(options.controller.max_measured_wz_rad_s, "max measured wz");
  require_positive_finite(options.controller.arm_position_scale, "arm position scale");
  require_positive_finite(options.controller.max_arm_translation_m, "max arm translation");
  require_positive_finite(
      options.controller.max_arm_joint_velocity_rad_s, "max arm joint velocity");
  require_positive_finite(
      options.controller.max_measured_arm_velocity_rad_s, "max measured arm velocity");
  require_positive_finite(
      options.controller.max_arm_ready_joint_velocity_rad_s, "max arm ready velocity");
  require_positive_finite(options.controller.max_hand_target_rate_per_s, "max hand rate");
  require_positive_finite(
      options.controller.max_measured_hand_velocity, "max measured hand speed");
  require_positive_finite(options.controller.max_abs_hand_current, "max hand current");
  require_positive_finite(options.controller.revo1_grasp_target, "Revo-1 grasp target");
  if (options.controller.max_height_command > 1.0) {
    throw std::runtime_error("max lift command must not exceed 1.0");
  }
  if (options.controller.revo1_grasp_target > 1.0) {
    throw std::runtime_error("Revo-1 grasp target must not exceed 1.0");
  }
  if (options.domain_id < 0) {
    throw std::runtime_error("DDS domain must be non-negative");
  }
  if (options.backend == "unitree" && !options.allow_motion) {
    std::cerr << "[operator-g1d] hardware connected in read-only mode; pass --allow-motion only "
                 "after the current robot state and workspace are verified\n";
  }
  options.controller.motion_authorized = options.backend == "mock" || options.allow_motion;
  return options;
}

std::string read_text_file(const std::string& path) {
  std::ifstream input(path);
  if (!input) {
    throw std::runtime_error("cannot open file: " + path);
  }
  return std::string(
      std::istreambuf_iterator<char>(input), std::istreambuf_iterator<char>());
}

TelemetryValues telemetry_values(
    const Backend& backend,
    const BackendSnapshot& snapshot,
    const ControllerStatus& status) {
  TelemetryValues values;
  values.booleans["connected"] = snapshot.connected;
  values.booleans["motion_authorized"] = status.motion_authorized;
  values.booleans["estop_latched"] = status.estop_latched;
  values.booleans["watchdog_active"] = status.watchdog_active;
  values.booleans["release_required"] = status.release_required;
  values.booleans["control_conflict"] = status.control_conflict;
  values.booleans["odom_fresh"] = snapshot.odom_fresh;
  values.booleans["height_fresh"] = snapshot.height_fresh;
  values.booleans["lowstate_fresh"] = snapshot.lowstate_fresh;
  values.booleans["left_hand_fresh"] = snapshot.left_hand_fresh;
  values.booleans["right_hand_fresh"] = snapshot.right_hand_fresh;
  values.strings["backend"] = backend.name();
  values.strings["control_mode"] = operator_g1d::motion_mode_name(status.mode);
  values.strings["stop_reason"] = status.stop_reason;
  values.floats["command_age_ms"] = status.command_age_ms;
  values.floats["odom_age_ms"] = snapshot.odom_age_ms;
  values.floats["height_age_ms"] = snapshot.height_age_ms;
  values.floats["lowstate_age_ms"] = snapshot.lowstate_age_ms;
  values.floats["left_hand_age_ms"] = snapshot.left_hand_age_ms;
  values.floats["right_hand_age_ms"] = snapshot.right_hand_age_ms;
  values.floats["odom_x_m"] = snapshot.odom_x_m;
  values.floats["odom_y_m"] = snapshot.odom_y_m;
  values.floats["odom_yaw_rad"] = snapshot.odom_yaw_rad;
  values.floats["base_vx_mps"] = snapshot.measured_vx_mps;
  values.floats["base_vy_mps"] = snapshot.measured_vy_mps;
  values.floats["base_wz_rad_s"] = snapshot.measured_wz_rad_s;
  values.floats["height_m"] = snapshot.height_m;
  values.integers["motor_fault_count"] = snapshot.motor_fault_count;
  values.integers["mode_machine"] = snapshot.mode_machine;
  values.integers["last_base_result"] = snapshot.last_base_result;
  values.integers["last_height_result"] = snapshot.last_height_result;
  values.arrays["joint_positions_rad"] = snapshot.joint_positions_rad;
  values.arrays["joint_velocities_rad_s"] = snapshot.joint_velocities_rad_s;
  values.arrays["revo1_left_position"] = snapshot.left_hand_positions;
  values.arrays["revo1_right_position"] = snapshot.right_hand_positions;
  values.arrays["revo1_left_velocity"] = snapshot.left_hand_velocities;
  values.arrays["revo1_right_velocity"] = snapshot.right_hand_velocities;
  values.arrays["revo1_left_current"] = snapshot.left_hand_currents;
  values.arrays["revo1_right_current"] = snapshot.right_hand_currents;
  return values;
}

TelemetryValues blueprint_values(
    const BackendSnapshot& snapshot,
    const ControllerStatus& status) {
  TelemetryValues values;
  values.strings["g1d.summary"] =
      "Trigger: grasp | Grip: arm IK | X: ready pose | Y: initial pose | B: stop";

  if (!snapshot.connected) {
    values.strings["g1d.connection_state"] = "error";
    values.strings["g1d.connection_text"] = "未连接";
  } else if (!snapshot.odom_fresh || !snapshot.height_fresh || !snapshot.lowstate_fresh) {
    values.strings["g1d.connection_state"] = "warning";
    values.strings["g1d.connection_text"] = "反馈异常";
  } else {
    values.strings["g1d.connection_state"] = "active";
    values.strings["g1d.connection_text"] = "已连接";
  }

  if (!status.motion_authorized) {
    values.strings["g1d.motion_state"] = "read_only";
    values.strings["g1d.motion_text"] = "底盘锁定";
  } else if (status.estop_latched) {
    values.strings["g1d.motion_state"] = "estop";
    values.strings["g1d.motion_text"] = "机器人急停";
  } else if (status.release_required || status.watchdog_active) {
    values.strings["g1d.motion_state"] = "warning";
    values.strings["g1d.motion_text"] = "摇杆回中";
  } else if (status.mode == operator_g1d::MotionMode::Base) {
    values.strings["g1d.motion_state"] = "active";
    values.strings["g1d.motion_text"] = "底盘移动";
  } else if (status.mode == operator_g1d::MotionMode::Lift) {
    values.strings["g1d.motion_state"] = "active";
    values.strings["g1d.motion_text"] = "升降移动";
  } else if (status.mode == operator_g1d::MotionMode::Arms) {
    values.strings["g1d.motion_state"] = "active";
    values.strings["g1d.motion_text"] = "手臂遥操";
  } else if (status.control_conflict) {
    values.strings["g1d.motion_state"] = "warning";
    values.strings["g1d.motion_text"] = "控制冲突";
  } else {
    values.strings["g1d.motion_state"] = "ready";
    values.strings["g1d.motion_text"] = "可移动";
  }
  return values;
}

void stop_motion(
    std::mutex& motion_mutex,
    CommandController& controller,
    Backend& backend,
    const std::string& reason,
    bool latch_estop = false) {
  std::lock_guard<std::mutex> motion_lock(motion_mutex);
  controller.force_stop(reason, latch_estop);
  backend.emergency_stop();
}

void serve_connection(
    int client,
    const std::string& descriptor_message,
    operator_sdk::BlueprintPublisher& blueprint,
    CommandController& controller,
    Backend& backend,
    std::mutex& motion_mutex,
    std::chrono::milliseconds telemetry_period) {
  bool handshake_complete = false;
  auto next_telemetry = std::chrono::steady_clock::now();
  operator_g1d::FrameReader frame_reader;

  while (g_running.load()) {
    std::string payload;
    const ReadFrameResult result =
        frame_reader.read(client, payload, std::chrono::milliseconds(20));
    if (result == ReadFrameResult::Closed) {
      stop_motion(motion_mutex, controller, backend, "bridge_disconnected");
      return;
    }
    if (result == ReadFrameResult::Frame) {
      try {
        const auto message = operator_g1d::parse_inbound_message(payload);
        switch (message.kind) {
          case InboundKind::Hello:
            operator_g1d::write_frame(client, descriptor_message);
            operator_g1d::write_frame(client, blueprint.definition_message_json());
            handshake_complete = true;
            break;
          case InboundKind::Command:
            if (!handshake_complete) {
              throw std::runtime_error("Command received before Hello");
            }
            {
              std::lock_guard<std::mutex> motion_lock(motion_mutex);
              controller.accept(message.command, std::chrono::steady_clock::now());
            }
            break;
          case InboundKind::Stop:
            stop_motion(
                motion_mutex,
                controller,
                backend,
                message.reason.empty() ? "bridge_stop" : message.reason);
            operator_g1d::write_frame(
                client,
                operator_g1d::make_event_message(
                    "estop", message.reason.empty() ? "bridge_stop" : message.reason));
            break;
          case InboundKind::BlueprintEvent:
            std::cerr << "[operator-g1d] ignoring unexpected Blueprint event "
                      << blueprint.parse_event_message_json(payload) << '\n';
            break;
          case InboundKind::Shutdown:
            stop_motion(motion_mutex, controller, backend, "bridge_shutdown");
            g_running.store(false);
            return;
        }
      } catch (const std::exception& error) {
        stop_motion(motion_mutex, controller, backend, "protocol_error", true);
        operator_g1d::write_frame(
            client, operator_g1d::make_event_message("error", error.what()));
      }
    }

    const auto now = std::chrono::steady_clock::now();
    if (handshake_complete && now >= next_telemetry) {
      const BackendSnapshot snapshot = backend.snapshot();
      const ControllerStatus status = controller.status(now);
      const std::uint64_t timestamp_ns = operator_g1d::system_time_ns();
      operator_g1d::write_frame(
          client,
          operator_g1d::make_telemetry_message(
              telemetry_values(backend, snapshot, status), timestamp_ns));
      blueprint.update_values_json(
          operator_g1d::make_values_json(blueprint_values(snapshot, status)), timestamp_ns);
      operator_g1d::write_frame(client, blueprint.state_message_json());
      next_telemetry = now + telemetry_period;
    }
  }
}

}  // namespace

int main(int argc, char** argv) {
  try {
    const Options options = parse_options(argc, argv);
    operator_sdk::BlueprintPublisher blueprint;
    blueprint.set_blueprint_json(read_text_file(options.blueprint));
    const std::string descriptor_message =
        blueprint.descriptor_message_json(read_text_file(options.descriptor));

    std::signal(SIGINT, handle_signal);
    std::signal(SIGTERM, handle_signal);

    std::unique_ptr<Backend> backend;
    if (options.backend == "unitree") {
      backend = operator_g1d::make_unitree_backend(UnitreeBackendConfig{
          options.network_interface,
          options.domain_id,
          0.25,
      });
    } else {
      backend = operator_g1d::make_mock_backend();
    }
    backend->start();

    CommandController controller(options.controller);
    Listener listener(options.listen);
    std::cerr << "[operator-g1d] listening on " << listener.endpoint()
              << " backend=" << backend->name()
              << " motion_authorized=" << (options.controller.motion_authorized ? "true" : "false")
              << '\n';

    std::mutex error_mutex;
    std::mutex motion_mutex;
    std::exception_ptr control_error;
    const auto control_period = std::chrono::microseconds(1'000'000 / options.control_hz);
    std::thread control_thread([&]() {
      try {
        auto previous = std::chrono::steady_clock::now();
        auto next = previous;
        auto next_active_log = previous;
        operator_g1d::MotionMode last_logged_mode = operator_g1d::MotionMode::Stopped;
        std::string last_logged_reason = "startup_interlock";
        while (g_running.load()) {
          next += control_period;
          const auto now = std::chrono::steady_clock::now();
          const auto feedback = backend->snapshot();
          operator_g1d::ActuatorCommand command;
          ControllerStatus status;
          {
            std::lock_guard<std::mutex> motion_lock(motion_mutex);
            command = controller.resolve(feedback, now, now - previous);
            backend->apply(command);
            status = controller.status(now);
          }
          previous = now;

          const bool active = command.base_active || command.lift_active || command.arms_active ||
                              command.left_hand_active || command.right_hand_active;
          const bool state_changed =
              command.mode != last_logged_mode || status.stop_reason != last_logged_reason;
          if (state_changed || (active && now >= next_active_log)) {
            double left_arm_target_error_rad = 0.0;
            double right_arm_target_error_rad = 0.0;
            if (command.arms_active && command.joint_targets_rad.size() >= 29 &&
                feedback.joint_positions_rad.size() >= 29) {
              for (std::size_t joint = 15; joint < 22; ++joint) {
                left_arm_target_error_rad = std::max(
                    left_arm_target_error_rad,
                    std::abs(command.joint_targets_rad[joint] -
                             feedback.joint_positions_rad[joint]));
              }
              for (std::size_t joint = 22; joint < 29; ++joint) {
                right_arm_target_error_rad = std::max(
                    right_arm_target_error_rad,
                    std::abs(command.joint_targets_rad[joint] -
                             feedback.joint_positions_rad[joint]));
              }
            }
            std::cerr << "[operator-g1d] control mode=" << motion_mode_name(command.mode)
                      << " base_vx=" << command.base_vx_mps
                      << " base_wz=" << command.base_wz_rad_s
                      << " lift=" << command.lift_normalized
                      << " measured_vx=" << feedback.measured_vx_mps
                      << " measured_wz=" << feedback.measured_wz_rad_s
                      << " arm_target_error_lr=" << left_arm_target_error_rad
                      << "/" << right_arm_target_error_rad
                      << " estop=" << (status.estop_latched ? "true" : "false")
                      << " release_required=" << (status.release_required ? "true" : "false")
                      << " reason=" << (status.stop_reason.empty() ? "-" : status.stop_reason)
                      << std::endl;
            last_logged_mode = command.mode;
            last_logged_reason = status.stop_reason;
            next_active_log = now + std::chrono::milliseconds(500);
          }
          std::this_thread::sleep_until(next);
        }
      } catch (...) {
        {
          std::lock_guard<std::mutex> lock(error_mutex);
          control_error = std::current_exception();
        }
        stop_motion(motion_mutex, controller, *backend, "backend_failure", true);
        g_running.store(false);
      }
    });

    const auto telemetry_period = std::chrono::milliseconds(1000 / options.telemetry_hz);
    std::exception_ptr listener_error;
    try {
      while (g_running.load()) {
        const int client = listener.accept_one(200);
        if (client < 0) {
          continue;
        }
        std::cerr << "[operator-g1d] xr-bridge connected\n";
        stop_motion(
            motion_mutex,
            controller,
            *backend,
            "bridge_connected_waiting_for_reset");
        try {
          serve_connection(
              client,
              descriptor_message,
              blueprint,
              controller,
              *backend,
              motion_mutex,
              telemetry_period);
        } catch (const std::exception& error) {
          std::cerr << "[operator-g1d] connection error: " << error.what() << '\n';
          stop_motion(motion_mutex, controller, *backend, "bridge_connection_error");
        }
        ::shutdown(client, SHUT_RDWR);
        ::close(client);
      }
    } catch (...) {
      listener_error = std::current_exception();
    }

    g_running.store(false);
    stop_motion(motion_mutex, controller, *backend, "process_shutdown");
    if (control_thread.joinable()) {
      control_thread.join();
    }
    backend->stop();

    if (listener_error) {
      std::rethrow_exception(listener_error);
    }
    std::exception_ptr worker_error;
    {
      std::lock_guard<std::mutex> lock(error_mutex);
      worker_error = control_error;
    }
    if (worker_error) {
      std::rethrow_exception(worker_error);
    }
    return 0;
  } catch (const std::exception& error) {
    std::cerr << "operator-g1d-client: " << error.what() << '\n';
    return 1;
  }
}
