#!/usr/bin/env bash
# Desktop build + numerical validation of the retargeting toolkit.
#
# Builds the library + upper-body demo, runs the demo against the synthetic
# Quest3 upper-body source using the self-contained test data under data/, and
# verifies the output matches the checked-in reference (which is aligned with
# the original Python mink+MuJoCo pipeline to ~1e-13).
#
# Usage: build_desktop.sh [n_frames] [fps] [human_height]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
N="${1:-200}"
FPS="${2:-30}"
H="${3:-1.75}"

cd "$SCRIPT_DIR"
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j

REF="data/reference/qpos_upper_body_g1_f${N}_fps${FPS%.*}_h${H}.csv"
MJCF="data/robot/unitree_g1/g1_mocap_29dof.xml"
# The meshless MJCF carries the full kinematic tree (no 52MB STL meshes); MuJoCo
# loads it natively, which is exactly the on-device Android path.
MJCF_NOMESH="data/robot/unitree_g1/g1_mocap_29dof_nomesh.xml"

for BK in pinocchio mujoco; do
  XML="$MJCF"
  # MuJoCo's mj_loadXML needs the meshes for the full MJCF; use the meshless one.
  [[ "$BK" == "mujoco" ]] && XML="$MJCF_NOMESH"
  echo "[run] backend=$BK frames=$N fps=$FPS height=$H xml=$(basename "$XML")"
  ARGS=(--backend "$BK" --frames "$N" --fps "$FPS" --human_height "$H"
        --robot_xml "$XML" --ik_config data/ik_configs/quest3_upper_to_g1.json
        --out "build/qpos_${BK}.csv")
  [[ -f "$REF" ]] && ARGS+=(--verify "$REF")
  ./build/upper_body_demo "${ARGS[@]}"
done
echo "done."
