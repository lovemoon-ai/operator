#!/usr/bin/env bash
# Generate XR-ready Dexmate Vega U robot assets.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

DEFAULT_OPERATOR_DEPS_CACHE_ROOT="$HOME/.cache/operator/deps"
OPERATOR_DEPS_CACHE_ROOT="${OPERATOR_DEPS_CACHE_ROOT:-$DEFAULT_OPERATOR_DEPS_CACHE_ROOT}"
DEPS_SRC_DIR="${DEPS_SRC_DIR:-$OPERATOR_DEPS_CACHE_ROOT/src}"
DEPS_BUILD_DIR="${DEPS_BUILD_DIR:-$OPERATOR_DEPS_CACHE_ROOT/build}"
GIT_DEPTH="${GIT_DEPTH:-1}"

DEXMATE_URDF_URL="https://github.com/dexmate-ai/dexmate-urdf.git"
DEXMATE_URDF_COMMIT="5f2c4c5fdb91e59bdff2db2cb92bc91033152ea4"
DEXMATE_URDF_DIR="$DEPS_SRC_DIR/dexmate-urdf"
DEXMATE_VEGA_U_PATH="robots/humanoid/vega_1u"
DEXMATE_VEGA_U_SUPPORT_PATHS=(
    "robots/humanoid/vega_1"
    "robots/hands/f5d6_hand"
)
DEXMATE_VEGA_U_URDF="vega_1u_f5d6.urdf"

PYTHON_BIN="${PYTHON_BIN:-python3}"
VENV_DIR="${MAKE_ROBOT_VENV_DIR:-$DEPS_BUILD_DIR/make-robot-venv}"
ROBOTS_ASSET_DIR="$REPO_ROOT/xr/assets/robots/dexmate-vega-u"
ROBOT_NAME="dexmate_vega_u"
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

fetch_dexmate_urdf() {
    mkdir -p "$DEPS_SRC_DIR"
    if [ -e "$DEXMATE_URDF_DIR" ] && ! is_git_checkout "$DEXMATE_URDF_DIR"; then
        die "$DEXMATE_URDF_DIR exists but is not a git checkout"
    fi

    if [ ! -e "$DEXMATE_URDF_DIR" ]; then
        echo "[make-robot] cloning dexmate-urdf -> $DEXMATE_URDF_DIR"
        git clone --filter=blob:none --sparse "$DEXMATE_URDF_URL" "$DEXMATE_URDF_DIR"
    fi

    git -C "$DEXMATE_URDF_DIR" remote set-url origin "$DEXMATE_URDF_URL"
    require_clean_checkout "$DEXMATE_URDF_DIR"

    local -a fetch_args
    fetch_args=()
    if [ "$GIT_DEPTH" != "0" ]; then
        fetch_args+=(--depth "$GIT_DEPTH")
    fi

    echo "[make-robot] syncing dexmate-urdf $DEXMATE_URDF_COMMIT"
    if ! git -C "$DEXMATE_URDF_DIR" fetch "${fetch_args[@]}" origin "$DEXMATE_URDF_COMMIT"; then
        git -C "$DEXMATE_URDF_DIR" fetch "${fetch_args[@]}" origin main
    fi
    git -C "$DEXMATE_URDF_DIR" sparse-checkout set \
        "$DEXMATE_VEGA_U_PATH" \
        "${DEXMATE_VEGA_U_SUPPORT_PATHS[@]}"
    git -C "$DEXMATE_URDF_DIR" -c advice.detachedHead=false checkout --detach -q "$DEXMATE_URDF_COMMIT"
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
    printf '%s\n' "$DEXMATE_URDF_URL $DEXMATE_URDF_COMMIT $DEXMATE_VEGA_U_PATH/$DEXMATE_VEGA_U_URDF" > "$MESH_OUT_DIR/.source"
}

clean_generated_meshes() {
    rm -rf \
        "$MESH_OUT_DIR" \
        "$ROBOTS_ASSET_DIR/web-viewer" \
        "$ROBOTS_ASSET_DIR/viewer_meshes" \
        "$ROBOTS_ASSET_DIR/${ROBOT_NAME}_viewer.urdf"
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
    fetch_dexmate_urdf
fi

SOURCE_DIR="$DEXMATE_URDF_DIR/$DEXMATE_VEGA_U_PATH"
SOURCE_URDF="$SOURCE_DIR/$DEXMATE_VEGA_U_URDF"
[ -s "$SOURCE_URDF" ] || die "missing source URDF: $SOURCE_URDF"

ensure_python_deps
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
    --mesh-source-label "vega_1u"
)

if [ "$SKIP_GLB" -eq 1 ]; then
    args+=(--skip-glb)
fi

"$PY" "${args[@]}"
write_mesh_source
echo "[make-robot] done"
