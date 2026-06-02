#!/usr/bin/env bash
# Fetch the godot_openxr_vendors prebuilt binaries from upstream release.
#
# Upstream: https://github.com/GodotVR/godot_openxr_vendors
# The released `godotopenxrvendorsaddon.zip` (~46 MB) bundles all
# prebuilt platform/vendor binaries. We only ship to arm64 Android
# headsets, and only use meta/pico/khronos vendors (per the three
# export presets in xr/export_presets.cfg) — so we extract just:
#
#   android/{debug,release}/godotopenxr-{khronos,meta,pico}-{debug,release}.aar
#   android/template_{debug,release}/arm64/libgodotopenxrvendors.so
#
#   plus the host-platform stubs needed by Godot's headless export so
#   it doesn't silently drop the addon during GDExtension verification:
#   macos/template_{debug,release}/libgodotopenxrvendors.macos.framework/
#   linux/template_{debug,release}/x86_64/libgodotopenxrvendors.so
#
# = 12 files / ~30 MB on disk after extraction. Lynx and Magic Leap
# vendor .aars are intentionally skipped (all three presets disable
# them). Windows binaries and Android x86_64 binaries are also skipped
# — plugin.gdextension still lists them but Godot tolerates their
# absence on non-Windows / non-emulator hosts.
#
# Why host binaries matter for an Android-only product:
#   When you run `godot --headless --export-release "Meta Quest"` on
#   macOS or Linux, Godot first does a GDExtension verification step
#   that attempts to dlopen the *host* platform's library. If the host
#   library isn't on disk, that addon's plugin.gdextension is silently
#   dropped, the .aar plugins never get listed to Gradle, and the
#   resulting APK is missing libgodotopenxrvendors.so + libopenxr_loader.so.
#   The app then fails at runtime with "library libopenxr_loader.so not found".
#
# Usage:
#     ./prepare.sh              # fetch missing binaries (idempotent / fast no-op)
#     ./prepare.sh --force      # re-download and overwrite
#     ./prepare.sh --check      # exit 0 if all present, else 1 (no network)

set -euo pipefail

UPSTREAM_TAG="4.3.1-stable"
UPSTREAM_URL="https://github.com/GodotVR/godot_openxr_vendors/releases/download/${UPSTREAM_TAG}/godotopenxrvendorsaddon.zip"
ZIP_PREFIX="asset/addons/godotopenxrvendors/.bin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$SCRIPT_DIR/.bin"

# Files we extract — paths are relative to .bin/.
FILES=(
  # Vendor .aar plugins (Android, target headsets)
  android/debug/godotopenxr-khronos-debug.aar
  android/debug/godotopenxr-meta-debug.aar
  android/debug/godotopenxr-pico-debug.aar
  android/release/godotopenxr-khronos-release.aar
  android/release/godotopenxr-meta-release.aar
  android/release/godotopenxr-pico-release.aar
  # Android arm64 .so (target headsets)
  android/template_debug/arm64/libgodotopenxrvendors.so
  android/template_release/arm64/libgodotopenxrvendors.so
  # Host-platform .so / framework (needed by Godot headless export
  # for GDExtension verification — see comment at top of file)
  macos/template_debug/libgodotopenxrvendors.macos.framework/libgodotopenxrvendors.macos
  macos/template_release/libgodotopenxrvendors.macos.framework/libgodotopenxrvendors.macos
  linux/template_debug/x86_64/libgodotopenxrvendors.so
  linux/template_release/x86_64/libgodotopenxrvendors.so
)

mode="fetch"
case "${1:-}" in
  --force) mode="force" ;;
  --check) mode="check" ;;
  "") ;;
  *) echo "Unknown arg: $1" >&2; echo "Usage: $0 [--force|--check]" >&2; exit 2 ;;
esac

mkdir -p "$DEST"

missing=()
for f in "${FILES[@]}"; do
  [[ -f "$DEST/$f" ]] || missing+=("$f")
done

if [[ "$mode" == "check" ]]; then
  if (( ${#missing[@]} == 0 )); then
    echo "[prepare-godotopenxrvendors] ✓ all ${#FILES[@]} binaries present"
    exit 0
  fi
  echo "[prepare-godotopenxrvendors] ✗ ${#missing[@]}/${#FILES[@]} binaries missing — run ./prepare.sh" >&2
  exit 1
fi

if [[ "$mode" == "fetch" ]] && (( ${#missing[@]} == 0 )); then
  echo "[prepare-godotopenxrvendors] all ${#FILES[@]} binaries already present — nothing to do (--force to re-fetch)"
  exit 0
fi

if [[ "$mode" == "force" ]]; then
  echo "[prepare-godotopenxrvendors] --force: re-fetching all ${#FILES[@]} binaries"
else
  echo "[prepare-godotopenxrvendors] ${#missing[@]}/${#FILES[@]} binaries missing — fetching from upstream"
fi
echo "[prepare-godotopenxrvendors] source: $UPSTREAM_TAG ($UPSTREAM_URL)"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT INT TERM

zip="$tmpdir/addon.zip"
# --retry rides through transient network errors; -L follows GitHub's
# redirect to the asset CDN.
curl -fL --retry 3 --retry-delay 2 -o "$zip" "$UPSTREAM_URL"

# Extract only what we need (paths in zip are prefixed by `asset/`).
zip_paths=()
for f in "${FILES[@]}"; do
  zip_paths+=("$ZIP_PREFIX/$f")
done
unzip -q "$zip" "${zip_paths[@]}" -d "$tmpdir"

# Sanity: verify each path landed before we touch DEST.
for f in "${FILES[@]}"; do
  if [[ ! -f "$tmpdir/$ZIP_PREFIX/$f" ]]; then
    echo "ERROR: upstream missing $ZIP_PREFIX/$f at tag $UPSTREAM_TAG" >&2
    echo "       The zip layout may have changed — check UPSTREAM_TAG in this script." >&2
    exit 1
  fi
done

# Copy into place.
for f in "${FILES[@]}"; do
  mkdir -p "$DEST/$(dirname "$f")"
  cp "$tmpdir/$ZIP_PREFIX/$f" "$DEST/$f"
done

bytes=$(du -ck "$DEST"/android/{debug,release,template_debug,template_release} 2>/dev/null | tail -1 | awk '{print $1}')
echo "[prepare-godotopenxrvendors] ✓ ${#FILES[@]} binaries written to .bin/ (~${bytes}K)"
