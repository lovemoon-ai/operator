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
