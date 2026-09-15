#include "operator_g1d/backend.hpp"

#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <thread>
#include <utility>

#include <unitree/idl/hg/IMUState_.hpp>
#include <unitree/idl/hg/LowState_.hpp>
#include <unitree/idl/ros2/Odometry_.hpp>
#include <unitree/idl/ros2/Point32_.hpp>
#include <unitree/robot/channel/channel_factory.hpp>
#include <unitree/robot/channel/channel_subscriber.hpp>
#include <unitree/robot/g1/agv/g1_agv_client.hpp>

namespace operator_g1d {
namespace {

using geometry_msgs::msg::dds_::Point32_;
using nav_msgs::msg::dds_::Odometry_;
using unitree::robot::ChannelFactory;
using unitree::robot::ChannelSubscriber;
using unitree::robot::ChannelSubscriberPtr;
using unitree::robot::g1::AgvClient;
using unitree_hg::msg::dds_::IMUState_;
using unitree_hg::msg::dds_::LowState_;

constexpr std::size_t kMotorCount = 29;
constexpr std::array<std::size_t, 16> kValidUpperBodyIndices{
    12, 14,
    15, 16, 17, 18, 19, 20, 21,
    22, 23, 24, 25, 26, 27, 28,
};
constexpr auto kFeedbackFreshness = std::chrono::milliseconds(1000);

std::int64_t steady_time_ns() {
  return std::chrono::duration_cast<std::chrono::nanoseconds>(
             std::chrono::steady_clock::now().time_since_epoch())
      .count();
}

double age_ms(std::int64_t timestamp_ns) {
  if (timestamp_ns <= 0) {
    return -1.0;
  }
  return static_cast<double>(steady_time_ns() - timestamp_ns) / 1'000'000.0;
}

double yaw_from_quaternion(double x, double y, double z, double w) {
  const double sin_yaw = 2.0 * (w * z + x * y);
  const double cos_yaw = 1.0 - 2.0 * (y * y + z * z);
  return std::atan2(sin_yaw, cos_yaw);
}

class UnitreeBackend final : public Backend {
 public:
  explicit UnitreeBackend(UnitreeBackendConfig config) : config_(std::move(config)) {}
  ~UnitreeBackend() override { stop(); }

  std::string name() const override { return "unitree_sdk2"; }

  void start() override {
    {
      std::lock_guard<std::mutex> lock(lifecycle_mutex_);
      stopped_ = false;
      stopping_.store(false, std::memory_order_release);
    }
    if (config_.network_interface.empty()) {
      ChannelFactory::Instance()->Init(config_.domain_id);
    } else {
      ChannelFactory::Instance()->Init(config_.domain_id, config_.network_interface);
    }

    agv_client_ = std::make_unique<AgvClient>();
    agv_client_->SetTimeout(static_cast<float>(config_.rpc_timeout_seconds));
    agv_client_->Init();

    odom_subscriber_ = std::make_shared<ChannelSubscriber<Odometry_>>("rt/agv/odom");
    odom_subscriber_->InitChannel(
        [this](const void* message) { on_odometry(message); }, 1);

    height_subscriber_ = std::make_shared<ChannelSubscriber<Point32_>>("rt/hispeed_state");
    height_subscriber_->InitChannel(
        [this](const void* message) { on_height(message); }, 1);

    lowstate_subscriber_ = std::make_shared<ChannelSubscriber<LowState_>>("rt/lowstate");
    lowstate_subscriber_->InitChannel(
        [this](const void* message) { on_lowstate(message); }, 1);

    imu_subscriber_ = std::make_shared<ChannelSubscriber<IMUState_>>("rt/secondary_imu");
    imu_subscriber_->InitChannel(
        [this](const void* message) { on_imu(message); }, 1);

    std::lock_guard<std::mutex> lock(state_mutex_);
    snapshot_.connected = true;
  }

