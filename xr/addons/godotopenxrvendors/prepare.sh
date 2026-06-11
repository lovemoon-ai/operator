#!/usr/bin/env bash
# Fetch or build the pinned Godot OpenXR Vendors addon binaries.
#
# Default mode downloads the official release artifacts. For ego depth capture,
# use --build-patched so the pinned source tag is rebuilt with patches from
# ./patches. The generated .bin/ files remain ignored; VERSION + patches are
# the reproducible state tracked in git.
#
# Usage:
#     ./prepare.sh                         # fetch missing official binaries
#     ./prepare.sh --force                 # re-download official binaries
#     ./prepare.sh --check                 # verify all expected files exist
#     ./prepare.sh --build-patched         # clone pinned source, patch, build, sync
#     ./prepare.sh --build-patched --source /path/to/godot_openxr_vendors
#     ./prepare.sh --check-patched         # verify patched markers in Android libs

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$SCRIPT_DIR/.bin"
VERSION_FILE="$SCRIPT_DIR/VERSION"
ZIP_PREFIX="asset/addons/godotopenxrvendors/.bin"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

read_version_value() {
  local key="$1"
  awk -F= -v key="$key" '$1 == key { print substr($0, index($0, "=") + 1); found = 1 } END { exit found ? 0 : 1 }' "$VERSION_FILE"
}

[[ -f "$VERSION_FILE" ]] || die "missing $VERSION_FILE"

UPSTREAM_REPO="$(read_version_value upstream_repo)"
UPSTREAM_TAG="$(read_version_value upstream_tag)"
UPSTREAM_COMMIT="$(read_version_value upstream_commit)"
PATCH_SET="$(read_version_value patch_set)"
UPSTREAM_URL="https://github.com/GodotVR/godot_openxr_vendors/releases/download/${UPSTREAM_TAG}/godotopenxrvendorsaddon.zip"

PATCH_FILES=(
  patches/0001-meta-depth-callback-metadata.patch
  patches/0002-meta-vulkan-depth-readback.patch
  patches/0003-fb-body-tracking-vformat-fix.patch
)

# Files we keep locally, relative to .bin/.
FILES=(
  # Vendor .aar plugins (Android, target headsets).
  android/debug/godotopenxr-khronos-debug.aar
  android/debug/godotopenxr-meta-debug.aar
  android/debug/godotopenxr-pico-debug.aar
  android/release/godotopenxr-khronos-release.aar
  android/release/godotopenxr-meta-release.aar
  android/release/godotopenxr-pico-release.aar
  # Android arm64 .so (target headsets).
  android/template_debug/arm64/libgodotopenxrvendors.so
  android/template_release/arm64/libgodotopenxrvendors.so
  # Host libraries used by Godot headless export verification.
  macos/template_debug/libgodotopenxrvendors.macos.framework/libgodotopenxrvendors.macos
  macos/template_release/libgodotopenxrvendors.macos.framework/libgodotopenxrvendors.macos
  linux/template_debug/x86_64/libgodotopenxrvendors.so
  linux/template_release/x86_64/libgodotopenxrvendors.so
)

# These must be produced by --build-patched; other host stubs may be retained
# from the official release if the local platform build does not emit them.
PATCHED_REQUIRED_FILES=(
  android/debug/godotopenxr-meta-debug.aar
  android/release/godotopenxr-meta-release.aar
  android/template_debug/arm64/libgodotopenxrvendors.so
  android/template_release/arm64/libgodotopenxrvendors.so
)

PATCHED_SO_FILES=(
  android/template_debug/arm64/libgodotopenxrvendors.so
  android/template_release/arm64/libgodotopenxrvendors.so
)

PATCHED_AAR_FILES=(
  android/debug/godotopenxr-meta-debug.aar
  android/release/godotopenxr-meta-release.aar
)

PATCH_MARKERS=(
  "runtime_display_time_ns"
  "Failed to copy environment depth image for CPU readback: "
)

TEMP_DIRS=()
cleanup() {
  for d in "${TEMP_DIRS[@]+"${TEMP_DIRS[@]}"}"; do
    [[ -n "$d" && -d "$d" ]] && rm -rf "$d"
  done
  return 0
}
trap cleanup EXIT INT TERM

usage() {
  sed -n '3,14p' "$0" >&2
}

