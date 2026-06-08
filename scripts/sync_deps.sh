#!/usr/bin/env bash
# Sync external source dependencies into the local hidden .deps directory.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEFAULT_OPERATOR_DEPS_CACHE_ROOT="$REPO_ROOT/.deps"
OPERATOR_DEPS_CACHE_ROOT="${OPERATOR_DEPS_CACHE_ROOT:-$DEFAULT_OPERATOR_DEPS_CACHE_ROOT}"
DEPS_SRC_DIR="${DEPS_SRC_DIR:-$OPERATOR_DEPS_CACHE_ROOT/src}"
DEPS_BUILD_DIR="${DEPS_BUILD_DIR:-$OPERATOR_DEPS_CACHE_ROOT/build}"
GIT_DEPTH="${GIT_DEPTH:-1}"

GODOT_XR_TOOLS_COMMIT="5570cc7560eece651eb6eeea47311c96535ec712"
GODOT_CPP_COMMIT="60b5a4196de8442b43b32ba68ebe1e79cfcb762f"
FFMPEG_TAG="n8.1.1"
PINOCCHIO_ANDROID_COMMIT="74b44aff2fd00f66adb15d348f401b1579cc4126"
SPATIALMP4_COMMIT="7b2549eb6b2b0b281510b375d7e3f8967b438f49"

usage() {
    cat <<EOF
Usage: $0 [all|web|godot-xr-tools|godot-cpp|ffmpeg|pinocchio-android|spatialmp4]...

Environment:
  OPERATOR_DEPS_CACHE_ROOT  Dependency root (default: $DEFAULT_OPERATOR_DEPS_CACHE_ROOT)
                            Point at e.g. ~/.cache/operator/deps to share the
                            godot-cpp / ffmpeg / SpatialMP4 source + build cache across
                            branches and worktrees.
  GIT_DEPTH                 Fetch depth for pinned refs (default: 1, use 0 for full)
EOF
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

acquire_lock() {
    local lock_dir="$OPERATOR_DEPS_CACHE_ROOT/.sync.lock"
    local lock_pid=""
    local announced=0

    mkdir -p "$OPERATOR_DEPS_CACHE_ROOT"
    while ! mkdir "$lock_dir" 2>/dev/null; do
        if [ -f "$lock_dir/pid" ]; then
            lock_pid="$(cat "$lock_dir/pid" 2>/dev/null || true)"
            if [ -n "$lock_pid" ] && ! kill -0 "$lock_pid" 2>/dev/null; then
                rm -rf "$lock_dir"
                continue
            fi
        fi
        if [ "$announced" -eq 0 ]; then
            echo "[deps] waiting for another dependency sync to finish"
            announced=1
        fi
        sleep 1
    done

    echo "$$" > "$lock_dir/pid"
    trap 'rm -rf "$OPERATOR_DEPS_CACHE_ROOT/.sync.lock"' EXIT
}

is_git_checkout() {
    local dir="$1"
    local top dir_abs top_abs

    [ -d "$dir" ] || return 1
    top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || true)"
    [ -n "$top" ] || return 1
    dir_abs="$(cd "$dir" && pwd -P)"
    top_abs="$(cd "$top" && pwd -P)"
    [ "$dir_abs" = "$top_abs" ]
}

clone_repo() {
    local name="$1"
    local url="$2"
    local clone_ref="$3"
    local dest="$4"
    local tmp="${dest}.$$.tmp"
    local -a args

    rm -rf "$tmp"
    mkdir -p "$(dirname "$dest")"

    args=(--filter=blob:none --no-checkout)
    if [ "$GIT_DEPTH" != "0" ]; then
        args+=(--depth "$GIT_DEPTH")
    fi
    if [ -n "$clone_ref" ]; then
        args+=(--branch "$clone_ref")
    fi
    if is_git_checkout "$REPO_ROOT/third_party/$name"; then
        args+=(--reference-if-able "$REPO_ROOT/third_party/$name")
    elif [ -d "$REPO_ROOT/.git/modules/third_party/$name" ]; then
        args+=(--reference-if-able "$REPO_ROOT/.git/modules/third_party/$name")
    fi

    echo "[deps] cloning $name -> ${dest#$REPO_ROOT/}"
    git clone "${args[@]}" "$url" "$tmp"
    rm -rf "$dest"
    mv "$tmp" "$dest"
}

fetch_ref() {
    local dir="$1"
    local fetch_ref="$2"
    local local_ref="$3"
    local -a args

    args=()
    if [ "$GIT_DEPTH" != "0" ]; then
        args+=(--depth "$GIT_DEPTH")
    fi
    args+=(origin "$fetch_ref:$local_ref")

    git -C "$dir" fetch "${args[@]}"
}

