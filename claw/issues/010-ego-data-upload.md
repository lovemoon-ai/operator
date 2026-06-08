# Ego data upload — XR → user-hosted ingest server

Status: open · scope-defined, partially implemented
Category: feature (XR client outbound), tooling (NPM package)
Spawned-from: user request, 2026-06-03

## Why this exists

Today every Ego-mode recording (`xr/scripts/capture_app.gd::stop_capture`,
line 291) finalizes to local Android storage at
`{save_root}/{session_id}.mp4` plus the `{session_id}/` sidecar
directory and never leaves the device. Users pull recordings off via
`adb pull` or USB-MTP. For any team that wants to collect data from
multiple headsets, run nightly aggregation, or build a labeling UI on
top of the recordings, this is the wall they hit first.

The request: let the Ego config panel carry a website URL; if set,
each finalized session is auto-uploaded there. The receiving side
should be a reusable NPM package so teams can drop it into their own
web app rather than running a bespoke service.

## Scope

In scope:

* New URL + token + toggle fields on `ViewLockedCapturePanel` plus
  persistence to `user://capture_settings.cfg`.
* A background uploader on the XR side that runs **after**
  `SessionSpoolWriter::close()` finalizes the MP4 (never during
  recording — see trip-wires below).
* The upload protocol must support **files > 2 GB by default** (a
  full hour of stereo HEVC at ~24 Mbps lands around 10 GB), so the
  v1 wire is **TUS 1.0.0 resumable uploads** rather than a single
  multipart POST.
* A new `web/modules/ego-ingest/` library package that ships:
  - a TUS-spec-compliant ingest middleware for Express/connect,
  - a pluggable storage driver (disk default; S3 hook),
  - a small EventEmitter + SSE bridge,
  - a built-in dashboard (vanilla JS),
  - React component exports for embedding into existing web apps.
* A Next.js data-management / review web app at `web/app/` that
  consumes the package as a workspace dep — receives uploads from
  XR, browses sessions, plays back recordings, marks them as
  reviewed / flagged / annotated.

Out of scope (separate issues if pursued):

* Multi-tenant auth, project-level RBAC. v1 uses a single static
  bearer token configured per headset.
* In-headset preview of remote sessions. The dashboard is web-only.
* Resuming a half-uploaded session **across** XR app restarts.
  v1 persists the upload queue but a partial upload that was
  interrupted mid-PATCH restarts from the last server-acknowledged
  offset (TUS does that for us); a session whose XR app was killed
  before TUS `Upload-Offset: 0` was even POSTed will retry the
  whole thing on next launch.
* Server-side transcoding, frame extraction, ML processing. The
  package exposes `onSession` hooks for downstream pipelines but
  ships none.

## Wire protocol — why TUS, not a single multipart POST

We considered three options:

| Option | Pros | Cons |
|--------|------|------|
| Single `POST` multipart/form-data | 1-screen server impl, no state | Resets the entire transfer on any network blip. Most reverse proxies / WAFs cap request bodies at 2 GB or less by default (nginx `client_max_body_size`, Cloudflare 100 MB free / 500 MB Pro). Browser-side dashboards can't pause/resume. Memory pressure on the receiver. |
| TUS 1.0.0 resumable | Resumable across network blips; 256 KB–8 MB chunk size sidesteps proxy body limits; server can pre-flight Content-Length via `Upload-Length`; mature client/server libs in every language. Spec is small (~12 pages). | Two-phase (`POST` to create + `PATCH` to extend). Server must track `Upload-Offset` per resource. |
| S3 pre-signed URL multipart | Cloud-native, near-zero server work | Forces every deployment to run S3-compatible storage. Hard to debug — no app-level visibility into upload lifecycle. Coupling the SDK to S3 contradicts the "NPM package for self-hosted use" goal. |

