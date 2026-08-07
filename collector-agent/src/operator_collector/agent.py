from __future__ import annotations

import json
import platform
import socket
import threading
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
        self._state_lock = threading.RLock()

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
        base_state = workstation_state(self._runtime_config())
        with self._state_lock:
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
            with self._state_lock:
                self.remote_config = dict(response["config"])
                self.local["remote_config"] = self.remote_config
                save_config(self.local)

        credentials = (response or {}).get("uploadCredentials")
        if isinstance(credentials, dict):
            provisioned_token = str(credentials.get("token") or "").strip()
            with self._state_lock:
                if provisioned_token and self.local.get("modelscope_token") != provisioned_token:
                    self.local["modelscope_token"] = provisioned_token
                    save_config(self.local)

    def _heartbeat_forever(self, stopped: threading.Event) -> None:
        """Keep presence independent from long-running transfer jobs."""
        delay = 0.0
        backoff = 5.0
        while not stopped.wait(delay):
            try:
                self.heartbeat()
                delay = 5.0
                backoff = 5.0
            except Exception as error:
                print(f"Collector heartbeat error: {error}", flush=True)
                delay = backoff
                backoff = min(backoff * 2, 30.0)

    def run_forever(self) -> None:
        self.ensure_enrolled()
        heartbeat_stopped = threading.Event()
        heartbeat_thread = threading.Thread(
            target=self._heartbeat_forever,
            args=(heartbeat_stopped,),
            name="operator-collector-heartbeat",
            daemon=True,
        )
        heartbeat_thread.start()
        backoff = 1.0
        print(f"Operator Collector {__version__} connected to {self.server_url}", flush=True)
        try:
            while True:
                try:
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
        finally:
            heartbeat_stopped.set()
            heartbeat_thread.join(timeout=2)

    def _execute(self, job: dict[str, Any]) -> None:
        job_id = str(job["id"])
        kind = str(job["kind"])
        payload = job.get("payload") if isinstance(job.get("payload"), dict) else {}
        print(f"Running job {job_id}: {kind}", flush=True)

        def progress(
            value: float,
            message: str,
            metrics: dict[str, Any] | None = None,
        ) -> None:
            print(f"  {value * 100:5.1f}% {message}", flush=True)
            body: dict[str, Any] = {"progress": value, "message": message}
            if metrics:
                body["metrics"] = metrics
            self.client.json(
                "POST",
                f"/api/collector-agent/jobs/{urllib.parse.quote(job_id)}/progress",
                body,
            )

        try:
            result = run_job(kind, payload, JobContext(self._runtime_config(), progress))
            if kind == "scan":
                source = str(result.get("source") or "quest")
                state_key = "scannedLocalSessions" if source == "local" else "scannedQuestSessions"
                with self._state_lock:
                    self.state[state_key] = result.get("sessions", [])
                    self.state[f"last{source.title()}ScanAt"] = time.time()
            elif kind == "delete_quest":
                with self._state_lock:
                    self.state["scannedQuestSessions"] = result.get("sessions", [])
                    self.state["lastQuestScanAt"] = time.time()
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
            "state": workstation_state(self._runtime_config()),
        }

    def reset(self) -> None:
        preserved = {"server_url": self.server_url}
        save_config(preserved)
        self.local = preserved
        self.client.token = ""
        self.remote_config = {}

    def _runtime_config(self) -> dict[str, Any]:
        with self._state_lock:
            config = dict(self.remote_config)
            token = str(self.local.get("modelscope_token") or "").strip()
        if token:
            config["_modelscope_token"] = token
        return config
