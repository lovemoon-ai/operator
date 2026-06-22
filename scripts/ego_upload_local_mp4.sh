#!/usr/bin/env bash
# Local end-to-end test of the @love-moon/ego-ingest TUS upload path
# against a running `npm run dev` instance under web/app.
#
# What it does:
#   1. Synthesizes a real MP4 with ffmpeg (color bars + tone).
#   2. Uploads a manifest.json artifact via TUS POST + PATCH.
#   3. Uploads the MP4 via TUS POST + chunked PATCH (default 256 KB
#      chunks so multi-chunk + resume paths are exercised).
#   4. After chunk 2, does a HEAD probe to verify the server's
#      Upload-Offset matches what we sent (mimics resume after Wi-Fi
#      drop). Continues from there.
#   5. Queries the read API for the session record.
#   6. Downloads the media artifact and `cmp`s it against the original.
#
# Usage:
#   # 1. Start the web app in another terminal:
#   cd web && npm run dev
#
#   # 2. Run this in the repo root:
#   tools/ego_upload_local_mp4.sh
#
# Env knobs:
#   PORT          web/app port (default 3000)
#   HOST          web/app host (default 127.0.0.1)
#   TOKEN         Bearer token if web/app was started with INGEST_TOKEN
#   CHUNK_BYTES   PATCH chunk size (default 262144 — 256 KB)
#   DURATION_S    synthetic MP4 length in seconds (default 5)
#   VIDEO_SIZE    "WxH" (default 640x360)
#   BITRATE       libx264 bitrate (default 4M)

set -euo pipefail

PORT="${PORT:-3000}"
HOST="${HOST:-127.0.0.1}"
TOKEN="${TOKEN:-}"
CHUNK_BYTES="${CHUNK_BYTES:-262144}"
DURATION_S="${DURATION_S:-5}"
VIDEO_SIZE="${VIDEO_SIZE:-640x360}"
BITRATE="${BITRATE:-4M}"

BASE="http://${HOST}:${PORT}"

curl_auth() {
  if [ -n "$TOKEN" ]; then
    curl -H "Authorization: Bearer $TOKEN" "$@"
  else
    curl "$@"
  fi
}

# --- preflight ---
command -v ffmpeg >/dev/null || { echo "ffmpeg required" >&2; exit 1; }
if ! curl_auth -s -o /dev/null --connect-timeout 2 -X OPTIONS "${BASE}/api/ingest"; then
  echo "ERROR: ${BASE}/api/ingest not reachable. Start: cd web && npm run dev" >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
SESS="mp4-local-$(date +%s)-$$"
echo "▶ session_id: $SESS"
echo "▶ ingest:     ${BASE}/api/ingest"
echo "▶ chunk:      ${CHUNK_BYTES} bytes"

# --- 1. synthesize MP4 ---
echo "▶ ffmpeg → $TMP/clip.mp4 (${VIDEO_SIZE}, ${DURATION_S}s, ${BITRATE})"
ffmpeg -y -hide_banner -loglevel error \
  -f lavfi -i "testsrc=size=${VIDEO_SIZE}:rate=30:duration=${DURATION_S}" \
  -f lavfi -i "sine=frequency=440:duration=${DURATION_S}" \
  -c:v libx264 -preset ultrafast -pix_fmt yuv420p -b:v "$BITRATE" \
  -c:a aac -movflags +faststart "$TMP/clip.mp4"
SIZE=$(stat -f%z "$TMP/clip.mp4" 2>/dev/null || stat -c%s "$TMP/clip.mp4")
echo "  clip.mp4 = $SIZE bytes"

# Helper: TUS POST (returns Location path)
tus_create() {
  local upload_len="$1" filename="$2" kind="$3"
  local meta="session_id $(printf '%s' "$SESS" | base64),artifact_kind $(printf '%s' "$kind" | base64),filename $(printf '%s' "$filename" | base64),schema $(printf 'spatialmp4.quest_capture.spool.v3' | base64)"
  curl_auth -s -i -X POST "${BASE}/api/ingest" \
    -H 'Tus-Resumable: 1.0.0' \
    -H "Upload-Length: $upload_len" \
    -H "Upload-Metadata: $meta" \
    | awk '/^Location:/ {print $2}' | tr -d '\r'
}

