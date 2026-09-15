#pragma once

#include <stdexcept>
#include <string>
#include <string_view>
#include <utility>

#include "operator.h"

namespace operator_sdk {

class Error : public std::runtime_error { using std::runtime_error::runtime_error; };

class BlueprintPublisher {
 public:
  BlueprintPublisher() : handle_(operator_blueprint_publisher_new()) {
    if (!handle_) throw Error("creating Operator Blueprint publisher");
  }
  ~BlueprintPublisher() { operator_blueprint_publisher_free(handle_); }
  BlueprintPublisher(const BlueprintPublisher&) = delete;
  BlueprintPublisher& operator=(const BlueprintPublisher&) = delete;
  BlueprintPublisher(BlueprintPublisher&& other) noexcept
      : handle_(std::exchange(other.handle_, nullptr)) {}
  BlueprintPublisher& operator=(BlueprintPublisher&& other) noexcept {
    if (this != &other) {
      operator_blueprint_publisher_free(handle_);
      handle_ = std::exchange(other.handle_, nullptr);
    }
    return *this;
  }

  static std::string_view spec_sha256() {
    const operator_string_view_t value = operator_blueprint_spec_sha256();
    return std::string_view(reinterpret_cast<const char*>(value.data), value.len);
  }
  static uint32_t spec_version() { return operator_blueprint_spec_version(); }

  void set_blueprint_json(std::string_view value) {
    operator_bytes_t error{};
    if (!operator_blueprint_set_json(handle_, bytes(value), value.size(), &error)) fail(error);
  }
  void clear() {
    operator_bytes_t error{};
    if (!operator_blueprint_clear(handle_, &error)) fail(error);
  }
  uint64_t update_values_json(std::string_view value, uint64_t timestamp_ns) {
    operator_bytes_t error{}; uint64_t sequence = 0;
    if (!operator_blueprint_update_values_json(handle_, bytes(value), value.size(), timestamp_ns, &sequence, &error)) fail(error);
    return sequence;
  }
  std::string definition_message_json() { return output(operator_blueprint_definition_message_json); }
  std::string state_message_json() { return output(operator_blueprint_state_message_json); }
  std::string descriptor_message_json(std::string_view value) {
    operator_bytes_t result{}, error{};
    if (!operator_blueprint_descriptor_message_json(handle_, bytes(value), value.size(), &result, &error)) fail(error);
    return take(result);
  }
  std::string parse_event_message_json(std::string_view value) {
    operator_bytes_t result{}, error{};
    if (!operator_blueprint_parse_event_message_json(handle_, bytes(value), value.size(), &result, &error)) fail(error);
    return take(result);
  }
 private:
  class OwnedBytes {
   public:
    explicit OwnedBytes(operator_bytes_t value) : value_(value) {}
    ~OwnedBytes() { operator_bytes_free(value_); }
    OwnedBytes(const OwnedBytes&) = delete;
    OwnedBytes& operator=(const OwnedBytes&) = delete;

   private:
    operator_bytes_t value_;
  };

  using JsonFn = bool (*)(operator_blueprint_publisher_t*, operator_bytes_t*, operator_bytes_t*);
  static const uint8_t* bytes(std::string_view value) { return reinterpret_cast<const uint8_t*>(value.data()); }
  static std::string take(operator_bytes_t value) {
    OwnedBytes owned(value);
    if (value.len == 0) return {};
    return std::string(reinterpret_cast<const char*>(value.data), value.len);
  }
  [[noreturn]] static void fail(operator_bytes_t value) {
    std::string message = take(value);
    throw Error(message.empty() ? "unknown liboperator error" : std::move(message));
  }
  std::string output(JsonFn function) {
    operator_bytes_t result{}, error{}; if (!function(handle_, &result, &error)) fail(error); return take(result);
  }
  operator_blueprint_publisher_t* handle_ = nullptr;
};

}  // namespace operator_sdk
