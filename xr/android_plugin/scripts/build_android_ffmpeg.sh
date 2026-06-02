#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUEST_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKSPACE_ROOT="$(cd "$QUEST_ROOT/.." && pwd)"
SPATIALMP4_ROOT="${SPATIALMP4_ROOT:-$WORKSPACE_ROOT/SpatialMP4}"
FFMPEG_VERSION="${FFMPEG_VERSION:-8.1.1}"
FFMPEG_TAG="${FFMPEG_TAG:-n${FFMPEG_VERSION}}"
ANDROID_ABI="${ANDROID_ABI:-arm64-v8a}"
ANDROID_API="${ANDROID_API:-29}"
NDK_ROOT="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}"

if [ -z "$NDK_ROOT" ]; then
    SDK_ROOT="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
    if [ -d "$SDK_ROOT/ndk/28.1.13356709" ]; then
        NDK_ROOT="$SDK_ROOT/ndk/28.1.13356709"
    else
        NDK_ROOT="$(find "$SDK_ROOT/ndk" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort -V | tail -1)"
    fi
fi

if [ ! -d "$NDK_ROOT" ]; then
    echo "Android NDK not found. Set ANDROID_NDK_HOME or ANDROID_NDK_ROOT." >&2
    exit 1
fi

case "$ANDROID_ABI" in
    arm64-v8a)
        ARCH="aarch64"
        CPU="armv8-a"
        TARGET="aarch64-linux-android"
        ;;
    *)
        echo "Unsupported ABI: $ANDROID_ABI" >&2
        exit 1
        ;;
esac

HOST_TAG="darwin-x86_64"
if [[ "$(uname)" == "Linux" ]]; then
    HOST_TAG="linux-x86_64"
fi

TOOLCHAIN="$NDK_ROOT/toolchains/llvm/prebuilt/$HOST_TAG"
if [ ! -d "$TOOLCHAIN" ]; then
    echo "NDK LLVM toolchain not found: $TOOLCHAIN" >&2
    exit 1
fi

BUILD_ROOT="$SCRIPT_DIR/build_ffmpeg_android/$ANDROID_ABI"
SRC_DIR="$BUILD_ROOT/ffmpeg"
INSTALL_PREFIX="$QUEST_ROOT/android_plugin/spatialmp4_muxer/src/main/cpp/third_party/ffmpeg/$ANDROID_ABI"
READ_PATCH="$SPATIALMP4_ROOT/scripts/ffmpeg_8_1_1_read.patch"
ENC_PATCH="$SPATIALMP4_ROOT/scripts/ffmpeg_8_1_1_enc.patch"

mkdir -p "$BUILD_ROOT"
if [ ! -d "$SRC_DIR/.git" ]; then
    git clone https://git.ffmpeg.org/ffmpeg.git "$SRC_DIR"
fi

cd "$SRC_DIR"
git fetch --tags origin "$FFMPEG_TAG"
git reset --hard "$FFMPEG_TAG"
git clean -fdx
git apply "$READ_PATCH"
git apply "$ENC_PATCH"

make distclean >/dev/null 2>&1 || true

CC="$TOOLCHAIN/bin/${TARGET}${ANDROID_API}-clang"
CXX="$TOOLCHAIN/bin/${TARGET}${ANDROID_API}-clang++"
AR="$TOOLCHAIN/bin/llvm-ar"
NM="$TOOLCHAIN/bin/llvm-nm"
RANLIB="$TOOLCHAIN/bin/llvm-ranlib"
STRIP="$TOOLCHAIN/bin/llvm-strip"

./configure \
    --prefix="$INSTALL_PREFIX" \
    --target-os=android \
    --arch="$ARCH" \
    --cpu="$CPU" \
    --cc="$CC" \
    --cxx="$CXX" \
    --ar="$AR" \
    --nm="$NM" \
    --ranlib="$RANLIB" \
    --strip="$STRIP" \
    --enable-cross-compile \
    --enable-static \
    --disable-shared \
    --enable-pic \
    --disable-programs \
    --disable-doc \
    --disable-network \
    --disable-avdevice \
    --disable-avfilter \
    --disable-swresample \
    --disable-swscale \
    --disable-everything \
    --enable-muxer=mp4 \
    --enable-protocol=file \
    --enable-parser=hevc \
    --enable-encoder=ffv1

if [[ "$(uname)" == "Darwin" ]]; then
    MAKE_JOBS="$(sysctl -n hw.ncpu)"
else
    MAKE_JOBS="$(nproc)"
fi

make -j"$MAKE_JOBS"
make install
rm -rf "$INSTALL_PREFIX/share"

echo "Installed patched FFmpeg $FFMPEG_VERSION for $ANDROID_ABI to $INSTALL_PREFIX"
