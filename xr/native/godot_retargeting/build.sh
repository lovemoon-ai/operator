#!/usr/bin/env bash
# Build libgodot_retargeting.so for Android arm64 and stage it with libmujoco.so
# for both Godot's GDExtension loader and APK packaging.

set -euo pipefail

BUILD_TYPE="${1:-Release}"
BUILD_JOBS="${GODOT_RETARGETING_BUILD_JOBS:-4}"
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

ANDROID_ABI="${ANDROID_ABI:-arm64-v8a}"
# Default MuJoCo to the mujoco-android install (make -C xr build-mujoco-android),
# the same default godot_mujoco uses.
MUJOCO_ANDROID_INSTALL_DEFAULT="$DEPS_ROOT/build/mujoco-android/$ANDROID_ABI/src/build/android/$ANDROID_ABI/install"
MUJOCO_ANDROID_INPLACE="$DEPS_ROOT/src/mujoco-android/build/android/$ANDROID_ABI/install"
MUJOCO_ANDROID_ROOT="${MUJOCO_ANDROID_ROOT:-}"
if [[ -z "$MUJOCO_ANDROID_ROOT" ]]; then
    if   [[ -f "$MUJOCO_ANDROID_INSTALL_DEFAULT/lib/libmujoco.so" ]]; then MUJOCO_ANDROID_ROOT="$MUJOCO_ANDROID_INSTALL_DEFAULT"
    elif [[ -f "$MUJOCO_ANDROID_INPLACE/lib/libmujoco.so" ]]; then MUJOCO_ANDROID_ROOT="$MUJOCO_ANDROID_INPLACE"
    fi
fi

cd "$SCRIPT_DIR"

if [[ -z "${ANDROID_NDK:-}" ]]; then
    if [[ -n "${ANDROID_NDK_HOME:-}" ]]; then export ANDROID_NDK="$ANDROID_NDK_HOME"
    elif [[ -n "${ANDROID_NDK_ROOT:-}" ]]; then export ANDROID_NDK="$ANDROID_NDK_ROOT"
    else echo "ERROR: ANDROID_NDK / ANDROID_NDK_HOME / ANDROID_NDK_ROOT must be set." >&2; exit 1; fi
fi

if [[ -z "$MUJOCO_ANDROID_ROOT" || ! -f "$MUJOCO_ANDROID_ROOT/lib/libmujoco.so" ]]; then
    echo "ERROR: MuJoCo Android install not found." >&2
    echo "       Run: make -C $REPO_ROOT/xr build-mujoco-android" >&2
    echo "       or set MUJOCO_ANDROID_ROOT to an install with lib/libmujoco.so." >&2
    exit 1
fi

ensure_godot_cpp_link() {
    mkdir -p "$DEPS_ROOT/src" "$DEPS_ROOT/build"
    if [[ -L "$GODOT_CPP_LINK" ]]; then
        rm -f "$GODOT_CPP_LINK"; ln -s "$GODOT_CPP_LINK_TARGET" "$GODOT_CPP_LINK"; return
    fi
    if [[ -e "$GODOT_CPP_LINK" ]]; then
        echo "ERROR: $GODOT_CPP_LINK exists and is not the expected symlink." >&2; exit 1
    fi
    ln -s "$GODOT_CPP_LINK_TARGET" "$GODOT_CPP_LINK"
}

if [[ ! -f "$GODOT_CPP_SOURCE/SConstruct" ]]; then
    OPERATOR_DEPS_CACHE_ROOT="$OPERATOR_DEPS_CACHE_ROOT" "$DEPS_SCRIPT" godot-cpp
fi
ensure_godot_cpp_link

# Standalone retargeting toolkit (DuinoDu/retargeting). sync_deps.sh clones it
# into $DEPS_ROOT/src/retargeting and creates the ./retargeting symlink used by
# CMakeLists. Re-run the sync if the source is missing.
RETARGETING_SOURCE="$DEPS_ROOT/src/retargeting"
RETARGETING_LINK="$SCRIPT_DIR/retargeting"
if [[ "$DEPS_ROOT" == "$REPO_ROOT/.deps" ]]; then
    RETARGETING_LINK_TARGET="../../../.deps/src/retargeting"
else
    RETARGETING_LINK_TARGET="$RETARGETING_SOURCE"
fi
if [[ ! -f "$RETARGETING_SOURCE/app/CMakeLists.txt" ]]; then
    OPERATOR_DEPS_CACHE_ROOT="$OPERATOR_DEPS_CACHE_ROOT" "$DEPS_SCRIPT" retargeting
