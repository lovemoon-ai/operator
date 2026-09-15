#pragma once

#include <chrono>
#include <cstddef>
#include <string>
#include <vector>

#include "operator_g1d/types.hpp"

namespace operator_g1d {

constexpr std::size_t kMaxFrameLength = 16U * 1024U * 1024U;
enum class ReadFrameResult {
  Frame,
  Timeout,
  Closed,
};

class FrameReader {
 public:
  ReadFrameResult read(
      int fd,
      std::string& payload,
      std::chrono::milliseconds timeout);

 private:
  std::vector<std::uint8_t> buffer_;
};

InboundMessage parse_inbound_message(const std::string& payload);
std::string make_values_json(const TelemetryValues& values);
std::string make_telemetry_message(const TelemetryValues& values, std::uint64_t timestamp_ns);
std::string make_event_message(const std::string& kind, const std::string& message);

void write_frame(int fd, const std::string& payload);

}  // namespace operator_g1d
