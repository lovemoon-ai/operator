# web/

Web tier for Operator.

```
web/
├── app/                   ← Next.js 15 data-management / review app
│   ├── app/               ← App Router pages (home, /stats, /sessions/[id])
│   ├── components/        ← shared client components
│   ├── lib/               ← ingest singleton, reviews store, formatters
│   ├── server.ts          ← custom Express+Next server (mounts TUS ingest)
│   └── package.json
└── modules/
    └── ego-ingest/        ← @love-moon/ego-ingest library (workspace dep)
        ├── src/
        └── package.json
```

This is an **npm workspace**. Install once at the root and both
packages share `node_modules`:

```bash
cd web
npm install
```

## Run the data-management app

```bash
cd web
npm run dev
# → http://localhost:3000/
```

The dev server is `tsx watch server.ts`. It boots a single Express
process that:

- mounts the `@love-moon/ego-ingest` TUS middleware at `/api/ingest`
  (this is where the XR client uploads),
- exposes the read API at `/api/ingest-read/*` (consumed by the UI),
- exposes per-session review state at `/api/reviews/*`,
- delegates everything else to Next.js.

Configure via env vars:

| var | default | meaning |
|-----|---------|---------|
| `PORT` | `3000` | listen port; dev auto-uses the next free port when unset |
| `DATA_ROOT` | `./data` | sessions + `operator.db` (sqlite) live here |
| `MAX_BYTES` | `100 GB` | hard cap on Upload-Length |
| `AUTH_SESSION_SECRET` | dev fallback | iron-session cookie secret (32+ chars) |
| `AUTH_BASE_URL` | `http://localhost:<PORT>` | origin the app advertises in cookies / redirects |
| `DEV_USER_SUB` | `dev@localhost` | dev user's `sub` (web tier is local-only / single-user) |
| `FFMPEG_BIN` | `ffmpeg` | binary used by the preview worker |
| `PREVIEW_TRANSCODE` | unset | when `1`, re-encode preview to H.264 instead of stream-copy |
| `UV_BIN` | `uv` | uv binary used to run the rerun sidecar |
| `RERUN_PYTHON_BIN` | unset | escape hatch: run sidecar with this Python directly, bypassing uv (deps must already be installed) |
| `SPATIALMP4_HOME` | autodetect | local SpatialMP4 SDK checkout; sidecar uses its prebuilt `.so` |
| `RERUN_TOPK_FRAMES` | unset (unlimited) | cap on RGB+depth frames logged into the .rrd |
| `RERUN_JPEG_QUALITY` | `85` | JPEG quality for RGB frames stored in the .rrd |
| `RERUN_DISABLED` | unset | when `1`, skip the rerun worker entirely |

## Post-ingest workers

After a session's `media` artifact lands, two derivation workers run
sequentially (see `app/lib/workers/`):

1. **preview** — `ffmpeg -map 0:v:0 -map 0:a? -c copy -movflags +faststart`
   strips the FFV1 depth track and all `mett` timed-metadata
   tracks out of the SpatialMP4, leaving a clean RGB-only MP4 the
   browser can `<video>` inline. Set `PREVIEW_TRANSCODE=1` to swap the
   stream-copy for an H.264 re-encode (slower, but plays on Firefox /
   Linux Chrome).

