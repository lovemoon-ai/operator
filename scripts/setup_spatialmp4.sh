#!/usr/bin/env bash
# Prepare the SpatialMP4 SDK in Operator's shared dependency cache for the web
# rerun worker. The source checkout is managed by scripts/sync_deps.sh, while
# this script builds the Python binding that web/app/scripts/spatialmp4_to_rrd.py
# imports through SPATIALMP4_HOME.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEFAULT_OPERATOR_DEPS_CACHE_ROOT="$REPO_ROOT/.deps"
OPERATOR_DEPS_CACHE_ROOT="${OPERATOR_DEPS_CACHE_ROOT:-$DEFAULT_OPERATOR_DEPS_CACHE_ROOT}"
DEPS_SRC_DIR="${DEPS_SRC_DIR:-$OPERATOR_DEPS_CACHE_ROOT/src}"
DEPS_BUILD_DIR="${DEPS_BUILD_DIR:-$OPERATOR_DEPS_CACHE_ROOT/build}"
SPATIALMP4_HOME="${SPATIALMP4_HOME:-$DEPS_SRC_DIR/SpatialMP4}"
PYTHON_VERSION="${RERUN_PYTHON_VERSION:-${PYTHON_VERSION:-3.13}}"
BUILD_TYPE="${BUILD_TYPE:-Release}"
BUILD_JOBS="${BUILD_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"
BUILD_FFMPEG="${BUILD_FFMPEG:-auto}"
CLEAN="${CLEAN:-0}"

usage() {
    cat <<EOF_USAGE
Usage: $0 [--clean] [--no-ffmpeg] [--python VERSION]

Environment:
  OPERATOR_DEPS_CACHE_ROOT  Shared dependency root (default: $DEFAULT_OPERATOR_DEPS_CACHE_ROOT)
  SPATIALMP4_HOME           SpatialMP4 checkout (default: \$OPERATOR_DEPS_CACHE_ROOT/src/SpatialMP4)
  RERUN_PYTHON_VERSION      Python ABI for web rerun worker (default: 3.13)
  PYTHON_VERSION            Fallback Python ABI if RERUN_PYTHON_VERSION is unset
  BUILD_FFMPEG              auto|1|0 (default: auto; run SpatialMP4's ffmpeg build if needed)
  BUILD_JOBS                Parallel build jobs (default: CPU count)

Outputs:
  source: $SPATIALMP4_HOME
  build:  $DEPS_BUILD_DIR/spatialmp4/python<abi>

After setup, web can use:
  export SPATIALMP4_HOME=$SPATIALMP4_HOME
EOF_USAGE
}

while (($#)); do
    case "$1" in
        --clean) CLEAN=1; shift ;;
        --no-ffmpeg) BUILD_FFMPEG=0; shift ;;
        --python) PYTHON_VERSION="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ERROR: unknown arg: $1" >&2; usage >&2; exit 1 ;;
    esac
done

log() { echo "[spatialmp4] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

python_bin() {
    if command -v uv >/dev/null 2>&1; then
        uv python find "$PYTHON_VERSION"
        return
    fi
    if command -v "python$PYTHON_VERSION" >/dev/null 2>&1; then
        command -v "python$PYTHON_VERSION"
        return
    fi
    if command -v python3 >/dev/null 2>&1; then
        command -v python3
        return
    fi
    die "python not found; install uv or python$PYTHON_VERSION"
}

find_spatialmp4_so() {
    local root="$1"
    find "$root" -path '*/python/spatialmp4*.so' -type f -print -quit 2>/dev/null || true
}

log "sync source checkout"
"$SCRIPT_DIR/sync_deps.sh" spatialmp4

[ -d "$SPATIALMP4_HOME" ] || die "SpatialMP4 checkout missing: $SPATIALMP4_HOME"
[ -f "$SPATIALMP4_HOME/CMakeLists.txt" ] || die "not a SpatialMP4 checkout: $SPATIALMP4_HOME"

PYTHON_BIN="$(python_bin)"
PY_ABI="$($PYTHON_BIN - <<'PY'
import sys
print(f"{sys.version_info.major}{sys.version_info.minor}")
PY
)"
BUILD_DIR="$DEPS_BUILD_DIR/spatialmp4/python$PY_ABI"
HOST_DEPS_DIR="$DEPS_BUILD_DIR/spatialmp4/host_deps"
HOST_DEPS_LINK="$SPATIALMP4_HOME/scripts/build_ffmpeg"

if [ "$CLEAN" = "1" ]; then
    log "clean $BUILD_DIR"
    rm -rf "$BUILD_DIR"
fi
mkdir -p "$BUILD_DIR"
mkdir -p "$HOST_DEPS_DIR"

if [ "$BUILD_FFMPEG" = "auto" ]; then
    if [ -d "$HOST_DEPS_DIR/ffmpeg_install" ]; then
        BUILD_FFMPEG=0
    else
        BUILD_FFMPEG=1
    fi
fi

if [ -e "$HOST_DEPS_LINK" ] && [ ! -L "$HOST_DEPS_LINK" ]; then
    die "$HOST_DEPS_LINK exists and is not a symlink; move it or set SPATIALMP4_HOME to a clean checkout"
fi
rm -f "$HOST_DEPS_LINK"
ln -s "$HOST_DEPS_DIR" "$HOST_DEPS_LINK"

if [ "$BUILD_FFMPEG" = "1" ]; then
    log "build SpatialMP4 patched ffmpeg"
    (cd "$SPATIALMP4_HOME" && bash scripts/build_ffmpeg.sh)
else
    log "skip ffmpeg build"
fi

if [ ! -d "$HOST_DEPS_DIR/ffmpeg_install/lib/pkgconfig" ]; then
    die "SpatialMP4 host ffmpeg is missing at $HOST_DEPS_DIR/ffmpeg_install. Re-run without --no-ffmpeg, or set BUILD_FFMPEG=1."
fi

log "configure Python binding with $PYTHON_BIN"
cmake -S "$SPATIALMP4_HOME" -B "$BUILD_DIR" \
    -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
    -DBUILD_PYTHON=ON \
    -DBUILD_TESTING=OFF \
    -DBUILD_READER_SMOKE=OFF \
    -DPython3_EXECUTABLE="$PYTHON_BIN" \
    -DPython_EXECUTABLE="$PYTHON_BIN"

log "build Python binding"
cmake --build "$BUILD_DIR" -j"$BUILD_JOBS"

SO_PATH="$(find_spatialmp4_so "$BUILD_DIR")"
[ -n "$SO_PATH" ] || die "spatialmp4 Python extension not found under $BUILD_DIR"

cat <<EOF_DONE
[spatialmp4] ready
  SPATIALMP4_HOME=$SPATIALMP4_HOME
  build=$BUILD_DIR
  host_deps=$HOST_DEPS_DIR
  module=$SO_PATH

For local web runs:
  export SPATIALMP4_HOME="$SPATIALMP4_HOME"
  cd web && npm run dev
EOF_DONE
