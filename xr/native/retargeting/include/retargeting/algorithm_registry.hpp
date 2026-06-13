// Algorithm factory registry.
//
// Decouples the business layer from concrete algorithm classes: a retargeter
// asks for an algorithm by name ("gmr", ...) and the registry constructs it.
// New algorithms self-register at static-init time via
// REGISTER_RETARGETING_ALGORITHM, so adding one is a single new translation
// unit with no edits to the business layer.
#pragma once
#include <functional>
#include <memory>
#include <string>
#include <vector>

#include "algorithm.hpp"

namespace retargeting {

using AlgorithmFactory = std::function<std::unique_ptr<RetargetingAlgorithm>()>;

class AlgorithmRegistry {
 public:
  static AlgorithmRegistry& instance();

  void register_algorithm(const std::string& name, AlgorithmFactory factory);

  // Construct an algorithm by name; returns nullptr if unknown.
  std::unique_ptr<RetargetingAlgorithm> create(const std::string& name) const;

  bool has(const std::string& name) const;
  std::vector<std::string> names() const;

 private:
  AlgorithmRegistry() = default;
  std::vector<std::pair<std::string, AlgorithmFactory>> factories_;
};

// Helper that registers a factory at static-init time.
struct AlgorithmRegistrar {
  AlgorithmRegistrar(const std::string& name, AlgorithmFactory factory) {
    AlgorithmRegistry::instance().register_algorithm(name, std::move(factory));
  }
};

#define REGISTER_RETARGETING_ALGORITHM(NAME, TYPE)                       \
  static ::retargeting::AlgorithmRegistrar _retargeting_registrar_##TYPE( \
      NAME, []() -> std::unique_ptr<::retargeting::RetargetingAlgorithm> { \
        return std::make_unique<TYPE>();                                 \
      })

}  // namespace retargeting
