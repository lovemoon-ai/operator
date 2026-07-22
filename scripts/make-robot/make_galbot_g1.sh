#!/usr/bin/env bash
# Generate XR-ready Galbot One Golf ("Galbot G1") robot assets.
#
# Source: GalaxyGeneralRobotics/galbot_one_golf_description urdf/galbot_one_golf.urdf
# (visual meshes are .glb -> converted to .stl for the URDF; collision is .stl).
# Wheeled dual-arm mobile manipulator. Mirrors make_dexmate_vega_u.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

DEFAULT_OPERATOR_DEPS_CACHE_ROOT="$HOME/.cache/operator/deps"
OPERATOR_DEPS_CACHE_ROOT="${OPERATOR_DEPS_CACHE_ROOT:-$DEFAULT_OPERATOR_DEPS_CACHE_ROOT}"
DEPS_SRC_DIR="${DEPS_SRC_DIR:-$OPERATOR_DEPS_CACHE_ROOT/src}"
DEPS_BUILD_DIR="${DEPS_BUILD_DIR:-$OPERATOR_DEPS_CACHE_ROOT/build}"
GIT_DEPTH="${GIT_DEPTH:-1}"

GALBOT_URL="https://github.com/GalaxyGeneralRobotics/galbot_one_golf_description.git"
GALBOT_COMMIT="4047d57816dd53ef9f9df923b57643826df80b7d"
GALBOT_DIR="$DEPS_SRC_DIR/galbot_one_golf_description"
# The URDF lives in urdf/ and references meshes as "meshes/..." which resolve
# through the committed urdf/meshes -> ../meshes link; meshes/ holds the trees.
GALBOT_SPARSE_PATHS=(urdf meshes mjcf)

PYTHON_BIN="${PYTHON_BIN:-python3}"
VENV_DIR="${MAKE_ROBOT_VENV_DIR:-$DEPS_BUILD_DIR/make-robot-venv}"
ROBOTS_ASSET_DIR="$REPO_ROOT/xr/assets/robots/galbot-g1"
ROBOT_NAME="galbot_g1"
SOURCE_URDF_NAME="galbot_one_golf.urdf"
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
    dirty="$(git -C "$dir" status --porcelain --untracked-files=no 2>/dev/null || true)"
    if [ -n "$dirty" ]; then
        die "$dir has tracked local changes; refusing to overwrite dependency cache checkout"
    fi
}

fetch_galbot() {
    mkdir -p "$DEPS_SRC_DIR"
    if [ -e "$GALBOT_DIR" ] && ! is_git_checkout "$GALBOT_DIR"; then
        die "$GALBOT_DIR exists but is not a git checkout"
    fi

    if [ ! -e "$GALBOT_DIR" ]; then
        echo "[make-robot] cloning galbot_one_golf_description -> $GALBOT_DIR"
        git clone --filter=blob:none --sparse "$GALBOT_URL" "$GALBOT_DIR"
    fi

    git -C "$GALBOT_DIR" remote set-url origin "$GALBOT_URL"
    require_clean_checkout "$GALBOT_DIR"

    local -a fetch_args
    fetch_args=()
    if [ "$GIT_DEPTH" != "0" ]; then
        fetch_args+=(--depth "$GIT_DEPTH")
    fi

    echo "[make-robot] syncing galbot_one_golf_description $GALBOT_COMMIT"
    if ! git -C "$GALBOT_DIR" fetch "${fetch_args[@]}" origin "$GALBOT_COMMIT"; then
        git -C "$GALBOT_DIR" fetch "${fetch_args[@]}" origin main
    fi
    git -C "$GALBOT_DIR" sparse-checkout set "${GALBOT_SPARSE_PATHS[@]}"
    git -C "$GALBOT_DIR" -c advice.detachedHead=false checkout --detach -q "$GALBOT_COMMIT"
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

write_mesh_source() {
    mkdir -p "$MESH_OUT_DIR"
    printf '%s\n' "$GALBOT_URL $GALBOT_COMMIT urdf/$SOURCE_URDF_NAME" > "$MESH_OUT_DIR/.source"
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
    fetch_galbot
fi

SOURCE_DIR="$GALBOT_DIR/urdf"
SOURCE_URDF="$SOURCE_DIR/$SOURCE_URDF_NAME"
[ -s "$SOURCE_URDF" ] || die "missing source URDF: $SOURCE_URDF"

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
    --source-urdf "$SOURCE_URDF"
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
write_mesh_source
echo "[make-robot] done"