We pick **TUS 1.0.0**. The XR-side encoder is ~250 lines of GDScript
against Godot's `HTTPClient`; the server-side middleware is `tus-node-server`
(MIT, ~3k stars). S3 is supported by swapping the storage driver to
`tus-node-server`'s built-in `S3Store`, so the cloud-native path
stays open without us baking it in.

### Chunking

Default chunk size **8 MB**. Rationale: large enough that the TLS /
HTTP overhead per chunk stays under 1%; small enough that a Wi-Fi
hiccup loses at most one chunk of progress; matches `tus-node-server`'s
default; comfortably under the 10 MB Cloudflare Free tier per-request
limit if a team wants to front the ingest with Cloudflare.

### Headers (XR → server)

* `Tus-Resumable: 1.0.0`
* `Upload-Length: <bytes>` on the creation `POST`
* `Upload-Metadata: filename <b64>,session_id <b64>,schema <b64>,manifest_sha256 <b64>`
  — TUS-standard key/space/base64-value list; the server hydrates a
  `Session` record from these without parsing the MP4.
* `Authorization: Bearer <token>` — opaque to TUS; consumed by an
  Express middleware in front of `tus-node-server`.
* `X-Ego-Schema-Version: spatialmp4.quest_capture.spool.v2` — mirrors
  the `schema` field in `manifest.json` so the server can reject
  incompatible old recordings without inspecting the payload.

### Three uploads per session

`SessionSpoolWriter` produces three artifact classes
(`session_spool_writer.gd:70-83`). Rather than zip them client-side
(slow on Pico's eMMC, doubles disk pressure), we do three independent
TUS uploads sharing the same `session_id`:

1. `manifest.json` — always first; server allocates the session
   record so subsequent uploads can be associated.
2. `{session_id}.mp4` — the main artifact.
3. `sidecars.tar` — opt-in (default on when `record_depth` or
   `record_*pose` sidecars exist). Streamed `tar` over `HTTPClient`
   (no compression — depth JSONL compresses poorly and HEVC doesn't
   compress at all).

Each upload's `Upload-Metadata` includes the same `session_id` so
the server can group them.

### Idempotency / re-upload

The server keys sessions by `session_id` (sourced from
`Upload-Metadata`). If a session already has a finalized `mp4`
artifact, a fresh creation `POST` for the same `(session_id,
artifact_kind)` returns `409 Conflict` with a JSON body
`{ "existing": { ... } }`. The XR client treats `409` as success
("server already has it") and clears the queue entry.

## XR-side architecture

### New files

* `xr/scripts/ui/base_settings_panel.gd` — shared `ConfigFile` read/write
  helper used by both teleop and capture settings panels. Capture settings
  are stored at `user://capture_settings.cfg`.
* `xr/scripts/ego_uploader.gd` — `Node` autoloaded by `capture_app.gd`.
  Owns:
  - A `Queue` (Array of session descriptors) persisted to
    `user://ego_upload_queue.json` on every state change.
  - A worker `Thread` driving Godot's `HTTPClient` through the TUS
    state machine. Threaded because `HTTPClient.poll()` is blocking
    when waiting on socket I/O and would otherwise stall the main
    `_process` loop and trash recording FPS during the post-stop
    upload of the *next* session (the previous one being finalized
    in the background).
  - Signals: `upload_started(session_id)`, `upload_progress(session_id, sent, total)`,
    `upload_finished(session_id, response)`, `upload_failed(session_id, error)`.

### Modified files

* `xr/scripts/view_locked_capture_panel.gd`
  - New "Upload" section: `upload_url` LineEdit, `upload_token`
    LineEdit (`secret = true`), `upload_on_finalize` toggle,
    `keep_local_after_upload` toggle.
  - `get_options()` returns the four new fields.
* `xr/scripts/capture_app.gd`
  - Construct `EgoUploader` in `_ready()`, connect its signals to the
    `status_popup` for user-visible progress.
  - In `stop_capture()` after `writer.close()` (`capture_app.gd:297`),
    if `upload_on_finalize` is true and `upload_url` is non-empty,
    call `uploader.enqueue(session_dir, output_mp4_path, capture_options)`.
  - On `_ready()`, load persisted settings through
    `ViewLockedCapturePanel.load_settings()` and call
    `settings_panel.set_options(...)` so the panel reflects them on
    first frame.
  - Settings are saved by the panel through `BaseSettingsPanel` before
    `_on_capture_settings_saved` is emitted.
* `xr/scripts/view_locked_record_control.gd`
  - One new status line under the timer: `"Uploading 42% · ETA 1:12"`
    when an upload is active, `"Upload failed · tap to retry"` red on
    failure. Driven by the uploader's signals.

### Trip-wires

* **Never start an upload while a recording is active.** The Pico
  eMMC + Wi-Fi simultaneously sustaining a 24 Mbps HEVC write AND a
  TUS PATCH stream blew through the I/O budget in the prototype
  spike (frames dropped from 30 → 18 fps within ~10 s). The
  uploader's worker thread checks `capture_app.is_recording()` (new
  getter) and parks the queue until recording stops.
