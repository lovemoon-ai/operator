#!/usr/bin/env bash
# Build libpinocchio_gd.so for arm64-v8a and install it where the Godot
# Android export and the GDExtension loader both expect to find it.
#
# Requirements:
#   - $ANDROID_NDK pointing at an NDK r26+ install (Pinocchio needs >= C++17,
#     Eigen needs r25b workarounds — r26 is the safe floor).
#   - $VCPKG_ROOT pointing at a vcpkg checkout. The Pinocchio install we
#     consume was produced through the vcpkg toolchain; its exported CMake
#     config will re-find Eigen3 + Boost via that toolchain.
#   - godot-cpp synced by scripts/sync_deps.sh into
#     $OPERATOR_DEPS_CACHE_ROOT/src/godot-cpp.
#   - Pinocchio built by `make -C xr build-pinocchio` into
#     $OPERATOR_DEPS_CACHE_ROOT/build/pinocchio-android/<abi>/src/build/android/<abi>/install/.
#
# Usage:
#   xr/native/pinocchio/build.sh [Debug|Release]   # default Release

set -euo pipefail

BUILD_TYPE="${1:-Release}"
BUILD_JOBS="${PINOCCHIO_BUILD_JOBS:-4}"
ANDROID_ABI="${PINOCCHIO_ANDROID_ABI:-arm64-v8a}"
ANDROID_PLATFORM_LEVEL="${PINOCCHIO_ANDROID_API:-android-29}"

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

# Pinocchio install prefix, produced by xr/makefiles/Makefile.pinocchio. Path
# layout has to stay in lock-step with PINOCCHIO_INSTALL there.
PINOCCHIO_BUILD_DIR="$OPERATOR_DEPS_CACHE_ROOT/build/pinocchio-android"
PINOCCHIO_INSTALL_DIR="${PINOCCHIO_INSTALL_DIR:-$PINOCCHIO_BUILD_DIR/$ANDROID_ABI/src/build/android/$ANDROID_ABI/install}"

cd "$SCRIPT_DIR"

if [[ -z "${ANDROID_NDK:-}" ]]; then
    if [[ -n "${ANDROID_NDK_HOME:-}" ]]; then
        export ANDROID_NDK="$ANDROID_NDK_HOME"
    elif [[ -n "${ANDROID_NDK_ROOT:-}" ]]; then
        export ANDROID_NDK="$ANDROID_NDK_ROOT"
    else
        echo "ERROR: ANDROID_NDK / ANDROID_NDK_HOME / ANDROID_NDK_ROOT must be set." >&2
        exit 1
    fi
fi

# Note: VCPKG_ROOT is intentionally NOT required by this build. The wrapper
# consumes pinocchio + eigen + boost out of the install tree produced by
# `make -C xr build-pinocchio` directly; vcpkg's toolchain is only needed for
# the upstream pinocchio-android build, not for ours.

if [[ ! -f "$PINOCCHIO_INSTALL_DIR/lib/libpinocchio_default.so" ]]; then
    echo "ERROR: Pinocchio install not found at:" >&2
    echo "       $PINOCCHIO_INSTALL_DIR" >&2
    echo "       Run:  make -C xr build-pinocchio" >&2
    exit 1
fi

