#!/usr/bin/env bash
# End-to-end upload test against the prod ingest endpoint.
#
# Same TUS flow the headset uses (POST → PATCH manifest → POST →
# chunked PATCH media → HEAD resume probe), targeted at the public
# HTTPS endpoint with Bearer-token auth.
#
# What this exercises:
#   • TLS handshake to operator.conductor-ai.top
#   • Authorization: Bearer <upload_token>
#   • TUS POST → 201 + Location
#   • Multi-chunk PATCH with mid-flight HEAD offset probe
#   • Schema-version gating
#   • Session finalization (manifest + media both land → onSession fires)
#
# What this does NOT exercise:
#   • The QR/ack handshake (we assume you already pasted the token).
#   • The /api/ingest-read download path (cookie-auth, not bearer).
#     Verify the session landed by opening it in the dashboard.
#
# Usage:
#   # 1) Grab your upload token from https://operator.conductor-ai.top/connect
#   export TOKEN='paste-the-long-base64-blob-here'
#
#   # 2a) Synthesize a 5s test MP4 with ffmpeg and upload it:
#   bash scripts/ego_upload_prod_mp4.sh
#
#   # 2b) Or point at an MP4 you already have on disk:
#   MP4=/path/to/recording.mp4 bash scripts/ego_upload_prod_mp4.sh
#
# Env knobs:
#   TOKEN          (required) Bearer upload token from /connect
#   BASE           Ingest base URL (default: https://operator.conductor-ai.top)
#   MP4            Path to an existing MP4. If unset, ffmpeg synthesizes one.
#   SESSION_ID     Override the auto-generated session id.
#   CHUNK_BYTES    PATCH chunk size (default 1 MiB)
#   DURATION_S     synthetic clip length (default 5)
#   VIDEO_SIZE     synthetic clip resolution WxH (default 640x360)
#   BITRATE        synthetic clip bitrate (default 4M)

set -euo pipefail

BASE="${BASE:-https://operator.conductor-ai.top}"
TOKEN="${TOKEN:-}"
MP4="${MP4:-}"
SESSION_ID="${SESSION_ID:-prod-probe-$(date +%s)-$$}"
CHUNK_BYTES="${CHUNK_BYTES:-1048576}"          # 1 MiB
DURATION_S="${DURATION_S:-5}"
VIDEO_SIZE="${VIDEO_SIZE:-640x360}"
BITRATE="${BITRATE:-4M}"
SCHEMA="spatialmp4.quest_capture.spool.v2"

if [ -z "$TOKEN" ]; then
  cat >&2 <<EOF
ERROR: TOKEN is required.

  1. Open ${BASE}/connect in a browser and log in.
  2. Copy the string under "Your upload token".
  3. Re-run:  TOKEN='<paste>' bash $0
EOF
  exit 2
fi

# --- helpers ----------------------------------------------------------------

b64() { printf '%s' "$1" | base64 | tr -d '\n'; }

curl_auth() {
  curl -sS -H "Authorization: Bearer $TOKEN" "$@"
}

filesize() {
  stat -f%z "$1" 2>/dev/null || stat -c%s "$1"
}

# Print a tagged log line.
log() { printf '\n▶ %s\n' "$*"; }

# --- preflight --------------------------------------------------------------

log "preflight"
echo "   BASE      = $BASE"
echo "   SESSION   = $SESSION_ID"
echo "   CHUNK     = $CHUNK_BYTES bytes"

# OPTIONS should return 204 + Tus-Version when token is good.
PROBE=$(curl_auth -o /dev/null -w '%{http_code}' \
  -X OPTIONS "$BASE/api/ingest" \
  -H 'Tus-Resumable: 1.0.0')
case "$PROBE" in
  204) echo "   OPTIONS   = 204 ✓ (TUS endpoint up, token accepted)" ;;
  401) echo "   OPTIONS   = 401 ✗ token rejected — re-copy from /connect"; exit 3 ;;
  *)   echo "   OPTIONS   = $PROBE ✗ unexpected — abort"; exit 3 ;;
esac

# --- prep MP4 ---------------------------------------------------------------

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [ -z "$MP4" ]; then
  command -v ffmpeg >/dev/null || { echo "ffmpeg required (or set MP4=...)" >&2; exit 2; }
  MP4="$TMP/clip.mp4"
  log "ffmpeg → $MP4  (${VIDEO_SIZE}, ${DURATION_S}s, ${BITRATE})"
  ffmpeg -y -hide_banner -loglevel error \
    -f lavfi -i "testsrc=size=${VIDEO_SIZE}:rate=30:duration=${DURATION_S}" \
    -f lavfi -i "sine=frequency=440:duration=${DURATION_S}" \
    -c:v libx264 -preset ultrafast -pix_fmt yuv420p -b:v "$BITRATE" \
    -c:a aac -movflags +faststart "$MP4"
fi

[ -f "$MP4" ] || { echo "MP4 not found: $MP4" >&2; exit 2; }
SIZE=$(filesize "$MP4")
echo "   media     = $MP4 ($SIZE bytes)"

# --- 1. manifest -----------------------------------------------------------