* **The MP4 path the uploader reads is the finalized one, not
  `partial_mp4_path`.** `SessionSpoolWriter::close()` renames
  `partial → final` atomically (via the Kotlin muxer's
  `finishSpatialMp4`), so reading `saved_path` after `close()`
  returns the finalized file. Reading `output_mp4_path` directly
  would race the rename on slow eMMC.
* **Token storage is base64-obfuscated, not encrypted.** The
  `user://capture_settings.cfg` file is in the app's private data dir on
  Android, but rooted Pico headsets can still read it. Document this
  in the README — for production use, fronting the ingest server
  with mTLS or per-headset short-lived tokens is the recommended
  approach.
* **Don't upload over cellular.** The Quest/Pico/Glass XR devices
  this targets are Wi-Fi only at the time of writing, so this is
  defensive: the uploader checks `OS.has_feature("mobile")` and the
  network type via the Kotlin plugin and refuses to upload over a
  metered connection unless `allow_metered_upload` is true.

## NPM package — `@love-moon/ego-ingest`

### Goals

1. `npx @love-moon/ego-ingest serve --port 8443 --root ./sessions`
   should be enough to receive uploads from a headset on the same
   LAN. No config file required.
2. Embedding into an existing Express app should be a one-liner.
3. Embedding the dashboard UI into an existing React app should be a
   one-component-per-screen import.
4. Storage and persistence are pluggable; the defaults are the
   simplest thing that works (local disk + JSON file).

### Layout

```
web/modules/ego-ingest/
├── package.json          # name: @love-moon/ego-ingest
├── tsconfig.json
├── README.md
├── CHANGELOG.md
├── src/
│   ├── index.ts          # public API: createIngestMiddleware, createDashboard, stores
│   ├── tus/
│   │   ├── middleware.ts # wraps tus-node-server with our auth + onSession hook
│   │   └── metadata.ts   # Upload-Metadata parser / validator
│   ├── store/
│   │   ├── memory.ts     # default
│   │   ├── sqlite.ts     # opt-in (better-sqlite3 peer dep)
│   │   └── index.ts      # SessionStore interface
│   ├── storage/
│   │   ├── disk.ts       # default — files on local FS
│   │   ├── s3.ts         # opt-in (@aws-sdk/client-s3 peer dep)
│   │   └── index.ts      # StorageDriver interface
│   ├── events.ts         # EventEmitter + SSE bridge
│   ├── api.ts            # GET /sessions, /sessions/:id, /stats, /events (SSE)
│   ├── dashboard/
│   │   ├── server.ts     # serves the vanilla-JS dashboard
│   │   └── web/          # pre-built dashboard assets (Vite output)
│   └── ui/
│       └── react/
│           ├── index.ts
│           ├── SessionList.tsx
│           ├── SessionDetail.tsx
│           └── StatsPanel.tsx
├── examples/
│   ├── 01-minimal-express.ts
│   ├── 02-with-dashboard.ts
│   ├── 03-custom-storage-s3.ts
│   └── 04-react-embed/
└── test/
    ├── tus.test.ts       # round-trips a 2.5 GB file with mid-stream disconnects
    └── store.test.ts
```

