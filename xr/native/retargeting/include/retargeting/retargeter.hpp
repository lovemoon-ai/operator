// Business layer: scenario-specific retargeters.
//
// Each retargeter owns an algorithm (selected by name from the registry) and
// the ScenarioSpec that specializes it for one teleoperation use case. The base
// class drives the per-frame protocol; the three subclasses differ only in how
// they build their ScenarioSpec. This is the surface a Godot GDExtension would
// call once per frame with VR-derived poses.
#pragma once
#include <Eigen/Dense>
#include <memory>
#include <string>

#include "algorithm.hpp"
#include "scenario.hpp"
#include "types.hpp"

namespace retargeting {

class Retargeter {
 public:
  virtual ~Retargeter() = default;

  Scenario scenario() const { return spec_.kind; }
  const char* algorithm_name() const { return algo_->name(); }
  int nq() const { return algo_->nq(); }
  int nv() const { return algo_->nv(); }

  // One retargeting step: restore lock -> solve -> re-apply lock -> commit.
  Eigen::VectorXd step(const SkeletonFrame& frame) {
    algo_->begin_frame();
    Eigen::VectorXd qpos = algo_->solve(frame);
    algo_->end_frame(qpos);
    return qpos;
  }

  void set_configuration(const Eigen::VectorXd& qpos) { algo_->set_configuration(qpos); }
  RetargetingAlgorithm& algorithm() { return *algo_; }

 protected:
  Retargeter(std::unique_ptr<RetargetingAlgorithm> algo, ScenarioSpec spec)
      : algo_(std::move(algo)), spec_(spec) {
    algo_->configure(config_, spec_);
  }
  // Construct + configure with an explicit config (used by the factories).
  Retargeter(std::unique_ptr<RetargetingAlgorithm> algo, ScenarioSpec spec,
             const RetargetConfig& config)
      : algo_(std::move(algo)), spec_(spec), config_(config) {
    algo_->configure(config_, spec_);
  }

  std::unique_ptr<RetargetingAlgorithm> algo_;
  ScenarioSpec spec_;
  RetargetConfig config_;
};

// Full-body source pose -> full robot. Nothing locked.
class WholeBodyRetargeter : public Retargeter {
 public:
  static std::unique_ptr<WholeBodyRetargeter> create(
      const RetargetConfig& config, const std::string& algorithm = "gmr");

 private:
  WholeBodyRetargeter(std::unique_ptr<RetargetingAlgorithm> algo,
                      const RetargetConfig& config);
};

// Torso + arms; the robot's floating base + lower body are held fixed. The
// number of locked leading qpos entries is robot-specific (e.g. 19 for G1).
class UpperBodyRetargeter : public Retargeter {
 public:
  static std::unique_ptr<UpperBodyRetargeter> create(
      const RetargetConfig& config, int locked_qpos_prefix,
      const std::string& algorithm = "gmr", bool freeze_locked_in_solve = false,
      const std::vector<int>& clamp_qpos_indices = {});

 private:
  UpperBodyRetargeter(std::unique_ptr<RetargetingAlgorithm> algo,
                      const RetargetConfig& config, int locked_qpos_prefix,
                      bool freeze_locked_in_solve,
                      const std::vector<int>& clamp_qpos_indices);
};

// Finger/hand pose -> dexterous-hand joints. Wired through the same algorithm
// interface; needs a hand robot model + hand ik_config to produce motion.
class HandRetargeter : public Retargeter {
 public:
  static std::unique_ptr<HandRetargeter> create(
      const RetargetConfig& config, const std::string& algorithm = "gmr");

 private:
  HandRetargeter(std::unique_ptr<RetargetingAlgorithm> algo,
                 const RetargetConfig& config);
};

}  // namespace retargeting
