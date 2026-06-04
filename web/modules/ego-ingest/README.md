# @love-moon/ego-ingest

Receive, store, and visualize ego-mode XR recordings uploaded over
**TUS 1.0.0** from the [Teleoperate-Anything](../../README.md) XR
client.

The XR client (Quest / Pico / Glass XR) finalizes each recording to a
local MP4 + manifest, then resumably uploads them to whatever URL the
operator configured in the in-headset settings panel. This package is
the receiver:

- A drop-in Express / connect middleware that speaks the TUS protocol.
- A pluggable storage driver (disk default; S3 via your own adapter).
- A SessionStore that indexes who uploaded what, when, how big.
- A live event bus (SSE) for dashboards that want real-time updates.
- A vanilla-JS dashboard, plus React component exports for embeds.

## Quick start

```bash
npm install @love-moon/ego-ingest express
```

```ts
import express from 'express';
import {
  createDashboard,
  createIngestMiddleware,
  createReadApi,
  DiskStorage,
  IngestEvents,
  MemoryStore,
} from '@love-moon/ego-ingest';

const app = express();
const events = new IngestEvents();
const store = new MemoryStore({ persistTo: './sessions.index.json' });
const storage = new DiskStorage({ root: './sessions' });

app.use('/ingest', createIngestMiddleware({
  store, storage, events,
  onSession: (session) => console.log('received', session.id),
}));
app.use('/ingest/api', createReadApi({ store, storage, events }));
app.use('/dashboard', createDashboard({ apiBase: '/ingest/api' }));

app.listen(8443);
```

In the XR app, open the Ego settings panel and set:

- **Upload URL**: `http://<your-host>:8443/ingest`
- **Auto-upload on stop**: ON

Tap Stop after a recording — the manifest + MP4 stream up over TUS and
land in `./sessions/<session_id>/`. The dashboard at
`http://<your-host>:8443/dashboard` refreshes live via SSE.

For a fully-annotated runnable copy (auth, hashes, schema gating,
programmatic event subscription, downstream pipeline hook), see
[`examples/server.ts`](./examples/server.ts) — `npx tsx examples/server.ts`.

## Why TUS

Ego recordings routinely exceed 2 GB (an hour of stereo HEVC ≈ 10 GB).
Single-request `POST` uploads break on:

- Reverse-proxy body-size caps (nginx 1 MB default,
  Cloudflare Free 100 MB, Pro 500 MB).
- Wi-Fi drops mid-upload that reset the entire transfer.
- Browser-side dashboards that want to pause / resume / show progress.

TUS 1.0.0 is a tiny spec (12 pages) that sidesteps all three: the
client chunks the upload, the server tracks `Upload-Offset` per
resource, and any blip resumes from the last acknowledged byte. The
XR client uses 8 MB chunks by default, which sails under every common
proxy limit.

## Storage drivers

`DiskStorage` ships in-box. It lays sessions out as:

```
<root>/
  .partial/<resourceId>          # in-progress chunks
  <session_id>/
    manifest.json
    media.mp4
    manifest.meta.json           # echoed Upload-Metadata for debugging
```

Bring your own driver by implementing `StorageDriver` (see
`src/storage/index.ts`). The interface is byte-oriented — `appendStream`
is a Node `Writable` that you can wire to S3 multipart uploads, a
distributed FS, or anything else.

## Metadata stores

`MemoryStore` ships in-box. Optional `persistTo` snapshots to a JSON
file on every mutation, which is enough for solo-dev / single-headset
workflows. For team deployments swap in a SQLite-backed store —
implement the `SessionStore` interface (see `src/store/index.ts`).

## Example

One file in `examples/server.ts` exercises every public surface of the
package — TUS middleware, disk storage with SHA-256, persisted
metadata, bearer auth, the read API, the built-in dashboard,
programmatic SSE subscription, and an `onSession` hook for downstream
pipelines. Run it directly:

```bash
npx tsx examples/server.ts
# Override defaults via env: PORT, SESSIONS_ROOT, SESSIONS_INDEX,
# INGEST_TOKEN, MAX_BYTES.
```

The same file works as a copy-paste reference for embedding the
middleware in your own Express / Fastify / Hono app.

## React components

Already using React? Embed the same UI without iframing the dashboard:

```tsx
import { SessionList, SessionDetail, StatsPanel } from '@love-moon/ego-ingest/react';

const API_BASE = '/ingest/api';
// ...
<StatsPanel apiBase={API_BASE} range="7d" />
<SessionList apiBase={API_BASE} activeId={selected} onSelect={setSelected} />
<SessionDetail apiBase={API_BASE} sessionId={selected} />
```

Components are headless — no Tailwind / shadcn / Mantine dependency,
just structural inline styles and a stable `ego-*` className prefix
you can override. They share a single SSE connection per `apiBase`
via the `useIngestEvents` hook.

## Wire protocol cheat sheet

`POST /ingest` (creation):

```
Tus-Resumable: 1.0.0
Upload-Length: <bytes>
Upload-Metadata: session_id <b64>,artifact_kind <b64>,filename <b64>,schema <b64>
```

`PATCH /ingest/<resourceId>` (each chunk):

```
Tus-Resumable: 1.0.0
Content-Type: application/offset+octet-stream
Upload-Offset: <int>
Content-Length: <chunk-bytes>
<chunk body>
```

Server responds with `204 No Content` and `Upload-Offset: <new int>`.
On any network error the client sends `HEAD /ingest/<resourceId>` to
re-discover the server's persisted offset, then resumes PATCH from
there.

See [`claw/issues/010-ego-data-upload.md`](../../claw/issues/010-ego-data-upload.md)
for the design doc, trip-wires, and rollout plan.

## License

MIT.
