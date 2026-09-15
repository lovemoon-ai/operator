#pragma once

#include <memory>
#include <string>

#include "operator_g1d/types.hpp"

namespace operator_g1d {

struct UnitreeBackendConfig {
  std::string network_interface = "eth0";
  int domain_id = 0;
  double rpc_timeout_seconds = 0.25;
};

class Backend {
 public:
  virtual ~Backend() = default;
  virtual std::string name() const = 0;
  virtual void start() = 0;
  virtual void apply(const ActuatorCommand& command) = 0;
  virtual BackendSnapshot snapshot() const = 0;
  virtual void emergency_stop() noexcept = 0;
  virtual void stop() noexcept = 0;
};

std::unique_ptr<Backend> make_mock_backend();
std::unique_ptr<Backend> make_unitree_backend(UnitreeBackendConfig config);

}  // namespace operator_g1d
