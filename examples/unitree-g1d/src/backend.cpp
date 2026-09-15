#include "operator_g1d/backend.hpp"

#include <algorithm>
#include <chrono>
#include <mutex>

namespace operator_g1d {
namespace {

class MockBackend final : public Backend {
 public:
  std::string name() const override { return "mock"; }

  void start() override {
    std::lock_guard<std::mutex> lock(mutex_);
    snapshot_.connected = true;
    snapshot_.odom_fresh = true;
    snapshot_.height_fresh = true;
    snapshot_.lowstate_fresh = true;
    snapshot_.height_m = 0.75;
    snapshot_.joint_positions_rad.assign(29, 0.0);
    snapshot_.joint_velocities_rad_s.assign(29, 0.0);
    last_update_ = std::chrono::steady_clock::now();
  }

  void apply(const ActuatorCommand& command) override {
    std::lock_guard<std::mutex> lock(mutex_);
    const auto now = std::chrono::steady_clock::now();
    const double dt = std::chrono::duration<double>(now - last_update_).count();
    last_update_ = now;

    snapshot_.measured_vx_mps = command.base_active ? command.base_vx_mps : 0.0;
    snapshot_.measured_wz_rad_s = command.base_active ? command.base_wz_rad_s : 0.0;
    snapshot_.odom_x_m += snapshot_.measured_vx_mps * std::max(0.0, dt);
    snapshot_.odom_yaw_rad += snapshot_.measured_wz_rad_s * std::max(0.0, dt);
    snapshot_.height_m = std::clamp(
        snapshot_.height_m + (command.lift_active ? command.lift_normalized * 0.0765 * dt : 0.0),
        0.0,
        2.0);
    snapshot_.odom_age_ms = 0.0;
    snapshot_.height_age_ms = 0.0;
    snapshot_.lowstate_age_ms = 0.0;
  }

  BackendSnapshot snapshot() const override {
    std::lock_guard<std::mutex> lock(mutex_);
    return snapshot_;
  }

  void emergency_stop() noexcept override {
    std::lock_guard<std::mutex> lock(mutex_);
    snapshot_.measured_vx_mps = 0.0;
    snapshot_.measured_vy_mps = 0.0;
    snapshot_.measured_wz_rad_s = 0.0;
  }

  void stop() noexcept override {
    emergency_stop();
    std::lock_guard<std::mutex> lock(mutex_);
    snapshot_.connected = false;
  }

 private:
  mutable std::mutex mutex_;
  BackendSnapshot snapshot_;
  std::chrono::steady_clock::time_point last_update_ = std::chrono::steady_clock::now();
};

}  // namespace

std::unique_ptr<Backend> make_mock_backend() {
  return std::make_unique<MockBackend>();
}

std::string motion_mode_name(MotionMode mode) {
  switch (mode) {
    case MotionMode::Idle:
      return "idle";
    case MotionMode::Base:
      return "base";
    case MotionMode::Lift:
      return "lift";
    case MotionMode::ArmsUnavailable:
      return "arms_unavailable";
    case MotionMode::Conflict:
      return "conflict";
    case MotionMode::Stopped:
      return "stopped";
  }
  return "unknown";
}

std::uint64_t system_time_ns() {
  return static_cast<std::uint64_t>(
      std::chrono::duration_cast<std::chrono::nanoseconds>(
          std::chrono::system_clock::now().time_since_epoch())
          .count());
}

}  // namespace operator_g1d
