"""Content-addressed, host-owned model assets. No headset build tools involved.

A self-contained GLB carries its optional articulation in ``extras.operator_robot``.
The server exposes only explicitly registered immutable assets, not directories.
Use on the same trusted LAN as the robot session; hashes provide integrity, not
peer authentication. Keep this static transfer separate from pose traffic.
"""
from __future__ import annotations

from dataclasses import dataclass, field
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import re
import struct
import threading

MAX_ASSET_BYTES = 64 * 1024 * 1024
MAX_JSON_BYTES = 2 * 1024 * 1024
MAX_CACHE_BYTES = 256 * 1024 * 1024
ROBOT_ASSET_SCHEMA = "operator.robot_asset.v1"


def glb_document(data: bytes) -> dict:
    if not 20 <= len(data) <= MAX_ASSET_BYTES:
        raise ValueError("robot GLB exceeds the asset size limits")
    magic, version, size, json_size, kind = struct.unpack_from("<5I", data)
    if magic != 0x46546C67 or version != 2 or size != len(data) or kind != 0x4E4F534A:
        raise ValueError("expected a complete GLB 2.0 asset")
    if not 2 <= json_size <= MAX_JSON_BYTES or 20 + json_size > len(data):
        raise ValueError("invalid GLB JSON length")
    document = json.loads(data[20:20 + json_size])
    if not isinstance(document, dict):
        raise ValueError("GLB JSON must be an object")
    return document


@dataclass(frozen=True)
class RobotModelAsset:
    data: bytes = field(repr=False)
    sha256: str = field(init=False)
    joint_names: tuple[str, ...] = field(init=False)

    def __post_init__(self):
        data = bytes(self.data)
        document = glb_document(data)
        rig = document.get("extras", {}).get("operator_robot", {})
        if rig.get("schema") != ROBOT_ASSET_SCHEMA:
            raise ValueError("missing operator.robot_asset.v1 articulation")
        names = tuple(joint["name"] for joint in rig.get("joints", []))
        if len(names) > 256 or any(not isinstance(n, str) or not n for n in names) \
                or len(set(names)) != len(names):
            raise ValueError("asset must have 0..256 uniquely named joints")
        object.__setattr__(self, "data", data)
        object.__setattr__(self, "joint_names", names)
        object.__setattr__(self, "sha256", hashlib.sha256(data).hexdigest())

    def component(self, id: str, *, asset_port: int, **kwargs):
        from .blueprint import BlueprintComponent
        return BlueprintComponent.robot_model(
            id, asset_sha256=self.sha256, asset_size=len(self.data),
            asset_port=asset_port, joint_names=self.joint_names, **kwargs,
        )


class _BoundedServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, *args):
        self.slots = threading.BoundedSemaphore(8)
        super().__init__(*args)

    def process_request(self, request, client_address):
        if not self.slots.acquire(blocking=False):
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except BaseException:
            self.slots.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            request.settimeout(10)
            super().process_request_thread(request, client_address)
        finally:
            self.slots.release()


class RobotAssetServer:
    """Serve registered model bytes for the lifetime of a robot application."""

    def __init__(self, assets=(), *, host="0.0.0.0", port=0):
        self._assets: dict[str, RobotModelAsset] = {}
        self._lock = threading.Lock()
        self._thread = None
        self._closed = False
        self.requests = 0
        for asset in assets:
            self.register(asset)
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                match = re.fullmatch(r"/blueprint-assets/([0-9a-f]{64})\.glb", self.path)
                with owner._lock:
                    asset = owner._assets.get(match[1]) if match else None
                    owner.requests += 1
                if asset is None:
                    self.send_error(404)
                    return
                self.send_response(200)
                self.send_header("Content-Type", "model/gltf-binary")
                self.send_header("Content-Length", str(len(asset.data)))
                self.send_header("ETag", '"' + asset.sha256 + '"')
                self.send_header("Cache-Control", "public, max-age=31536000, immutable")
                self.end_headers()
                try:
                    self.wfile.write(asset.data)
                except (BrokenPipeError, ConnectionResetError, TimeoutError):
                    pass

            def log_message(self, *_args):
                pass

        self._server = _BoundedServer((host, port), Handler)
        self.port = self._server.server_port

    def register(self, asset: RobotModelAsset):
        if not isinstance(asset, RobotModelAsset):
            raise TypeError("register expects RobotModelAsset")
        with self._lock:
            total = sum(len(a.data) for key, a in self._assets.items() if key != asset.sha256)
            if total + len(asset.data) > MAX_CACHE_BYTES:
                raise ValueError("registered robot assets exceed 256 MiB")
            self._assets[asset.sha256] = asset

    def replace(self, assets) -> None:
        """Atomically replace the served asset set without changing the port.

        Hashes not present in ``assets`` stop resolving immediately. Because
        blueprints reference assets by ``sha256`` over a separate channel,
        publish the updated blueprint *before* calling this, or a headset that
        re-fetches the previously advertised hash gets a 404 and silently
        renders nothing.
        """
        if self._closed:
            raise RuntimeError("asset server has been closed")
        replacement: dict[str, RobotModelAsset] = {}
        for asset in assets:
            if not isinstance(asset, RobotModelAsset):
                raise TypeError("replace expects RobotModelAsset values")
            replacement[asset.sha256] = asset
        if sum(len(asset.data) for asset in replacement.values()) > MAX_CACHE_BYTES:
            raise ValueError("registered robot assets exceed 256 MiB")
        with self._lock:
            self._assets = replacement

    def start(self):
        if self._closed:
            raise RuntimeError("asset server has been closed")
        if self._thread is None:
            self._thread = threading.Thread(target=self._server.serve_forever, daemon=True)
            self._thread.start()
        return self

    def close(self):
        if self._closed:
            return
        self._closed = True
        if self._thread is not None:
            self._server.shutdown()
            self._thread.join(timeout=5)
        self._server.server_close()

    def __enter__(self):
        return self.start()

    def __exit__(self, *_args):
        self.close()
