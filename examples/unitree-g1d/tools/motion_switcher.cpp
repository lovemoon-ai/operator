#include <chrono>
#include <iostream>
#include <stdexcept>
#include <string>
#include <thread>

#include <unitree/robot/b2/motion_switcher/motion_switcher_client.hpp>
#include <unitree/robot/channel/channel_factory.hpp>

int main(int argc, char** argv) {
  if (argc < 2 || argc > 4) {
    std::cerr << "usage: g1d-motion-switcher check|release|select [mode] [interface]\n";
    return 2;
  }
  const std::string action = argv[1];
  const std::string mode = action == "select" && argc >= 3 ? argv[2] : "";
  const std::string interface =
      action == "select" ? (argc >= 4 ? argv[3] : "eth0") : (argc >= 3 ? argv[2] : "eth0");

  unitree::robot::ChannelFactory::Instance()->Init(0, interface);
  unitree::robot::b2::MotionSwitcherClient client;
  client.SetTimeout(5.0F);
  client.Init();

  std::string before_form;
  std::string before_mode;
  const int before_result = client.CheckMode(before_form, before_mode);
  if (before_result != 0) {
    std::cerr << "CheckMode failed: " << before_result << '\n';
    return 1;
  }
  std::cout << "before form=" << before_form << " mode=" << before_mode << '\n';
  if (action == "check") return 0;

  int result = 0;
  if (action == "release") {
    result = client.ReleaseMode();
  } else if (action == "select") {
    if (mode.empty()) throw std::runtime_error("select requires a mode");
    result = client.SelectMode(mode);
  } else {
    throw std::runtime_error("unknown action: " + action);
  }
  if (result != 0) {
    std::cerr << action << " failed: " << result << '\n';
    return 1;
  }
  std::this_thread::sleep_for(std::chrono::seconds(1));
  std::string after_form;
  std::string after_mode;
  const int after_result = client.CheckMode(after_form, after_mode);
  if (after_result != 0) {
    std::cerr << "post-action CheckMode failed: " << after_result << '\n';
    return 1;
  }
  std::cout << "after form=" << after_form << " mode=" << after_mode << '\n';
  return 0;
}
