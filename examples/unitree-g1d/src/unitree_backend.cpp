#include "operator_g1d/backend.hpp"

#include <algorithm>
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
#include <unitree/idl/hg/LowCmd_.hpp>
#include <unitree/idl/hg/LowState_.hpp>
#include <unitree/idl/go2/MotorCmds_.hpp>
#include <unitree/idl/go2/MotorStates_.hpp>
#include <unitree/idl/ros2/Odometry_.hpp>
#include <unitree/idl/ros2/Point32_.hpp>
#include <unitree/robot/channel/channel_factory.hpp>
#include <unitree/robot/channel/channel_publisher.hpp>
#include <unitree/robot/channel/channel_subscriber.hpp>
#include <unitree/robot/g1/agv/g1_agv_client.hpp>

namespace operator_g1d {
namespace {

using geometry_msgs::msg::dds_::Point32_;
using nav_msgs::msg::dds_::Odometry_;
using unitree::robot::ChannelFactory;
using unitree::robot::ChannelPublisher;
using unitree::robot::ChannelPublisherPtr;
using unitree::robot::ChannelSubscriber;
using unitree::robot::ChannelSubscriberPtr;
using unitree::robot::g1::AgvClient;
using unitree_hg::msg::dds_::IMUState_;
using unitree_hg::msg::dds_::LowCmd_;
using unitree_hg::msg::dds_::LowState_;
using unitree_go::msg::dds_::MotorCmds_;
using unitree_go::msg::dds_::MotorStates_;

constexpr std::size_t kMotorCount = 29;
constexpr std::size_t kHandMotorCount = 6;
constexpr std::array<std::size_t, 16> kValidUpperBodyIndices{
    12, 14,
    15, 16, 17, 18, 19, 20, 21,
    22, 23, 24, 25, 26, 27, 28,
};
constexpr auto kFeedbackFreshness = std::chrono::milliseconds(1000);
constexpr double kHandCurrentEmaAlpha = 0.03;
constexpr std::array<float, kMotorCount> kJointKp{
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 60, 0, 40,
    100, 100, 100, 100, 100, 100, 100,
    100, 100, 100, 100, 100, 100, 100};
constexpr std::array<float, kMotorCount> kJointKd{
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 1,
    3, 3, 3, 3, 3, 3, 3,
    3, 3, 3, 3, 3, 3, 3};

std::uint32_t crc32_core(const std::uint32_t* pointer, std::uint32_t length) {
  std::uint32_t crc = 0xffffffffU;
  constexpr std::uint32_t polynomial = 0x04c11db7U;
  for (std::uint32_t index = 0; index < length; ++index) {
    std::uint32_t bit = 1U << 31U;
    const std::uint32_t data = pointer[index];
    for (std::uint32_t count = 0; count < 32; ++count) {
      crc = (crc & 0x80000000U) != 0U ? (crc << 1U) ^ polynomial : crc << 1U;
      if ((data & bit) != 0U) crc ^= polynomial;
      bit >>= 1U;
    }
  }
  return crc;
}

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

    lowcmd_publisher_ =
        std::make_shared<ChannelPublisher<LowCmd_>>("rt/lowcmd");
    lowcmd_publisher_->InitChannel();

    left_hand_publisher_ =
        std::make_shared<ChannelPublisher<MotorCmds_>>("rt/brainco/left/cmd");
    right_hand_publisher_ =
        std::make_shared<ChannelPublisher<MotorCmds_>>("rt/brainco/right/cmd");
    left_hand_publisher_->InitChannel();
    right_hand_publisher_->InitChannel();

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

    left_hand_subscriber_ =
        std::make_shared<ChannelSubscriber<MotorStates_>>("rt/brainco/left/state");
    left_hand_subscriber_->InitChannel(
        [this](const void* message) { on_hand_state(message, true); }, 1);
    right_hand_subscriber_ =
        std::make_shared<ChannelSubscriber<MotorStates_>>("rt/brainco/right/state");
    right_hand_subscriber_->InitChannel(
        [this](const void* message) { on_hand_state(message, false); }, 1);

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

