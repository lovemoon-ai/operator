#include "gmr_algorithm.hpp"

namespace retargeting {
namespace gmr {

void GmrAlgorithm::configure(const RetargetConfig& config, const ScenarioSpec& spec) {
  spec_ = spec;
  solver_ = std::make_unique<GmrSolver>(config.backend, config.robot_xml,
                                        config.ik_config_json, config.human_height,
                                        config.damping);
  if (spec_.locked_qpos_prefix > 0)
    solver_->lock_qpos_prefix(spec_.locked_qpos_prefix);
  solver_->set_freeze_locked_in_solve(spec_.freeze_locked_in_solve);
  if (!spec_.clamp_qpos_indices.empty())
    solver_->set_clamp_qpos(spec_.clamp_qpos_indices);
}

void GmrAlgorithm::begin_frame() {
  if (solver_) solver_->reset_locked_region();
}

Eigen::VectorXd GmrAlgorithm::solve(const SkeletonFrame& frame) {
  return solver_->retarget(frame, /*offset_to_ground=*/false);
}

void GmrAlgorithm::end_frame(Eigen::VectorXd& qpos) {
  solver_->freeze_locked_region(qpos);
  solver_->update_configuration(qpos);
}

void GmrAlgorithm::set_configuration(const Eigen::VectorXd& qpos) {
  if (solver_) solver_->update_configuration(qpos);
}

}  // namespace gmr
}  // namespace retargeting
