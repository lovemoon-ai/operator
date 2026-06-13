#include "retargeting/builtins.hpp"

#include <memory>

#include "gmr/gmr_algorithm.hpp"
#include "retargeting/algorithm_registry.hpp"

namespace retargeting {

void register_builtin_algorithms() {
  static bool done = false;
  if (done) return;
  done = true;

  AlgorithmRegistry::instance().register_algorithm(
      "gmr", []() -> std::unique_ptr<RetargetingAlgorithm> {
        return std::make_unique<gmr::GmrAlgorithm>();
      });

  // Future algorithms register here (or add their own builtins TU).
}

}  // namespace retargeting