### Public API sketch

```ts
import express from 'express';
import {
  createIngestMiddleware,
  createDashboard,
  SqliteStore,
  DiskStorage,
} from '@love-moon/ego-ingest';

const app = express();
const store = new SqliteStore('./sessions.db');
const storage = new DiskStorage({ root: './sessions' });

app.use(
  '/ingest',
  createIngestMiddleware({
    store,
    storage,
    auth: (req) => req.headers.authorization === `Bearer ${process.env.TOKEN}`,
    maxUploadSizeBytes: 50 * 1024 ** 3, // 50 GB hard cap
    onSession: async (session) => {
      console.log(`received ${session.id} (${session.durationSec}s)`);
    },
  }),
);

app.use('/dashboard', createDashboard({ store, ingestBase: '/ingest' }));
app.listen(8443);
```

React embed:

```tsx
import { SessionList, SessionDetail, StatsPanel } from '@love-moon/ego-ingest/react';

<SessionList apiBase="/ingest/api" onSelect={(id) => setSelected(id)} />
<SessionDetail apiBase="/ingest/api" sessionId={selected} />
<StatsPanel apiBase="/ingest/api" range="7d" />
```

### Dashboard v1 features

* Session list (newest first, paginated, filter by date range).
* Per-session detail: manifest viewer, MP4 thumbnail strip (extracted
  server-side via ffmpeg on receive — optional), download buttons,
  raw artifact tree.
* Stats panel: sessions/day, total minutes recorded, total bytes
  stored, % failed uploads (server pulls this from the SessionStore's
  upload-attempt log).
* Live updates via SSE on `/ingest/api/events`.

### Acceptance for the NPM package

* `npm run test` round-trips a synthetic 2.5 GB file through TUS
  with a forced socket disconnect at ~50% offset; server-side bytes
  on disk match input SHA-256.
* `examples/01-minimal-express.ts` runs without modification and
  accepts an upload from `tools/ego_upload_smoke.py` (a new
  Python TUS client that mimics the XR-side state machine for CI
  use without bringing up Godot).
* Dashboard renders an uploaded session in any of: Chrome, Safari,
  Firefox latest stable.

## Rollout / PR sequence

* **PR-1 (XR, no upload yet).** Base settings persistence +
  capture-panel UI for `upload_url` / `upload_token` /
  `upload_on_finalize` / `keep_local_after_upload`, persisted across
  app launches. Stores into `manifest.json`'s `capture_options` so
  later replays know how the session was supposed to be routed.
* **PR-2 (XR).** `ego_uploader.gd` with TUS state machine, queue
  persistence, progress UI, and `tools/ego_upload_smoke.py` for
  e2e local testing against a stub TUS server.
* **PR-3 (NPM).** Package skeleton, TUS middleware, disk storage,
  memory store, `01-minimal-express.ts` example. Published to npm
  under `@love-moon/ego-ingest`.
* **PR-4 (NPM).** SSE events, dashboard UI (vanilla JS), React
  component exports, examples 02–04, SQLite store, S3 storage hook.

## Acceptance criteria for closure

* Setting `upload_url` + token in the headset panel and tapping
  Stop after a 5-minute recording results in the MP4 +
  manifest.json + sidecars appearing in the dashboard within 30 s
  of XR-side finalization (10 GbE LAN).
* Killing Wi-Fi mid-upload and re-enabling it resumes from the
  last acknowledged TUS offset (verified by server log showing
  no duplicate bytes written).
* `npx @love-moon/ego-ingest serve` starts a working ingest with
  dashboard at `/dashboard`, no further config.
* A new app embedding `<SessionList />` and `<SessionDetail />`
  in their own React project shows live data within 60 minutes
  of `npm install` (target: documented end-to-end in
  `examples/04-react-embed/README.md`).
