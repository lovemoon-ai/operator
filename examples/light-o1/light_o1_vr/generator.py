"""Text -> ``(frames, 138)`` human action through Light-O1's HTTP services.

Two live clients mirror Light-O1's own console: the Control Server
(``light-deploy-server``, asynchronous generations you poll) and the resident
GPU API (``light-deploy-api``, one synchronous request). ``FileGenerator``
replays saved ``human_action.npy`` files so the VR side can be exercised
without a GPU. All requests use the standard library only.
"""
from __future__ import annotations

from dataclasses import dataclass
import io
import json
from pathlib import Path
import re
import threading
import time
from typing import Any, Mapping
import urllib.error
import urllib.request
import zipfile

import numpy as np

ACTION_FPS = 20.0
ACTION_DIM = 138
REPRESENTATION = "human_action_138_v1"


class GenerationError(RuntimeError):
    """Light-O1 could not produce a usable action."""


class GenerationCancelled(GenerationError):
    """The caller abandoned the request before it finished."""


@dataclass(frozen=True)
class GeneratedAction:
    prompt: str
    action: np.ndarray
    reasoning: str = ""
    source: str = ""
    generation_id: str = ""

    @property
    def frames(self) -> int:
        return int(self.action.shape[0])

    @property
    def seconds(self) -> float:
        return self.frames / ACTION_FPS


def validate_action(action) -> np.ndarray:
    try:
        array = np.asarray(action, dtype=np.float32)
    except (TypeError, ValueError) as exc:
        raise GenerationError(f"action is not numeric: {exc}") from exc
    if array.ndim != 2 or array.shape[1] != ACTION_DIM or array.shape[0] < 1:
        raise GenerationError(f"expected a (frames, {ACTION_DIM}) action, got {array.shape}")
    if not np.isfinite(array).all():
        raise GenerationError("action contains non-finite values")
    return array


def normalize_prompt(text: str) -> str:
    return re.sub(r"[^a-z0-9]+", " ", text.lower()).strip()


def _error_message(status: int, body: bytes) -> str:
    try:
        payload = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        payload = None
    detail: Any = None
    if isinstance(payload, dict):
        detail = payload.get("detail")
        error = payload.get("error")
        if detail is None and isinstance(error, dict):
            detail = error.get("message")
        elif detail is None and isinstance(error, str):
            detail = error
    if detail is None:
        detail = body[:200].decode("utf-8", "replace") if body else "no response body"
    return f"HTTP {status}: {detail}"


class _Http:
    """Minimal JSON/bytes HTTP helper; every transport failure is a GenerationError."""

    def __init__(self, base_url: str, timeout: float):
        if not base_url.startswith(("http://", "https://")):
            raise ValueError(f"Light-O1 URL must start with http:// or https://: {base_url!r}")
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout

    def request(self, method: str, path: str, body: Mapping[str, Any] | None = None,
                *, timeout: float | None = None) -> tuple[int, bytes]:
        data = None
        headers = {"Accept": "application/json, application/zip, */*"}
        if body is not None:
            data = json.dumps(dict(body), allow_nan=False).encode("utf-8")
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(self.base_url + path, data=data, method=method, headers=headers)
        try:
            with urllib.request.urlopen(request, timeout=self.timeout if timeout is None else timeout) as response:
                return int(response.status), response.read()
        except urllib.error.HTTPError as exc:
            return int(exc.code), exc.read()
        except (urllib.error.URLError, OSError, TimeoutError) as exc:
            raise GenerationError(f"cannot reach Light-O1 at {self.base_url}: {exc}") from exc

    def json(self, method: str, path: str, body: Mapping[str, Any] | None = None, *,
             expect: tuple[int, ...] = (200,), timeout: float | None = None) -> Any:
        status, payload = self.request(method, path, body, timeout=timeout)
        if status not in expect:
            raise GenerationError(_error_message(status, payload))
        try:
            return json.loads(payload.decode("utf-8"))
        except (UnicodeDecodeError, ValueError) as exc:
            raise GenerationError(f"Light-O1 returned invalid JSON from {path}") from exc


def _request_body(prompt: str, *, seed: int, thinking: bool) -> dict[str, Any]:
    text = prompt.strip()
    if not text:
        raise GenerationError("prompt must not be empty")
    if len(text) > 4000:
        raise GenerationError("prompt is longer than Light-O1's 4000 character limit")
    if not 0 <= int(seed) <= 2_147_483_647:
        raise GenerationError("seed must be within 0..2147483647")
    return {"prompt": text, "seed": int(seed), "enable_thinking": bool(thinking)}


