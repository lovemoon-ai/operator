// Alignment test: feed real GMR-coordinate quest3 human frames through the C++
// retargeter and compare the per-frame robot joint angles to the Python GMR
// reference (robot_solution.jsonl). This validates the C++ pipeline against the
// original Python implementation on real (non-synthetic) data.
//
// Usage:
//   retarget_align <gmr_input.jsonl> <robot_solution.jsonl> <robot_xml>
//                  <ik_config.json> [human_height] [locked_prefix] [freeze]
#include <cmath>
#include <cstdlib>
#include <cstdio>
#include <fstream>
#include <string>
#include <vector>

#include <nlohmann/json.hpp>

#include "retargeting/retargeter.hpp"

using json = nlohmann::json;
using retargeting::Pose;
using retargeting::SkeletonFrame;

int main(int argc, char** argv) {
  if (argc < 5) {
    fprintf(stderr,
            "usage: %s <gmr_input.jsonl> <robot_solution.jsonl> <robot_xml> "
            "<ik_config> [human_height=1.75] [locked_prefix=19] [freeze=0]\n",
            argv[0]);
    return 2;
  }
  std::string gmr_path = argv[1], sol_path = argv[2], xml = argv[3], ik = argv[4];
  double human_height = argc > 5 ? std::stod(argv[5]) : 1.75;
  int locked_prefix = argc > 6 ? std::stoi(argv[6]) : 19;
  bool freeze = argc > 7 ? (std::stoi(argv[7]) != 0) : false;

  retargeting::RetargetConfig cfg;
  cfg.robot_xml = xml;
  cfg.ik_config_json = ik;
  cfg.human_height = human_height;
  cfg.backend = retargeting::KinematicsBackendKind::Mujoco;
  // Python clamps waist_roll(20), waist_pitch(21), and the wrists
  // (26,27,28,33,34,35) to rest each frame, in addition to the legs (prefix 19).
  std::vector<int> clamp;
  if (freeze) clamp = {20, 21, 26, 27, 28, 33, 34, 35};
  auto rt = retargeting::UpperBodyRetargeter::create(cfg, locked_prefix, "gmr", false, clamp);
  printf("human_height=%.3f locked_prefix=%d extra_clamp=%d\n", human_height, locked_prefix, freeze);

  // Drift test: env CONST_FRAME=N feeds frame N repeatedly 400 times and prints
  // how the arm joints evolve, to see if a STATIC input drifts.
  if (const char* cf = std::getenv("CONST_FRAME")) {
    int target = std::atoi(cf);
    std::ifstream gi(gmr_path);
    std::string line; int idx = 0; json jg;
    while (std::getline(gi, line)) { if (idx++ == target) { jg = json::parse(line); break; } }
    SkeletonFrame f;
    for (auto& [name, rec] : jg["joints"].items()) {
      Pose p; auto pos = rec["position"]; auto rot = rec["rotation"];
      p.pos = Eigen::Vector3d(pos[0], pos[1], pos[2]);
      p.quat = Eigen::Vector4d(rot[0], rot[1], rot[2], rot[3]);
      f[name] = p;
    }
    printf("CONST drift test (frame %d fed repeatedly):\n", target);
    for (int k = 0; k < 400; ++k) {
      Eigen::VectorXd q = rt->step(f);
      if (k == 0 || k == 1 || k == 5 || k == 20 || k == 100 || k == 399)
        printf("  iter %3d: L_sh_pitch[22]=%+.5f L_sh_roll[23]=%+.5f L_elbow[25]=%+.5f R_sh_pitch[29]=%+.5f\n",
               k, q[22], q[23], q[25], q[29]);
    }
    return 0;
  }

  std::ifstream gmr_in(gmr_path), sol_in(sol_path);
  if (!gmr_in || !sol_in) { fprintf(stderr, "cannot open input files\n"); return 2; }

  std::string lg, ls;
  int frame = 0;
  double global_max = 0.0, sum_abs = 0.0;
  long count = 0;
  double worst_frame_max = 0.0; int worst_frame = -1;
  while (std::getline(gmr_in, lg) && std::getline(sol_in, ls)) {
    if (lg.empty()) continue;
    json jg = json::parse(lg);
    json js = json::parse(ls);

    SkeletonFrame f;
    for (auto& [name, rec] : jg["joints"].items()) {
      Pose p;
      auto pos = rec["position"];
      auto rot = rec["rotation"];  // wxyz
      p.pos = Eigen::Vector3d(pos[0], pos[1], pos[2]);
      p.quat = Eigen::Vector4d(rot[0], rot[1], rot[2], rot[3]);
      f[name] = p;
    }
    Eigen::VectorXd q = rt->step(f);  // length 36 (base 7 + 29 joints)

    std::vector<double> ref = js["joint_q"].get<std::vector<double>>();  // 29
    std::vector<std::string> jn = js["joint_names"].get<std::vector<std::string>>();
    double fmax = 0.0; int fmax_j = -1;
    for (size_t i = 0; i < ref.size() && (int)(7 + i) < q.size(); ++i) {
      double d = std::fabs(q[7 + i] - ref[i]);
      if (d > fmax) { fmax = d; fmax_j = (int)i; }
      sum_abs += d; ++count;
    }
    if (frame == 0 || frame == 100) {
      printf("--- frame %d (worst joint %s d=%.3f) ---\n", frame,
             fmax_j >= 0 ? jn[fmax_j].c_str() : "?", fmax);
      for (size_t i = 12; i < ref.size(); ++i)  // upper-body joints only
        printf("  %-26s cpp=%+.4f  py=%+.4f  d=%+.4f\n",
               jn[i].c_str(), q[7 + i], ref[i], q[7 + i] - ref[i]);
    }
    if (fmax > worst_frame_max) { worst_frame_max = fmax; worst_frame = frame; }
    global_max = std::max(global_max, fmax);
    ++frame;
  }
  printf("frames=%d  max_abs_diff=%.4e (rad)  mean_abs_diff=%.4e  worst_frame=%d (%.4e)\n",
         frame, global_max, count ? sum_abs / count : 0.0, worst_frame, worst_frame_max);
  printf("RESULT: %s (tol 1e-3 rad)\n", global_max < 1e-3 ? "ALIGNED" : "MISMATCH");
  return global_max < 1e-3 ? 0 : 1;
}