fi
# Always (re)point the symlink at the current cache root so switching
# OPERATOR_DEPS_CACHE_ROOT never leaves a stale-but-resolvable link. Fail loudly
# if the path is occupied by a real file/dir rather than the expected symlink.
if [[ -e "$RETARGETING_LINK" && ! -L "$RETARGETING_LINK" ]]; then
    echo "ERROR: $RETARGETING_LINK exists and is not a symlink. Remove it and re-run." >&2; exit 1
fi
rm -f "$RETARGETING_LINK"; ln -s "$RETARGETING_LINK_TARGET" "$RETARGETING_LINK"
[[ -f "$RETARGETING_LINK/app/CMakeLists.txt" ]] || { echo "ERROR: retargeting toolkit missing at $RETARGETING_LINK" >&2; exit 1; }

GODOT_CPP_DIR_REAL="$(cd "$GODOT_CPP_LINK" && pwd -P)"
[[ -n "$GODOT_CPP_DIR_REAL" ]] || { echo "ERROR: cannot resolve $GODOT_CPP_LINK" >&2; exit 1; }

BUILD_DIR="build-${ANDROID_ABI}"
CMAKE_EXTRA_ARGS=()
if [[ -n "${FETCHCONTENT_SOURCE_DIR_JSON:-}" ]]; then
    CMAKE_EXTRA_ARGS+=("-DFETCHCONTENT_SOURCE_DIR_JSON=$FETCHCONTENT_SOURCE_DIR_JSON")
fi
cmake -B "$BUILD_DIR" \
    -DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI="$ANDROID_ABI" \
    -DANDROID_PLATFORM=android-29 \
    -DANDROID_STL=c++_shared \
    -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
    -DGODOTCPP_TARGET="$GODOTCPP_TARGET" \
    -DGODOT_CPP_DIR="$GODOT_CPP_DIR_REAL" \
    -DGODOT_CPP_BUILD_DIR="$GODOT_CPP_BUILD" \
    -DMUJOCO_ROOT="$MUJOCO_ANDROID_ROOT" \
    -DCMAKE_PREFIX_PATH="${CMAKE_PREFIX_PATH:-/opt/homebrew}" \
    -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH \
    "${CMAKE_EXTRA_ARGS[@]}"

cmake --build "$BUILD_DIR" -j"$BUILD_JOBS"

SO="$BUILD_DIR/libgodot_retargeting.so"
MUJOCO_SO="$MUJOCO_ANDROID_ROOT/lib/libmujoco.so"

# Validate both libraries are non-empty ELF shared objects before staging. A
# 0-byte or non-ELF file here is exactly what shipped an unloadable extension
# into the APK (dlopen -> "bad ELF magic: 504b0304"), so fail loudly instead.
assert_elf() {
    local f="$1"
    [[ -s "$f" ]] || { echo "ERROR: $f is empty" >&2; exit 1; }
    local magic
    magic="$(od -An -tx1 -N4 "$f" | tr -d ' \n')"
    [[ "$magic" == "7f454c46" ]] || { echo "ERROR: $f is not an ELF object (magic=$magic)" >&2; exit 1; }
}
assert_elf "$SO"
assert_elf "$MUJOCO_SO"

ADDON_DIR="$SCRIPT_DIR/../../addons/godot_retargeting/bin"
# RELEASE gradle packages jniLibs from libs/release/<abi> (see
# android/build/build.gradle: release.jniLibs.srcDirs = ['libs/release']), so
# stage there — NOT libs/<abi>, which release builds ignore.
JNI_DIR="$SCRIPT_DIR/../../android/build/libs/release/${ANDROID_ABI}"
mkdir -p "$ADDON_DIR" "$JNI_DIR"
cp "$SO" "$ADDON_DIR/libgodot_retargeting.so"
cp "$MUJOCO_SO" "$ADDON_DIR/libmujoco.so"
cp "$SO" "$JNI_DIR/libgodot_retargeting.so"
cp "$MUJOCO_SO" "$JNI_DIR/libmujoco.so"

echo
echo "Built $(stat -f '%z' "$SO" 2>/dev/null || stat -c '%s' "$SO") byte libgodot_retargeting.so"
echo "Installed:"
echo "  $ADDON_DIR/libgodot_retargeting.so"
echo "  $ADDON_DIR/libmujoco.so"
echo "  $JNI_DIR/libgodot_retargeting.so"
echo "  $JNI_DIR/libmujoco.so"
