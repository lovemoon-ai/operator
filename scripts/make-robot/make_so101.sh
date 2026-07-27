#!/usr/bin/env bash
# Generate XR-ready SO-101 (SO-ARM101 follower) robot assets.
#
# Source: TheRobotStudio/SO-ARM100 Simulation/SO101/so101_new_calib.urdf with
# its colocated STL meshes. Mirrors make_unitree_g1.sh.
#
# urdf_to_godot_assets.py always writes an MJCF proxy, but SO-101 already ships
# a curated one: assets/mujoco/so101_kinematic.xml, the mesh-free model the
# Inside Robot profile simulates and the IK solver is calibrated against. The
# proxy would be a second, unused model in every APK, so it is written to the
# dependency cache instead of into the shipped assets.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

DEFAULT_OPERATOR_DEPS_CACHE_ROOT="$HOME/.cache/operator/deps"
OPERATOR_DEPS_CACHE_ROOT="${OPERATOR_DEPS_CACHE_ROOT:-$DEFAULT_OPERATOR_DEPS_CACHE_ROOT}"
DEPS_SRC_DIR="${DEPS_SRC_DIR:-$OPERATOR_DEPS_CACHE_ROOT/src}"
DEPS_BUILD_DIR="${DEPS_BUILD_DIR:-$OPERATOR_DEPS_CACHE_ROOT/build}"
GIT_DEPTH="${GIT_DEPTH:-1}"

SO_ARM_URL="https://github.com/TheRobotStudio/SO-ARM100.git"
SO_ARM_COMMIT="fda892cba81032c46c40976a48c9ceadbf40a9ca"
SO_ARM_PATH="Simulation/SO101"
SO_ARM_DIR="$DEPS_SRC_DIR/SO-ARM100"

PYTHON_BIN="${PYTHON_BIN:-python3}"
VENV_DIR="${MAKE_ROBOT_VENV_DIR:-$DEPS_BUILD_DIR/make-robot-venv}"
ROBOTS_ASSET_DIR="$REPO_ROOT/xr/assets/robots/so101"
ROBOT_NAME="so101"
SOURCE_URDF_NAME="so101_new_calib.urdf"
URDF_OUT="$ROBOTS_ASSET_DIR/$ROBOT_NAME.urdf"
GLB_OUT="$ROBOTS_ASSET_DIR/$ROBOT_NAME.glb"
MJCF_OUT="${SO101_MJCF_OUT:-$DEPS_BUILD_DIR/make-robot/so101_visual.xml}"
MESH_OUT_DIR="$ROBOTS_ASSET_DIR/meshes"

SKIP_SYNC=0
SKIP_GLB=0

