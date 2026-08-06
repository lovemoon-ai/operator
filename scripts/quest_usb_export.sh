#!/usr/bin/env bash
# Export one completed Quest Ego recording over USB/ADB, verify every byte,
# then remove only that verified session from the Quest.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  bash scripts/quest_usb_export.sh \
    --quest-root <absolute Quest recording root> \
    --session-id <session id> \
    [--output-root <computer directory>] \
    [--serial <adb serial>] \
    [--yes]

Required:
  --quest-root   Recording root on the Quest. There is deliberately no default.
  --session-id   Completed session to export.

Optional:
  --output-root  Parent directory on this computer (default: tmp_data/quest).
  --serial       Select a Quest when more than one ADB device is visible.
  --yes          Skip the typed deletion confirmation.
  -h, --help     Show this help.

Expected device layout under QUEST_ROOT:
  <session-id>.mp4
  <session-id>/manifest.json
  <session-id>/... additional sidecars ...

Result on this computer:
  OUTPUT_ROOT/<session-id>/media.mp4
  OUTPUT_ROOT/<session-id>/manifest.json
  OUTPUT_ROOT/<session-id>/sidecars/...

The device files are deleted only after the MP4 and every sidecar match their
device SHA-256 checksums, manifest.json parses as JSON, and the verified export
has been moved into its final destination.
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '▶ %s\n' "$*"
}

ok() {
  printf '✓ %s\n' "$*"
}

QUEST_ROOT=""
SESSION_ID=""
OUTPUT_ROOT="tmp_data/quest"
ADB_SERIAL=""
ASSUME_YES=0
ADB_BIN="${ADB_BIN:-adb}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --quest-root)
      [ "$#" -ge 2 ] || die "--quest-root requires a value"
      QUEST_ROOT="$2"
      shift 2
      ;;
    --session-id)
      [ "$#" -ge 2 ] || die "--session-id requires a value"
      SESSION_ID="$2"
      shift 2
      ;;
    --output-root)
      [ "$#" -ge 2 ] || die "--output-root requires a value"
      OUTPUT_ROOT="$2"
      shift 2
      ;;
    --serial)
      [ "$#" -ge 2 ] || die "--serial requires a value"
      ADB_SERIAL="$2"
      shift 2
      ;;
    --yes)
      ASSUME_YES=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[ -n "$QUEST_ROOT" ] || die "--quest-root is required; specify the Quest recording root explicitly"
[ -n "$SESSION_ID" ] || die "--session-id is required"
[ -n "$OUTPUT_ROOT" ] || die "--output-root cannot be empty"

while [ "$QUEST_ROOT" != "/" ] && [[ "$QUEST_ROOT" == */ ]]; do
  QUEST_ROOT="${QUEST_ROOT%/}"
done

