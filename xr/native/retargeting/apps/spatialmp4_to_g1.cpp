// spatialmp4_to_g1 — C++ port of GMR's scripts/spatialmp4_body_to_g1.py.
//
// Pipeline: load a SpatialMP4/Quest body-pose JSONL (raw OpenXR-space joints) ->
// convert to GMR coords + anchor/heading-align (preprocess) -> retarget to the
// Unitree G1 (upper body; legs + wrists + waist roll/pitch held at rest, only
// the arms + waist-yaw driven) -> save robot_solution.jsonl (per-frame joint_q).
// Optionally compares against a reference robot_solution.jsonl (the Python output)
// and writes the normalized GMR-space body frames.
//
// This is the offline, headless equivalent of the Godot G1 overlay's runtime
// path, so the whole chain can be validated against Python without a device.
//
// Usage:
//   spatialmp4_to_g1 <body.jsonl> --save_jsonl <out.jsonl>
//       [--robot_xml <g1_mocap_nomesh.xml>] [--ik_config <quest3_upper_to_g1.json>]
//       [--human_height 1.75] [--pelvis_height 0.88] [--no_heading_align]
//       [--normalized <gmr.jsonl>] [--compare <ref_robot_solution.jsonl>]
#include <cmath>
#include <cstdio>
#include <fstream>
#include <string>
#include <vector>

#include <nlohmann/json.hpp>

#include "retargeting/retargeter.hpp"

using json = nlohmann::json;
using retargeting::Pose;
using retargeting::SkeletonFrame;

namespace {

// 29 actuated G1 joints in qpos order (qpos[7..35]); matches the MJCF + the
// Python actuated_qpos_names_and_indices() ordering.
const std::vector<std::string> kJointNames = {
    "left_hip_pitch_joint", "left_hip_roll_joint", "left_hip_yaw_joint",
    "left_knee_joint", "left_ankle_pitch_joint", "left_ankle_roll_joint",
    "right_hip_pitch_joint", "right_hip_roll_joint", "right_hip_yaw_joint",
    "right_knee_joint", "right_ankle_pitch_joint", "right_ankle_roll_joint",
    "waist_yaw_joint", "waist_roll_joint", "waist_pitch_joint",
    "left_shoulder_pitch_joint", "left_shoulder_roll_joint", "left_shoulder_yaw_joint",
    "left_elbow_joint", "left_wrist_roll_joint", "left_wrist_pitch_joint",
    "left_wrist_yaw_joint", "right_shoulder_pitch_joint", "right_shoulder_roll_joint",
    "right_shoulder_yaw_joint", "right_elbow_joint", "right_wrist_roll_joint",
    "right_wrist_pitch_joint", "right_wrist_yaw_joint"};

// Clamp set for the spatialmp4 config: waist roll/pitch (qpos 20,21) + the 6
// wrist joints (26,27,28, 33,34,35). Legs are the locked prefix (19).
const std::vector<int> kClampQpos = {20, 21, 26, 27, 28, 33, 34, 35};

// OpenXR -> GMR position: OPENXR_TO_GMR @ (x,y,z) = (-z, -x, y).
Eigen::Vector3d openxr_to_gmr(const Eigen::Vector3d& p) {
  return Eigen::Vector3d(-p.z(), -p.x(), p.y());
}

// Hamilton product of (w,x,y,z) quaternions.
Eigen::Vector4d qmul(const Eigen::Vector4d& a, const Eigen::Vector4d& b) {
  return Eigen::Vector4d(
      a[0]*b[0] - a[1]*b[1] - a[2]*b[2] - a[3]*b[3],
      a[0]*b[1] + a[1]*b[0] + a[2]*b[3] - a[3]*b[2],
      a[0]*b[2] - a[1]*b[3] + a[2]*b[0] + a[3]*b[1],
      a[0]*b[3] + a[1]*b[2] - a[2]*b[1] + a[3]*b[0]);
}

// Quaternion (wxyz) of OPENXR_TO_GMR (R.from_matrix(...).as_quat(scalar_first)).
const Eigen::Vector4d kOpenxrToGmrQuat(0.5, 0.5, -0.5, -0.5);

struct Joint {
  std::string name;
  Eigen::Vector3d pos;   // OpenXR position
  Eigen::Vector4d quat;  // OpenXR orientation (w,x,y,z)
};

struct RawFrame {
  double timestamp_s = 0.0;
  std::vector<Joint> joints;
};

std::vector<RawFrame> load_body_jsonl(const std::string& path) {
  std::vector<RawFrame> frames;
  std::ifstream in(path);
  std::string line;
  int idx = 0;
  while (std::getline(in, line)) {
    if (line.empty() || line[0] == '#') continue;
    json r = json::parse(line);
    RawFrame f;
    f.timestamp_s = r.value("timestamp_s", static_cast<double>(idx) / 30.0);
    for (auto& [name, rec] : r["joints"].items()) {
      auto pos = rec["position"];
      auto rot = rec["rotation"];  // xyzw (adapter quat_order)
      Joint j;
      j.name = name;
      j.pos = Eigen::Vector3d(pos[0].get<double>(), pos[1].get<double>(), pos[2].get<double>());
      // xyzw -> wxyz
      j.quat = Eigen::Vector4d(rot[3].get<double>(), rot[0].get<double>(),
                               rot[1].get<double>(), rot[2].get<double>());
      f.joints.push_back(std::move(j));
    }
    frames.push_back(std::move(f));
    ++idx;
  }
  return frames;
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 2) {
    fprintf(stderr, "usage: %s <body.jsonl> --save_jsonl <out> [opts]\n", argv[0]);
    return 2;
  }
  std::string body_path = argv[1];
  std::string save_path, normalized_path, compare_path;
  std::string robot_xml = "data/robot/unitree_g1/g1_mocap_29dof_nomesh.xml";
  std::string ik_config = "data/ik_configs/quest3_upper_to_g1.json";
  double human_height = 1.75, pelvis_height = 0.88;
  bool align_heading = true;
  for (int i = 2; i < argc; ++i) {
    std::string a = argv[i];
    auto next = [&]() { return std::string(argv[++i]); };
    if (a == "--save_jsonl") save_path = next();
    else if (a == "--normalized") normalized_path = next();
    else if (a == "--compare") compare_path = next();
    else if (a == "--robot_xml") robot_xml = next();
    else if (a == "--ik_config") ik_config = next();
    else if (a == "--human_height") human_height = std::stod(next());
    else if (a == "--pelvis_height") pelvis_height = std::stod(next());
    else if (a == "--no_heading_align") align_heading = false;
  }

