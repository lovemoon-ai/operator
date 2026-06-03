#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUEST_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKSPACE_ROOT="$(cd "$QUEST_ROOT/.." && pwd)"
SPATIALMP4_ROOT="${SPATIALMP4_ROOT:-$WORKSPACE_ROOT/SpatialMP4}"
FFMPEG_VERSION="${FFMPEG_VERSION:-8.1.1}"
FFMPEG_TAG="${FFMPEG_TAG:-n${FFMPEG_VERSION}}"
FFMPEG_SOURCE="${FFMPEG_SOURCE:-$WORKSPACE_ROOT/third_party/ffmpeg}"
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

ensure_ffmpeg_source() {
    mkdir -p "$WORKSPACE_ROOT/third_party"

    if ! git -C "$FFMPEG_SOURCE" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        if git -C "$WORKSPACE_ROOT" ls-files --error-unmatch third_party/ffmpeg >/dev/null 2>&1; then
            echo "FFmpeg submodule not initialised; running 'git submodule update --init'..." >&2
            git -C "$WORKSPACE_ROOT" submodule update --init --depth=1 third_party/ffmpeg
        else
            echo "FFmpeg submodule not tracked; cloning $FFMPEG_TAG fallback..." >&2
            tmp="$WORKSPACE_ROOT/third_party/ffmpeg.$$.tmp"
            rm -rf "$tmp"
            if git clone --depth 1 --branch "$FFMPEG_TAG" https://github.com/FFmpeg/FFmpeg.git "$tmp"; then
                rm -rf "$FFMPEG_SOURCE"
                mv "$tmp" "$FFMPEG_SOURCE"
            else
                rm -rf "$tmp"
                echo "ERROR: FFmpeg clone failed" >&2
                exit 1
            fi
        fi
    fi

    if ! git -C "$FFMPEG_SOURCE" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        echo "ERROR: FFmpeg source not found at $FFMPEG_SOURCE" >&2
        exit 1
    fi
}

abs_git_common_dir() {
    local repo="$1"
    local common_dir
    common_dir="$(git -C "$repo" rev-parse --git-common-dir)"
    if [[ "$common_dir" = /* ]]; then
        printf '%s\n' "$common_dir"
    else
        (cd "$repo" && cd "$common_dir" && pwd)
    fi
}

resolve_ffmpeg_ref() {
    local commit
    if commit="$(git -C "$FFMPEG_SOURCE" rev-parse --verify --quiet "$FFMPEG_TAG^{commit}")"; then
        printf '%s\n' "$commit"
        return
    fi

    echo "FFmpeg tag $FFMPEG_TAG not present locally; fetching that tag..." >&2
    git -C "$FFMPEG_SOURCE" fetch --depth=1 origin "refs/tags/$FFMPEG_TAG:refs/tags/$FFMPEG_TAG"
    git -C "$FFMPEG_SOURCE" rev-parse --verify "$FFMPEG_TAG^{commit}"
}

prepare_ffmpeg_worktree() {
    local ffmpeg_ref
    local source_common
    ffmpeg_ref="$(resolve_ffmpeg_ref)"
    source_common="$(abs_git_common_dir "$FFMPEG_SOURCE")"

    git -C "$FFMPEG_SOURCE" worktree prune

    if [ -e "$SRC_DIR" ]; then
        if git -C "$SRC_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
            local src_common
            src_common="$(abs_git_common_dir "$SRC_DIR")"
            if [ "$src_common" != "$source_common" ]; then
                echo "Removing old standalone FFmpeg checkout at $SRC_DIR" >&2
                rm -rf "$SRC_DIR"
            fi
        else
            rm -rf "$SRC_DIR"
        fi
    fi

    if [ ! -e "$SRC_DIR" ]; then
        git -C "$FFMPEG_SOURCE" worktree add --detach "$SRC_DIR" "$ffmpeg_ref"
    fi

    git -C "$SRC_DIR" reset --hard "$ffmpeg_ref"
    git -C "$SRC_DIR" clean -fdx
}

for patch in "$READ_PATCH" "$ENC_PATCH"; do
    if [ ! -f "$patch" ]; then
        echo "Required FFmpeg patch not found: $patch" >&2
        exit 1
    fi
done

ensure_ffmpeg_source
prepare_ffmpeg_worktree

cd "$SRC_DIR"
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
