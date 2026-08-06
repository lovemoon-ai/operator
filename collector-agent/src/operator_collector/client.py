from __future__ import annotations

import json
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any


class ApiError(RuntimeError):
    def __init__(self, status: int, message: str):
        super().__init__(f"HTTP {status}: {message}")
        self.status = status


class CollectorClient:
    def __init__(self, server_url: str, token: str = "") -> None:
        self.server_url = server_url.rstrip("/")
        self.token = token

    def _url(self, path: str) -> str:
        return f"{self.server_url}{path if path.startswith('/') else '/' + path}"

    def json(
        self,
        method: str,
        path: str,
        body: dict[str, Any] | None = None,
        *,
        auth: bool = True,
        headers: dict[str, str] | None = None,
        timeout: float = 30,
    ) -> dict[str, Any] | None:
        data = None if body is None else json.dumps(body).encode("utf-8")
        request_headers = {"Accept": "application/json"}
        if data is not None:
            request_headers["Content-Type"] = "application/json"
        if auth and self.token:
            request_headers["Authorization"] = f"Bearer {self.token}"
        if headers:
            request_headers.update(headers)
        request = urllib.request.Request(
            self._url(path), data=data, method=method, headers=request_headers
        )
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                raw = response.read()
                if response.status == 204 or not raw:
                    return None
                value = json.loads(raw.decode("utf-8"))
                return value if isinstance(value, dict) else {"value": value}
        except urllib.error.HTTPError as error:
            raw = error.read().decode("utf-8", errors="replace")
            try:
                parsed = json.loads(raw)
                message = str(parsed.get("error", raw)) if isinstance(parsed, dict) else raw
            except json.JSONDecodeError:
                message = raw or error.reason
            raise ApiError(error.code, message) from error
        except urllib.error.URLError as error:
            raise RuntimeError(f"Cannot reach Operator server {self.server_url}: {error.reason}") from error

    def upload_preview(self, item_id: str, preview: Path) -> dict[str, Any] | None:
        data = preview.read_bytes()
        request = urllib.request.Request(
            self._url(f"/api/collector-agent/items/{urllib.parse.quote(item_id)}/preview"),
            data=data,
            method="PUT",
            headers={
                "Authorization": f"Bearer {self.token}",
                "Content-Type": "video/mp4",
                "Content-Length": str(len(data)),
            },
        )
        try:
            with urllib.request.urlopen(request, timeout=600) as response:
                raw = response.read()
                return json.loads(raw.decode("utf-8")) if raw else None
        except urllib.error.HTTPError as error:
            raise ApiError(error.code, error.read().decode("utf-8", errors="replace")) from error

    def upload_preview_frame(
        self, item_id: str, index: int, preview: Path
    ) -> dict[str, Any] | None:
        data = preview.read_bytes()
        request = urllib.request.Request(
            self._url(
                f"/api/collector-agent/items/{urllib.parse.quote(item_id)}/previews/{index}"
            ),
            data=data,
            method="PUT",
            headers={
                "Authorization": f"Bearer {self.token}",
                "Content-Type": "image/jpeg",
                "Content-Length": str(len(data)),
            },
        )
        try:
            with urllib.request.urlopen(request, timeout=120) as response:
                raw = response.read()
                return json.loads(raw.decode("utf-8")) if raw else None
        except urllib.error.HTTPError as error:
            raise ApiError(error.code, error.read().decode("utf-8", errors="replace")) from error