  std::vector<RawFrame> raw = load_body_jsonl(body_path);
  if (raw.empty()) { fprintf(stderr, "no frames in %s\n", body_path.c_str()); return 2; }

  // --- preprocess: OpenXR->GMR + heading-align + anchor (anchor_and_align_frame)
  auto get = [](const RawFrame& f, const std::string& n, Eigen::Vector3d& out) {
    for (auto& j : f.joints) if (j.name == n) { out = j.pos; return true; }
    return false;
  };
  double heading_yaw = 0.0;
  if (align_heading) {
    Eigen::Vector3d ls, rs;
    if (get(raw[0], "LeftShoulder", ls) && get(raw[0], "RightShoulder", rs)) {
      Eigen::Vector3d side = openxr_to_gmr(ls) - openxr_to_gmr(rs);
      side.z() = 0.0;
      if (side.norm() > 1e-5)
        heading_yaw = M_PI / 2.0 - std::atan2(side.y(), side.x());
    }
  }
  const double cz = std::cos(heading_yaw), sz = std::sin(heading_yaw);
  // Combined orientation transform applied to each joint quat: Rz(heading) * OPENXR_TO_GMR.
  const Eigen::Vector4d rz_quat(std::cos(heading_yaw / 2.0), 0, 0, std::sin(heading_yaw / 2.0));
  const Eigen::Vector4d combined_quat = qmul(rz_quat, kOpenxrToGmrQuat);

