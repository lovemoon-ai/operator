#include "retargeting/retargeter.hpp"

#include <stdexcept>

#include "retargeting/algorithm_registry.hpp"
#include "retargeting/builtins.hpp"

namespace retargeting {

namespace {
std::unique_ptr<RetargetingAlgorithm> make_algorithm(const std::string& name) {
  register_builtin_algorithms();
  auto algo = AlgorithmRegistry::instance().create(name);
  if (!algo)
    throw std::runtime_error("unknown retargeting algorithm: '" + name + "'");
  return algo;
}
}  // namespace

// ---- Whole body ------------------------------------------------------------

WholeBodyRetargeter::WholeBodyRetargeter(std::unique_ptr<RetargetingAlgorithm> algo,
                                         const RetargetConfig& config)
    : Retargeter(std::move(algo),
                 ScenarioSpec{Scenario::WholeBody, /*locked_qpos_prefix=*/0},
                 config) {}

std::unique_ptr<WholeBodyRetargeter> WholeBodyRetargeter::create(
    const RetargetConfig& config, const std::string& algorithm) {
  return std::unique_ptr<WholeBodyRetargeter>(
      new WholeBodyRetargeter(make_algorithm(algorithm), config));
}

// ---- Upper body ------------------------------------------------------------

UpperBodyRetargeter::UpperBodyRetargeter(std::unique_ptr<RetargetingAlgorithm> algo,
                                         const RetargetConfig& config,
                                         int locked_qpos_prefix,
                                         bool freeze_locked_in_solve,
                                         const std::vector<int>& clamp_qpos_indices)
    : Retargeter(std::move(algo),
                 ScenarioSpec{Scenario::UpperBody, locked_qpos_prefix,
                              freeze_locked_in_solve, clamp_qpos_indices},
                 config) {}

std::unique_ptr<UpperBodyRetargeter> UpperBodyRetargeter::create(
    const RetargetConfig& config, int locked_qpos_prefix,
    const std::string& algorithm, bool freeze_locked_in_solve,
    const std::vector<int>& clamp_qpos_indices) {
  return std::unique_ptr<UpperBodyRetargeter>(new UpperBodyRetargeter(
      make_algorithm(algorithm), config, locked_qpos_prefix,
      freeze_locked_in_solve, clamp_qpos_indices));
}

// ---- Hand ------------------------------------------------------------------

HandRetargeter::HandRetargeter(std::unique_ptr<RetargetingAlgorithm> algo,
                               const RetargetConfig& config)
    : Retargeter(std::move(algo),
                 ScenarioSpec{Scenario::Hand, /*locked_qpos_prefix=*/0}, config) {}

std::unique_ptr<HandRetargeter> HandRetargeter::create(
    const RetargetConfig& config, const std::string& algorithm) {
  return std::unique_ptr<HandRetargeter>(
      new HandRetargeter(make_algorithm(algorithm), config));
}

}  // namespace retargeting