usage() {
    cat <<EOF
Usage: $0 [--no-sync] [--skip-glb]

Environment:
  OPERATOR_DEPS_CACHE_ROOT  Global dependency cache root
                            (default: $DEFAULT_OPERATOR_DEPS_CACHE_ROOT)
  GIT_DEPTH                 Fetch depth for pinned source refs (default: 1,
                            use 0 for full history if your Git server rejects
                            fetching the pinned commit by SHA)
  PYTHON_BIN                Python interpreter for the generator venv
                            (default: python3)
  MAKE_ROBOT_VENV_DIR       Python venv path
                            (default: \$OPERATOR_DEPS_CACHE_ROOT/build/make-robot-venv)
EOF
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

is_git_checkout() {
    local dir="$1"
    [ -d "$dir/.git" ] || return 1
    git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1
}

require_clean_checkout() {
    local dir="$1"
    local dirty
    dirty="$(git -C "$dir" status --porcelain 2>/dev/null || true)"
    if [ -n "$dirty" ]; then
        die "$dir has local changes; refusing to overwrite dependency cache checkout"
    fi
}

fetch_so_arm() {
    mkdir -p "$DEPS_SRC_DIR"
    if [ -e "$SO_ARM_DIR" ] && ! is_git_checkout "$SO_ARM_DIR"; then
        die "$SO_ARM_DIR exists but is not a git checkout"
    fi

    if [ ! -e "$SO_ARM_DIR" ]; then
        echo "[make-robot] cloning SO-ARM100 -> $SO_ARM_DIR"
        git clone --filter=blob:none --sparse "$SO_ARM_URL" "$SO_ARM_DIR"
    fi

    git -C "$SO_ARM_DIR" remote set-url origin "$SO_ARM_URL"
    require_clean_checkout "$SO_ARM_DIR"

    local -a fetch_args
    fetch_args=()
    if [ "$GIT_DEPTH" != "0" ]; then
        fetch_args+=(--depth "$GIT_DEPTH")
    fi

    echo "[make-robot] syncing SO-ARM100 $SO_ARM_COMMIT"
    if ! git -C "$SO_ARM_DIR" fetch "${fetch_args[@]}" origin "$SO_ARM_COMMIT"; then
        git -C "$SO_ARM_DIR" fetch "${fetch_args[@]}" origin main
    fi
    git -C "$SO_ARM_DIR" sparse-checkout set "$SO_ARM_PATH"
    git -C "$SO_ARM_DIR" -c advice.detachedHead=false checkout --detach -q "$SO_ARM_COMMIT"
}

ensure_python_core_deps() {
    mkdir -p "$DEPS_BUILD_DIR"
    if [ ! -x "$VENV_DIR/bin/python" ]; then
        echo "[make-robot] creating Python venv -> $VENV_DIR"
        "$PYTHON_BIN" -m venv "$VENV_DIR"
    fi

    if "$VENV_DIR/bin/python" - <<'PY' >/dev/null 2>&1
import numpy
PY
    then
        return
    fi

    echo "[make-robot] installing core Python dependencies"
    "$VENV_DIR/bin/python" -m pip install --upgrade pip
    "$VENV_DIR/bin/python" -m pip install "numpy<2"
}

ensure_python_deps() {
    ensure_python_core_deps

    if "$VENV_DIR/bin/python" - <<'PY' >/dev/null 2>&1
import collada
import trimesh
PY
    then
        return
    fi

    echo "[make-robot] installing mesh conversion Python dependencies"
    "$VENV_DIR/bin/python" -m pip install trimesh pycollada
}

record_mesh_source() {
    # urdf_to_godot_assets.py already copies every referenced mesh into the
    # exact `meshes/assets/...` path written to the generated URDF. Copying the
    # source directory again would duplicate all STLs at `meshes/` and also ship
    # unreferenced CAD `.part` files.
    printf '%s\n' "$SO_ARM_URL $SO_ARM_COMMIT $SO_ARM_PATH/assets" > "$MESH_OUT_DIR/.source"
}

clean_generated_meshes() {
    rm -rf "$MESH_OUT_DIR"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --no-sync)
            SKIP_SYNC=1
            ;;
        --skip-glb)
            SKIP_GLB=1
            ;;
        -h|--help|help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            die "unknown argument: $1"
            ;;
    esac
    shift
done

if [ "$SKIP_SYNC" -eq 0 ]; then
    fetch_so_arm
fi

SOURCE_DIR="$SO_ARM_DIR/$SO_ARM_PATH"
[ -s "$SOURCE_DIR/$SOURCE_URDF_NAME" ] || die "missing source URDF: $SOURCE_DIR/$SOURCE_URDF_NAME"
mkdir -p "$(dirname "$MJCF_OUT")"

if [ "$SKIP_GLB" -eq 0 ]; then
    ensure_python_deps
else
    ensure_python_core_deps
fi
PY="$VENV_DIR/bin/python"
clean_generated_meshes

args=(
    "$SCRIPT_DIR/urdf_to_godot_assets.py"
    --source-dir "$SOURCE_DIR"
    --source-urdf "$SOURCE_DIR/$SOURCE_URDF_NAME"
    --robot-name "$ROBOT_NAME"
    --urdf-out "$URDF_OUT"
    --mjcf-out "$MJCF_OUT"
    --glb-out "$GLB_OUT"
    --mesh-copy-root "$MESH_OUT_DIR"
    --mesh-reference-prefix "meshes"
    --mesh-source-label ""
)

if [ "$SKIP_GLB" -eq 1 ]; then
    args+=(--skip-glb)
fi

"$PY" "${args[@]}"
record_mesh_source
echo "[make-robot] done"
