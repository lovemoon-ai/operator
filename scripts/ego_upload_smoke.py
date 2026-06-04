#!/usr/bin/env python3
"""
Tiny self-contained TUS 1.0.0 receiver for end-to-end testing of the
XR-side ego_uploader.gd without bringing up the full @love-moon/ego-ingest
NPM stack.

Implements the core TUS protocol plus the `creation` extension:

    OPTIONS /<base>            → Tus-Resumable, Tus-Version, Tus-Extension
    POST    /<base>            → 201 Created, Location: /<base>/<id>
    HEAD    /<base>/<id>       → Upload-Offset, Upload-Length
    PATCH   /<base>/<id>       → 204 No Content, Upload-Offset

Storage layout:
    <root>/<session_id>/<artifact_kind><ext>     # final, when Upload-Length reached
    <root>/.partial/<resource_id>                # in-progress bytes
    <root>/.partial/<resource_id>.meta.json      # parsed Upload-Metadata + offset

Why stdlib only:
    The XR side is the actual product, and we want CI / dev-machine smoke
    runs that don't fight pip versions. The NPM ingest package is the
    polished receiver — this is the duct-tape rig that proves the wire
    protocol is sound.

Usage:
    python3 tools/ego_upload_smoke.py --port 8443 --root ./uploads
    python3 tools/ego_upload_smoke.py --port 8443 --token devtoken --base /ingest

Test it locally with curl:
    curl -i -X OPTIONS http://localhost:8443/ingest
    curl -i -X POST http://localhost:8443/ingest \
         -H 'Tus-Resumable: 1.0.0' -H 'Upload-Length: 11' \
         -H 'Upload-Metadata: session_id YWFh,artifact_kind bWFuaWZlc3Q=,filename bWFuaWZlc3QuanNvbg=='
    curl -i -X PATCH http://localhost:8443/ingest/<id> \
         -H 'Tus-Resumable: 1.0.0' -H 'Content-Type: application/offset+octet-stream' \
         -H 'Upload-Offset: 0' --data-binary 'hello world'

License: same as parent repo.
"""
from __future__ import annotations

import argparse
import base64
import io
import json
import os
import secrets
import sys
import threading
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Dict, Optional, Tuple

TUS_VERSION = "1.0.0"
TUS_EXTENSIONS = "creation,creation-with-upload,termination"
# Most reverse proxies cap individual request bodies; the XR side chunks
# at 8 MB so any cap above that is fine. We document the receiver as
# unconstrained — it's stdlib HTTP server so the only ceiling is disk.
MAX_BODY_BYTES = 64 * 1024 * 1024  # 64 MB per PATCH (generous)
PARTIAL_DIRNAME = ".partial"

_STORE_LOCK = threading.Lock()


# --------------------------------------------------------------------------- #
# Metadata helpers                                                            #
# --------------------------------------------------------------------------- #

def parse_upload_metadata(raw: str) -> Dict[str, str]:
    """Parse TUS Upload-Metadata header.

    Format is a comma-separated list of `<key> <base64 value>`. Empty
    values are permitted (key with no second token). We're forgiving
    about whitespace because not every client encodes the spec strictly.
    """
    out: Dict[str, str] = {}
    if not raw:
        return out
    for entry in raw.split(","):
        entry = entry.strip()
        if not entry:
            continue
        parts = entry.split(" ", 1)
        if not parts:
            continue
        key = parts[0].strip()
        if not key:
            continue
        if len(parts) == 1:
            out[key] = ""
            continue
        try:
            out[key] = base64.b64decode(parts[1].strip()).decode("utf-8", errors="replace")
        except Exception:
            out[key] = parts[1].strip()
    return out


def b64(text: str) -> str:
    return base64.b64encode(text.encode("utf-8")).decode("ascii")


# --------------------------------------------------------------------------- #
# Storage                                                                     #
# --------------------------------------------------------------------------- #