    if (command.arms_active && command.joint_targets_rad.size() == kMotorCount) {
      last_arm_targets_ = command.joint_targets_rad;
      {
        std::lock_guard<std::mutex> state_lock(state_mutex_);
        snapshot_.arm_command_targets_rad = last_arm_targets_;
      }
      arm_owned_ = true;
      arm_command_active_ = true;
    } else if (arm_owned_ && arm_command_active_) {
      capture_safe_arm_hold();
      arm_command_active_ = false;
    }
    if (arm_owned_) {
      write_arm_command(last_arm_targets_);
    }
    apply_hand_command(true, command.left_hand_active, command.left_hand_targets);
    apply_hand_command(false, command.right_hand_active, command.right_hand_targets);
  }

  BackendSnapshot snapshot() const override {
    std::lock_guard<std::mutex> lock(state_mutex_);
    BackendSnapshot result = snapshot_;
    result.odom_age_ms = age_ms(last_odom_ns_);
    result.height_age_ms = age_ms(last_height_ns_);
    result.lowstate_age_ms = age_ms(last_lowstate_ns_);
    result.left_hand_age_ms = age_ms(last_left_hand_ns_);
    result.right_hand_age_ms = age_ms(last_right_hand_ns_);
    result.odom_fresh =
        result.odom_age_ms >= 0.0 && result.odom_age_ms <= kFeedbackFreshness.count();
    result.height_fresh =
        result.height_age_ms >= 0.0 && result.height_age_ms <= kFeedbackFreshness.count();
    result.lowstate_fresh =
        result.lowstate_age_ms >= 0.0 && result.lowstate_age_ms <= kFeedbackFreshness.count();
    result.left_hand_fresh = result.left_hand_age_ms >= 0.0 &&
                             result.left_hand_age_ms <= kFeedbackFreshness.count();
    result.right_hand_fresh = result.right_hand_age_ms >= 0.0 &&
                              result.right_hand_age_ms <= kFeedbackFreshness.count();
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
      if (arm_owned_) {
        capture_safe_arm_hold();
        arm_command_active_ = false;
        for (int attempt = 0; attempt < 8; ++attempt) {
          write_arm_command(last_arm_targets_);
          std::this_thread::sleep_for(std::chrono::milliseconds(10));
        }
      }
      hold_hand(true);
      hold_hand(false);
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

    // Stop the SDK's DDS dispatch threads before individual reader handles are
    // destroyed. Closing a reader while CycloneDDS is inside its callback can
    // trip EntityDelegate::prevent_callbacks() during normal SIGTERM shutdown.
    try {
      ChannelFactory::Instance()->Release();
    } catch (...) {
    }

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
    close_channel(right_hand_subscriber_);
    close_channel(left_hand_subscriber_);
    close_channel(lowstate_subscriber_);
    close_channel(height_subscriber_);
    close_channel(odom_subscriber_);
    if (lowcmd_publisher_) {
      try {
        lowcmd_publisher_->CloseChannel();
      } catch (...) {
      }
      lowcmd_publisher_.reset();
    }
    close_channel(right_hand_publisher_);
    close_channel(left_hand_publisher_);

    {
      std::lock_guard<std::mutex> callback_lock(callback_mutex_);
    }
    std::lock_guard<std::mutex> lock(state_mutex_);
    snapshot_.connected = false;
  }

 private:
  void capture_safe_arm_hold() {
    constexpr double kSettledVelocityRadS = 0.12;
    constexpr double kSettledSupportOffsetRad = 0.12;
    constexpr double kMovingSupportOffsetRad = 0.04;
    std::lock_guard<std::mutex> state_lock(state_mutex_);
    if (snapshot_.joint_positions_rad.size() != kMotorCount ||
        snapshot_.joint_velocities_rad_s.size() != kMotorCount) {
      return;
    }
    if (last_arm_targets_.size() != kMotorCount) {
      last_arm_targets_ = snapshot_.joint_positions_rad;
      return;
    }
    for (std::size_t joint = 15; joint < 29; ++joint) {
      const double measured = snapshot_.joint_positions_rad[joint];
      const double offset = last_arm_targets_[joint] - measured;
      const bool settled =
          std::abs(snapshot_.joint_velocities_rad_s[joint]) <= kSettledVelocityRadS &&
          std::abs(offset) <= kSettledSupportOffsetRad;
      if (!settled) {
        last_arm_targets_[joint] = measured + std::clamp(
            offset, -kMovingSupportOffsetRad, kMovingSupportOffsetRad);
      }
    }
    snapshot_.arm_command_targets_rad = last_arm_targets_;
  }