mode="fetch"
source_ref=""
keep_source=false

while (( $# > 0 )); do
  case "$1" in
    --force)
      mode="force"
      ;;
    --check)
      mode="check"
      ;;
    --check-patched)
      mode="check_patched"
      ;;
    --build-patched)
      mode="build_patched"
      ;;
    --source)
      [[ $# -ge 2 ]] || die "--source requires a path or git URL"
      source_ref="$2"
      shift
      ;;
    --keep-source)
      keep_source=true
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      die "unknown arg: $1"
      ;;
  esac
  shift
done

mkdir -p "$DEST"

is_required_patched_file() {
  local needle="$1"
  local f
  for f in "${PATCHED_REQUIRED_FILES[@]}"; do
    [[ "$f" == "$needle" ]] && return 0
  done
  return 1
}

collect_missing() {
  missing=()
  local f
  for f in "${FILES[@]}"; do
    [[ -f "$DEST/$f" ]] || missing+=("$f")
  done
}

print_source() {
  echo "[prepare-godotopenxrvendors] upstream: $UPSTREAM_TAG ($UPSTREAM_COMMIT)"
  echo "[prepare-godotopenxrvendors] patch set: $PATCH_SET"
}

fetch_release() {
  local force_label="${1:-}"
  if [[ "$force_label" == "force" ]]; then
    echo "[prepare-godotopenxrvendors] --force: re-fetching official binaries"
  else
    echo "[prepare-godotopenxrvendors] fetching missing official binaries"
  fi
  print_source
  echo "[prepare-godotopenxrvendors] release: $UPSTREAM_URL"

  local tmpdir
  tmpdir="$(mktemp -d)"
  TEMP_DIRS+=("$tmpdir")
  local zip="$tmpdir/addon.zip"
  curl -fL --retry 3 --retry-delay 2 -o "$zip" "$UPSTREAM_URL"

  local zip_paths=()
  local f
  for f in "${FILES[@]}"; do
    zip_paths+=("$ZIP_PREFIX/$f")
  done
  unzip -q "$zip" "${zip_paths[@]}" -d "$tmpdir"

  for f in "${FILES[@]}"; do
    [[ -f "$tmpdir/$ZIP_PREFIX/$f" ]] || die "upstream zip missing $ZIP_PREFIX/$f"
  done

  for f in "${FILES[@]}"; do
    mkdir -p "$DEST/$(dirname "$f")"
    cp "$tmpdir/$ZIP_PREFIX/$f" "$DEST/$f"
  done

  local bytes
  bytes=$(du -ck "$DEST"/android/{debug,release,template_debug,template_release} 2>/dev/null | tail -1 | awk '{print $1}')
  echo "[prepare-godotopenxrvendors] wrote ${#FILES[@]} official files to .bin/ (~${bytes}K)"
}

ensure_prebuilt_present() {
  collect_missing
  if (( ${#missing[@]} > 0 )); then
    echo "[prepare-godotopenxrvendors] ${#missing[@]}/${#FILES[@]} files missing before patched build"
    fetch_release
  fi
}

check_present() {
  collect_missing
  if (( ${#missing[@]} == 0 )); then
    echo "[prepare-godotopenxrvendors] all ${#FILES[@]} files present"
    return 0
  fi

  echo "[prepare-godotopenxrvendors] ${#missing[@]}/${#FILES[@]} files missing:" >&2
  printf '  %s\n' "${missing[@]}" >&2
  return 1
}

check_markers_in_file() {
  local path="$1"
  local label="$2"
  [[ -f "$path" ]] || die "missing $label"

  local strings_out
  strings_out="$(mktemp)"
  strings "$path" > "$strings_out"

  local marker
  for marker in "${PATCH_MARKERS[@]}"; do
    if ! grep -Fq "$marker" "$strings_out"; then
      rm -f "$strings_out"
      die "$label is not patched; missing marker: $marker"
    fi
  done
  rm -f "$strings_out"
}

check_markers_in_aar() {
  local aar="$1"
  local label="$2"
  [[ -f "$aar" ]] || die "missing $label"

  local tmp_so
  tmp_so="$(mktemp)"
  if ! unzip -p "$aar" jni/arm64-v8a/libgodotopenxrvendors.so > "$tmp_so"; then
    rm -f "$tmp_so"
    die "$label does not contain jni/arm64-v8a/libgodotopenxrvendors.so"
  fi
  check_markers_in_file "$tmp_so" "$label:jni/arm64-v8a/libgodotopenxrvendors.so"
  rm -f "$tmp_so"
}

check_patched() {
  check_present

  local f
  for f in "${PATCHED_SO_FILES[@]}"; do
    check_markers_in_file "$DEST/$f" ".bin/$f"
  done
  for f in "${PATCHED_AAR_FILES[@]}"; do
    check_markers_in_aar "$DEST/$f" ".bin/$f"
  done

  echo "[prepare-godotopenxrvendors] patched Android binaries verified"
}

prepare_source_tree() {
  local build_tmp="$1"
  local src="$build_tmp/godot_openxr_vendors"

  if [[ -n "$source_ref" ]]; then
    echo "[prepare-godotopenxrvendors] cloning source from $source_ref" >&2
    git clone "$source_ref" "$src"
    git -C "$src" checkout --detach "$UPSTREAM_COMMIT"
  else
    echo "[prepare-godotopenxrvendors] cloning $UPSTREAM_REPO at $UPSTREAM_TAG" >&2
    git clone --depth 1 --branch "$UPSTREAM_TAG" "$UPSTREAM_REPO" "$src"
  fi

  local actual_commit
  actual_commit="$(git -C "$src" rev-parse HEAD)"
  [[ "$actual_commit" == "$UPSTREAM_COMMIT" ]] || die "expected $UPSTREAM_COMMIT, got $actual_commit"

  git -C "$src" submodule update --init --recursive >&2

  local patch
  for patch in "${PATCH_FILES[@]}"; do
    [[ -f "$SCRIPT_DIR/$patch" ]] || die "missing patch $patch"
    git -C "$src" apply --check "$SCRIPT_DIR/$patch"
    git -C "$src" apply "$SCRIPT_DIR/$patch"
    echo "[prepare-godotopenxrvendors] applied $patch" >&2
  done

  echo "$src"
}

copy_built_files() {
  local built_bin="$1"
  [[ -d "$built_bin" ]] || die "build output missing: $built_bin"

  local copied=0
  local kept=0
  local f
  for f in "${FILES[@]}"; do
    if [[ -f "$built_bin/$f" ]]; then
      mkdir -p "$DEST/$(dirname "$f")"
      cp "$built_bin/$f" "$DEST/$f"
      copied=$((copied + 1))
    elif is_required_patched_file "$f"; then
      die "patched build did not produce required file: $f"
    else
      kept=$((kept + 1))
      echo "[prepare-godotopenxrvendors] keeping existing .bin/$f"
    fi
  done

  echo "[prepare-godotopenxrvendors] copied $copied patched files; kept $kept existing host stubs"
}

build_patched() {
  ensure_prebuilt_present
  print_source

  local build_tmp
  build_tmp="$(mktemp -d)"
  if [[ "$keep_source" == true ]]; then
    echo "[prepare-godotopenxrvendors] keeping source/build tree: $build_tmp"
  else
    TEMP_DIRS+=("$build_tmp")
  fi

  local src
  src="$(prepare_source_tree "$build_tmp")"

  echo "[prepare-godotopenxrvendors] building patched vendor addon"
  (cd "$src" && ./gradlew buildPlugin -PdoNotStrip=true)

  local built_bin="$src/asset/addons/godotopenxrvendors/.bin"
  if [[ ! -d "$built_bin" ]]; then
    built_bin="$src/demo/addons/godotopenxrvendors/.bin"
  fi
  copy_built_files "$built_bin"
  check_patched
}

case "$mode" in
  check)
    check_present
    ;;
  check_patched)
    check_patched
    ;;
  force)
    fetch_release force
    ;;
  build_patched)
    build_patched
    ;;
  fetch)
    collect_missing
    if (( ${#missing[@]} == 0 )); then
      echo "[prepare-godotopenxrvendors] all ${#FILES[@]} files already present"
      print_source
    else
      echo "[prepare-godotopenxrvendors] ${#missing[@]}/${#FILES[@]} files missing"
      fetch_release
    fi
    ;;
  *)
    die "unknown mode: $mode"
    ;;
esac
