from __future__ import annotations

import json
import platform
import socket
import time
import urllib.parse
import webbrowser
from pathlib import Path
from typing import Any

from . import __version__
from .client import ApiError, CollectorClient
from .config import default_server_url, load_config, save_config
from .jobs import JobContext, run_job, workstation_state


class CollectorAgent:
    def __init__(self, server_url: str | None = None, *, open_browser: bool = True) -> None:
        self.local = load_config()
        self.server_url = (server_url or self.local.get("server_url") or default_server_url()).rstrip("/")
        self.local["server_url"] = self.server_url
        self.client = CollectorClient(self.server_url, str(self.local.get("token") or ""))
        self.open_browser = open_browser
        self.remote_config = dict(self.local.get("remote_config") or {})
        self.state: dict[str, Any] = {}

    def ensure_enrolled(self, timeout_seconds: int = 600) -> None:
        if self.client.token:
            return
        response = self.client.json(
            "POST",
            "/api/collector-agent/bootstrap",
            {
                "hostname": socket.gethostname(),
                "platform": platform.system(),
                "agentVersion": __version__,
            },
            auth=False,
        )
        if not response:
            raise RuntimeError("Server returned an empty enrollment response")
        enrollment_id = str(response["enrollmentId"])
        poll_secret = str(response["pollSecret"])
        enrollment_url = self.server_url + str(response["enrollmentPath"])
        print(f"Pair this workstation in your browser:\n{enrollment_url}", flush=True)
        if self.open_browser:
            webbrowser.open(enrollment_url)

        deadline = time.monotonic() + timeout_seconds
        while time.monotonic() < deadline:
            status = self.client.json(
                "GET",
                f"/api/collector-agent/bootstrap/{urllib.parse.quote(enrollment_id)}",
                auth=False,
                headers={"X-Enrollment-Secret": poll_secret},
            )
            if status and status.get("status") == "approved":
                self.local.update({
                    "agent_id": status["agentId"],
                    "token": status["token"],
                    "remote_config": status.get("config") or {},
                })
                save_config(self.local)
                self.client.token = str(status["token"])
                self.remote_config = dict(status.get("config") or {})
                print("Workstation paired successfully.", flush=True)
                return
            time.sleep(2)
        raise TimeoutError("Workstation enrollment expired before it was approved")

    def heartbeat(self) -> None:
        base_state = workstation_state(self.remote_config)
        base_state.update(self.state)
        response = self.client.json(
            "POST",
            "/api/collector-agent/heartbeat",
            {
                "hostname": socket.gethostname(),
                "platform": platform.system(),
                "agentVersion": __version__,
                "state": base_state,
            },
        )
        if response and isinstance(response.get("config"), dict):
            self.remote_config = dict(response["config"])
            self.local["remote_config"] = self.remote_config
            save_config(self.local)

    def run_forever(self) -> None:
        self.ensure_enrolled()
        next_heartbeat = 0.0
        backoff = 1.0
        print(f"Operator Collector {__version__} connected to {self.server_url}", flush=True)
        try:
            while True:
                try:
                    now = time.monotonic()
                    if now >= next_heartbeat:
                        self.heartbeat()
                        next_heartbeat = now + 5
                    job = self.client.json("POST", "/api/collector-agent/jobs/next")
                    if job:
                        self._execute(job)
                    else:
                        time.sleep(1)
                    backoff = 1.0
                except Exception as error:
                    print(f"Collector connection error: {error}", flush=True)
                    time.sleep(backoff)
                    backoff = min(backoff * 2, 30)
        except KeyboardInterrupt:
            print("Collector stopped.", flush=True)

    def _execute(self, job: dict[str, Any]) -> None:
        job_id = str(job["id"])
        kind = str(job["kind"])
        payload = job.get("payload") if isinstance(job.get("payload"), dict) else {}
        print(f"Running job {job_id}: {kind}", flush=True)

        def progress(value: float, message: str) -> None:
            print(f"  {value * 100:5.1f}% {message}", flush=True)
            self.client.json(
                "POST",
                f"/api/collector-agent/jobs/{urllib.parse.quote(job_id)}/progress",
                {"progress": value, "message": message},
            )

        try:
            result = run_job(kind, payload, JobContext(self.remote_config, progress))
            if kind == "scan":
                source = str(result.get("source") or "quest")
                state_key = "scannedLocalSessions" if source == "local" else "scannedQuestSessions"
                self.state[state_key] = result.get("sessions", [])
                self.state[f"last{source.title()}ScanAt"] = time.time()
            complete = self.client.json(
                "POST",
                f"/api/collector-agent/jobs/{urllib.parse.quote(job_id)}/complete",
                {"message": "completed", "result": result},
                timeout=120,
            )
            item_id = str((complete or {}).get("itemId") or "")
            preview_values = result.get("preview_paths")
            if item_id and isinstance(preview_values, list):
                previews = [Path(str(value)) for value in preview_values]
                previews = [preview for preview in previews if preview.is_file()]
                if previews:
                    print(f"  uploading {len(previews)} preview images", flush=True)
                    for index, preview in enumerate(previews[:6]):
                        self.client.upload_preview_frame(item_id, index, preview)
            else:
                # Backward compatibility for jobs created by Agent 0.1.1.
                preview_value = str(result.get("preview_path") or "")
                if item_id and preview_value:
                    preview = Path(preview_value)
                    if preview.is_file():
                        print("  uploading browser preview", flush=True)
                        self.client.upload_preview(item_id, preview)
            print(f"Job {job_id} completed.", flush=True)
        except Exception as error:
            print(f"Job {job_id} failed: {error}", flush=True)
            try:
                self.client.json(
                    "POST",
                    f"/api/collector-agent/jobs/{urllib.parse.quote(job_id)}/fail",
                    {"message": "failed", "error": str(error)},
                )
            except (ApiError, RuntimeError) as report_error:
                print(f"Could not report job failure: {report_error}", flush=True)

    def status(self) -> dict[str, Any]:
        return {
            "server_url": self.server_url,
            "agent_id": self.local.get("agent_id"),
            "paired": bool(self.client.token),
            "config": self.remote_config,
            "state": workstation_state(self.remote_config),
        }

    def reset(self) -> None:
        preserved = {"server_url": self.server_url}
        save_config(preserved)
        self.local = preserved
        self.client.token = ""
        self.remote_config = {}
