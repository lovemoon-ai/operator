// Business-layer scenario description.
//
// The toolkit separates *what* is being retargeted (a business scenario) from
// *how* the joint angles are computed (an algorithm). A Scenario names the three
// supported teleoperation use cases; a ScenarioSpec is the concrete data the
// business layer hands to an algorithm so it can specialize itself for that use
// case without the algorithm needing to hard-code any one scenario.
#pragma once
#include <string>
#include <vector>

namespace retargeting {

// The three teleoperation use cases the business layer distinguishes.
enum class Scenario {
  WholeBody,   // full-body source pose -> full robot (legs + torso + arms).
  UpperBody,   // torso + arms only; the robot's lower body is held fixed.
  Hand,        // finger/hand pose -> dexterous-hand joints.
};

inline const char* to_string(Scenario s) {
  switch (s) {
    case Scenario::WholeBody: return "whole_body";
    case Scenario::UpperBody: return "upper_body";
    case Scenario::Hand:      return "hand";
  }
  return "unknown";
}

// Data the business layer passes to an algorithm to specialize it for a
// scenario. Kept as plain data so new algorithms can interpret the fields they
// understand and ignore the rest.
struct ScenarioSpec {
  Scenario kind = Scenario::WholeBody;

  // Number of leading robot configuration (qpos) entries to hold fixed across
  // the solve. For the upper-body scenario on a humanoid this pins the floating
  // base + lower-body joints so only the torso/arms move. Robot-specific
  // (e.g. 19 = 7 base + 12 leg DoFs for a Unitree G1); 0 means "nothing locked"
  // (whole-body). This is the faithful generalization of the GMR port's
  // configure_g1_upper_body_only(); a name-based lock list can be layered on top
  // later as more robots are added.
  int locked_qpos_prefix = 0;
};

}  // namespace retargeting