  void write_hand_command(bool left, const std::array<double, kHandMotorCount>& targets) {
    auto& publisher = left ? left_hand_publisher_ : right_hand_publisher_;
    if (!publisher) return;
    MotorCmds_ message;
    message.cmds().resize(kHandMotorCount);
    for (std::size_t motor = 0; motor < kHandMotorCount; ++motor) {
      message.cmds()[motor].q() = static_cast<float>(std::clamp(targets[motor], 0.0, 1.0));
      message.cmds()[motor].dq() = 0.25F;
    }
    publisher->Write(message);
  }

  void apply_hand_command(
      bool left,
      bool active,
      const std::array<double, kHandMotorCount>& targets) {
    bool& owned = left ? left_hand_owned_ : right_hand_owned_;
    bool& was_active = left ? left_hand_command_active_ : right_hand_command_active_;
    auto& last_targets = left ? last_left_hand_targets_ : last_right_hand_targets_;
    if (active) {
      last_targets = targets;
      owned = true;
      was_active = true;
    } else if (owned && was_active) {
      std::lock_guard<std::mutex> state_lock(state_mutex_);
      const auto& positions =
          left ? snapshot_.left_hand_positions : snapshot_.right_hand_positions;
      if (positions.size() == kHandMotorCount) {
        std::copy_n(positions.begin(), kHandMotorCount, last_targets.begin());
      }
      was_active = false;
    }
    if (owned) write_hand_command(left, last_targets);
  }