2. **rerun** — invokes `app/scripts/spatialmp4_to_rrd.py` which uses
   the [SpatialMP4 SDK](https://github.com/Pico-Developer/SpatialMP4)
   (same one as the reference visualizer
   `examples/python/visualize_rerun_quest.py` in that repo) to read
   the container, then logs RGB / depth / head trajectory /
   controller poses / hand joints into a Rerun `.rrd` that the
   embedded `@rerun-io/web-viewer` loads in the session detail page.

   Coordinate conventions match the SDK reference verbatim
   (`world = RUB`, camera Pinhole = `RDF`, head gaze along local
   `-Z`, `T_W_camera = T_W_head ⋅ T_imu_camera` with SVD reproject),
   so a coordinate-frame intuition built against the local viewer
   transfers 1-for-1 to the embedded one.

   Captures that intentionally disable head pose still produce an RRD with
   2D RGB/depth plus absolute controller, hand, body, and input streams. The
   converter omits world-space camera transforms, head-relative views, and
   camera-image overlays because those cannot be reconstructed without the
   head trajectory. Mono RGB captures are reassembled before logging because
   the pinned SpatialMP4 SDK exposes every decoded video frame as two halves.

   The sidecar's Python environment is managed by
   [`uv`](https://docs.astral.sh/uv/) via PEP 723 inline metadata at
   the top of the script — `rerun-sdk`, `numpy`, `scipy`, and
   `opencv-python` resolve on first run, cached after. The
   SpatialMP4 SDK itself is **not** on PyPI; we expect a local
   checkout (auto-detected via `SPATIALMP4_HOME`, Operator's shared
   `.deps/src/SpatialMP4` cache, or these legacy dev paths, first
   match wins):

   * `$OPERATOR_DEPS_CACHE_ROOT/src/SpatialMP4`
   * `<repo>/.deps/src/SpatialMP4`
   * `$HOME/ws/spatialmp4-quest/SpatialMP4`
   * `$HOME/spatialmp4-quest/SpatialMP4`
   * `$HOME/SpatialMP4`

   The sidecar's bootstrap walks the checkout for a
   `spatialmp4.cpython-<abi>-<plat>.so` matching its own Python
   ABI (uv picks 3.13 by default) and prepends that directory to
   `sys.path`.

   One-time setup:

   ```bash
   # 1. uv + ffmpeg for the preview worker
   brew install ffmpeg uv             # macOS
   # or: sudo apt install ffmpeg && curl -LsSf https://astral.sh/uv/install.sh | sh

   # 2. SpatialMP4 SDK — sync into .deps and build once for the
   # Python ABI uv will pick.
   scripts/setup_spatialmp4.sh
   ```

   Subsequent ingests just trigger `uv run --script …`, which is
   ~instant after the first warm-up. The worker fails open: missing
   uv / missing SDK / sidecar exception → the Rerun panel hides
   itself, the `<video>` preview still works. Check the dev-server
   log for the `[workers] rerun …` line.

## Identity

The web tier is **local-only**. Every install runs a single fixed dev
user (`DEV_USER_SUB`, default `dev@localhost`); the browser flow stamps
an iron-session cookie for that user via `/auth/start` and skips any
remote SSO.

- Headsets authenticate via a **per-user upload token**. The dev user
  has exactly one token, displayed on `/connect`. The QR ack endpoint
  hands the token to the device after verifying the 5-minute signed
  ticket — the device never has to type it.
- Reads and writes are still scoped to `req.user`, so if you ever
  re-introduce multi-user auth the rest of the stack already respects
  it.

## Demo seeding (optional)

Drop seed files into `$DATA_ROOT/seed/` to give every newly-logged-in
user a pre-baked sample session so they can see playback / Rerun /
review without owning a headset:

```
$DATA_ROOT/seed/manifest.json
$DATA_ROOT/seed/media.mp4
$DATA_ROOT/seed/preview.mp4    # optional, regenerable by the worker
$DATA_ROOT/seed/session.rrd    # optional, regenerable by the worker
```

The seed is hardlinked into `$DATA_ROOT/sessions/<userId>-demo/` on
first login and the user's `seeded` flag is set so it doesn't recreate.

## Point the XR client at it

In the headset's Ego settings panel:

- **Upload URL**: `http://<your-mac-ip>:3000/api/ingest`
- **Bearer token**: filled automatically by the `/connect` QR scan
- **Auto-upload on stop**: ON

After tapping Stop, the recording appears in the dashboard within a
few seconds. The header's "live" indicator turns green while the
SSE stream is open — pages refresh automatically.

## Smoke test without a headset

The dev user's upload token sits in the sqlite DB:

```bash
npm run dev &
sleep 4
# log in once so the users row exists, then pull the token
curl -s http://localhost:3000/auth/start >/dev/null
TOKEN=$(sqlite3 ./data/operator.db "SELECT upload_token FROM users LIMIT 1;")

META="session_id $(printf 'demo-1' | base64),artifact_kind $(printf 'manifest' | base64),filename $(printf 'manifest.json' | base64)"

LOC=$(curl -s -i -X POST http://localhost:3000/api/ingest \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Tus-Resumable: 1.0.0' -H 'Upload-Length: 27' \
  -H "Upload-Metadata: $META" | awk '/^Location:/ {print $2}' | tr -d '\r')

printf '{"schema":"v2","note":"yo"}' | curl -X PATCH "http://localhost:3000$LOC" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Tus-Resumable: 1.0.0' \
  -H 'Content-Type: application/offset+octet-stream' \
  -H 'Upload-Offset: 0' -H 'Content-Length: 27' --data-binary @-
```

Visit `http://localhost:3000/` — you'll be auto-logged-in as the dev
user and the `demo-1` session shows up under "Sessions". Click in to
mark it reviewed, add notes, etc.
