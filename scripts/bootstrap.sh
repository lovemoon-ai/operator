#!/usr/bin/env bash
# scripts/bootstrap.sh — provision the operator host toolchain on a fresh
# Linux machine.
#
# Installs everything the xr/ build needs into
#     ~/.local/opt/operator-build-tools   (override: OPERATOR_BUILD_TOOLS)
# plus the Android SDK packages into
#     ~/Android/Sdk                       (override: ANDROID_SDK_ROOT/ANDROID_HOME)
# plus the Godot 4.5.1 export templates into
#     ~/.local/share/godot/export_templates/4.5.1.stable/
#
# Layout produced (mirrors the reference install):
#   operator-build-tools/
#     env.sh                                source this before `make build-*`
#     jdk-17 -> jdk-17.0.20+8/              Temurin JDK 17 (Gradle/AGP)
#     android-cmdline-tools-11076708/       sdkmanager
#     cmake-3.31.8-linux-x86_64/            cmake >= 3.26 (see xr/Makefile:
#                                           SDK cmake 3.22.1 misreads NDK 28
#                                           and links MuJoCo with ld.gold)
#     godot-4.5.1/                          Godot_v4.5.1-stable_linux.x86_64
#     godot-export-templates-4.5.1/         staging for the export templates
#     eigen3/usr/                           libeigen3-dev .deb, unpacked
#     json/                                 nlohmann/json 3.11.3 sources
#                                           (FETCHCONTENT_SOURCE_DIR_JSON)
#     scons/usr/                            scons .deb, unpacked
#     hosttools/                            godot/ninja shims (env.sh rebuilds)
#     downloads/, packages/                 fetch cache (re-runs are cheap)
#
# Everything is idempotent: existing components are skipped, cached downloads
# are re-verified against the pinned sha256.
#
# NOT covered here (host-level, install separately):
#   - Rust toolchain for robot/   (https://rustup.rs)
#   - Python 3 venv for python/   (cd python && python3 -m venv .venv)
#   - an Android XR device for runtime tests
#
# Usage:
#   bash scripts/bootstrap.sh
#   source ~/.local/opt/operator-build-tools/env.sh
#   cd xr && make build-quest

set -euo pipefail

TOOLS="${OPERATOR_BUILD_TOOLS:-$HOME/.local/opt/operator-build-tools}"
export ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Android/Sdk}}"
export ANDROID_HOME="$ANDROID_SDK_ROOT"
DL="$TOOLS/downloads"
PKG="$TOOLS/packages"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

# --- pinned versions ----------------------------------------------------------
GODOT_VERSION=4.5.1
GODOT_ZIP="Godot_v${GODOT_VERSION}-stable_linux.x86_64.zip"
GODOT_TPZ="Godot_v${GODOT_VERSION}-stable_export_templates.tpz"
GODOT_BASE="https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}-stable"

CMAKE_VER=3.31.8
CMAKE_TGZ="cmake-${CMAKE_VER}-linux-x86_64.tar.gz"

JDK_DIR="jdk-17.0.20+8"
JDK_TGZ="OpenJDK17U-jdk_x64_linux_hotspot_17.0.20_8.tar.gz"

CMDTOOLS_ZIP="commandlinetools-linux-11076708_latest.zip"

JSON_VER=3.11.3
JSON_TXZ="json-${JSON_VER}.tar.xz"

EIGEN_DEB="libeigen3-dev_3.4.0-2ubuntu2_all.deb"
SCONS_DEB="scons_4.0.1+dfsg-2_all.deb"

