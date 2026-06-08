#!/usr/bin/env bash
# Build the XR Quest release APK, stamp it with a tag + timestamp, then
# create an annotated git tag and push it to the remote.
#
# Flow:
#   1. Resolve VERSION (arg or default) and a UTC build timestamp.
#   2. cd xr && make build-quest  ->  xr/build/quest/Operator.apk
#   3. Copy the APK to xr/dist/Operator-<TAG>.apk where
#        TAG = quest-v<VERSION>-<TIMESTAMP>   (always unique)
#   4. Create an annotated git tag <TAG> at HEAD and push it to origin.
#
# Usage:
#   bash scripts/release_and_tag.sh [VERSION]
#
#   # default VERSION (0.1.0):
#   bash scripts/release_and_tag.sh
#
#   # explicit version:
#   bash scripts/release_and_tag.sh 1.2.0
#
# Env knobs:
#   VERSION    Release version (default: 0.1.0). Arg $1 overrides this.
#   REMOTE     Git remote to push the tag to (default: origin).
#   DIST_DIR   Where the renamed APK is copied (default: xr/dist).
#   SKIP_BUILD Set to 1 to reuse an existing xr/build/quest/Operator.apk.
#   NO_PUSH    Set to 1 to create the tag locally but skip the push.
#   NO_RELEASE Set to 1 to skip creating the GitHub Release / APK upload.

set -euo pipefail

# --- locate repo root regardless of CWD ------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
XR_DIR="$REPO_ROOT/xr"

# --- config ----------------------------------------------------------------
VERSION="${1:-${VERSION:-0.1.0}}"
REMOTE="${REMOTE:-origin}"
DIST_DIR="${DIST_DIR:-$XR_DIR/dist}"
APK_SRC="$XR_DIR/build/quest/Operator.apk"

TIMESTAMP="$(date -u +%Y%m%d-%H%M%S)"
TAG="quest-v${VERSION}-${TIMESTAMP}"
APK_OUT="$DIST_DIR/Operator-${TAG}.apk"

log()  { printf '\033[1;34m[release]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[release] ERROR:\033[0m %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

# Godot bakes the Android versionName/versionCode from export_presets.cfg, not
# from the git tag. We patch the "Meta Quest" preset in place before export and
# restore it afterwards so the working tree stays clean — same backup/restore
# idiom the Makefile uses for AndroidManifest.xml.
EXPORT_PRESETS="$XR_DIR/export_presets.cfg"
PRESETS_BAK=""
restore_presets() {
    if [ -n "$PRESETS_BAK" ] && [ -f "$PRESETS_BAK" ]; then
        mv -f "$PRESETS_BAK" "$EXPORT_PRESETS"
        PRESETS_BAK=""
    fi
}
trap restore_presets EXIT

sync_version_into_preset() {
    [ -f "$EXPORT_PRESETS" ] || { log "WARN: $EXPORT_PRESETS missing — skipping version sync"; return; }
    PRESETS_BAK="$(mktemp)"
    cp "$EXPORT_PRESETS" "$PRESETS_BAK"
    log "Sync version into Meta Quest preset: name=${VERSION} code=${VERSION_CODE}"
    # target becomes 1 inside the "Meta Quest" preset and resets at the next
    # preset's name= line, so only that preset's version fields are touched.
    awk -v ver="$VERSION" -v code="$VERSION_CODE" '
        /^name=/ { target = ($0 == "name=\"Meta Quest\"") }
        target && /^version\/name=/ { print "version/name=\"" ver "\""; next }
        target && /^version\/code=/ { print "version/code=" code; next }
        { print }
    ' "$PRESETS_BAK" > "$EXPORT_PRESETS"
}

# --- preflight checks ------------------------------------------------------
command -v git  >/dev/null 2>&1 || die "git not found on PATH"
[ -d "$XR_DIR" ] || die "xr/ directory not found at $XR_DIR"

cd "$REPO_ROOT"

# Must be inside a git repo with at least one commit.
git rev-parse --git-dir >/dev/null 2>&1 || die "not inside a git repository"
COMMIT="$(git rev-parse --short HEAD)" || die "no commits at HEAD"

# Android versionCode must be a monotonically increasing integer; the commit
# count is monotonic and bumps on every release commit.
VERSION_CODE="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

# Refuse to overwrite an existing tag.
if git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null; then
    die "tag '${TAG}' already exists locally"
fi

log "Version   : ${VERSION}"
log "Timestamp : ${TIMESTAMP} (UTC)"
log "Tag       : ${TAG}"
log "Commit    : ${COMMIT}"
log "Remote    : ${REMOTE}"

# --- build -----------------------------------------------------------------
if [ "${SKIP_BUILD:-0}" = "1" ]; then
    log "SKIP_BUILD=1 — reusing existing APK"
    [ -f "$APK_SRC" ] || die "SKIP_BUILD set but $APK_SRC is missing"
else
    sync_version_into_preset
    log "Building Quest release APK (make build-quest)…"
    make -C "$XR_DIR" build-quest
    restore_presets
fi

[ -f "$APK_SRC" ] || die "expected APK not found at $APK_SRC"

# --- stamp / copy ----------------------------------------------------------
mkdir -p "$DIST_DIR"
cp -f "$APK_SRC" "$APK_OUT"
APK_SIZE="$(du -h "$APK_OUT" | cut -f1)"
log "APK -> ${APK_OUT} (${APK_SIZE})"

# --- tag -------------------------------------------------------------------
log "Creating annotated tag ${TAG}…"
git tag -a "$TAG" -m "Quest release ${VERSION}

Built: ${TIMESTAMP} UTC
Commit: ${COMMIT}
APK: $(basename "$APK_OUT")"

# --- push ------------------------------------------------------------------
if [ "${NO_PUSH:-0}" = "1" ]; then
    log "NO_PUSH=1 — tag created locally, not pushed."
    log "Push later with: git push ${REMOTE} ${TAG}"
    log "Done. Release artifact: ${APK_OUT}"
    exit 0
fi

log "Pushing tag to ${REMOTE}…"
git push "$REMOTE" "$TAG"
log "Pushed ${TAG} to ${REMOTE}."

# --- GitHub Release + APK asset --------------------------------------------
# A git tag only appears on the Tags page; to attach the APK we create a
# GitHub Release for the tag and upload the APK as a release asset.
if [ "${NO_RELEASE:-0}" = "1" ]; then
    log "NO_RELEASE=1 — skipping GitHub Release."
elif ! command -v gh >/dev/null 2>&1; then
    log "WARN: gh CLI not found — skipping GitHub Release."
    log "Create it later with: gh release create ${TAG} \"${APK_OUT}\" -t \"${TAG}\" --generate-notes"
else
    log "Creating GitHub Release ${TAG} and uploading APK…"
    gh release create "$TAG" "$APK_OUT" \
        --title "$TAG" \
        --notes "Quest release ${VERSION} (versionCode ${VERSION_CODE})

Built: ${TIMESTAMP} UTC
Commit: ${COMMIT}
APK: $(basename "$APK_OUT")"
    log "GitHub Release published: $(gh repo view --json url -q .url 2>/dev/null)/releases/tag/${TAG}"
fi

log "Done. Release artifact: ${APK_OUT}"