  void apply(const ActuatorCommand& command) override {
    std::lock_guard<std::mutex> command_lock(command_mutex_);

    if (command.base_active) {
      base_owned_ = true;
      const int result = agv_client_->Move(
          static_cast<float>(command.base_vx_mps),
          0.0F,
          static_cast<float>(command.base_wz_rad_s));
      std::lock_guard<std::mutex> state_lock(state_mutex_);
      snapshot_.last_base_result = result;
    } else if (base_owned_) {
      const int result = agv_client_->Move(0.0F, 0.0F, 0.0F);
      std::lock_guard<std::mutex> state_lock(state_mutex_);
      snapshot_.last_base_result = result;
    }

    if (command.lift_active) {
      lift_owned_ = true;
      const int result = agv_client_->HeightAdjust(static_cast<float>(command.lift_normalized));
      std::lock_guard<std::mutex> state_lock(state_mutex_);
      snapshot_.last_height_result = result;
    } else if (lift_owned_) {
      const int result = agv_client_->HeightAdjust(0.0F);
      std::lock_guard<std::mutex> state_lock(state_mutex_);
      snapshot_.last_height_result = result;
    }
  }

  BackendSnapshot snapshot() const override {
    std::lock_guard<std::mutex> lock(state_mutex_);
    BackendSnapshot result = snapshot_;
    result.odom_age_ms = age_ms(last_odom_ns_);
    result.height_age_ms = age_ms(last_height_ns_);
    result.lowstate_age_ms = age_ms(last_lowstate_ns_);
    result.odom_fresh =
        result.odom_age_ms >= 0.0 && result.odom_age_ms <= kFeedbackFreshness.count();
    result.height_fresh =
        result.height_age_ms >= 0.0 && result.height_age_ms <= kFeedbackFreshness.count();
    result.lowstate_fresh =
        result.lowstate_age_ms >= 0.0 && result.lowstate_age_ms <= kFeedbackFreshness.count();
    return result;
  }

  void emergency_stop() noexcept override {
    std::lock_guard<std::mutex> command_lock(command_mutex_);
    try {
      if (base_owned_) {
        for (int attempt = 0; attempt < 8; ++attempt) {
          const int result = agv_client_->Move(0.0F, 0.0F, 0.0F);
          {
            std::lock_guard<std::mutex> state_lock(state_mutex_);
            snapshot_.last_base_result = result;
          }
          std::this_thread::sleep_for(std::chrono::milliseconds(40));
        }
      }
      if (lift_owned_) {
        for (int attempt = 0; attempt < 4; ++attempt) {
          const int result = agv_client_->HeightAdjust(0.0F);
          {
            std::lock_guard<std::mutex> state_lock(state_mutex_);
            snapshot_.last_height_result = result;
          }
          std::this_thread::sleep_for(std::chrono::milliseconds(40));
        }
      }
    } catch (...) {
    }
  }

  void stop() noexcept override {
    {
      std::lock_guard<std::mutex> lock(lifecycle_mutex_);
      if (stopped_) {
        return;
      }
      stopped_ = true;
      stopping_.store(true, std::memory_order_release);
    }
    emergency_stop();

    const auto close_channel = [](auto& subscriber) noexcept {
      if (!subscriber) {
        return;
      }
      try {
        subscriber->CloseChannel();
      } catch (...) {
      }
      subscriber.reset();
    };
    close_channel(imu_subscriber_);
    close_channel(lowstate_subscriber_);
    close_channel(height_subscriber_);
    close_channel(odom_subscriber_);

    {
      std::lock_guard<std::mutex> callback_lock(callback_mutex_);
    }
    std::lock_guard<std::mutex> lock(state_mutex_);
    snapshot_.connected = false;
  }

 private:
  void on_odometry(const void* message) {
    std::lock_guard<std::mutex> callback_lock(callback_mutex_);
    if (stopping_.load(std::memory_order_acquire)) {
      return;
    }
    const auto& odometry = *static_cast<const Odometry_*>(message);
    const auto& pose = odometry.pose().pose();
    const auto& position = pose.position();
    const auto& orientation = pose.orientation();
    const auto& twist = odometry.twist().twist();

    std::lock_guard<std::mutex> lock(state_mutex_);
    snapshot_.odom_x_m = position.x();
    snapshot_.odom_y_m = position.y();
    snapshot_.odom_yaw_rad = yaw_from_quaternion(
        orientation.x(), orientation.y(), orientation.z(), orientation.w());
    snapshot_.measured_vx_mps = twist.linear().x();
    snapshot_.measured_vy_mps = twist.linear().y();
    snapshot_.measured_wz_rad_s = twist.angular().z();
    last_odom_ns_ = steady_time_ns();
  }