# sdkmanager packages. The NDK is pinned by the repo: xr/Makefile reads
# ndkVersion from xr/android/build/config.gradle and refuses to build against
# any other NDK, so bootstrap reads the same source of truth.
NDK_VERSION="$(sed -n "s/.*ndkVersion[^']*'\([^']*\)'.*/\1/p" \
    "$REPO_ROOT/xr/android/build/config.gradle" 2>/dev/null || true)"
NDK_VERSION="${NDK_VERSION:-28.1.13356709}"
SDK_PACKAGES=(
    "platform-tools"
    "platforms;android-35"
    "build-tools;35.0.0"
    "cmake;3.22.1"   # only its bundled ninja is used; never put its cmake on PATH
    "ndk;${NDK_VERSION}"
)

# --- helpers ------------------------------------------------------------------
log()  { printf '[bootstrap] %s\n' "$*"; }
die()  { printf '[bootstrap] ERROR: %s\n' "$*" >&2; exit 1; }

fetch() { # fetch <dest-file> <url> <sha256>
    local dest="$1" url="$2" sha="$3"
    if [ -f "$dest" ]; then
        if echo "$sha  $dest" | sha256sum -c --status - 2>/dev/null; then
            log "cached  $(basename "$dest")"
            return 0
        fi
        log "checksum mismatch, re-fetching $(basename "$dest")"
        rm -f "$dest"
    fi
    log "fetch   $url"
    curl -fL --retry 3 --connect-timeout 30 -o "$dest.part" "$url"
    mv "$dest.part" "$dest"
    echo "$sha  $dest" | sha256sum -c --status - \
        || die "sha256 mismatch for $(basename "$dest")"
}

# --- 0. host prerequisites ----------------------------------------------------
need_cmds=(curl unzip tar xz sha256sum dpkg-deb python3)
missing=()
for c in "${need_cmds[@]}"; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
done
if [ "${#missing[@]}" -gt 0 ]; then
    log "missing host tools: ${missing[*]} — trying apt-get"
    if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get update
        sudo apt-get install -y curl unzip tar xz-utils coreutils dpkg python3
    else
        die "install these first: ${missing[*]}"
    fi
fi
for c in "${need_cmds[@]}"; do
    command -v "$c" >/dev/null 2>&1 || die "still missing: $c"
done

mkdir -p "$TOOLS" "$DL" "$PKG" "$TOOLS/hosttools" "$ANDROID_SDK_ROOT"

# --- 1. Temurin JDK 17 ----------------------------------------------------------
if [ ! -x "$TOOLS/jdk-17/bin/java" ]; then
    fetch "$DL/$JDK_TGZ" \
        "https://github.com/adoptium/temurin17-binaries/releases/download/jdk-17.0.20%2B8/$JDK_TGZ" \
        "be7668bc030d578b83d6d5ef9221d6d6729bbbca8cf94a7d52e16ac68b5a5a35"
    tar -xzf "$DL/$JDK_TGZ" -C "$TOOLS"
    ln -sfn "$TOOLS/$JDK_DIR" "$TOOLS/jdk-17"
fi
export JAVA_HOME="$TOOLS/jdk-17"
export PATH="$JAVA_HOME/bin:$PATH"
log "jdk     $("$JAVA_HOME/bin/java" -version 2>&1 | head -1)"

# --- 2. Android cmdline-tools + SDK packages ------------------------------------
CMDTOOLS_DIR="$TOOLS/android-cmdline-tools-11076708"
if [ ! -x "$CMDTOOLS_DIR/cmdline-tools/bin/sdkmanager" ]; then
    fetch "$DL/$CMDTOOLS_ZIP" \
        "https://dl.google.com/android/repository/$CMDTOOLS_ZIP" \
        "2d2d50857e4eb553af5a6dc3ad507a17adf43d115264b1afc116f95c92e5e258"
    mkdir -p "$CMDTOOLS_DIR"
    unzip -qo "$DL/$CMDTOOLS_ZIP" -d "$CMDTOOLS_DIR"
fi
# Standard SDK-side layout too, so gradle/AGP find sdkmanager where they expect.
if [ ! -x "$ANDROID_SDK_ROOT/cmdline-tools/latest/bin/sdkmanager" ]; then
    mkdir -p "$ANDROID_SDK_ROOT/cmdline-tools/latest"
    cp -a "$CMDTOOLS_DIR/cmdline-tools/." "$ANDROID_SDK_ROOT/cmdline-tools/latest/"
fi
SDKMANAGER="$ANDROID_SDK_ROOT/cmdline-tools/latest/bin/sdkmanager"

log "accepting SDK licenses"
yes | "$SDKMANAGER" --sdk_root="$ANDROID_SDK_ROOT" --licenses >/dev/null 2>&1 || true
for p in "${SDK_PACKAGES[@]}"; do
    log "sdkmanager \"$p\""
    "$SDKMANAGER" --sdk_root="$ANDROID_SDK_ROOT" "$p"
done
[ -d "$ANDROID_SDK_ROOT/ndk/$NDK_VERSION" ] \
    || die "NDK $NDK_VERSION missing after sdkmanager run"

# --- 3. cmake 3.31.8 (must shadow the SDK's 3.22.1 — see header comment) --------
if [ ! -x "$TOOLS/cmake-${CMAKE_VER}-linux-x86_64/bin/cmake" ]; then
    fetch "$DL/$CMAKE_TGZ" \
        "https://github.com/Kitware/CMake/releases/download/v${CMAKE_VER}/$CMAKE_TGZ" \
        "630615d8e98ac33eba7fbe472626dff5c899c85af3c024585ae109166a6909d0"
    tar -xzf "$DL/$CMAKE_TGZ" -C "$TOOLS"
fi
log "cmake   $("$TOOLS/cmake-${CMAKE_VER}-linux-x86_64/bin/cmake" --version | head -1)"

# --- 4. Godot 4.5.1 editor binary -----------------------------------------------
if [ ! -x "$TOOLS/godot-${GODOT_VERSION}/Godot_v${GODOT_VERSION}-stable_linux.x86_64" ]; then
    fetch "$DL/$GODOT_ZIP" "$GODOT_BASE/$GODOT_ZIP" \
        "02ec53d1cc7dbb9cc6355393c61b9ab43d1244751a124f10248a4802830788cd"
    mkdir -p "$TOOLS/godot-${GODOT_VERSION}"
    unzip -qo "$DL/$GODOT_ZIP" -d "$TOOLS/godot-${GODOT_VERSION}"
    chmod +x "$TOOLS/godot-${GODOT_VERSION}/Godot_v${GODOT_VERSION}-stable_linux.x86_64"
fi

# --- 5. Godot export templates ----------------------------------------------------
TEMPLATES_HOME="$HOME/.local/share/godot/export_templates/${GODOT_VERSION}.stable"
if [ ! -f "$TEMPLATES_HOME/android_release.apk" ]; then
    fetch "$DL/$GODOT_TPZ" "$GODOT_BASE/$GODOT_TPZ" \
        "e5c2301c6c541ae8a5ad63589291200a033e7e1b80897c6a6580b90b37e35b3e"
    STAGE="$TOOLS/godot-export-templates-${GODOT_VERSION}"
    mkdir -p "$STAGE"
    unzip -qo "$DL/$GODOT_TPZ" -d "$STAGE"   # extracts a templates/ folder
    mkdir -p "$TEMPLATES_HOME"
    cp -a "$STAGE/templates/." "$TEMPLATES_HOME/"
fi
log "templates $TEMPLATES_HOME"

# --- 6. nlohmann/json sources (FetchContent offline override) ---------------------
if [ ! -d "$TOOLS/json/include/nlohmann" ]; then
    fetch "$DL/$JSON_TXZ" \
        "https://github.com/nlohmann/json/releases/download/v${JSON_VER}/json.tar.xz" \
        "d6c65aca6b1ed68e7a182f4757257b107ae403032760ed6ef121c9d55e81757d"
    tmp="$(mktemp -d)"
    tar -xJf "$DL/$JSON_TXZ" -C "$tmp"
    mkdir -p "$TOOLS/json"
    shopt -s dotglob nullglob
    entries=("$tmp"/*)
    if [ "${#entries[@]}" -eq 1 ] && [ -d "${entries[0]}" ]; then
        mv "${entries[0]}"/* "$TOOLS/json/"   # tarball has a wrapping top dir
    else
        mv "$tmp"/* "$TOOLS/json/"
    fi
    shopt -u dotglob nullglob
    rm -rf "$tmp"
fi

# --- 7. eigen3 + scons from Ubuntu .debs (unpacked, not installed) ----------------
if [ ! -d "$TOOLS/eigen3/usr/include/eigen3" ]; then
    fetch "$PKG/$EIGEN_DEB" \
        "https://archive.ubuntu.com/ubuntu/pool/universe/e/eigen3/$EIGEN_DEB" \
        "04ee3759712a0f003fb186edf83724947826d7a43f3ef8d858cd359ca38a25ef"
    mkdir -p "$TOOLS/eigen3"
    dpkg-deb -x "$PKG/$EIGEN_DEB" "$TOOLS/eigen3"
fi
if [ ! -x "$TOOLS/scons/usr/bin/scons" ]; then
    fetch "$PKG/$SCONS_DEB" \
        "https://archive.ubuntu.com/ubuntu/pool/universe/s/scons/$SCONS_DEB" \
        "d451de7060ea2f2eed75fb8ac55a37df680a678ffaeaa2e8be44ce36ad575f6d"
    mkdir -p "$TOOLS/scons"
    dpkg-deb -x "$PKG/$SCONS_DEB" "$TOOLS/scons"
fi

# --- 8. env.sh --------------------------------------------------------------------
cat > "$TOOLS/env.sh" <<'ENVEOF'
# operator-build-tools/env.sh — host toolchain for `make build-*` in operator/xr.
#
#   source ~/.local/opt/operator-build-tools/env.sh
#
# Installed by scripts/bootstrap.sh. Idempotent: sourcing twice will not
# duplicate PATH entries, and any value you set yourself beforehand wins.
#
# Deliberately NOT set: ANDROID_NDK / ANDROID_NDK_HOME / ANDROID_NDK_ROOT. The
# xr Makefile pins those itself from android/build/config.gradle (`ndkVersion`)
# and exports them over whatever the shell had. Setting them here would just
# create a second, silently-ignored source of truth.

# --- locate ourselves (bash + zsh), so the tree stays relocatable ------------
_obt_self=""
if [ -n "${BASH_SOURCE:-}" ]; then
    _obt_self="${BASH_SOURCE[0]}"
elif [ -n "${ZSH_VERSION:-}" ]; then
    _obt_self="$(eval 'print -r -- ${(%):-%x}')"
fi
[ -n "$_obt_self" ] || _obt_self="$HOME/.local/opt/operator-build-tools/env.sh"

OPERATOR_BUILD_TOOLS="$(cd "$(dirname "$_obt_self")" && pwd -P)"
export OPERATOR_BUILD_TOOLS
unset _obt_self

# --- helpers ----------------------------------------------------------------
# Prepend only if the directory exists and is not already on PATH. Called in
# ascending priority order: the LAST successful call ends up first on PATH.
_obt_prepend() {
    [ -d "$1" ] || return 0
    case ":$PATH:" in
        *":$1:"*) return 0 ;;
    esac
    PATH="$1:$PATH"
}

# --- Android SDK ------------------------------------------------------------
: "${ANDROID_SDK_ROOT:=${ANDROID_HOME:-$HOME/Android/Sdk}}"
ANDROID_HOME="$ANDROID_SDK_ROOT"
export ANDROID_SDK_ROOT ANDROID_HOME

# --- JDK --------------------------------------------------------------------
if [ -d "$OPERATOR_BUILD_TOOLS/jdk-17" ]; then
    JAVA_HOME="$OPERATOR_BUILD_TOOLS/jdk-17"
    export JAVA_HOME
fi

# --- PATH (ascending priority — cmake must end up ahead of the SDK's) -------
_obt_prepend "$OPERATOR_BUILD_TOOLS/scons/usr/bin"
_obt_prepend "$OPERATOR_BUILD_TOOLS/android-cmdline-tools-11076708/cmdline-tools/bin"
_obt_prepend "$ANDROID_SDK_ROOT/platform-tools"
[ -n "${JAVA_HOME:-}" ] && _obt_prepend "$JAVA_HOME/bin"

# --- shim directory -----------------------------------------------------------
# Holds symlinks for tools that exist on disk under a name PATH lookup will not
# find, or that must be borrowed from elsewhere without dragging their siblings
# along. Rebuilt on every source, so it self-heals.
mkdir -p "$OPERATOR_BUILD_TOOLS/hosttools"

# godot ships as Godot_v4.5.1-stable_linux.x86_64 — putting godot-4.5.1/ on PATH
# alone gives you nothing named `godot`.
for _obt_godot in "$OPERATOR_BUILD_TOOLS"/godot-4.5.1/Godot_v*_linux.x86_64; do
    [ -x "$_obt_godot" ] && ln -sf "$_obt_godot" "$OPERATOR_BUILD_TOOLS/hosttools/godot"
done
unset _obt_godot

# ninja comes bundled with the Android SDK's CMake package. It is exposed
# through a shim directory holding ONLY a ninja symlink, because the SDK's
# cmake must not come along for the ride: with NDK 28's toolchain file, cmake
# 3.22.1 leaves CMAKE_ANDROID_NDK_VERSION empty, so CMake's Compiler/Clang.cmake
# applies its NDK<22 workaround (-fuse-ld=gold for IPO), which overrides
# MuJoCo's own -fuse-ld=lld and kills the host x86_64 ld.gold on aarch64
# objects ("unsupported ELF machine number 183"). cmake >= 3.26 reads the NDK
# version correctly. Keep in sync with xr/Makefile, which builds the same shim
# under xr/build/hosttools.
: "${ANDROID_CMAKE_VERSION:=3.22.1}"
export ANDROID_CMAKE_VERSION
_obt_sdk_ninja="$ANDROID_SDK_ROOT/cmake/$ANDROID_CMAKE_VERSION/bin/ninja"
if [ ! -x "$_obt_sdk_ninja" ]; then
    _obt_sdk_ninja="$(ls -1 "$ANDROID_SDK_ROOT"/cmake/*/bin/ninja 2>/dev/null | sort -V | tail -1)"
fi
if [ -n "$_obt_sdk_ninja" ] && [ -x "$_obt_sdk_ninja" ]; then
    ln -sf "$_obt_sdk_ninja" "$OPERATOR_BUILD_TOOLS/hosttools/ninja"
fi
unset _obt_sdk_ninja

_obt_prepend "$OPERATOR_BUILD_TOOLS/cmake-3.31.8-linux-x86_64/bin"
_obt_prepend "$OPERATOR_BUILD_TOOLS/hosttools"

export PATH

# --- vendored headers the native builds look for ------------------------------
# retargeting/build.sh forwards both of these.
if [ -d "$OPERATOR_BUILD_TOOLS/eigen3/usr" ]; then
    case ":${CMAKE_PREFIX_PATH:-}:" in
        *":$OPERATOR_BUILD_TOOLS/eigen3/usr:"*) ;;
        *) CMAKE_PREFIX_PATH="${CMAKE_PREFIX_PATH:+$CMAKE_PREFIX_PATH:}$OPERATOR_BUILD_TOOLS/eigen3/usr" ;;
    esac
    export CMAKE_PREFIX_PATH
fi
if [ -d "$OPERATOR_BUILD_TOOLS/json" ]; then
    export FETCHCONTENT_SOURCE_DIR_JSON="$OPERATOR_BUILD_TOOLS/json"
fi

# --- shared dependency cache ----------------------------------------------------
# Repo default is <repo>/.deps. Pointing it at a shared cache keeps sources and
# native build trees alive across worktrees — but note that CHANGING this value
# orphans everything already built under the old root, which silently forces a
# full rebuild of MuJoCo et al.
: "${OPERATOR_DEPS_CACHE_ROOT:=$HOME/.cache/operator}"
export OPERATOR_DEPS_CACHE_ROOT

unset -f _obt_prepend

# --- summary --------------------------------------------------------------------
printf '[operator-build-tools] %s\n' "$OPERATOR_BUILD_TOOLS"
printf '  cmake  %s\n' "$(command -v cmake >/dev/null 2>&1 && cmake --version | head -1 || echo 'NOT FOUND')"
printf '  ninja  %s\n' "$(command -v ninja >/dev/null 2>&1 && ninja --version || echo 'NOT FOUND')"
printf '  godot  %s\n' "$(command -v godot >/dev/null 2>&1 && godot --version 2>/dev/null | head -1 || echo 'NOT FOUND')"
printf '  java   %s\n' "${JAVA_HOME:-<system>}"
printf '  sdk    %s\n' "$ANDROID_SDK_ROOT"
printf '  deps   %s\n' "$OPERATOR_DEPS_CACHE_ROOT"
ENVEOF
chmod +x "$TOOLS/env.sh"

# --- 9. verify ------------------------------------------------------------------
log "verifying toolchain via env.sh"
( source "$TOOLS/env.sh" >/dev/null
  command -v cmake  >/dev/null || { echo 'cmake not on PATH'  >&2; exit 1; }
  command -v ninja  >/dev/null || { echo 'ninja not on PATH'  >&2; exit 1; }
  command -v godot  >/dev/null || { echo 'godot not on PATH'  >&2; exit 1; }
  command -v adb    >/dev/null || { echo 'adb not on PATH'    >&2; exit 1; }
  cmake_v="$(cmake --version | head -1 | awk '{print $3}')"
  [ "$(printf '3.26\n%s\n' "$cmake_v" | sort -V | head -1)" = "3.26" ] \
      || { echo "cmake $cmake_v < 3.26" >&2; exit 1; }
  godot --version 2>/dev/null | head -1 | grep -q '^4\.5\.1\.stable' \
      || { echo 'godot is not 4.5.1.stable' >&2; exit 1; }
)

log "done. Next steps:"
log "  source $TOOLS/env.sh"
log "  cd $REPO_ROOT/xr && make build-quest        # or build-pico"
log "  (robot/ needs rustup; python/ needs a venv — see AGENTS.md)"
