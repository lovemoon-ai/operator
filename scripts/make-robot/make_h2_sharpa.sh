#!/usr/bin/env bash
# Generate XR-ready Unitree H2 + Sharpa hand robot assets.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

DEFAULT_OPERATOR_DEPS_CACHE_ROOT="$HOME/.cache/operator/deps"
OPERATOR_DEPS_CACHE_ROOT="${OPERATOR_DEPS_CACHE_ROOT:-$DEFAULT_OPERATOR_DEPS_CACHE_ROOT}"
DEPS_SRC_DIR="${DEPS_SRC_DIR:-$OPERATOR_DEPS_CACHE_ROOT/src}"
DEPS_BUILD_DIR="${DEPS_BUILD_DIR:-$OPERATOR_DEPS_CACHE_ROOT/build}"
GIT_DEPTH="${GIT_DEPTH:-1}"

UNITREE_ROS_URL="https://github.com/unitreerobotics/unitree_ros.git"
UNITREE_ROS_COMMIT="cdf67e6eb4c98d73202f29a25e3d098e2aa3b247"
UNITREE_ROS_PATH="robots/h2_plus"
UNITREE_ROS_DIR="$DEPS_SRC_DIR/unitree_ros"

PYTHON_BIN="${PYTHON_BIN:-python3}"
VENV_DIR="${MAKE_ROBOT_VENV_DIR:-$DEPS_BUILD_DIR/make-robot-venv}"
ROBOTS_ASSET_DIR="$REPO_ROOT/xr/assets/robots/h2-plus"
ROBOT_NAME="h2_with_sharpa"
URDF_OUT="$ROBOTS_ASSET_DIR/$ROBOT_NAME.urdf"
GLB_OUT="$ROBOTS_ASSET_DIR/$ROBOT_NAME.glb"
MJCF_OUT="$REPO_ROOT/xr/assets/mujoco/$ROBOT_NAME.xml"
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

fetch_unitree() {
    mkdir -p "$DEPS_SRC_DIR"
    if [ -e "$UNITREE_ROS_DIR" ] && ! is_git_checkout "$UNITREE_ROS_DIR"; then
        die "$UNITREE_ROS_DIR exists but is not a git checkout"
    fi

    if [ ! -e "$UNITREE_ROS_DIR" ]; then
        echo "[make-robot] cloning unitree_ros -> $UNITREE_ROS_DIR"
        git clone --filter=blob:none --sparse "$UNITREE_ROS_URL" "$UNITREE_ROS_DIR"
    fi

    git -C "$UNITREE_ROS_DIR" remote set-url origin "$UNITREE_ROS_URL"
    require_clean_checkout "$UNITREE_ROS_DIR"

    local -a fetch_args
    fetch_args=()
    if [ "$GIT_DEPTH" != "0" ]; then
        fetch_args+=(--depth "$GIT_DEPTH")
    fi

    echo "[make-robot] syncing unitree_ros $UNITREE_ROS_COMMIT"
    if ! git -C "$UNITREE_ROS_DIR" fetch "${fetch_args[@]}" origin "$UNITREE_ROS_COMMIT"; then
        git -C "$UNITREE_ROS_DIR" fetch "${fetch_args[@]}" origin master
    fi
    git -C "$UNITREE_ROS_DIR" sparse-checkout set "$UNITREE_ROS_PATH"
    git -C "$UNITREE_ROS_DIR" -c advice.detachedHead=false checkout --detach -q "$UNITREE_ROS_COMMIT"
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

sync_meshes() {
    local source_mesh_dir="$SOURCE_DIR/meshes"
    [ -d "$source_mesh_dir" ] || die "missing source mesh directory: $source_mesh_dir"

    mkdir -p "$MESH_OUT_DIR"
    echo "[make-robot] syncing meshes -> ${MESH_OUT_DIR#$REPO_ROOT/}"
    if command -v rsync >/dev/null 2>&1; then
        rsync -a "$source_mesh_dir/" "$MESH_OUT_DIR/"
    else
        cp -R "$source_mesh_dir/." "$MESH_OUT_DIR/"
    fi
    printf '%s\n' "$UNITREE_ROS_URL $UNITREE_ROS_COMMIT $UNITREE_ROS_PATH/meshes" > "$MESH_OUT_DIR/.source"
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
    fetch_unitree
fi

SOURCE_DIR="$UNITREE_ROS_DIR/$UNITREE_ROS_PATH"
[ -s "$SOURCE_DIR/H2_Plus.urdf" ] || die "missing source URDF: $SOURCE_DIR/H2_Plus.urdf"

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
sync_meshes
echo "[make-robot] done"
