// Algorithm-layer interface.
//
// A RetargetingAlgorithm maps a frame of source skeleton poses onto a robot
// configuration (MuJoCo-convention qpos). It is the extension point of the
// toolkit: GMR is the first implementation (algorithms/gmr), and additional
// algorithms (analytic IK, learned retargeters, ...) plug in by implementing
// this interface and registering a factory (see algorithm_registry.hpp).
//
// The per-frame protocol the business layer drives is:
//     begin_frame();                     // restore any locked region
//     qpos = solve(frame);               // run the algorithm
//     end_frame(qpos);                   // re-apply the lock, commit
// For scenarios with nothing locked (whole-body) begin/end are cheap no-ops.
#pragma once
#include <Eigen/Dense>
#include <string>

#include "scenario.hpp"
#include "types.hpp"

namespace retargeting {

class RetargetingAlgorithm {
 public:
  virtual ~RetargetingAlgorithm() = default;

  // Stable identifier, matching the name used to register the factory.
  virtual const char* name() const = 0;

  // Bind to a robot + mapping and specialize for a scenario. Must be called
  // once before any begin_frame/solve/end_frame.
  virtual void configure(const RetargetConfig& config, const ScenarioSpec& spec) = 0;

  // Restore the locked configuration region to its held values before a solve.
  virtual void begin_frame() = 0;

  // Run one retargeting step and return the resulting robot qpos.
  virtual Eigen::VectorXd solve(const SkeletonFrame& frame) = 0;

  // Re-apply the locked region to `qpos` and commit it as the new state.
  virtual void end_frame(Eigen::VectorXd& qpos) = 0;

  // Robot configuration / tangent sizes (valid after configure()).
  virtual int nq() const = 0;
  virtual int nv() const = 0;

  // Replace the current robot configuration (e.g. to seed from a known pose).
  virtual void set_configuration(const Eigen::VectorXd& qpos) = 0;
};

}  // namespace retargeting
