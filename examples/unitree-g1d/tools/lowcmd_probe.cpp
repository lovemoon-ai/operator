#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <iomanip>
#include <iostream>
#include <memory>
#include <mutex>
#include <thread>

#include <unitree/idl/hg/LowCmd_.hpp>
#include <unitree/idl/hg/LowState_.hpp>
#include <unitree/robot/channel/channel_factory.hpp>
#include <unitree/robot/channel/channel_subscriber.hpp>

int main(int argc, char** argv) {
  const std::string interface = argc >= 2 ? argv[1] : "eth0";
  const double seconds = argc >= 3 ? std::stod(argv[2]) : 3.0;
  unitree::robot::ChannelFactory::Instance()->Init(0, interface);

  std::atomic<std::uint64_t> count{0};
  std::mutex mutex;
  unitree_hg::msg::dds_::LowCmd_ latest;
  unitree_hg::msg::dds_::LowState_ latest_state;
  std::atomic<std::uint64_t> state_count{0};
  auto subscriber = std::make_shared<
      unitree::robot::ChannelSubscriber<unitree_hg::msg::dds_::LowCmd_>>("rt/lowcmd");
  subscriber->InitChannel(
      [&](const void* raw) {
        std::lock_guard<std::mutex> lock(mutex);
        latest = *static_cast<const unitree_hg::msg::dds_::LowCmd_*>(raw);
        count.fetch_add(1, std::memory_order_relaxed);
      },
      100);
  auto state_subscriber = std::make_shared<
      unitree::robot::ChannelSubscriber<unitree_hg::msg::dds_::LowState_>>("rt/lowstate");
  state_subscriber->InitChannel(
      [&](const void* raw) {
        std::lock_guard<std::mutex> lock(mutex);
        latest_state = *static_cast<const unitree_hg::msg::dds_::LowState_*>(raw);
        state_count.fetch_add(1, std::memory_order_relaxed);
      },
      100);

  const auto start = std::chrono::steady_clock::now();
  std::uint64_t previous_count = 0;
  while (std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count() < seconds) {
    std::this_thread::sleep_for(std::chrono::milliseconds(200));
    const auto current_count = count.load(std::memory_order_relaxed);
    if (current_count == previous_count) continue;
    previous_count = current_count;
    std::lock_guard<std::mutex> lock(mutex);
    std::cout << std::fixed << std::setprecision(4)
              << "count=" << current_count
              << " mode_pr=" << static_cast<int>(latest.mode_pr())
              << " mode_machine=" << static_cast<int>(latest.mode_machine())
              << " left_q=";
    for (std::size_t joint = 15; joint < 22; ++joint) {
      if (joint != 15) std::cout << ',';
      std::cout << latest.motor_cmd()[joint].q();
    }
    std::cout << " left_kp=";
    for (std::size_t joint = 15; joint < 22; ++joint) {
      if (joint != 15) std::cout << ',';
      std::cout << latest.motor_cmd()[joint].kp();
    }
    if (state_count.load(std::memory_order_relaxed) > 0) {
      std::cout << " measured_q=";
      for (std::size_t joint = 15; joint < 22; ++joint) {
        if (joint != 15) std::cout << ',';
        std::cout << latest_state.motor_state()[joint].q();
      }
      std::cout << " measured_dq=";
      for (std::size_t joint = 15; joint < 22; ++joint) {
        if (joint != 15) std::cout << ',';
        std::cout << latest_state.motor_state()[joint].dq();
      }
    }
    std::cout << '\n';
  }
  subscriber->CloseChannel();
  state_subscriber->CloseChannel();
  std::cout << "total=" << count.load(std::memory_order_relaxed) << '\n';
  return 0;
}
