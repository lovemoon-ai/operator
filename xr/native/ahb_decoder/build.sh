#!/usr/bin/env bash
# Build libahb_decoder.so for arm64-v8a and install it where the
# Godot Android export and the Kotlin System.loadLibrary() call both
# expect to find it.
#
# Requirements:
#   - $ANDROID_NDK pointing at an NDK r25+ install
#   - godot-cpp submodule initialised (`git submodule update --init`)
#
# Usage:
#   xr/native/ahb_decoder/build.sh [Debug|Release]   # default Release

set -euo pipefail

BUILD_TYPE="${1:-Release}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if [[ -z "${ANDROID_NDK:-}" ]]; then
    if [[ -n "${ANDROID_NDK_HOME:-}" ]]; then
        export ANDROID_NDK="$ANDROID_NDK_HOME"
    else
        echo "ERROR: ANDROID_NDK or ANDROID_NDK_HOME must be set." >&2
        exit 1
    fi
fi

if [[ ! -f "godot-cpp/SConstruct" ]]; then
    REPO_ROOT="$(cd ../../.. && pwd)"
    if git -C "$REPO_ROOT" ls-files --error-unmatch xr/native/ahb_decoder/godot-cpp >/dev/null 2>&1; then
        echo "godot-cpp submodule not initialised; running 'git submodule update --init'..." >&2
        git -C "$REPO_ROOT" submodule update --init --depth=1 xr/native/ahb_decoder/godot-cpp
    else
        # Submodule is declared in .gitmodules but the gitlink was never
        # committed, so `submodule update` can't resolve the path. Clone the
        # matching branch directly. Clone into a PID-suffixed temp dir, then
        # atomically move into place so a partial/interrupted clone never
        # leaves a half-populated godot-cpp/ that the SConstruct check accepts.
        echo "godot-cpp submodule not tracked; cloning godot-cpp (branch 4.5) fallback..." >&2
        tmp="godot-cpp.$$.tmp"
        rm -rf "$tmp"
        if git clone --depth 1 --branch 4.5 https://github.com/godotengine/godot-cpp.git "$tmp"; then
            rm -rf godot-cpp
            mv "$tmp" godot-cpp
        else
            rm -rf "$tmp"
            echo "ERROR: godot-cpp clone failed" >&2
            exit 1
        fi
    fi
fi

BUILD_DIR="build-arm64"
cmake -B "$BUILD_DIR" \
    -DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI=arm64-v8a \
    -DANDROID_PLATFORM=android-29 \
    -DCMAKE_BUILD_TYPE="$BUILD_TYPE"

cmake --build "$BUILD_DIR" -j4

SO="$BUILD_DIR/libahb_decoder.so"
if [[ ! -s "$SO" ]]; then
    echo "ERROR: build produced empty $SO" >&2
    exit 1
fi

# Install to:
#   1. addons/ahb_decoder/  — referenced by ahb_decoder.gdextension
#   2. android/build/libs/arm64-v8a/  — picked up by Kotlin
#      System.loadLibrary("ahb_decoder")
ADDON_DST="$SCRIPT_DIR/../../addons/ahb_decoder/libahb_decoder.so"
JNI_DST="$SCRIPT_DIR/../../android/build/libs/arm64-v8a/libahb_decoder.so"

mkdir -p "$(dirname "$ADDON_DST")"
mkdir -p "$(dirname "$JNI_DST")"
cp "$SO" "$ADDON_DST"
cp "$SO" "$JNI_DST"

echo
echo "Built $(stat -f '%z' "$SO" 2>/dev/null || stat -c '%s' "$SO") byte libahb_decoder.so"
echo "Installed:"
echo "  $ADDON_DST"
echo "  $JNI_DST"