log "uploading manifest.json"
MANIFEST=$(cat <<JSON
{"schema":"$SCHEMA","session_id":"$SESSION_ID","probe":true,"source":"ego_upload_prod_mp4.sh"}
JSON
)
MSIZE=${#MANIFEST}
MMETA="session_id $(b64 "$SESSION_ID"),artifact_kind $(b64 manifest),filename $(b64 manifest.json),schema $(b64 "$SCHEMA")"

MLOC=$(curl_auth -i -X POST "$BASE/api/ingest" \
  -H 'Tus-Resumable: 1.0.0' \
  -H "Upload-Length: $MSIZE" \
  -H "Upload-Metadata: $MMETA" \
  | awk 'BEGIN{IGNORECASE=1} /^location:/ {print $2}' | tr -d '\r')
[ -n "$MLOC" ] || { echo "✗ manifest POST failed (no Location)" >&2; exit 4; }
echo "   Location  = $MLOC"

printf '%s' "$MANIFEST" | curl_auth -X PATCH "${BASE}${MLOC}" \
  -H 'Tus-Resumable: 1.0.0' \
  -H 'Content-Type: application/offset+octet-stream' \
  -H 'Upload-Offset: 0' \
  -H "Content-Length: $MSIZE" \
  --data-binary @- -o /dev/null -w "   PATCH     = %{http_code} in %{time_total}s\n"

# --- 2. media (chunked + mid-flight HEAD probe) -----------------------------

log "uploading media in ${CHUNK_BYTES}-byte chunks"
MEDIA_META="session_id $(b64 "$SESSION_ID"),artifact_kind $(b64 media),filename $(b64 "$(basename "$MP4")"),schema $(b64 "$SCHEMA")"

LOC=$(curl_auth -i -X POST "$BASE/api/ingest" \
  -H 'Tus-Resumable: 1.0.0' \
  -H "Upload-Length: $SIZE" \
  -H "Upload-Metadata: $MEDIA_META" \
  | awk 'BEGIN{IGNORECASE=1} /^location:/ {print $2}' | tr -d '\r')
[ -n "$LOC" ] || { echo "✗ media POST failed (no Location)" >&2; exit 4; }
echo "   Location  = $LOC"

OFFSET=0
COUNTER=0
while [ "$OFFSET" -lt "$SIZE" ]; do
  REMAINING=$((SIZE - OFFSET))
  N=$CHUNK_BYTES
  [ "$N" -gt "$REMAINING" ] && N=$REMAINING
  COUNTER=$((COUNTER + 1))
  PCT=$((100 * (OFFSET + N) / SIZE))

  # Slice the chunk to a temp file (faster + more portable than dd bs=1).
  CHUNK_FILE="$TMP/chunk"
  dd if="$MP4" of="$CHUNK_FILE" bs="$N" skip="$((OFFSET / N))" count=1 status=none 2>/dev/null || \
    dd if="$MP4" of="$CHUNK_FILE" bs=1 skip="$OFFSET" count="$N" status=none

  curl_auth -X PATCH "${BASE}${LOC}" \
      -H 'Tus-Resumable: 1.0.0' \
      -H 'Content-Type: application/offset+octet-stream' \
      -H "Upload-Offset: $OFFSET" \
      -H "Content-Length: $N" \
      --data-binary "@$CHUNK_FILE" -o /dev/null \
      -w "   chunk $(printf '%2d' "$COUNTER")  ${PCT}%%  PATCH %{http_code}  %{time_total}s\n"

  OFFSET=$((OFFSET + N))

  # After chunk 2, ask the server what offset it thinks it has — this
  # is the same resume probe ego_uploader.gd does after a network
  # blip. Server-side bytes-on-disk must match what we sent.
  if [ "$COUNTER" -eq 2 ] && [ "$OFFSET" -lt "$SIZE" ]; then
    HEAD_OFF=$(curl_auth -i -X HEAD "${BASE}${LOC}" \
      -H 'Tus-Resumable: 1.0.0' \
      | awk 'BEGIN{IGNORECASE=1} /^upload-offset:/ {print $2}' | tr -d '\r')
    if [ "$HEAD_OFF" = "$OFFSET" ]; then
      echo "   HEAD probe ✓ server offset $HEAD_OFF matches client $OFFSET"
    else
      echo "   HEAD probe ✗ server=$HEAD_OFF client=$OFFSET" >&2
      exit 5
    fi
  fi
done

# --- 3. final HEAD: server agrees the upload is complete --------------------

log "final HEAD"
FINAL_OFF=$(curl_auth -i -X HEAD "${BASE}${LOC}" \
  -H 'Tus-Resumable: 1.0.0' \
  | awk 'BEGIN{IGNORECASE=1} /^upload-offset:/ {print $2}' | tr -d '\r')
if [ "$FINAL_OFF" = "$SIZE" ]; then
  echo "   server offset $FINAL_OFF == media size $SIZE ✓"
else
  echo "   server offset $FINAL_OFF != $SIZE ✗" >&2
  exit 6
fi

cat <<EOF

✅ Upload complete.
   Session:   $SESSION_ID
   Dashboard: $BASE/sessions/$SESSION_ID

   Open the URL above in a browser (logged in as the same user the
   token belongs to) — you should see a session row with manifest +
   media artifacts, and the preview worker should kick off shortly.
EOF