  void hold_hand(bool left) {
    bool& owned = left ? left_hand_owned_ : right_hand_owned_;
    bool& was_active = left ? left_hand_command_active_ : right_hand_command_active_;
    auto& last_targets = left ? last_left_hand_targets_ : last_right_hand_targets_;
    if (!owned) return;
    {
      std::lock_guard<std::mutex> state_lock(state_mutex_);
      const auto& positions =
          left ? snapshot_.left_hand_positions : snapshot_.right_hand_positions;
      if (positions.size() == kHandMotorCount) {
        std::copy_n(positions.begin(), kHandMotorCount, last_targets.begin());
      }
    }
    was_active = false;
    for (int attempt = 0; attempt < 4; ++attempt) {
      write_hand_command(left, last_targets);
      std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
  }

  void write_arm_command(const std::vector<double>& targets) {
    if (!lowcmd_publisher_ || targets.size() != kMotorCount) return;
    std::int64_t mode_machine = 0;
    {
      std::lock_guard<std::mutex> state_lock(state_mutex_);
      mode_machine = snapshot_.mode_machine;
    }
    LowCmd_ message;
    message.mode_pr() = static_cast<std::uint8_t>(0);
    message.mode_machine() = static_cast<std::uint8_t>(mode_machine);
    for (std::size_t joint = 0; joint < kMotorCount; ++joint) {
      message.motor_cmd().at(joint).mode() = 1;
      message.motor_cmd().at(joint).tau() = 0.0F;
      message.motor_cmd().at(joint).q() = static_cast<float>(targets[joint]);
      message.motor_cmd().at(joint).dq() = 0.0F;
      message.motor_cmd().at(joint).kp() = kJointKp[joint];
      message.motor_cmd().at(joint).kd() = kJointKd[joint];
    }
    message.crc() = crc32_core(
        reinterpret_cast<std::uint32_t*>(&message),
        static_cast<std::uint32_t>((sizeof(message) >> 2U) - 1U));
    lowcmd_publisher_->Write(message);
  }

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
    if (lowstate.crc() != crc32_core(
                              reinterpret_cast<const std::uint32_t*>(&lowstate),
                              static_cast<std::uint32_t>((sizeof(lowstate) >> 2U) - 1U))) {
      return;
    }
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

  void on_hand_state(const void* message, bool left) {
    std::lock_guard<std::mutex> callback_lock(callback_mutex_);
    if (stopping_.load(std::memory_order_acquire)) return;
    const auto& state = *static_cast<const MotorStates_*>(message);
    if (state.states().size() < kHandMotorCount) return;
    std::vector<double> positions(kHandMotorCount, 0.0);
    std::vector<double> velocities(kHandMotorCount, 0.0);
    std::vector<double> currents(kHandMotorCount, 0.0);
    for (std::size_t motor = 0; motor < kHandMotorCount; ++motor) {
      positions[motor] = state.states()[motor].q();
      velocities[motor] = state.states()[motor].dq();
      const double raw_current = state.states()[motor].tau_est();
      auto& filter = left ? left_hand_current_ema_ : right_hand_current_ema_;
      bool& initialized = left ? left_hand_current_initialized_ : right_hand_current_initialized_;
      currents[motor] = initialized
                            ? filter[motor] + kHandCurrentEmaAlpha * (raw_current - filter[motor])
                            : raw_current;
      filter[motor] = currents[motor];
    }
    (left ? left_hand_current_initialized_ : right_hand_current_initialized_) = true;
    std::lock_guard<std::mutex> state_lock(state_mutex_);
    if (left) {
      snapshot_.left_hand_positions = std::move(positions);
      snapshot_.left_hand_velocities = std::move(velocities);
      snapshot_.left_hand_currents = std::move(currents);
      last_left_hand_ns_ = steady_time_ns();
    } else {
      snapshot_.right_hand_positions = std::move(positions);
      snapshot_.right_hand_velocities = std::move(velocities);
      snapshot_.right_hand_currents = std::move(currents);
      last_right_hand_ns_ = steady_time_ns();
    }
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
  std::int64_t last_left_hand_ns_ = 0;
  std::int64_t last_right_hand_ns_ = 0;
  bool base_owned_ = false;
  bool lift_owned_ = false;
  bool arm_owned_ = false;
  bool arm_command_active_ = false;
  bool left_hand_owned_ = false;
  bool right_hand_owned_ = false;
  bool left_hand_command_active_ = false;
  bool right_hand_command_active_ = false;
  bool stopped_ = false;
  std::atomic<bool> stopping_{false};

  std::unique_ptr<AgvClient> agv_client_;
  ChannelPublisherPtr<LowCmd_> lowcmd_publisher_;
  std::vector<double> last_arm_targets_;
  std::array<double, kHandMotorCount> last_left_hand_targets_{};
  std::array<double, kHandMotorCount> last_right_hand_targets_{};
  std::array<double, kHandMotorCount> left_hand_current_ema_{};
  std::array<double, kHandMotorCount> right_hand_current_ema_{};
  bool left_hand_current_initialized_ = false;
  bool right_hand_current_initialized_ = false;
  ChannelPublisherPtr<MotorCmds_> left_hand_publisher_;
  ChannelPublisherPtr<MotorCmds_> right_hand_publisher_;
  ChannelSubscriberPtr<Odometry_> odom_subscriber_;
  ChannelSubscriberPtr<Point32_> height_subscriber_;
  ChannelSubscriberPtr<LowState_> lowstate_subscriber_;
  ChannelSubscriberPtr<IMUState_> imu_subscriber_;
  ChannelSubscriberPtr<MotorStates_> left_hand_subscriber_;
  ChannelSubscriberPtr<MotorStates_> right_hand_subscriber_;
};

}  // namespace

std::unique_ptr<Backend> make_unitree_backend(UnitreeBackendConfig config) {
  return std::make_unique<UnitreeBackend>(std::move(config));
}

}  // namespace operator_g1d
