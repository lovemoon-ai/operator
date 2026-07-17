#!/usr/bin/env bash
# Build libhand_capture.so for arm64-v8a and install it where the Godot
# Android export expects it (same pattern as native/ahb_decoder/build.sh).
#
# Requirements:
#   - $ANDROID_NDK pointing at an NDK r25+ install
#   - godot-cpp synced by scripts/sync_deps.sh into
#     $OPERATOR_DEPS_CACHE_ROOT/src/godot-cpp (defaults to .deps/src/godot-cpp)
#
# Usage:
#   xr/native/hand_capture/build.sh [Debug|Release]   # default Release

set -euo pipefail

BUILD_TYPE="${1:-Release}"
BUILD_JOBS="${HAND_CAPTURE_BUILD_JOBS:-4}"
case "$BUILD_TYPE" in
    Debug)
        GODOTCPP_TARGET="template_debug"
        ;;
    Release|RelWithDebInfo|MinSizeRel)
        GODOTCPP_TARGET="template_release"
        ;;
    *)
        echo "ERROR: unsupported build type '$BUILD_TYPE'" >&2
        exit 1
        ;;
esac
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
OPERATOR_DEPS_CACHE_ROOT="${OPERATOR_DEPS_CACHE_ROOT:-$REPO_ROOT/.deps}"
GODOT_CPP_SOURCE="$OPERATOR_DEPS_CACHE_ROOT/src/godot-cpp"
GODOT_CPP_LINK="$SCRIPT_DIR/godot-cpp"
if [[ "$OPERATOR_DEPS_CACHE_ROOT" == "$REPO_ROOT/.deps" ]]; then
    GODOT_CPP_LINK_TARGET="../../../.deps/src/godot-cpp"
else
    GODOT_CPP_LINK_TARGET="$GODOT_CPP_SOURCE"
fi
GODOT_CPP_BUILD="$OPERATOR_DEPS_CACHE_ROOT/build/godot-cpp"
DEPS_SCRIPT="$REPO_ROOT/scripts/sync_deps.sh"
cd "$SCRIPT_DIR"

if [[ -z "${ANDROID_NDK:-}" ]]; then
    if [[ -n "${ANDROID_NDK_HOME:-}" ]]; then
        export ANDROID_NDK="$ANDROID_NDK_HOME"
    else
        echo "ERROR: ANDROID_NDK or ANDROID_NDK_HOME must be set." >&2
        exit 1
    fi
fi

ensure_godot_cpp_link() {
    mkdir -p "$OPERATOR_DEPS_CACHE_ROOT/src" "$OPERATOR_DEPS_CACHE_ROOT/build"

    if [[ -L "$GODOT_CPP_LINK" ]]; then
        rm -f "$GODOT_CPP_LINK"
        ln -s "$GODOT_CPP_LINK_TARGET" "$GODOT_CPP_LINK"
        return
    fi

    if [[ -e "$GODOT_CPP_LINK" ]]; then
        echo "ERROR: $GODOT_CPP_LINK exists and is not the expected symlink." >&2
        echo "Remove it, then rerun build.sh." >&2
        exit 1
    fi

    ln -s "$GODOT_CPP_LINK_TARGET" "$GODOT_CPP_LINK"
}

if [[ ! -f "$GODOT_CPP_SOURCE/SConstruct" ]]; then
    "$DEPS_SCRIPT" godot-cpp
fi

ensure_godot_cpp_link

# Resolve the symlink so the shared godot-cpp build dir records a stable
# source path across worktrees (see ahb_decoder/build.sh for the rationale).
GODOT_CPP_DIR_REAL="$(cd "$GODOT_CPP_LINK" && pwd -P)"
if [[ -z "$GODOT_CPP_DIR_REAL" ]]; then
    echo "ERROR: failed to resolve $GODOT_CPP_LINK to a real path" >&2
    echo "       (is the godot-cpp symlink broken? try: make -C xr deps)" >&2
    exit 1
fi

BUILD_DIR="build-arm64"
cmake -B "$BUILD_DIR" \
    -DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI=arm64-v8a \
    -DANDROID_PLATFORM=android-29 \
    -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
    -DGODOTCPP_TARGET="$GODOTCPP_TARGET" \
    -DGODOT_CPP_DIR="$GODOT_CPP_DIR_REAL" \
    -DGODOT_CPP_BUILD_DIR="$GODOT_CPP_BUILD"

cmake --build "$BUILD_DIR" -j"$BUILD_JOBS"

SO="$BUILD_DIR/libhand_capture.so"
if [[ ! -s "$SO" ]]; then
    echo "ERROR: build produced empty $SO" >&2
    exit 1
fi

# Install to addons/hand_capture/ — referenced by hand_capture.gdextension.
ADDON_DST="$SCRIPT_DIR/../../addons/hand_capture/libhand_capture.so"
mkdir -p "$(dirname "$ADDON_DST")"
cp "$SO" "$ADDON_DST"

echo
echo "Built $(stat -f '%z' "$SO" 2>/dev/null || stat -c '%s' "$SO") byte libhand_capture.so"
echo "Installed:"
echo "  $ADDON_DST"
