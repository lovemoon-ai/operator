#!/usr/bin/env bash
# Cross-compile the retargeting upper-body demo for Android (arm64-v8a) and,
# optionally, push it to a connected device and run the numerical verification.
#
# On Android the kinematics backend is MuJoCo (from mujoco-android): MuJoCo loads
# MJCF natively, whereas the pinocchio-android build is core-only without the
# MJCF parser. Eigen is header-only (resolved from the host); nlohmann-json is
# vendored under third_party/. No pinocchio / vcpkg dependency on this path.
#
# Prerequisites:
#   - ANDROID_NDK / ANDROID_NDK_HOME pointing at an NDK r26+ install.
#   - MuJoCo built for Android:  make -C xr build-mujoco-android
#     (or set MUJOCO_ANDROID_ROOT to a prebuilt install with lib/libmujoco.so).
#
# Usage:
#   build_android.sh            # build, then push+run+verify if a device is up
#   build_android.sh --no-run   # build only
#   build_android.sh --run      # build and force push+run+verify
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
BUILD_TYPE="${BUILD_TYPE:-Release}"
ANDROID_ABI="${ANDROID_ABI:-arm64-v8a}"
ANDROID_API="${ANDROID_API:-android-29}"
DEVICE_DIR="/data/local/tmp/retargeting"

RUN_MODE="auto"
for a in "$@"; do
  case "$a" in
    --no-run) RUN_MODE="no-run" ;;
    --run)    RUN_MODE="run" ;;
  esac
done

# --- locate the NDK -------------------------------------------------------
if [[ -z "${ANDROID_NDK:-}" ]]; then
  if [[ -n "${ANDROID_NDK_HOME:-}" ]]; then ANDROID_NDK="$ANDROID_NDK_HOME"
  elif [[ -n "${ANDROID_NDK_ROOT:-}" ]]; then ANDROID_NDK="$ANDROID_NDK_ROOT"
  else echo "ERROR: set ANDROID_NDK / ANDROID_NDK_HOME / ANDROID_NDK_ROOT." >&2; exit 1; fi
fi
HOST_TAG="$(uname | tr 'A-Z' 'a-z')-x86_64"
NDK_SYSROOT="$ANDROID_NDK/toolchains/llvm/prebuilt/$HOST_TAG/sysroot"

# --- locate the MuJoCo Android install ------------------------------------
OPERATOR_DEPS_CACHE_ROOT="${OPERATOR_DEPS_CACHE_ROOT:-$REPO_ROOT/.deps}"
MJ_DEFAULT="$OPERATOR_DEPS_CACHE_ROOT/build/mujoco-android/$ANDROID_ABI/src/build/android/$ANDROID_ABI/install"
# The wrapper can also build in-place under .deps/src/mujoco-android (no worktree).
MJ_INPLACE="$OPERATOR_DEPS_CACHE_ROOT/src/mujoco-android/build/android/$ANDROID_ABI/install"
MUJOCO_ANDROID_ROOT="${MUJOCO_ANDROID_ROOT:-}"
if [[ -z "$MUJOCO_ANDROID_ROOT" ]]; then
  if   [[ -f "$MJ_DEFAULT/lib/libmujoco.so" ]]; then MUJOCO_ANDROID_ROOT="$MJ_DEFAULT"
  elif [[ -f "$MJ_INPLACE/lib/libmujoco.so" ]]; then MUJOCO_ANDROID_ROOT="$MJ_INPLACE"
  fi
fi
if [[ -z "$MUJOCO_ANDROID_ROOT" || ! -f "$MUJOCO_ANDROID_ROOT/lib/libmujoco.so" ]]; then
  echo "ERROR: MuJoCo Android install not found." >&2
  echo "       Run:  make -C $REPO_ROOT/xr build-mujoco-android" >&2
  echo "       or set MUJOCO_ANDROID_ROOT to an install with lib/libmujoco.so." >&2
  exit 1
fi
echo "MuJoCo Android install: $MUJOCO_ANDROID_ROOT"

# --- configure + build ----------------------------------------------------
cd "$SCRIPT_DIR"
BUILD_DIR="build-android-${ANDROID_ABI}"
cmake -B "$BUILD_DIR" \
  -DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI="$ANDROID_ABI" \
  -DANDROID_PLATFORM="$ANDROID_API" \
  -DANDROID_STL=c++_shared \
  -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
  -DRETARGETING_WITH_PINOCCHIO=OFF \
  -DRETARGETING_WITH_MUJOCO=ON \
  -DMUJOCO_ROOT="$MUJOCO_ANDROID_ROOT" \
  -DMUJOCO_LIB="$MUJOCO_ANDROID_ROOT/lib/libmujoco.so" \
  -DCMAKE_PREFIX_PATH="/opt/homebrew" \
  -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH   # allow host (header-only) Eigen3

cmake --build "$BUILD_DIR" -j"${BUILD_JOBS:-4}"

BIN="$BUILD_DIR/upper_body_demo"
[[ -x "$BIN" ]] || { echo "ERROR: build produced no $BIN" >&2; exit 1; }
echo "Built $BIN"; file "$BIN" 2>/dev/null || true

# --- stage runtime .so set + data -----------------------------------------
STAGE="$BUILD_DIR/stage"
rm -rf "$STAGE"; mkdir -p "$STAGE/libs"
cp -a "$MUJOCO_ANDROID_ROOT/lib/"libmujoco.so* "$STAGE/libs/"
CXX_SHARED="$NDK_SYSROOT/usr/lib/aarch64-linux-android/libc++_shared.so"
[[ -f "$CXX_SHARED" ]] && cp -a "$CXX_SHARED" "$STAGE/libs/"
cp "$BIN" "$STAGE/"
cp -a data "$STAGE/"
echo "Staged $(ls "$STAGE/libs" | wc -l | tr -d ' ') shared libs + data."

# --- run on device --------------------------------------------------------
if [[ "$RUN_MODE" == "no-run" ]]; then exit 0; fi
if ! command -v adb >/dev/null 2>&1; then echo "[skip] adb not found; build only."; exit 0; fi
if [[ "$(adb get-state 2>/dev/null)" != "device" ]]; then
  if [[ "$RUN_MODE" == "run" ]]; then echo "ERROR: no device." >&2; exit 1; fi
  echo "[skip] no device connected; build only."; exit 0
fi

N="${FRAMES:-200}"; FPS="${FPS:-30}"; H="${HEIGHT:-1.75}"
REF="data/reference/qpos_upper_body_g1_f${N}_fps${FPS}_h${H}.csv"
# Meshless MJCF: MuJoCo loads the kinematic tree without the 52MB STL meshes.
ROBOT="data/robot/unitree_g1/g1_mocap_29dof_nomesh.xml"

echo "[device] pushing to $DEVICE_DIR ..."
adb shell "rm -rf $DEVICE_DIR && mkdir -p $DEVICE_DIR"
adb push "$STAGE/." "$DEVICE_DIR" >/dev/null
adb shell "chmod 755 $DEVICE_DIR/upper_body_demo"

echo "[device] running upper_body_demo (backend=mujoco, frames=$N) ..."
adb shell "cd $DEVICE_DIR && LD_LIBRARY_PATH=$DEVICE_DIR/libs ./upper_body_demo \
  --backend mujoco --frames $N --fps $FPS --human_height $H \
  --robot_xml $ROBOT --ik_config data/ik_configs/quest3_upper_to_g1.json \
  --out $DEVICE_DIR/qpos_device.csv --verify $REF"
RC=$?
echo "[device] exit=$RC"
exit $RC