class Store:
    """Filesystem-backed TUS storage."""

    def __init__(self, root: Path):
        self.root = root
        self.partial_dir = root / PARTIAL_DIRNAME
        self.partial_dir.mkdir(parents=True, exist_ok=True)

    def _meta_path(self, resource_id: str) -> Path:
        return self.partial_dir / f"{resource_id}.meta.json"

    def _data_path(self, resource_id: str) -> Path:
        return self.partial_dir / resource_id

    def create(self, upload_length: int, metadata: Dict[str, str]) -> str:
        resource_id = secrets.token_urlsafe(16)
        meta = {
            "resource_id": resource_id,
            "upload_length": upload_length,
            "metadata": metadata,
            "offset": 0,
            "created_at": datetime.now(timezone.utc).isoformat(),
        }
        with _STORE_LOCK:
            self._data_path(resource_id).touch()
            self._meta_path(resource_id).write_text(json.dumps(meta, indent=2))
        return resource_id

    def load(self, resource_id: str) -> Optional[dict]:
        path = self._meta_path(resource_id)
        if not path.exists():
            return None
        try:
            return json.loads(path.read_text())
        except Exception:
            return None

    def append(self, resource_id: str, offset: int, body: io.BufferedIOBase, length: int) -> Tuple[int, Optional[str]]:
        """Append `length` bytes from `body` at `offset`. Returns (new_offset, error)."""
        meta = self.load(resource_id)
        if meta is None:
            return -1, "resource not found"
        expected = int(meta.get("offset", 0))
        if offset != expected:
            return -1, f"Upload-Offset mismatch: server={expected} client={offset}"

        data_path = self._data_path(resource_id)
        # Append in 1 MB sub-chunks so we never buffer the whole PATCH
        # body in memory — a 2.5 GB single request would otherwise OOM
        # a small dev box.
        written = 0
        with data_path.open("ab") as out:
            remaining = length
            while remaining > 0:
                read_size = min(1024 * 1024, remaining)
                buf = body.read(read_size)
                if not buf:
                    break
                out.write(buf)
                written += len(buf)
                remaining -= len(buf)
        if written != length:
            return -1, f"short body: expected {length} got {written}"

        new_offset = expected + written
        meta["offset"] = new_offset
        meta["last_patch_at"] = datetime.now(timezone.utc).isoformat()
        with _STORE_LOCK:
            self._meta_path(resource_id).write_text(json.dumps(meta, indent=2))

        upload_length = int(meta.get("upload_length", 0))
        if upload_length > 0 and new_offset >= upload_length:
            self._finalize(meta)
        return new_offset, None

    def _finalize(self, meta: dict) -> None:
        """Move the in-progress file to its session-keyed final home."""
        resource_id = meta["resource_id"]
        m = meta.get("metadata", {})
        session_id = (m.get("session_id") or resource_id).strip() or resource_id
        artifact_kind = (m.get("artifact_kind") or "data").strip() or "data"
        filename = (m.get("filename") or "").strip()
        # If client gave a filename keep its extension, otherwise infer
        # from artifact_kind.
        ext = ""
        if filename and "." in filename:
            ext = "." + filename.rsplit(".", 1)[-1]
        elif artifact_kind == "manifest":
            ext = ".json"
        elif artifact_kind == "media":
            ext = ".mp4"
        target_dir = self.root / session_id
        target_dir.mkdir(parents=True, exist_ok=True)
        target = target_dir / f"{artifact_kind}{ext}"
        # If a previous run finalized the same artifact, the new upload
        # wins (TUS clients shouldn't retry past completion, but the
        # smoke server is forgiving for dev workflows).
        with _STORE_LOCK:
            data_path = self._data_path(resource_id)
            if target.exists():
                target.unlink()
            os.replace(data_path, target)
            # Write a sidecar JSON next to the artifact so the operator
            # can see what metadata was carried with the upload.
            (target_dir / f"{artifact_kind}.meta.json").write_text(json.dumps(meta, indent=2))
            self._meta_path(resource_id).unlink(missing_ok=True)
        print(f"[smoke] finalized {session_id}/{artifact_kind} ({target.stat().st_size:,} bytes) → {target}", flush=True)


# --------------------------------------------------------------------------- #
# HTTP handler                                                                #
# --------------------------------------------------------------------------- #

