// Upper-body retargeting demo / validation harness.
//
// Drives the *business layer* (UpperBodyRetargeter) with the synthetic Quest3
// upper-body source and the GMR *algorithm*, writing per-frame robot qpos to a
// CSV. This is the toolkit-level equivalent of the standalone GMR port's
// quest3_upper_to_g1 binary; its output is intended to be byte-identical to it
// (and therefore aligned with the original Python reference to ~1e-13).
#include <cmath>
#include <cstdio>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

#include "retargeting/retargeter.hpp"
#include "sources/quest3_source.hpp"

namespace {
// Load a CSV of doubles into row-major [rows*cols] plus its shape.
std::vector<double> load_csv(const std::string& path, int& rows, int& cols) {
  std::ifstream in(path);
  std::vector<double> data;
  std::string line;
  rows = 0; cols = 0;
  while (std::getline(in, line)) {
    if (line.empty()) continue;
    int c = 0;
    std::stringstream ss(line);
    std::string cell;
    while (std::getline(ss, cell, ',')) { data.push_back(std::stod(cell)); ++c; }
    if (rows == 0) cols = c;
    ++rows;
  }
  return data;
}
}  // namespace

int main(int argc, char** argv) {
  using namespace retargeting;

  RetargetConfig cfg;
  // Self-contained defaults: data ships under retargeting/data and is pushed to
  // the device alongside the binary, so the cwd-relative paths resolve there.
  cfg.robot_xml = "data/robot/unitree_g1/g1_mocap_29dof.xml";
  cfg.ik_config_json = "data/ik_configs/quest3_upper_to_g1.json";
  cfg.human_height = 1.75;
  cfg.damping = 1.0;
  cfg.backend = KinematicsBackendKind::Pinocchio;

  std::string out_csv = "qpos_retargeting.csv";
  std::string verify_csv;
  int n_frames = 60;
  double fps = 30.0;
  // Robot-specific: G1 floating base (7) + 12 lower-body joint DoFs.
  int locked_qpos_prefix = 19;

  for (int i = 1; i < argc; ++i) {
    std::string a = argv[i];
    auto next = [&]() { return std::string(argv[++i]); };
    if (a == "--robot_xml") cfg.robot_xml = next();
    else if (a == "--ik_config") cfg.ik_config_json = next();
    else if (a == "--out") out_csv = next();
    else if (a == "--verify") verify_csv = next();
    else if (a == "--frames") n_frames = std::stoi(next());
    else if (a == "--fps") fps = std::stod(next());
    else if (a == "--human_height") cfg.human_height = std::stod(next());
    else if (a == "--locked_prefix") locked_qpos_prefix = std::stoi(next());
    else if (a == "--backend")
      cfg.backend = (next() == "mujoco") ? KinematicsBackendKind::Mujoco
                                         : KinematicsBackendKind::Pinocchio;
  }

  auto retargeter = UpperBodyRetargeter::create(cfg, locked_qpos_prefix, "gmr");
  std::cout << "scenario=" << to_string(retargeter->scenario())
            << " algorithm=" << retargeter->algorithm_name()
            << " nq=" << retargeter->nq() << "\n";

  std::vector<double> all;  // row-major qpos for optional verification
  std::ofstream out(out_csv);
  out.precision(17);

  for (int frame_idx = 0; frame_idx < n_frames; ++frame_idx) {
    SkeletonFrame human = sources::synthetic_quest3_upper_frame(frame_idx, fps);
    Eigen::VectorXd qpos = retargeter->step(human);
    for (int i = 0; i < qpos.size(); ++i) {
      out << qpos[i];
      if (i + 1 < qpos.size()) out << ",";
      all.push_back(qpos[i]);
    }
    out << "\n";
  }
  out.close();
  std::cout << "Wrote " << n_frames << " frames to " << out_csv << "\n";

  if (!verify_csv.empty()) {
    int rr = 0, cc = 0;
    std::vector<double> ref = load_csv(verify_csv, rr, cc);
    const int cols = retargeter->nq();
    if (rr != n_frames || cc != cols || ref.size() != all.size()) {
      std::cout << "VERIFY: shape mismatch got " << n_frames << "x" << cols
                << " ref " << rr << "x" << cc << "  -> FAIL\n";
      return 2;
    }
    double maxd = 0.0;
    for (size_t i = 0; i < all.size(); ++i)
      maxd = std::max(maxd, std::fabs(all[i] - ref[i]));
    const double tol = 1e-6;
    std::cout << "VERIFY: max abs diff vs reference = " << maxd
              << (maxd < tol ? "  -> PASS ✓\n" : "  -> FAIL ✗\n");
    return maxd < tol ? 0 : 1;
  }
  return 0;
}