ensure_godot_cpp_link() {
    mkdir -p "$OPERATOR_DEPS_CACHE_ROOT/src" "$OPERATOR_DEPS_CACHE_ROOT/build"

    if [[ -L "$GODOT_CPP_LINK" ]]; then
        rm -f "$GODOT_CPP_LINK"
        ln -s "$GODOT_CPP_LINK_TARGET" "$GODOT_CPP_LINK"
        return
    fi

    if [[ -e "$GODOT_CPP_LINK" ]]; then
        if [[ -f "$GODOT_CPP_LINK/SConstruct" && ! -e "$GODOT_CPP_SOURCE" ]]; then
            echo "Migrating local godot-cpp checkout to .deps/src/godot-cpp..." >&2
            mv "$GODOT_CPP_LINK" "$GODOT_CPP_SOURCE"
        elif [[ -d "$GODOT_CPP_LINK" && -z "$(find "$GODOT_CPP_LINK" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
            rmdir "$GODOT_CPP_LINK"
        else
            echo "ERROR: $GODOT_CPP_LINK exists and is not the expected symlink." >&2
            echo "Move it to $GODOT_CPP_SOURCE or remove it, then rerun build.sh." >&2
            exit 1
        fi
    fi

    ln -s "$GODOT_CPP_LINK_TARGET" "$GODOT_CPP_LINK"
}

if [[ ! -f "$GODOT_CPP_SOURCE/SConstruct" ]]; then
    "$DEPS_SCRIPT" godot-cpp
fi

ensure_godot_cpp_link

# Pass the symlink's real path (not the per-worktree symlink itself) to cmake
# so the SHARED godot-cpp build dir records a stable source path — see the
# matching comment in native/ahb_decoder/build.sh for the full rationale.
GODOT_CPP_DIR_REAL="$(cd "$GODOT_CPP_LINK" && pwd -P)"
if [[ -z "$GODOT_CPP_DIR_REAL" ]]; then
    echo "ERROR: failed to resolve $GODOT_CPP_LINK to a real path" >&2
    echo "       (is the godot-cpp symlink broken? try: make -C xr deps)" >&2
    exit 1
fi

BUILD_DIR="build-${ANDROID_ABI}"

# We deliberately do NOT chainload vcpkg's toolchain here, even though the
# upstream pinocchio-android build does. The vcpkg toolchain overrides
# find_package to look only in $VCPKG_INSTALLED_DIR for the active triplet,
# which means `find_package(pinocchio CONFIG)` cannot see the install at
# $PINOCCHIO_INSTALL_DIR (pinocchio is not a vcpkg port). Instead, drive
# cmake with the NDK toolchain directly and put both install trees on
# CMAKE_PREFIX_PATH so:
#   * find_package(pinocchio CONFIG) resolves through PINOCCHIO_INSTALL_DIR
#   * the find_dependency(Eigen3 / Boost*) calls inside pinocchioConfig.cmake
#     resolve through the vcpkg_installed/arm64-android tree the upstream
#     pinocchio-android build already populated.
VCPKG_INSTALLED_DIR="$OPERATOR_DEPS_CACHE_ROOT/build/pinocchio-android/$ANDROID_ABI/src/vcpkg_installed/arm64-android"
if [[ ! -d "$VCPKG_INSTALLED_DIR/share/eigen3" ]]; then
    echo "ERROR: vcpkg install tree not found at $VCPKG_INSTALLED_DIR" >&2
    echo "       Re-run: make -C xr build-pinocchio" >&2
    exit 1
fi

cmake -B "$BUILD_DIR" \
    -DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI="$ANDROID_ABI" \
    -DANDROID_PLATFORM="$ANDROID_PLATFORM_LEVEL" \
    -DANDROID_STL=c++_shared \
    -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
    -DCMAKE_PREFIX_PATH="$PINOCCHIO_INSTALL_DIR;$VCPKG_INSTALLED_DIR" \
    -DCMAKE_FIND_ROOT_PATH="$PINOCCHIO_INSTALL_DIR;$VCPKG_INSTALLED_DIR;$ANDROID_NDK/toolchains/llvm/prebuilt/$(uname | tr A-Z a-z)-x86_64/sysroot" \
    -DPINOCCHIO_INSTALL_DIR="$PINOCCHIO_INSTALL_DIR" \
    -DGODOT_CPP_DIR="$GODOT_CPP_DIR_REAL" \
    -DGODOT_CPP_BUILD_DIR="$GODOT_CPP_BUILD"

cmake --build "$BUILD_DIR" -j"$BUILD_JOBS"

SO="$BUILD_DIR/libpinocchio_gd.so"
if [[ ! -s "$SO" ]]; then
    echo "ERROR: build produced empty $SO" >&2
    exit 1
fi

# Install to:
#   1. addons/pinocchio/libpinocchio_gd.so  — referenced by the .gdextension
#   2. addons/pinocchio/libpinocchio_default.so — runtime dependency,
#      listed in the [dependencies] block of pinocchio.gdextension so Godot
#      copies it into the APK lib/arm64-v8a/ alongside the wrapper.
#   3. android/build/libs/<abi>/  — picked up by Gradle as a JNI lib so
#      System.loadLibrary("pinocchio_gd") works from Kotlin too.
ADDON_DST="$SCRIPT_DIR/../../addons/pinocchio/libpinocchio_gd.so"
ADDON_CORE_DST="$SCRIPT_DIR/../../addons/pinocchio/libpinocchio_default.so"
JNI_DST="$SCRIPT_DIR/../../android/build/libs/${ANDROID_ABI}/libpinocchio_gd.so"
JNI_CORE_DST="$SCRIPT_DIR/../../android/build/libs/${ANDROID_ABI}/libpinocchio_default.so"

mkdir -p "$(dirname "$ADDON_DST")"
mkdir -p "$(dirname "$JNI_DST")"
cp "$SO" "$ADDON_DST"
cp "$PINOCCHIO_INSTALL_DIR/lib/libpinocchio_default.so" "$ADDON_CORE_DST"
cp "$SO" "$JNI_DST"
cp "$PINOCCHIO_INSTALL_DIR/lib/libpinocchio_default.so" "$JNI_CORE_DST"

echo
echo "Built $(stat -f '%z' "$SO" 2>/dev/null || stat -c '%s' "$SO") byte libpinocchio_gd.so"
echo "Installed:"
echo "  $ADDON_DST"
echo "  $ADDON_CORE_DST"
echo "  $JNI_DST"
echo "  $JNI_CORE_DST"
