// Diagnostic probe: replicate the g1_overlay.gd VR->GMR mapping on synthetic
// "hands down" vs "hands up" body poses and print the resulting robot joint
// angles, to isolate whether the back-tilt is mapping/algorithm/FK.
#include <cmath>
#include <cstdio>
#include <map>
#include <string>

#include "retargeting/retargeter.hpp"
#include "sources/quest3_source.hpp"

using retargeting::Pose;
using retargeting::SkeletonFrame;

struct V3 { double x, y, z; };
static V3 sub(V3 a, V3 b) { return {a.x - b.x, a.y - b.y, a.z - b.z}; }
static double dot(V3 a, V3 b) { return a.x*b.x + a.y*b.y + a.z*b.z; }
static V3 cross(V3 a, V3 b) {
  return {a.y*b.z - a.z*b.y, a.z*b.x - a.x*b.z, a.x*b.y - a.y*b.x};
}
static V3 norm(V3 a) { double l = std::sqrt(dot(a,a)); return {a.x/l, a.y/l, a.z/l}; }

// Replicate g1_overlay.gd _on_canonical_frame_ready mapping (Godot Y-up world).
static SkeletonFrame map_to_gmr(const std::map<std::string, V3>& vr) {
  V3 hips = vr.at("Hips");
  V3 up = {0, 1, 0};
  V3 lr = sub(vr.at("LeftShoulder"), vr.at("RightShoulder"));
  V3 left_h = norm({lr.x, 0, lr.z});
  V3 fwd = norm(cross(left_h, up));
  SkeletonFrame f;
  for (auto& [name, p] : vr) {
    V3 rel = sub(p, hips);
    Pose pose;
    pose.pos = Eigen::Vector3d(dot(rel, fwd), dot(rel, left_h), p.y);
    pose.quat = Eigen::Vector4d(1, 0, 0, 0);
    f[name] = pose;
  }
  return f;
}

static int g_prefix = 19;
static bool g_freeze = false;
static void run(const char* label, const std::map<std::string, V3>& vr,
                const std::string& xml, const std::string& ik) {
  retargeting::RetargetConfig cfg;
  cfg.robot_xml = xml;
  cfg.ik_config_json = ik;
  cfg.human_height = 1.75;
  cfg.backend = retargeting::KinematicsBackendKind::Mujoco;
  auto rt = retargeting::UpperBodyRetargeter::create(cfg, g_prefix, "gmr", g_freeze);
  SkeletonFrame f = map_to_gmr(vr);
  Eigen::VectorXd q = rt->step(f);
  auto deg = [](double r) { return r * 180.0 / M_PI; };
  printf("[%s] waist_pitch[21]=%+6.1f  L_sh_pitch[22]=%+6.1f  L_sh_roll[23]=%+6.1f  L_elbow[25]=%+6.1f  R_sh_pitch[29]=%+6.1f (deg)\n",
         label, deg(q[21]), deg(q[22]), deg(q[23]), deg(q[25]), deg(q[29]));
  // also print GMR-frame wrist target for sanity
  V3 hips = vr.at("Hips");
  printf("        L_wrist_gmr=(%.2f,%.2f,%.2f)\n",
         f["LeftWrist"].pos.x(), f["LeftWrist"].pos.y(), f["LeftWrist"].pos.z());
}

int main(int argc, char** argv) {
  std::string xml = "data/robot/unitree_g1/g1_mocap_29dof_nomesh.xml";
  std::string ik = "data/ik_configs/quest3_upper_to_g1.json";
  if (argc > 1) xml = argv[1];
  if (argc > 2) ik = argv[2];
  if (argc > 3) g_prefix = std::atoi(argv[3]);
  if (argc > 4) g_freeze = std::atoi(argv[4]) != 0;
  printf("locked_qpos_prefix = %d  freeze_in_solve = %d\n", g_prefix, g_freeze);

  // Operator facing -Z (Godot), left = -X. Y is up.
  std::map<std::string, V3> down = {
    {"Hips",          {0.0, 0.95, 0.0}},
    {"Chest",         {0.0, 1.40, 0.0}},
    {"LeftShoulder",  {-0.18, 1.45, 0.0}},
    {"RightShoulder", { 0.18, 1.45, 0.0}},
    {"LeftArmLower",  {-0.20, 1.15, 0.03}},
    {"RightArmLower", { 0.20, 1.15, 0.03}},
    {"LeftWrist",     {-0.20, 0.90, 0.05}},
    {"RightWrist",    { 0.20, 0.90, 0.05}},
  };
  std::map<std::string, V3> up = {
    {"Hips",          {0.0, 0.95, 0.0}},
    {"Chest",         {0.0, 1.40, 0.0}},
    {"LeftShoulder",  {-0.18, 1.45, 0.0}},
    {"RightShoulder", { 0.18, 1.45, 0.0}},
    {"LeftArmLower",  {-0.20, 1.62, 0.05}},
    {"RightArmLower", { 0.20, 1.62, 0.05}},
    {"LeftWrist",     {-0.18, 1.92, 0.05}},
    {"RightWrist",    { 0.18, 1.92, 0.05}},
  };
  run("hands_down", down, xml, ik);
  run("hands_up  ", up, xml, ik);

  // Known-good reference: feed the synthetic quest3 frames DIRECTLY (already in
  // GMR coords) and print the same angles, for arm-down vs arm-up phases.
  printf("--- synthetic quest3 (known-good, fed directly) ---\n");
  auto run_syn = [&](const char* label, int frame_idx) {
    retargeting::RetargetConfig cfg;
    cfg.robot_xml = xml; cfg.ik_config_json = ik; cfg.human_height = 1.75;
    cfg.backend = retargeting::KinematicsBackendKind::Mujoco;
    auto rt = retargeting::UpperBodyRetargeter::create(cfg, 19, "gmr");
    SkeletonFrame f = retargeting::sources::synthetic_quest3_upper_frame(frame_idx, 30.0);
    Eigen::VectorXd q = rt->step(f);
    auto deg = [](double r) { return r * 180.0 / M_PI; };
    auto& w = f["LeftWrist"];
    printf("[%s] waist_pitch[21]=%+6.1f  L_sh_pitch[22]=%+6.1f  L_elbow[25]=%+6.1f   L_wrist_gmr=(%.2f,%.2f,%.2f)\n",
           label, deg(q[21]), deg(q[22]), deg(q[25]), w.pos.x(), w.pos.y(), w.pos.z());
  };
  // phase = 2*pi*0.45*t; sin(phase) peaks. find frames where arm_raise low/high.
  run_syn("syn_armdown", 37);  // sin(phase)~-1 -> arm_raise~0.02
  run_syn("syn_armup  ", 18);  // sin(phase)~+1 -> arm_raise~0.34
  return 0;
}
