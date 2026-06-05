# web/

Web tier for the Teleoperate-Anything project.

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

Configure via env vars (all optional):

| var | default | meaning |
|-----|---------|---------|
| `PORT` | `3000` | listen port |
| `DATA_ROOT` | `./data` | where sessions + index + reviews are stored |
| `INGEST_TOKEN` | unset | when set, require `Authorization: Bearer <token>` |
| `MAX_BYTES` | `100 GB` | hard cap on Upload-Length |
| `INTERNAL_API_BASE` | `http://localhost:3000` | base used by server-side fetches |
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
   strips the FFV1 depth track and the seven `mett` timed-metadata
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

   The sidecar's Python environment is managed by
   [`uv`](https://docs.astral.sh/uv/) via PEP 723 inline metadata at
   the top of the script — `rerun-sdk`, `numpy`, `scipy`, and
   `opencv-python` resolve on first run, cached after. The
   SpatialMP4 SDK itself is **not** on PyPI; we expect a local
   checkout (auto-detected via `SPATIALMP4_HOME` or these dev paths,
   first match wins):

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

   # 2. SpatialMP4 SDK — build once for the Python ABI uv will pick
   git clone https://github.com/Pico-Developer/SpatialMP4 \
       ~/ws/spatialmp4-quest/SpatialMP4
   cd ~/ws/spatialmp4-quest/SpatialMP4
   cmake -S . -B build/host_py \
       -DPython_EXECUTABLE=$(uv python find)
   cmake --build build/host_py -j
   ```

   Subsequent ingests just trigger `uv run --script …`, which is
   ~instant after the first warm-up. The worker fails open: missing
   uv / missing SDK / sidecar exception → the Rerun panel hides
   itself, the `<video>` preview still works. Check the dev-server
   log for the `[workers] rerun …` line.

## Point the XR client at it

In the headset's Ego settings panel:

- **Upload URL**: `http://<your-mac-ip>:3000/api/ingest`
- **Bearer token**: only if you set `INGEST_TOKEN`
- **Auto-upload on stop**: ON

After tapping Stop, the recording appears in the dashboard within a
few seconds. The header's "live" indicator turns green while the
SSE stream is open — pages refresh automatically.

## Smoke test without a headset

```bash
META="session_id $(printf 'demo-1' | base64),artifact_kind $(printf 'manifest' | base64),filename $(printf 'manifest.json' | base64)"

LOC=$(curl -s -i -X POST http://localhost:3000/api/ingest \
  -H 'Tus-Resumable: 1.0.0' -H 'Upload-Length: 27' \
  -H "Upload-Metadata: $META" | awk '/^Location:/ {print $2}' | tr -d '\r')

printf '{"schema":"v2","note":"yo"}' | curl -X PATCH "http://localhost:3000$LOC" \
  -H 'Tus-Resumable: 1.0.0' \
  -H 'Content-Type: application/offset+octet-stream' \
  -H 'Upload-Offset: 0' -H 'Content-Length: 27' --data-binary @-
```

Refresh `http://localhost:3000/` — the `demo-1` session shows up
under "Sessions". Click in to mark it reviewed, add notes, etc.
