#!/usr/bin/env bash
# Fetch SO-101 mesh STL files from the upstream mujoco_menagerie repo.
#
# The 19 STL meshes (~17 MB) live in
# https://github.com/google-deepmind/mujoco_menagerie/tree/main/robotstudio_so101/assets
# (Apache-2.0). We keep them out of this repo to avoid bloat and pull
# them on demand into assets/so101/assets/.
#
# Pinned to a specific commit so re-runs are reproducible. Bump
# UPSTREAM_COMMIT below when you want to track upstream changes.
#
# Usage:
#     ./prepare.sh              # fetch missing STLs (idempotent / fast no-op)
#     ./prepare.sh --force      # re-fetch and overwrite even if present
#     ./prepare.sh --check      # exit 0 if all STLs present, else 1 (no network)

set -euo pipefail

UPSTREAM_REPO="https://github.com/google-deepmind/mujoco_menagerie.git"
UPSTREAM_COMMIT="b846dd12bc459d776cccb3dee0b1d02acbf7a9c7"   # main @ 2026-06-02
UPSTREAM_SUBDIR="robotstudio_so101/assets"

# Resolve script dir → destination is sibling of this script.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$SCRIPT_DIR/assets/so101/assets"

STLS=(
  base_motor_holder_so101_v1.stl
  base_so101_v2.stl
  motor_holder_so101_base_v1.stl
  motor_holder_so101_wrist_v1.stl
  moving_jaw_so101_gripper_part0_v1.stl
  moving_jaw_so101_gripper_part1_v1.stl
  moving_jaw_so101_gripper_v1.stl
  moving_jaw_so101_v1.stl
  rotation_pitch_so101_v1.stl
  sts3215_03a_no_horn_v1.stl
  sts3215_03a_v1.stl
  under_arm_so101_v1.stl
  upper_arm_so101_v1.stl
  waveshare_mounting_plate_so101_v2.stl
  wrist_roll_follower_so101_camera_mount.stl
  wrist_roll_follower_so101_gripper_part0_v1.stl
  wrist_roll_follower_so101_gripper_v1.stl
  wrist_roll_follower_so101_v1.stl
  wrist_roll_pitch_so101_v2.stl
)

mode="fetch"
case "${1:-}" in
  --force) mode="force" ;;
  --check) mode="check" ;;
  "") ;;
  *) echo "Unknown arg: $1" >&2; echo "Usage: $0 [--force|--check]" >&2; exit 2 ;;
esac

mkdir -p "$DEST"

# Count what's missing.
missing=()
for s in "${STLS[@]}"; do
  [[ -f "$DEST/$s" ]] || missing+=("$s")
done

if [[ "$mode" == "check" ]]; then
  if (( ${#missing[@]} == 0 )); then
    echo "[prepare-assets] ✓ all ${#STLS[@]} STL files present"
    exit 0
  fi
  echo "[prepare-assets] ✗ ${#missing[@]}/${#STLS[@]} STL files missing — run ./prepare.sh" >&2
  exit 1
fi

if [[ "$mode" == "fetch" ]] && (( ${#missing[@]} == 0 )); then
  echo "[prepare-assets] all ${#STLS[@]} STL files already present — nothing to do (--force to re-fetch)"
  exit 0
fi

if [[ "$mode" == "force" ]]; then
  echo "[prepare-assets] --force: re-fetching all ${#STLS[@]} STL files"
else
  echo "[prepare-assets] ${#missing[@]}/${#STLS[@]} STL files missing — fetching from upstream"
fi
echo "[prepare-assets] source: $UPSTREAM_REPO @ ${UPSTREAM_COMMIT:0:10}"

# Sparse-checkout into a temp dir. Atomic: either everything copies
# over or DEST is untouched.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

(
  cd "$tmp"
  git init -q
  git remote add origin "$UPSTREAM_REPO"
  git config core.sparseCheckout true
  mkdir -p .git/info
  echo "$UPSTREAM_SUBDIR/*.stl" > .git/info/sparse-checkout
  # --filter=blob:none keeps the initial fetch tiny; sparse-checkout
  # then only pulls the blobs we actually need.
  git fetch -q --depth=1 --filter=blob:none origin "$UPSTREAM_COMMIT"
  git checkout -q FETCH_HEAD -- "$UPSTREAM_SUBDIR"
)

# Verify all expected STLs landed; bail noisily if upstream layout changed.
for s in "${STLS[@]}"; do
  if [[ ! -f "$tmp/$UPSTREAM_SUBDIR/$s" ]]; then
    echo "ERROR: upstream missing $UPSTREAM_SUBDIR/$s at commit ${UPSTREAM_COMMIT:0:10}" >&2
    echo "       The pinned commit may be outdated — check UPSTREAM_COMMIT in this script." >&2
    exit 1
  fi
done

# Copy into place.
for s in "${STLS[@]}"; do
  cp "$tmp/$UPSTREAM_SUBDIR/$s" "$DEST/$s"
done

echo "[prepare-assets] ✓ ${#STLS[@]} STL files written to $DEST"
