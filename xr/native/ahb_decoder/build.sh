#!/usr/bin/env bash
# Build libahb_decoder.so for arm64-v8a and install it where the
# Godot Android export and the Kotlin System.loadLibrary() call both
# expect to find it.
#
# Requirements:
#   - $ANDROID_NDK pointing at an NDK r25+ install
#   - godot-cpp submodule initialised at third_party/godot-cpp
#
# Usage:
#   xr/native/ahb_decoder/build.sh [Debug|Release]   # default Release

set -euo pipefail

BUILD_TYPE="${1:-Release}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
GODOT_CPP_SOURCE="$REPO_ROOT/third_party/godot-cpp"
GODOT_CPP_LINK="$SCRIPT_DIR/godot-cpp"
GODOT_CPP_LINK_TARGET="../../../third_party/godot-cpp"
GODOT_CPP_BUILD="$REPO_ROOT/third_party/godot-cpp-build"
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
    mkdir -p "$REPO_ROOT/third_party"

    if [[ -L "$GODOT_CPP_LINK" ]]; then
        ln -sfn "$GODOT_CPP_LINK_TARGET" "$GODOT_CPP_LINK"
        return
    fi

    if [[ -e "$GODOT_CPP_LINK" ]]; then
        if [[ -f "$GODOT_CPP_LINK/SConstruct" && ! -e "$GODOT_CPP_SOURCE" ]]; then
            echo "Migrating local godot-cpp checkout to third_party/godot-cpp..." >&2
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
    mkdir -p "$REPO_ROOT/third_party"
    if git -C "$REPO_ROOT" ls-files --error-unmatch third_party/godot-cpp >/dev/null 2>&1; then
        echo "godot-cpp submodule not initialised; running 'git submodule update --init'..." >&2
        git -C "$REPO_ROOT" submodule update --init --depth=1 third_party/godot-cpp
    else
        # Submodule is declared in .gitmodules but the gitlink was never
        # committed, so `submodule update` can't resolve the path. Clone the
        # matching branch directly. Clone into a PID-suffixed temp dir, then
        # atomically move into place so a partial/interrupted clone never
        # leaves a half-populated godot-cpp/ that the SConstruct check accepts.
        echo "godot-cpp submodule not tracked; cloning godot-cpp (branch 4.5) fallback..." >&2
        tmp="$REPO_ROOT/third_party/godot-cpp.$$.tmp"
        rm -rf "$tmp"
        if git clone --depth 1 --branch 4.5 https://github.com/godotengine/godot-cpp.git "$tmp"; then
            rm -rf "$GODOT_CPP_SOURCE"
            mv "$tmp" "$GODOT_CPP_SOURCE"
        else
            rm -rf "$tmp"
            echo "ERROR: godot-cpp clone failed" >&2
            exit 1
        fi
    fi
fi

ensure_godot_cpp_link

BUILD_DIR="build-arm64"
cmake -B "$BUILD_DIR" \
    -DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI=arm64-v8a \
    -DANDROID_PLATFORM=android-29 \
    -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
    -DGODOT_CPP_DIR="$GODOT_CPP_LINK" \
    -DGODOT_CPP_BUILD_DIR="$GODOT_CPP_BUILD"

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