sync_repo() {
    local name="$1"
    local url="$2"
    local fetch_ref="$3"
    local local_ref="$4"
    local checkout_ref="$5"
    local clone_ref="$6"
    local dest="$DEPS_SRC_DIR/$name"
    local current=""
    local wanted=""

    if [ -e "$dest" ] && ! is_git_checkout "$dest"; then
        die "$dest exists but is not a standalone git checkout"
    fi

    if [ ! -e "$dest" ]; then
        clone_repo "$name" "$url" "$clone_ref" "$dest"
    fi

    git -C "$dest" remote set-url origin "$url"

    if wanted="$(git -C "$dest" rev-parse --verify --quiet "$checkout_ref^{commit}")"; then
        current="$(git -C "$dest" rev-parse --verify --quiet HEAD 2>/dev/null || true)"
        if [ "$current" != "$wanted" ]; then
            fetch_ref "$dest" "$fetch_ref" "$local_ref"
            wanted="$(git -C "$dest" rev-parse --verify "$checkout_ref^{commit}")"
        fi
    else
        fetch_ref "$dest" "$fetch_ref" "$local_ref"
        wanted="$(git -C "$dest" rev-parse --verify "$checkout_ref^{commit}")"
    fi

    git -C "$dest" -c advice.detachedHead=false checkout --detach -q "$wanted"
    git -C "$dest" reset --hard -q "$wanted"
    git -C "$dest" clean -fdx -q
    echo "[deps] $name ready at $wanted"
}

ensure_symlink() {
    local link="$1"
    local target="$2"

    mkdir -p "$(dirname "$link")"
    if [ -e "$link" ] && [ ! -L "$link" ]; then
        die "$link exists and is not a symlink"
    fi
    rm -f "$link"
    ln -s "$target" "$link"
}

sync_godot_xr_tools() {
    sync_repo \
        "godot-xr-tools" \
        "https://github.com/godotvr/godot-xr-tools.git" \
        "refs/heads/master" \
        "refs/remotes/origin/master" \
        "$GODOT_XR_TOOLS_COMMIT" \
        "master"

    if [ "$OPERATOR_DEPS_CACHE_ROOT" = "$DEFAULT_OPERATOR_DEPS_CACHE_ROOT" ]; then
        ensure_symlink \
            "$REPO_ROOT/xr/addons/godot-xr-tools" \
            "../../.deps/src/godot-xr-tools/addons/godot-xr-tools"
    else
        ensure_symlink \
            "$REPO_ROOT/xr/addons/godot-xr-tools" \
            "$DEPS_SRC_DIR/godot-xr-tools/addons/godot-xr-tools"
    fi
}

sync_godot_cpp() {
    sync_repo \
        "godot-cpp" \
        "https://github.com/godotengine/godot-cpp.git" \
        "refs/heads/4.5" \
        "refs/remotes/origin/4.5" \
        "$GODOT_CPP_COMMIT" \
        "4.5"

    if [ "$OPERATOR_DEPS_CACHE_ROOT" = "$DEFAULT_OPERATOR_DEPS_CACHE_ROOT" ]; then
        ensure_symlink \
            "$REPO_ROOT/xr/native/ahb_decoder/godot-cpp" \
            "../../../.deps/src/godot-cpp"
    else
        ensure_symlink \
            "$REPO_ROOT/xr/native/ahb_decoder/godot-cpp" \
            "$DEPS_SRC_DIR/godot-cpp"
    fi
}

sync_ffmpeg() {
    sync_repo \
        "ffmpeg" \
        "https://github.com/FFmpeg/FFmpeg.git" \
        "refs/tags/$FFMPEG_TAG" \
        "refs/tags/$FFMPEG_TAG" \
        "$FFMPEG_TAG" \
        ""
}

sync_pinocchio_android() {
    # Android build wrapper for stack-of-tasks/pinocchio. The pristine
    # checkout lives in .deps/src/pinocchio-android. The actual build is
    # driven by xr/makefiles/Makefile.pinocchio against a per-ABI git
    # worktree under .deps/build/pinocchio-android/<abi>/src so that
    # `git clean -fdx` (run by sync_repo) never wipes build artifacts.
    sync_repo \
        "pinocchio-android" \
        "https://github.com/DuinoDu/pinocchio-android.git" \
        "refs/heads/main" \
        "refs/remotes/origin/main" \
        "$PINOCCHIO_ANDROID_COMMIT" \
        "main"
}

sync_spatialmp4() {
    sync_repo \
        "SpatialMP4" \
        "https://github.com/Pico-Developer/SpatialMP4.git" \
        "refs/heads/main" \
        "refs/remotes/origin/main" \
        "$SPATIALMP4_COMMIT" \
        "main"
}

acquire_lock
mkdir -p "$DEPS_SRC_DIR" "$DEPS_BUILD_DIR"

if [ "$#" -eq 0 ]; then
    set -- all
fi

for dep in "$@"; do
    case "$dep" in
        all)
            sync_godot_xr_tools
            sync_godot_cpp
            sync_ffmpeg
            sync_pinocchio_android
            ;;
        web)
            sync_spatialmp4
            ;;
        godot-xr-tools)
            sync_godot_xr_tools
            ;;
        godot-cpp)
            sync_godot_cpp
            ;;
        ffmpeg)
            sync_ffmpeg
            ;;
        pinocchio-android)
            sync_pinocchio_android
            ;;
        spatialmp4|SpatialMP4)
            sync_spatialmp4
            ;;
        -h|--help|help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            die "unknown dependency: $dep"
            ;;
    esac
done

echo "[deps] done: ${OPERATOR_DEPS_CACHE_ROOT#$REPO_ROOT/}"
