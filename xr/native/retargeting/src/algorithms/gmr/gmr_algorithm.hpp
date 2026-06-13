// GMR as a pluggable RetargetingAlgorithm.
//
// Thin adapter that wraps GmrSolver behind the toolkit's algorithm interface so
// the business layer can drive it like any other algorithm. Registered under
// the name "gmr".
#pragma once
#include <memory>

#include "gmr_solver.hpp"
#include "retargeting/algorithm.hpp"

namespace retargeting {
namespace gmr {

class GmrAlgorithm : public RetargetingAlgorithm {
 public:
  const char* name() const override { return "gmr"; }

  void configure(const RetargetConfig& config, const ScenarioSpec& spec) override;
  void begin_frame() override;
  Eigen::VectorXd solve(const SkeletonFrame& frame) override;
  void end_frame(Eigen::VectorXd& qpos) override;

  int nq() const override { return solver_ ? solver_->nq() : 0; }
  int nv() const override { return solver_ ? solver_->nv() : 0; }
  void set_configuration(const Eigen::VectorXd& qpos) override;

 private:
  std::unique_ptr<GmrSolver> solver_;
  ScenarioSpec spec_;
};

}  // namespace gmr
}  // namespace retargeting