# --- 2. manifest ---
echo
echo "▶ uploading manifest.json"
MANIFEST_BODY="{\"schema\":\"spatialmp4.quest_capture.spool.v3\",\"session_id\":\"$SESS\",\"local_smoke\":true,\"source\":\"ego_upload_local_mp4.sh\"}"
MSIZE=${#MANIFEST_BODY}
MLOC=$(tus_create "$MSIZE" "manifest.json" "manifest")
[ -n "$MLOC" ] || { echo "✗ manifest POST failed" >&2; exit 2; }
printf '%s' "$MANIFEST_BODY" | curl_auth -s -X PATCH "${BASE}${MLOC}" \
  -H 'Tus-Resumable: 1.0.0' \
  -H 'Content-Type: application/offset+octet-stream' \
  -H 'Upload-Offset: 0' \
  -H "Content-Length: $MSIZE" \
  --data-binary @- -o /dev/null -w "  manifest PATCH %{http_code}\n"

# --- 3. media (chunked) ---
echo
echo "▶ uploading clip.mp4 in ${CHUNK_BYTES}-byte chunks"
LOC=$(tus_create "$SIZE" "clip.mp4" "media")
[ -n "$LOC" ] || { echo "✗ media POST failed" >&2; exit 2; }
echo "  location: $LOC"

OFFSET=0
COUNTER=0
while [ "$OFFSET" -lt "$SIZE" ]; do
  REMAINING=$((SIZE - OFFSET))
  N=$CHUNK_BYTES
  [ "$N" -gt "$REMAINING" ] && N=$REMAINING
  COUNTER=$((COUNTER + 1))
  PCT=$((100 * (OFFSET + N) / SIZE))
  dd if="$TMP/clip.mp4" bs=1 skip="$OFFSET" count="$N" status=none | \
  curl_auth -s -X PATCH "${BASE}${LOC}" \
      -H 'Tus-Resumable: 1.0.0' \
      -H 'Content-Type: application/offset+octet-stream' \
      -H "Upload-Offset: $OFFSET" \
      -H "Content-Length: $N" \
      --data-binary @- -o /dev/null -w "  chunk $COUNTER  ${PCT}%  PATCH %{http_code}  %{time_total}s\n"
  OFFSET=$((OFFSET + N))

  # After chunk 2, mimic a network drop: HEAD probe to confirm the
  # server agrees about Upload-Offset before continuing.
  if [ "$COUNTER" -eq 2 ] && [ "$OFFSET" -lt "$SIZE" ]; then
    HEAD_OFFSET=$(curl_auth -s -i -X HEAD "${BASE}${LOC}" \
      -H 'Tus-Resumable: 1.0.0' \
      | awk '/^Upload-Offset:/ {print $2}' | tr -d '\r')
    if [ "$HEAD_OFFSET" = "$OFFSET" ]; then
      echo "  HEAD probe: server offset $HEAD_OFFSET ✓ (resume works)"
    else
      echo "  HEAD probe: server offset $HEAD_OFFSET, client $OFFSET ✗" >&2
      exit 3
    fi
  fi
done

# --- 4. verify ---
echo
echo "▶ session record"
curl_auth -s "${BASE}/api/ingest-read/sessions/$SESS" | python3 -m json.tool

echo
echo "▶ download + compare"
curl_auth -s "${BASE}/api/ingest-read/sessions/$SESS/artifacts/media" -o "$TMP/downloaded.mp4"
if cmp "$TMP/clip.mp4" "$TMP/downloaded.mp4"; then
  echo "✓ downloaded MP4 matches original byte-for-byte"
else
  echo "✗ downloaded MP4 differs from original" >&2
  exit 4
fi

echo
echo "▶ detail page video element"
curl -s "${BASE}/sessions/$SESS" | grep -oE '<video[^>]*src="[^"]*"' | head -1 || \
  echo "(detail page not reached — ok if you tested against a non-app server)"

echo
echo "✅ ALL PASS  ·  session in dashboard: ${BASE}/sessions/$SESS"