class ControlServerClient:
    """``light-deploy-server``: POST a generation, poll it, download ``action.npy``."""

    source = "light-deploy-server"

    def __init__(self, base_url: str = "http://127.0.0.1:8090", *, timeout: float = 900.0,
                 poll_interval: float = 0.5, request_timeout: float = 30.0):
        if timeout <= 0 or poll_interval <= 0 or request_timeout <= 0:
            raise ValueError("timeouts and poll interval must be positive")
        self._http = _Http(base_url, request_timeout)
        self.timeout = timeout
        self.poll_interval = poll_interval

    @property
    def base_url(self) -> str:
        return self._http.base_url

    def health(self) -> dict[str, Any]:
        payload = self._http.json("GET", "/api/health")
        if not isinstance(payload, dict):
            raise GenerationError("Light-O1 health response is not an object")
        return payload

    def ready(self) -> bool:
        try:
            inference = self.health().get("inference", {})
        except GenerationError:
            return False
        return bool(isinstance(inference, dict) and inference.get("ready"))

    def generate(self, prompt: str, *, seed: int = 0, thinking: bool = True,
                 cancel: threading.Event | None = None) -> GeneratedAction:
        job = self._http.json("POST", "/api/generations", _request_body(prompt, seed=seed, thinking=thinking),
                              expect=(200, 202))
        generation_id = str(job.get("generation_id", "")) if isinstance(job, dict) else ""
        if not generation_id:
            raise GenerationError("Light-O1 did not return a generation_id")
        deadline = time.monotonic() + self.timeout
        status = job
        while str(status.get("state", "")) == "running":
            if cancel is not None and cancel.is_set():
                raise GenerationCancelled("generation cancelled")
            if time.monotonic() >= deadline:
                raise GenerationError(f"generation {generation_id} did not finish within {self.timeout:g}s")
            time.sleep(self.poll_interval)
            status = self._http.json("GET", f"/api/generations/{generation_id}")
            if not isinstance(status, dict):
                raise GenerationError("Light-O1 generation status is not an object")
        state = str(status.get("state", ""))
        if state != "done":
            error = status.get("error")
            message = error.get("message") if isinstance(error, dict) else error
            raise GenerationError(f"generation {state or 'failed'}: {message or 'no details'}")
        http_status, archive = self._http.request("GET", f"/api/generations/{generation_id}/download")
        if http_status != 200:
            raise GenerationError(_error_message(http_status, archive))
        try:
            with zipfile.ZipFile(io.BytesIO(archive)) as bundle:
                action = np.load(io.BytesIO(bundle.read("action.npy")), allow_pickle=False)
        except (zipfile.BadZipFile, KeyError, ValueError, OSError) as exc:
            raise GenerationError(f"Light-O1 download is not an action bundle: {exc}") from exc
        reasoning = status.get("reasoning", "")
        return GeneratedAction(prompt=prompt.strip(), action=validate_action(action),
                               reasoning=str(reasoning or ""), source=self.source,
                               generation_id=generation_id)


class GpuApiClient:
    """``light-deploy-api``: one synchronous ``POST /api/generate``."""

    source = "light-deploy-api"

    def __init__(self, base_url: str = "http://127.0.0.1:8030", *, timeout: float = 900.0):
        if timeout <= 0:
            raise ValueError("timeout must be positive")
        self._http = _Http(base_url, timeout)

    @property
    def base_url(self) -> str:
        return self._http.base_url

    def ready(self) -> bool:
        try:
            status, payload = self._http.request("GET", "/health", timeout=10.0)
        except GenerationError:
            return False
        if status != 200:
            return False
        try:
            return bool(json.loads(payload.decode("utf-8")).get("ready"))
        except (UnicodeDecodeError, ValueError, AttributeError):
            return False

    def generate(self, prompt: str, *, seed: int = 0, thinking: bool = True,
                 cancel: threading.Event | None = None) -> GeneratedAction:
        del cancel  # A single blocking request cannot be abandoned server-side.
        payload = self._http.json("POST", "/api/generate", _request_body(prompt, seed=seed, thinking=thinking))
        if not isinstance(payload, dict):
            raise GenerationError("Light-O1 generate response is not an object")
        if payload.get("representation") not in (None, REPRESENTATION):
            raise GenerationError(f"unsupported action representation {payload.get('representation')!r}")
        return GeneratedAction(prompt=prompt.strip(), action=validate_action(payload.get("action")),
                               reasoning=str(payload.get("reasoning") or ""), source=self.source)


class FileGenerator:
    """Serve saved human actions by name; no GPU, no network.

    ``directory/<name>.npy`` and ``directory/<name>/human_action.npy`` (the
    layout of Light-O1's ``run_demo.sh``) both register the prompt ``<name>``
    with underscores read as spaces. Prompts are matched case-insensitively.
    """

    source = "file"

    def __init__(self, directory):
        self.directory = Path(directory).expanduser().resolve()
        if not self.directory.is_dir():
            raise FileNotFoundError(f"action directory not found: {self.directory}")
        self._files: dict[str, Path] = {}
        self._titles: dict[str, str] = {}
        candidates = sorted(self.directory.glob("*.npy")) + sorted(self.directory.glob("*/human_action.npy"))
        for path in candidates:
            name = path.stem if path.suffix == ".npy" and path.parent == self.directory else path.parent.name
            title = name.replace("_", " ").strip()
            key = normalize_prompt(title)
            if key and key not in self._files:
                self._files[key] = path
                self._titles[key] = title
        if not self._files:
            raise FileNotFoundError(f"no *.npy or */human_action.npy actions under {self.directory}")

    @property
    def prompts(self) -> list[str]:
        return [self._titles[key] for key in sorted(self._files)]

    def ready(self) -> bool:
        return True

    def generate(self, prompt: str, *, seed: int = 0, thinking: bool = True,
                 cancel: threading.Event | None = None) -> GeneratedAction:
        del seed, thinking, cancel
        key = normalize_prompt(prompt)
        path = self._files.get(key)
        if path is None:
            raise GenerationError(f"no saved action for prompt {prompt!r}; known: {', '.join(self.prompts)}")
        try:
            action = np.load(path, allow_pickle=False)
        except (OSError, ValueError) as exc:
            raise GenerationError(f"cannot load {path}: {exc}") from exc
        return GeneratedAction(prompt=prompt.strip(), action=validate_action(action),
                               reasoning=f"replayed from {path}", source=self.source)
