#!/usr/bin/env bash
# Build libgodot_mujoco.so for Android arm64 and stage it with libmujoco.so
# for both Godot's GDExtension loader and APK packaging.

set -euo pipefail

BUILD_TYPE="${1:-Release}"
BUILD_JOBS="${GODOT_MUJOCO_BUILD_JOBS:-4}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
OPERATOR_DEPS_CACHE_ROOT="${OPERATOR_DEPS_CACHE_ROOT:-${DEPS_ROOT:-$REPO_ROOT/.deps}}"
DEPS_ROOT="$OPERATOR_DEPS_CACHE_ROOT"
GODOT_CPP_SOURCE="$DEPS_ROOT/src/godot-cpp"
GODOT_CPP_LINK="$SCRIPT_DIR/godot-cpp"
if [[ "$DEPS_ROOT" == "$REPO_ROOT/.deps" ]]; then
    GODOT_CPP_LINK_TARGET="../../../.deps/src/godot-cpp"
else
    GODOT_CPP_LINK_TARGET="$GODOT_CPP_SOURCE"
fi
GODOT_CPP_BUILD="$DEPS_ROOT/build/godot-cpp"
DEPS_SCRIPT="$REPO_ROOT/scripts/sync_deps.sh"
# Default to the install produced by `make -C xr build-mujoco-android`
# (xr/makefiles/Makefile.mujoco-android), mirroring how the pinocchio addon
# consumes the pinocchio-android install. Override MUJOCO_ANDROID_ROOT to point
# at any other prebuilt MuJoCo Android tree.
MUJOCO_ANDROID_ABI="${MUJOCO_ANDROID_ABI:-arm64-v8a}"
MUJOCO_ANDROID_INSTALL_DEFAULT="$DEPS_ROOT/build/mujoco-android/$MUJOCO_ANDROID_ABI/src/build/android/$MUJOCO_ANDROID_ABI/install"
MUJOCO_ANDROID_ROOT="${MUJOCO_ANDROID_ROOT:-$MUJOCO_ANDROID_INSTALL_DEFAULT}"

cd "$SCRIPT_DIR"

if [[ -z "${ANDROID_NDK:-}" ]]; then
    if [[ -n "${ANDROID_NDK_HOME:-}" ]]; then
        export ANDROID_NDK="$ANDROID_NDK_HOME"
    else
        echo "ERROR: ANDROID_NDK or ANDROID_NDK_HOME must be set." >&2
        exit 1
    fi
fi

if [[ ! -f "$MUJOCO_ANDROID_ROOT/include/mujoco/mujoco.h" || ! -s "$MUJOCO_ANDROID_ROOT/lib/libmujoco.so" ]]; then
    echo "ERROR: MuJoCo Android install not found under $MUJOCO_ANDROID_ROOT" >&2
    echo "       (expected include/mujoco/mujoco.h and lib/libmujoco.so)" >&2
    echo >&2
    echo "To fix, do ONE of the following:" >&2
    echo "  1. Build the MuJoCo Android dependency (recommended):" >&2
    echo "       make -C $REPO_ROOT/xr build-mujoco-android" >&2
    echo "     then re-run this script." >&2
    echo "  2. Point at an existing prebuilt MuJoCo Android tree:" >&2
    echo "       MUJOCO_ANDROID_ROOT=/path/to/install $0 ${1:-Release}" >&2
    echo "     where that dir contains include/mujoco/mujoco.h and lib/libmujoco.so." >&2
    exit 1
fi

ensure_godot_cpp_link() {
    mkdir -p "$DEPS_ROOT/src" "$DEPS_ROOT/build"
    if [[ -L "$GODOT_CPP_LINK" ]]; then
        rm -f "$GODOT_CPP_LINK"
        ln -s "$GODOT_CPP_LINK_TARGET" "$GODOT_CPP_LINK"
        return
    fi
    if [[ -e "$GODOT_CPP_LINK" ]]; then
        if [[ -f "$GODOT_CPP_LINK/SConstruct" && ! -e "$GODOT_CPP_SOURCE" ]]; then
            mv "$GODOT_CPP_LINK" "$GODOT_CPP_SOURCE"
        elif [[ -d "$GODOT_CPP_LINK" && -z "$(find "$GODOT_CPP_LINK" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
            rmdir "$GODOT_CPP_LINK"
        else
            echo "ERROR: $GODOT_CPP_LINK exists and is not the expected symlink." >&2
            exit 1
        fi
    fi
    ln -s "$GODOT_CPP_LINK_TARGET" "$GODOT_CPP_LINK"
}

if [[ ! -f "$GODOT_CPP_SOURCE/SConstruct" ]]; then
    OPERATOR_DEPS_CACHE_ROOT="$OPERATOR_DEPS_CACHE_ROOT" "$DEPS_SCRIPT" godot-cpp
fi
ensure_godot_cpp_link

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
    -DGODOT_CPP_DIR="$GODOT_CPP_DIR_REAL" \
    -DGODOT_CPP_BUILD_DIR="$GODOT_CPP_BUILD" \
    -DMUJOCO_ROOT="$MUJOCO_ANDROID_ROOT"

cmake --build "$BUILD_DIR" -j"$BUILD_JOBS"

SO="$BUILD_DIR/libgodot_mujoco.so"
if [[ ! -s "$SO" ]]; then
    echo "ERROR: build produced empty $SO" >&2
    exit 1
fi

ADDON_DIR="$SCRIPT_DIR/../../addons/godot_mujoco/bin"
JNI_DIR="$SCRIPT_DIR/../../android/build/libs/arm64-v8a"
mkdir -p "$ADDON_DIR" "$JNI_DIR"
cp "$SO" "$ADDON_DIR/libgodot_mujoco.so"
cp "$MUJOCO_ANDROID_ROOT/lib/libmujoco.so" "$ADDON_DIR/libmujoco.so"
cp "$SO" "$JNI_DIR/libgodot_mujoco.so"
cp "$MUJOCO_ANDROID_ROOT/lib/libmujoco.so" "$JNI_DIR/libmujoco.so"

echo
echo "Built $(stat -c '%s' "$SO" 2>/dev/null || stat -f '%z' "$SO") byte libgodot_mujoco.so"
echo "Installed:"
echo "  $ADDON_DIR/libgodot_mujoco.so"
echo "  $ADDON_DIR/libmujoco.so"
echo "  $JNI_DIR/libgodot_mujoco.so"
echo "  $JNI_DIR/libmujoco.so"
