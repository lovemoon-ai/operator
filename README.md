# Operator — Egocentric Data Collection

**A toolkit for capturing, uploading, and reviewing egocentric (first-person)
XR recordings for robot learning.**

Put on a Quest / Pico / Glass XR headset, record what you see and do from a
first-person viewpoint, and the session is finalized on-device to a SpatialMP4
(MP4 video + audio + a sidecar manifest of poses and metadata), then resumably
uploaded to your own ingest server for indexing, storage, and review.

```
   Headset (xr/)                          Ingest server (web/)
 ┌────────────────────────┐                ┌────────────────────────┐
 │ capture_app.gd         │                │ @love-moon/ego-ingest  │
 │  → SpatialMP4 record   │ ─────────────► │  TUS receiver + storage│
 │  → ego_uploader.gd     │   MP4+manifest │  SessionStore + index  │
 │  → ego_qr_scanner.gd   │                │  live dashboard (SSE)  │
 └────────────────────────┘                └────────────────────────┘
```

## How it works

1. **Capture** (`xr/scenes/capture_app.tscn`, `xr/scripts/capture_app.gd`) —
   records the headset's egocentric view to a **SpatialMP4** session: an H.264
   MP4 with AAC audio plus a `manifest.json` sidecar carrying device type,
   timing, and pose data. Backed by per-vendor capture plugins
   (`xr/android_plugin/picocapture`, `questcapture`).
2. **Configure & upload** (`xr/scripts/ego_uploader.gd`) — point the headset at
   an ingest URL (scan a QR code via `ego_qr_scanner.gd` or set it in the
   in-headset settings panel), then each session is uploaded over **TUS 1.0.0**
   so interrupted uploads resume instead of restarting.
3. **Ingest & review** (`web/modules/ego-ingest`, `@love-moon/ego-ingest`) — a
   drop-in Express/connect TUS receiver with pluggable storage (disk by
   default), a SessionStore that indexes who uploaded what, a live SSE event
   bus, and a dashboard (vanilla JS + React exports). The Next.js app in
   `web/app` mounts it for browsing and reviewing sessions.

## Quick start

### Record on a headset and validate end-to-end

```bash
# 1. Clone and sync third-party deps
git clone https://github.com/lovemoon-ai/operator
cd operator/xr && make deps

# 2. Install host tooling (macOS example)
brew install ffmpeg android-platform-tools

# 3. Build + install the XR APK (first build > 10 min), then run the
#    ego-record CI: builds a capture APK, records on the attached headset,
#    pulls the SpatialMP4, and validates the MP4 + manifest.
cd ..
bash tests/02_ego_record.sh --device quest
```

> The XR client must run on a real Android XR device — it cannot be tested with
> desktop `godot --headless`.

### Receive uploads

Spin up the polished ingest receiver:

```bash
cd web && npm install      # npm workspace: app + ego-ingest
# see web/README.md to run the data-management app
```

…or use the tiny stdlib smoke receiver to prove the wire protocol without the
NPM stack:

```bash
python3 scripts/ego_upload_smoke.py --port 8443 --root ./uploads
```

Upload prerecorded MP4s for local/prod smoke tests:

```bash
bash scripts/ego_upload_local_mp4.sh   # against a local receiver
bash scripts/ego_upload_prod_mp4.sh    # against the deployed ingest
```

## Key paths

| Path | Role |
| --- | --- |
| `xr/scripts/capture_app.gd` | On-device SpatialMP4 recorder |
| `xr/scripts/ego_uploader.gd` | TUS resumable uploader |
| `xr/scripts/ego_qr_scanner.gd` | QR-code ingest-URL config |
| `web/modules/ego-ingest/` | `@love-moon/ego-ingest` TUS receiver + dashboard |
| `scripts/ego_upload_smoke.py` | Minimal stdlib TUS receiver for testing |
| `tests/02_ego_record.sh` | End-to-end record → pull → validate CI |

## Docs

- Ingest package: `web/modules/ego-ingest/README.md`
- Web data-management app: `web/README.md`
- Build commands & device constraints: `AGENTS.md`