[[ "$QUEST_ROOT" == /* ]] || die "--quest-root must be an absolute Quest path"
[[ "$QUEST_ROOT" =~ ^/[A-Za-z0-9._/-]+$ ]] || die "--quest-root contains unsupported characters"
case "/${QUEST_ROOT#/}/" in
  *"/../"*|*"/./"*) die "--quest-root must not contain . or .. path components" ;;
esac
case "$QUEST_ROOT" in
  /|/sdcard|/storage|/storage/emulated|/storage/emulated/0)
    die "refusing unsafe or overly broad Quest root: $QUEST_ROOT"
    ;;
  /sdcard/*|/storage/*)
    ;;
  *)
    die "--quest-root must be below /sdcard or /storage"
    ;;
esac

[[ "$SESSION_ID" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || \
  die "--session-id may contain only letters, digits, dot, underscore, and dash"
[ "$SESSION_ID" != "." ] && [ "$SESSION_ID" != ".." ] || die "unsafe session id"

command -v "$ADB_BIN" >/dev/null 2>&1 || die "adb not found: $ADB_BIN"
command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required on this computer"
command -v python3 >/dev/null 2>&1 || die "python3 is required to validate manifest.json"

if [ -z "$ADB_SERIAL" ]; then
  mapfile -t DEVICE_ROWS < <("$ADB_BIN" devices | awk 'NR > 1 && NF >= 2 { print $1 "\t" $2 }')
  [ "${#DEVICE_ROWS[@]}" -eq 1 ] || {
    "$ADB_BIN" devices -l >&2
    die "expected exactly one ADB device; connect one Quest or pass --serial"
  }
  IFS=$'\t' read -r ADB_SERIAL DEVICE_STATE <<<"${DEVICE_ROWS[0]}"
  [ "$DEVICE_STATE" = "device" ] || die "ADB device $ADB_SERIAL is $DEVICE_STATE; authorize it in the headset"
fi

ADB=("$ADB_BIN" -s "$ADB_SERIAL")
adb_cmd() {
  "${ADB[@]}" "$@"
}

[ "$(adb_cmd get-state 2>/dev/null)" = "device" ] || die "ADB device is not ready: $ADB_SERIAL"
adb_cmd shell command -v sha256sum >/dev/null 2>&1 || \
  die "sha256sum is unavailable on the Quest; refusing an unverifiable export"

REMOTE_MP4="$QUEST_ROOT/$SESSION_ID.mp4"
REMOTE_SIDECARS="$QUEST_ROOT/$SESSION_ID"
REMOTE_MANIFEST="$REMOTE_SIDECARS/manifest.json"

adb_cmd shell test -f "$REMOTE_MP4" || die "MP4 not found on Quest: $REMOTE_MP4"
adb_cmd shell test -d "$REMOTE_SIDECARS" || die "sidecar directory not found on Quest: $REMOTE_SIDECARS"
adb_cmd shell test -f "$REMOTE_MANIFEST" || die "manifest.json not found on Quest: $REMOTE_MANIFEST"

printf '%s\n' "Quest device:  $ADB_SERIAL"
printf '%s\n' "Quest MP4:     $REMOTE_MP4"
printf '%s\n' "Quest sidecars: $REMOTE_SIDECARS"
printf '%s\n' "Computer root: $OUTPUT_ROOT"
printf '%s\n' "After verification, only the MP4 and sidecar directory shown above will be deleted from the Quest."

if [ "$ASSUME_YES" -ne 1 ]; then
  [ -t 0 ] || die "interactive confirmation required; run in a terminal or pass --yes"
  printf 'Type the session id (%s) to confirm export and post-verification deletion: ' "$SESSION_ID"
  read -r CONFIRM_SESSION
  [ "$CONFIRM_SESSION" = "$SESSION_ID" ] || die "confirmation did not match; nothing was copied or deleted"
fi

mkdir -p "$OUTPUT_ROOT"
DESTINATION="$OUTPUT_ROOT/$SESSION_ID"
[ ! -e "$DESTINATION" ] && [ ! -L "$DESTINATION" ] || \
  die "destination already exists; refusing to overwrite: $DESTINATION"

STAGING="$OUTPUT_ROOT/.${SESSION_ID}.partial.$$"
[ ! -e "$STAGING" ] && [ ! -L "$STAGING" ] || die "staging path already exists: $STAGING"
mkdir -p "$STAGING/.verification"

cleanup() {
  if [ -n "${STAGING:-}" ] && [ -d "$STAGING" ]; then
    case "$(basename "$STAGING")" in
      ".${SESSION_ID}.partial."*) rm -rf -- "$STAGING" ;;
    esac
  fi
}
trap cleanup EXIT

remote_sidecar_manifest() {
  adb_cmd shell "cd '$REMOTE_SIDECARS' && find . -type f -exec sha256sum '{}' ';' | LC_ALL=C sort" | tr -d '\r'
}

log "Snapshotting Quest checksums before copy"
REMOTE_MEDIA_SHA_BEFORE="$(adb_cmd shell sha256sum "$REMOTE_MP4" | tr -d '\r' | awk '{print $1}')"
[ -n "$REMOTE_MEDIA_SHA_BEFORE" ] || die "could not checksum Quest MP4"
remote_sidecar_manifest > "$STAGING/.verification/remote-sidecars-before.sha256"
SIDECAR_COUNT="$(wc -l < "$STAGING/.verification/remote-sidecars-before.sha256" | tr -d ' ')"
[ "$SIDECAR_COUNT" -gt 0 ] || die "sidecar directory contains no files"

log "Copying MP4"
adb_cmd pull "$REMOTE_MP4" "$STAGING/media.mp4"

log "Copying all sidecars"
adb_cmd pull "$REMOTE_SIDECARS" "$STAGING/sidecars"

[ -s "$STAGING/media.mp4" ] || die "copied MP4 is missing or empty"
[ -f "$STAGING/sidecars/manifest.json" ] || die "copied sidecars do not contain manifest.json"
python3 -m json.tool "$STAGING/sidecars/manifest.json" >/dev/null || \
  die "copied manifest.json is not valid JSON"

(cd "$STAGING/sidecars" && find . -type f -exec sha256sum '{}' ';' | LC_ALL=C sort) \
  > "$STAGING/.verification/local-sidecars.sha256"
remote_sidecar_manifest > "$STAGING/.verification/remote-sidecars-after.sha256"
REMOTE_MEDIA_SHA_AFTER="$(adb_cmd shell sha256sum "$REMOTE_MP4" | tr -d '\r' | awk '{print $1}')"
LOCAL_MEDIA_SHA="$(sha256sum "$STAGING/media.mp4" | awk '{print $1}')"

[ "$REMOTE_MEDIA_SHA_BEFORE" = "$REMOTE_MEDIA_SHA_AFTER" ] || \
  die "Quest MP4 changed during copy; device data was not deleted"
[ "$REMOTE_MEDIA_SHA_BEFORE" = "$LOCAL_MEDIA_SHA" ] || \
  die "copied MP4 checksum mismatch; device data was not deleted"
cmp -s "$STAGING/.verification/remote-sidecars-before.sha256" \
  "$STAGING/.verification/remote-sidecars-after.sha256" || \
  die "Quest sidecars changed during copy; device data was not deleted"
cmp -s "$STAGING/.verification/remote-sidecars-before.sha256" \
  "$STAGING/.verification/local-sidecars.sha256" || \
  die "copied sidecar checksum mismatch; device data was not deleted"

cp -- "$STAGING/sidecars/manifest.json" "$STAGING/manifest.json"
cmp -s "$STAGING/manifest.json" "$STAGING/sidecars/manifest.json" || \
  die "top-level manifest copy failed; device data was not deleted"
rm -rf -- "$STAGING/.verification"

mv -- "$STAGING" "$DESTINATION"
STAGING=""
ok "verified MP4, valid manifest.json, and $SIDECAR_COUNT sidecar files"
ok "saved export to $DESTINATION"

log "Deleting the verified session from the Quest"
adb_cmd shell rm -f "$REMOTE_MP4"
adb_cmd shell rm -rf "$REMOTE_SIDECARS"

if adb_cmd shell test -e "$REMOTE_MP4"; then
  die "local export is safe, but Quest MP4 deletion failed: $REMOTE_MP4"
fi
if adb_cmd shell test -e "$REMOTE_SIDECARS"; then
  die "local export is safe, but Quest sidecar deletion failed: $REMOTE_SIDECARS"
fi

ok "removed the verified Quest MP4 and sidecars"
printf '\nExport complete:\n  %s\n  %s\n  %s\n' \
  "$DESTINATION/media.mp4" \
  "$DESTINATION/manifest.json" \
  "$DESTINATION/sidecars"