  void on_height(const void* message) {
    std::lock_guard<std::mutex> callback_lock(callback_mutex_);
    if (stopping_.load(std::memory_order_acquire)) {
      return;
    }
    const auto& height = *static_cast<const Point32_*>(message);
    std::lock_guard<std::mutex> lock(state_mutex_);
    snapshot_.height_m = height.y();
    last_height_ns_ = steady_time_ns();
  }

  void on_lowstate(const void* message) {
    std::lock_guard<std::mutex> callback_lock(callback_mutex_);
    if (stopping_.load(std::memory_order_acquire)) {
      return;
    }
    const auto& lowstate = *static_cast<const LowState_*>(message);
    std::vector<double> positions(kMotorCount, 0.0);
    std::vector<double> velocities(kMotorCount, 0.0);
    std::int64_t fault_count = 0;
    for (std::size_t index = 0; index < kMotorCount; ++index) {
      positions[index] = lowstate.motor_state()[index].q();
      velocities[index] = lowstate.motor_state()[index].dq();
    }
    for (const std::size_t index : kValidUpperBodyIndices) {
      if (lowstate.motor_state()[index].motorstate() != 0) {
        ++fault_count;
      }
    }

    std::lock_guard<std::mutex> lock(state_mutex_);
    snapshot_.joint_positions_rad = std::move(positions);
    snapshot_.joint_velocities_rad_s = std::move(velocities);
    snapshot_.motor_fault_count = fault_count;
    snapshot_.mode_machine = lowstate.mode_machine();
    last_lowstate_ns_ = steady_time_ns();
  }

  void on_imu(const void* message) {
    std::lock_guard<std::mutex> callback_lock(callback_mutex_);
    if (stopping_.load(std::memory_order_acquire)) {
      return;
    }
    const auto& imu = *static_cast<const IMUState_*>(message);
    std::lock_guard<std::mutex> lock(state_mutex_);
    imu_rpy_ = {
        static_cast<double>(imu.rpy()[0]),
        static_cast<double>(imu.rpy()[1]),
        static_cast<double>(imu.rpy()[2]),
    };
    imu_gyro_ = {
        static_cast<double>(imu.gyroscope()[0]),
        static_cast<double>(imu.gyroscope()[1]),
        static_cast<double>(imu.gyroscope()[2]),
    };
  }

  UnitreeBackendConfig config_;
  std::mutex lifecycle_mutex_;
  std::mutex callback_mutex_;
  mutable std::mutex state_mutex_;
  std::mutex command_mutex_;
  BackendSnapshot snapshot_;
  std::array<double, 3> imu_rpy_{};
  std::array<double, 3> imu_gyro_{};
  std::int64_t last_odom_ns_ = 0;
  std::int64_t last_height_ns_ = 0;
  std::int64_t last_lowstate_ns_ = 0;
  bool base_owned_ = false;
  bool lift_owned_ = false;
  bool stopped_ = false;
  std::atomic<bool> stopping_{false};

  std::unique_ptr<AgvClient> agv_client_;
  ChannelSubscriberPtr<Odometry_> odom_subscriber_;
  ChannelSubscriberPtr<Point32_> height_subscriber_;
  ChannelSubscriberPtr<LowState_> lowstate_subscriber_;
  ChannelSubscriberPtr<IMUState_> imu_subscriber_;
};

}  // namespace

std::unique_ptr<Backend> make_unitree_backend(UnitreeBackendConfig config) {
  return std::make_unique<UnitreeBackend>(std::move(config));
}

}  // namespace operator_g1d
