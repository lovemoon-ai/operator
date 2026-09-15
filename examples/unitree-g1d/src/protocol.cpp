#include "operator_g1d/protocol.hpp"

#include <arpa/inet.h>
#include <algorithm>
#include <array>
#include <cerrno>
#include <cstring>
#include <poll.h>
#include <stdexcept>
#include <sys/socket.h>
#include <unistd.h>

#include <unitree/common/json/jsonize.hpp>

namespace operator_g1d {
namespace {

using unitree::common::Any;
using unitree::common::AnyCast;
using unitree::common::FromJson;
using unitree::common::FromJsonString;
using unitree::common::JsonArray;
using unitree::common::JsonMap;
using unitree::common::ToJson;
using unitree::common::ToJsonString;

template <typename T>
void read_optional(const JsonMap& object, const std::string& key, T& value) {
  const auto found = object.find(key);
  if (found != object.end()) {
    FromJson(found->second, value);
  }
}

Pose6D parse_pose(const Any& value) {
  const auto& object = AnyCast<JsonMap>(value);
  std::vector<double> position;
  std::vector<double> rotation;
  read_optional(object, "position", position);
  read_optional(object, "rotation", rotation);
  if (position.size() != 3 || rotation.size() != 4) {
    throw std::runtime_error("pose must contain position[3] and rotation[4]");
  }
  Pose6D pose;
  std::copy(position.begin(), position.end(), pose.position.begin());
  std::copy(rotation.begin(), rotation.end(), pose.rotation.begin());
  return pose;
}

DeviceCommand parse_command(const JsonMap& object) {
  DeviceCommand command;
  read_optional(object, "axes", command.axes);
  read_optional(object, "buttons", command.buttons);
  read_optional(object, "timestamp_ns", command.timestamp_ns);

  const auto poses = object.find("poses");
  if (poses != object.end()) {
    const auto& pose_map = AnyCast<JsonMap>(poses->second);
    for (const auto& entry : pose_map) {
      command.poses.emplace(entry.first, parse_pose(entry.second));
    }
  }
  return command;
}

JsonMap encode_values(const TelemetryValues& values) {
  JsonMap payload;
  for (const auto& entry : values.floats) {
    payload[entry.first] = entry.second;
  }
  for (const auto& entry : values.integers) {
    payload[entry.first] = entry.second;
  }
  for (const auto& entry : values.booleans) {
    payload[entry.first] = entry.second;
  }
  for (const auto& entry : values.strings) {
    payload[entry.first] = entry.second;
  }
  for (const auto& entry : values.arrays) {
    Any encoded;
    ToJson(entry.second, encoded);
    payload[entry.first] = encoded;
  }
  return payload;
}

void write_exact(int fd, const void* source, std::size_t length) {
  const auto* input = static_cast<const std::uint8_t*>(source);
  std::size_t offset = 0;
  while (offset < length) {
    const ssize_t count = ::send(fd, input + offset, length - offset, MSG_NOSIGNAL);
    if (count < 0) {
      if (errno == EINTR) {
        continue;
      }
      throw std::runtime_error(std::string("send failed: ") + std::strerror(errno));
    }
    offset += static_cast<std::size_t>(count);
  }
}

}  // namespace

InboundMessage parse_inbound_message(const std::string& payload) {
  JsonMap root;
  FromJsonString(payload, root);
  std::string type;
  read_optional(root, "type", type);
  if (type.empty()) {
    throw std::runtime_error("adapter message is missing type");
  }

  InboundMessage message;
  if (type == "Hello") {
    message.kind = InboundKind::Hello;
  } else if (type == "Command") {
    message.kind = InboundKind::Command;
    message.command = parse_command(root);
  } else if (type == "Stop") {
    message.kind = InboundKind::Stop;
    read_optional(root, "reason", message.reason);
  } else if (type == "BlueprintEvent") {
    message.kind = InboundKind::BlueprintEvent;
  } else if (type == "Shutdown") {
    message.kind = InboundKind::Shutdown;
  } else {
    throw std::runtime_error("unsupported adapter message type: " + type);
  }
  return message;
}

std::string make_values_json(const TelemetryValues& values) {
  return ToJsonString(encode_values(values));
}

std::string make_telemetry_message(const TelemetryValues& values, std::uint64_t timestamp_ns) {
  JsonMap root;
  root["type"] = std::string("Telemetry");
  root["values"] = encode_values(values);
  root["timestamp_ns"] = timestamp_ns;
  return ToJsonString(root);
}

std::string make_event_message(const std::string& kind, const std::string& message) {
  JsonMap root;
  root["type"] = std::string("Event");
  root["kind"] = kind;
  root["msg"] = message;
  return ToJsonString(root);
}

ReadFrameResult FrameReader::read(
    int fd,
    std::string& payload,
    std::chrono::milliseconds timeout) {
  const auto deadline = std::chrono::steady_clock::now() + timeout;
  for (;;) {
    if (buffer_.size() >= 4) {
      const std::uint32_t length = static_cast<std::uint32_t>(buffer_[0]) |
                                   (static_cast<std::uint32_t>(buffer_[1]) << 8U) |
                                   (static_cast<std::uint32_t>(buffer_[2]) << 16U) |
                                   (static_cast<std::uint32_t>(buffer_[3]) << 24U);
      if (length > kMaxFrameLength) {
        throw std::runtime_error("adapter frame exceeds 16 MiB limit");
      }
      const std::size_t frame_size = 4U + static_cast<std::size_t>(length);
      if (buffer_.size() >= frame_size) {
        payload.assign(
            reinterpret_cast<const char*>(buffer_.data() + 4),
            static_cast<std::size_t>(length));
        buffer_.erase(buffer_.begin(), buffer_.begin() + frame_size);
        return ReadFrameResult::Frame;
      }
    }

    const auto now = std::chrono::steady_clock::now();
    if (now >= deadline) {
      return ReadFrameResult::Timeout;
    }
    const auto remaining = std::chrono::duration_cast<std::chrono::milliseconds>(deadline - now);
    const int poll_timeout_ms = std::max(1, static_cast<int>(remaining.count()));
    pollfd descriptor{fd, POLLIN, 0};
    int result;
    do {
      result = ::poll(&descriptor, 1, poll_timeout_ms);
    } while (result < 0 && errno == EINTR);
    if (result == 0) {
      return ReadFrameResult::Timeout;
    }
    if (result < 0) {
      throw std::runtime_error(std::string("poll failed: ") + std::strerror(errno));
    }
    if ((descriptor.revents & POLLNVAL) != 0) {
      return ReadFrameResult::Closed;
    }
    if ((descriptor.revents & POLLIN) != 0) {
      std::array<std::uint8_t, 64U * 1024U> chunk{};
      const ssize_t count = ::recv(fd, chunk.data(), chunk.size(), MSG_DONTWAIT);
      if (count > 0) {
        buffer_.insert(buffer_.end(), chunk.begin(), chunk.begin() + count);
        continue;
      }
      if (count == 0) {
        return ReadFrameResult::Closed;
      }
      if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) {
        continue;
      }
      throw std::runtime_error(std::string("recv failed: ") + std::strerror(errno));
    }
    if ((descriptor.revents & (POLLERR | POLLHUP)) != 0) {
      return ReadFrameResult::Closed;
    }
  }
}

void write_frame(int fd, const std::string& payload) {
  if (payload.size() > kMaxFrameLength) {
    throw std::runtime_error("adapter frame exceeds 16 MiB limit");
  }
  const std::uint32_t length = static_cast<std::uint32_t>(payload.size());
  const std::array<std::uint8_t, 4> header{
      static_cast<std::uint8_t>(length & 0xffU),
      static_cast<std::uint8_t>((length >> 8U) & 0xffU),
      static_cast<std::uint8_t>((length >> 16U) & 0xffU),
      static_cast<std::uint8_t>((length >> 24U) & 0xffU),
  };
  write_exact(fd, header.data(), header.size());
  if (!payload.empty()) {
    write_exact(fd, payload.data(), payload.size());
  }
}

}  // namespace operator_g1d
