#!/usr/bin/env bash
# Release the current VERSION: build the XR Quest APK, tag HEAD v<VERSION>,
# push the tag, and attach the APK to its GitHub Release. Pushing the tag also
# runs .github/workflows/python-release.yml, which publishes operator-xr to PyPI.
#
# Flow:
#   1. Read VERSION and check every component agrees (scripts/version.py).
#   2. cd xr && make build-quest  ->  xr/build/quest/Operator.apk
#      (the operator-features export plugin stamps versionName = VERSION and
#      versionCode = commit count)
#   3. Copy the APK to xr/dist/Operator-v<VERSION>-quest.apk.
#   4. Create an annotated git tag v<VERSION> at HEAD and push it to origin.
#
# Bump the version first (python3 scripts/version.py set X.Y.Z), merge that to
# main, then run this from the up-to-date main checkout:
#   bash scripts/release_and_tag.sh
#
# Env knobs:
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
VERSION="$(cat "$REPO_ROOT/VERSION")"
REMOTE="${REMOTE:-origin}"
DIST_DIR="${DIST_DIR:-$XR_DIR/dist}"
APK_SRC="$XR_DIR/build/quest/Operator.apk"

TIMESTAMP="$(date -u +%Y%m%d-%H%M%S)"
TAG="v${VERSION}"
APK_OUT="$DIST_DIR/Operator-${TAG}-quest.apk"

log()  { printf '\033[1;34m[release]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[release] ERROR:\033[0m %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

[ "$#" -eq 0 ] || die "takes no arguments; the version comes from VERSION (bump it with: python3 scripts/version.py set X.Y.Z)"

# --- preflight checks ------------------------------------------------------
command -v git  >/dev/null 2>&1 || die "git not found on PATH"
[ -d "$XR_DIR" ] || die "xr/ directory not found at $XR_DIR"

cd "$REPO_ROOT"
python3 scripts/version.py check || die "component versions disagree with VERSION"

# Must be inside a git repo with at least one commit.
git rev-parse --git-dir >/dev/null 2>&1 || die "not inside a git repository"
COMMIT="$(git rev-parse --short HEAD)" || die "no commits at HEAD"

# Same versionCode the export plugin stamps into the APK.
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
    log "Building Quest release APK (make build-quest)…"
    make -C "$XR_DIR" build-quest
fi

[ -f "$APK_SRC" ] || die "expected APK not found at $APK_SRC"

# --- stamp / copy ----------------------------------------------------------
mkdir -p "$DIST_DIR"
cp -f "$APK_SRC" "$APK_OUT"
APK_SIZE="$(du -h "$APK_OUT" | cut -f1)"
log "APK -> ${APK_OUT} (${APK_SIZE})"

# --- tag -------------------------------------------------------------------
log "Creating annotated tag ${TAG}…"
git tag -a "$TAG" -m "Operator ${TAG}

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
        --notes "Operator ${TAG}: Quest APK (versionCode ${VERSION_CODE})

Built: ${TIMESTAMP} UTC
Commit: ${COMMIT}
APK: $(basename "$APK_OUT")"
    log "GitHub Release published: $(gh repo view --json url -q .url 2>/dev/null)/releases/tag/${TAG}"
fi

log "Done. Release artifact: ${APK_OUT}"
