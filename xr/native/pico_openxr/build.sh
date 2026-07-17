#!/usr/bin/env bash
# Build libpico_openxr.so for arm64-v8a and install it for both Godot's
# GDExtension loader and Android packaging.

set -euo pipefail

BUILD_TYPE="${1:-Release}"
BUILD_JOBS="${PICO_OPENXR_BUILD_JOBS:-4}"
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
	-DGODOTCPP_TARGET="$GODOTCPP_TARGET" \
	-DGODOT_CPP_DIR="$GODOT_CPP_DIR_REAL" \
	-DGODOT_CPP_BUILD_DIR="$GODOT_CPP_BUILD"

cmake --build "$BUILD_DIR" -j"$BUILD_JOBS"

SO="$BUILD_DIR/libpico_openxr.so"
if [[ ! -s "$SO" ]]; then
	echo "ERROR: build produced empty $SO" >&2
	exit 1
fi

ADDON_DST="$SCRIPT_DIR/../../addons/pico_openxr/libpico_openxr.so"
JNI_DST="$SCRIPT_DIR/../../android/build/libs/arm64-v8a/libpico_openxr.so"

mkdir -p "$(dirname "$ADDON_DST")"
mkdir -p "$(dirname "$JNI_DST")"
cp "$SO" "$ADDON_DST"
cp "$SO" "$JNI_DST"

echo
echo "Built $(stat -f '%z' "$SO" 2>/dev/null || stat -c '%s' "$SO") byte libpico_openxr.so"
echo "Installed:"
echo "  $ADDON_DST"
echo "  $JNI_DST"