class TusHandler(BaseHTTPRequestHandler):
    # Filled in by serve()
    store: Store = None  # type: ignore[assignment]
    base_path: str = "/ingest"
    bearer_token: Optional[str] = None

    # Suppress the default `127.0.0.1 - - "POST ..."` chatter; we print
    # our own structured lines in the handlers below.
    def log_message(self, format: str, *args) -> None:  # noqa: A002
        return

    # --- auth ----------------------------------------------------------------

    def _check_auth(self) -> bool:
        if not self.bearer_token:
            return True
        header = self.headers.get("Authorization", "")
        if header == f"Bearer {self.bearer_token}":
            return True
        self._send(401, body=b"unauthorized\n")
        return False

    # --- routing -------------------------------------------------------------

    def _match_base(self) -> Optional[str]:
        """Return resource_id ('' for collection) if the request targets us."""
        path = self.path
        if path == self.base_path:
            return ""
        prefix = self.base_path + "/"
        if path.startswith(prefix):
            tail = path[len(prefix):]
            # No nested routes — first segment only.
            return tail.split("/", 1)[0]
        return None

    # --- response helpers ----------------------------------------------------

    def _tus_headers(self, extra: Optional[Dict[str, str]] = None) -> None:
        self.send_header("Tus-Resumable", TUS_VERSION)
        self.send_header("Cache-Control", "no-store")
        if extra:
            for k, v in extra.items():
                self.send_header(k, str(v))

    def _send(self, status: int, headers: Optional[Dict[str, str]] = None, body: bytes = b"") -> None:
        self.send_response(status)
        self._tus_headers(headers)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)

    # --- HTTP verbs ----------------------------------------------------------

    def do_OPTIONS(self) -> None:  # noqa: N802
        resource = self._match_base()
        if resource is None:
            self._send(404)
            return
        self._send(
            204,
            headers={
                "Tus-Version": TUS_VERSION,
                "Tus-Extension": TUS_EXTENSIONS,
                "Tus-Max-Size": str(1024 ** 4),  # 1 TiB, dev-only
            },
        )

    def do_POST(self) -> None:  # noqa: N802
        resource = self._match_base()
        if resource is None:
            self._send(404)
            return
        if resource != "":
            self._send(405)
            return
        if not self._check_auth():
            return
        if self.headers.get("Tus-Resumable") != TUS_VERSION:
            self._send(412, body=b"Tus-Resumable mismatch\n")
            return
        try:
            upload_length = int(self.headers.get("Upload-Length", "0"))
        except ValueError:
            upload_length = 0
        if upload_length <= 0:
            self._send(400, body=b"Upload-Length required\n")
            return
        metadata = parse_upload_metadata(self.headers.get("Upload-Metadata", ""))
        resource_id = self.store.create(upload_length, metadata)
        location = f"{self.base_path}/{resource_id}"
        self._send(
            201,
            headers={
                "Location": location,
                "Upload-Offset": "0",
                "Upload-Length": str(upload_length),
            },
        )
        sid = metadata.get("session_id", "?")
        kind = metadata.get("artifact_kind", "?")
        print(f"[smoke] POST  {self.base_path} session={sid} kind={kind} length={upload_length:,} → {location}", flush=True)

    def do_HEAD(self) -> None:  # noqa: N802
        resource_id = self._match_base()
        if not resource_id:
            self._send(404)
            return
        if not self._check_auth():
            return
        meta = self.store.load(resource_id)
        if meta is None:
            self._send(404)
            return
        self._send(
            200,
            headers={
                "Upload-Offset": str(int(meta.get("offset", 0))),
                "Upload-Length": str(int(meta.get("upload_length", 0))),
            },
        )

    def do_PATCH(self) -> None:  # noqa: N802
        resource_id = self._match_base()
        if not resource_id:
            self._send(404)
            return
        if not self._check_auth():
            return
        if self.headers.get("Tus-Resumable") != TUS_VERSION:
            self._send(412, body=b"Tus-Resumable mismatch\n")
            return
        if self.headers.get("Content-Type") != "application/offset+octet-stream":
            self._send(415, body=b"Content-Type must be application/offset+octet-stream\n")
            return
        try:
            offset = int(self.headers.get("Upload-Offset", "-1"))
            length = int(self.headers.get("Content-Length", "-1"))
        except ValueError:
            self._send(400, body=b"bad Upload-Offset/Content-Length\n")
            return
        if offset < 0 or length < 0:
            self._send(400, body=b"missing Upload-Offset/Content-Length\n")
            return
        if length > MAX_BODY_BYTES:
            self._send(413, body=f"chunk too large (>{MAX_BODY_BYTES})\n".encode())
            return
        # Snapshot metadata BEFORE append() so we can log even after
        # _finalize() deletes the .meta.json file on the last chunk.
        meta_before = self.store.load(resource_id) or {}
        new_offset, err = self.store.append(resource_id, offset, self.rfile, length)
        if err:
            self._send(409, body=(err + "\n").encode())
            print(f"[smoke] PATCH {self.path} REJECTED: {err}", flush=True)
            return
        self._send(204, headers={"Upload-Offset": str(new_offset)})
        total = int(meta_before.get("upload_length", 0))
        sid = (meta_before.get("metadata") or {}).get("session_id", "?")
        kind = (meta_before.get("metadata") or {}).get("artifact_kind", "?")
        pct = (new_offset * 100 // total) if total else 0
        print(f"[smoke] PATCH {self.path} session={sid} kind={kind} {new_offset:,}/{total:,} ({pct}%)", flush=True)


# --------------------------------------------------------------------------- #
# Entrypoint                                                                  #
# --------------------------------------------------------------------------- #

def main() -> int:
    parser = argparse.ArgumentParser(description="Stdlib TUS 1.0.0 receiver for Ego upload smoke tests.")
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8443)
    parser.add_argument("--root", type=Path, default=Path("./uploads"))
    parser.add_argument("--base", default="/ingest", help="URL path the TUS endpoint listens on")
    parser.add_argument("--token", default=None, help="Optional Bearer token to require")
    args = parser.parse_args()

    args.root.mkdir(parents=True, exist_ok=True)
    TusHandler.store = Store(args.root)
    TusHandler.base_path = "/" + args.base.strip("/")
    TusHandler.bearer_token = args.token

    server = ThreadingHTTPServer((args.host, args.port), TusHandler)
    print(
        f"[smoke] listening on http://{args.host}:{args.port}{TusHandler.base_path}  "
        f"root={args.root.resolve()}  auth={'on' if args.token else 'off'}",
        flush=True,
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("[smoke] stopping", flush=True)
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
