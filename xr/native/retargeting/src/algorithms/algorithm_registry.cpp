#include "retargeting/algorithm_registry.hpp"

namespace retargeting {

AlgorithmRegistry& AlgorithmRegistry::instance() {
  static AlgorithmRegistry registry;
  return registry;
}

void AlgorithmRegistry::register_algorithm(const std::string& name,
                                           AlgorithmFactory factory) {
  for (auto& [n, f] : factories_) {
    if (n == name) {
      f = std::move(factory);  // last registration wins
      return;
    }
  }
  factories_.emplace_back(name, std::move(factory));
}

std::unique_ptr<RetargetingAlgorithm> AlgorithmRegistry::create(
    const std::string& name) const {
  for (const auto& [n, f] : factories_)
    if (n == name) return f();
  return nullptr;
}

bool AlgorithmRegistry::has(const std::string& name) const {
  for (const auto& [n, f] : factories_)
    if (n == name) return true;
  return false;
}

std::vector<std::string> AlgorithmRegistry::names() const {
  std::vector<std::string> out;
  out.reserve(factories_.size());
  for (const auto& [n, f] : factories_) out.push_back(n);
  return out;
}

}  // namespace retargeting