  // Anchor a frame: GMR positions relative to hips (heading-rotated, hips pinned
  // to pelvis_height) + the converted+anchored orientation. The orientation is
  // needed: the SE3 IK error couples the position tangent to the target rotation.
  auto anchor = [&](const RawFrame& f, std::vector<Joint>& out) {
    Eigen::Vector3d hips_xr;
    if (!get(f, "Hips", hips_xr)) return false;
    Eigen::Vector3d root = openxr_to_gmr(hips_xr);
    for (auto& jin : f.joints) {
      Eigen::Vector3d r = openxr_to_gmr(jin.pos) - root;
      Joint jo;
      jo.name = jin.name;
      jo.pos = Eigen::Vector3d(r.x() * cz - r.y() * sz, r.x() * sz + r.y() * cz,
                               r.z() + pelvis_height);
      jo.quat = qmul(combined_quat, jin.quat);  // Rz(heading) * (OPENXR_TO_GMR * q)
      out.push_back(std::move(jo));
    }
    return true;
  };

  // --- retargeter (legs locked-prefix 19; clamp waist roll/pitch + wrists) ----
  retargeting::RetargetConfig cfg;
  cfg.robot_xml = robot_xml;
  cfg.ik_config_json = ik_config;
  cfg.human_height = human_height;
  cfg.backend = retargeting::KinematicsBackendKind::Mujoco;
  auto rt = retargeting::UpperBodyRetargeter::create(cfg, 19, "gmr", false, kClampQpos);

  printf("loaded %zu frames; heading_yaw=%.2f deg; pelvis_height=%.2f\n",
         raw.size(), heading_yaw * 180.0 / M_PI, pelvis_height);

  std::ofstream out(save_path);
  std::ofstream norm;
  if (!normalized_path.empty()) norm.open(normalized_path);

  // optional reference for comparison
  std::vector<std::vector<double>> ref;
  if (!compare_path.empty()) {
    std::ifstream rin(compare_path);
    std::string rl;
    while (std::getline(rin, rl)) {
      if (rl.empty()) continue;
      ref.push_back(json::parse(rl)["joint_q"].get<std::vector<double>>());
    }
  }
  double max_diff = 0.0; int worst_frame = -1; std::string worst_joint;

  for (size_t fi = 0; fi < raw.size(); ++fi) {
    std::vector<Joint> aligned;
    if (!anchor(raw[fi], aligned)) continue;
    SkeletonFrame sf;
    for (auto& j : aligned) {
      Pose p; p.pos = j.pos; p.quat = j.quat;
      sf[j.name] = p;
    }
    Eigen::VectorXd q = rt->step(sf);  // length 36

    // robot_solution.jsonl record
    json rec;
    rec["timestamp_ns"] = static_cast<long long>(std::llround(raw[fi].timestamp_s * 1e9));
    rec["joint_names"] = kJointNames;
    std::vector<double> jq(29);
    for (int i = 0; i < 29; ++i) jq[i] = q[7 + i];
    rec["joint_q"] = jq;
    out << rec.dump() << "\n";

    if (norm.is_open()) {
      json nr;
      nr["timestamp_s"] = raw[fi].timestamp_s;
      nr["coordinate_space"] = "gmr";
      nr["quat_order"] = "wxyz";
      json js;
      for (auto& j : aligned)
        js[j.name] = {{"position", {j.pos.x(), j.pos.y(), j.pos.z()}},
                      {"rotation", {j.quat[0], j.quat[1], j.quat[2], j.quat[3]}}};
      nr["joints"] = js;
      norm << nr.dump() << "\n";
    }

    if (fi < ref.size()) {
      for (int i = 0; i < 29 && i < (int)ref[fi].size(); ++i) {
        double d = std::fabs(jq[i] - ref[fi][i]);
        if (d > max_diff) { max_diff = d; worst_frame = (int)fi; worst_joint = kJointNames[i]; }
      }
    }
  }
  out.close();
  printf("saved robot_solution -> %s\n", save_path.c_str());
  if (!normalized_path.empty()) printf("saved normalized gmr frames -> %s\n", normalized_path.c_str());
  if (!compare_path.empty()) {
    printf("compare vs %s: max_abs_diff=%.4e rad (worst frame %d joint %s) -> %s\n",
           compare_path.c_str(), max_diff, worst_frame, worst_joint.c_str(),
           max_diff < 1e-3 ? "ALIGNED" : "MISMATCH");
  }
  return 0;
}
