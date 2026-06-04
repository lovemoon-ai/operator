#!/usr/bin/env bash
# Build libahb_decoder.so for arm64-v8a and install it where the
# Godot Android export and the Kotlin System.loadLibrary() call both
# expect to find it.
#
# Requirements:
#   - $ANDROID_NDK pointing at an NDK r25+ install
#   - godot-cpp synced by scripts/sync_deps.sh into .deps/src/godot-cpp
#
# Usage:
#   xr/native/ahb_decoder/build.sh [Debug|Release]   # default Release

set -euo pipefail

BUILD_TYPE="${1:-Release}"
BUILD_JOBS="${AHB_BUILD_JOBS:-4}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
DEPS_ROOT="${DEPS_ROOT:-$REPO_ROOT/.deps}"
GODOT_CPP_SOURCE="$DEPS_ROOT/src/godot-cpp"
GODOT_CPP_LINK="$SCRIPT_DIR/godot-cpp"
if [[ "$DEPS_ROOT" == "$REPO_ROOT/.deps" ]]; then
    GODOT_CPP_LINK_TARGET="../../../.deps/src/godot-cpp"
else
    GODOT_CPP_LINK_TARGET="$GODOT_CPP_SOURCE"
fi
GODOT_CPP_BUILD="$DEPS_ROOT/build/godot-cpp"
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
    mkdir -p "$DEPS_ROOT/src" "$DEPS_ROOT/build"

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

BUILD_DIR="build-arm64"
cmake -B "$BUILD_DIR" \
    -DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI=arm64-v8a \
    -DANDROID_PLATFORM=android-29 \
    -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
    -DGODOT_CPP_DIR="$GODOT_CPP_LINK" \
    -DGODOT_CPP_BUILD_DIR="$GODOT_CPP_BUILD"

cmake --build "$BUILD_DIR" -j"$BUILD_JOBS"

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
