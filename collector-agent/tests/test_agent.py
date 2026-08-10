from __future__ import annotations

import threading
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from operator_collector.agent import CollectorAgent


class AgentTests(unittest.TestCase):
    def make_agent(self) -> CollectorAgent:
        with patch("operator_collector.agent.load_config", return_value={}):
            agent = CollectorAgent("http://station.invalid", open_browser=False)
        save_patcher = patch("operator_collector.agent.save_config")
        save_patcher.start()
        self.addCleanup(save_patcher.stop)
        return agent

    def test_heartbeat_worker_runs_independently(self) -> None:
        agent = self.make_agent()
        stopped = threading.Event()
        calls: list[bool] = []

        def heartbeat() -> None:
            calls.append(True)
            stopped.set()

        agent.heartbeat = heartbeat  # type: ignore[method-assign]
        agent._heartbeat_forever(stopped)
        self.assertEqual(calls, [True])

    def test_job_progress_forwards_transfer_metrics(self) -> None:
        agent = self.make_agent()
        requests: list[tuple[str, str, dict | None]] = []

        def request(method: str, path: str, body: dict | None = None, **_kwargs):
            requests.append((method, path, body))
            return {}

        agent.client.json = request  # type: ignore[method-assign]

        def run(_kind, _payload, context):
            context.progress(
                0.5,
                "uploading",
                {"transferredBytes": 50, "totalBytes": 100},
            )
            return {}

        with patch("operator_collector.agent.run_job", side_effect=run):
            agent._execute({"id": "job-1", "kind": "upload", "payload": {}})

        progress_request = next(value for value in requests if value[1].endswith("/progress"))
        self.assertEqual(progress_request[2]["metrics"]["transferredBytes"], 50)

    def test_progress_failure_does_not_fail_completed_local_work(self) -> None:
        agent = self.make_agent()
        paths: list[str] = []

        def request(_method: str, path: str, _body=None, **_kwargs):
            paths.append(path)
            if path.endswith("/progress"):
                raise RuntimeError("station temporarily offline")
            return {}

        agent.client.json = request  # type: ignore[method-assign]
        with patch("operator_collector.agent.run_job", return_value={}):
            agent._execute({"id": "job-2", "kind": "scan", "payload": {}})

        self.assertTrue(any(path.endswith("/complete") for path in paths))
        self.assertFalse(any(path.endswith("/fail") for path in paths))

    def test_completion_is_journaled_and_retried_after_network_loss(self) -> None:
        agent = self.make_agent()
        paths: list[str] = []

        def request(_method: str, path: str, _body=None, **_kwargs):
            paths.append(path)
            if path.endswith("/complete"):
                raise RuntimeError("response lost")
            return {}

        agent.client.json = request  # type: ignore[method-assign]
        with patch("operator_collector.agent.run_job", return_value={"value": 1}):
            agent._execute({"id": "job-3", "kind": "scan", "payload": {}})

        self.assertEqual(agent.local["pending_job_completions"]["job-3"], {"value": 1})
        self.assertFalse(any(path.endswith("/fail") for path in paths))

        agent.client.json = lambda *_args, **_kwargs: {}  # type: ignore[method-assign]
        agent._flush_pending_completions()
        self.assertNotIn("pending_job_completions", agent.local)

    def test_journal_failure_never_reports_committed_work_as_failed(self) -> None:
        agent = self.make_agent()
        paths: list[str] = []

        def request(_method: str, path: str, _body=None, **_kwargs):
            paths.append(path)
            if path.endswith("/complete"):
                raise RuntimeError("station offline")
            return {}

        agent.client.json = request  # type: ignore[method-assign]
        with (
            patch("operator_collector.agent.run_job", return_value={"committed": True}),
            patch("operator_collector.agent.save_config", side_effect=OSError("disk full")),
        ):
            agent._execute({"id": "job-journal", "kind": "import", "payload": {}})

        self.assertTrue(any(path.endswith("/complete") for path in paths))
        self.assertFalse(any(path.endswith("/fail") for path in paths))

    def test_preview_failure_never_reverses_completion(self) -> None:
        agent = self.make_agent()
        paths: list[str] = []
        with tempfile.TemporaryDirectory() as directory:
            preview = Path(directory) / "preview.jpg"
            preview.write_bytes(b"jpeg")

            def request(_method: str, path: str, _body=None, **_kwargs):
                paths.append(path)
                return {"itemId": "item-1"} if path.endswith("/complete") else {}

            agent.client.json = request  # type: ignore[method-assign]
            agent.client.upload_preview_frame = (  # type: ignore[method-assign]
                lambda *_args, **_kwargs: (_ for _ in ()).throw(RuntimeError("preview failed"))
            )
            with patch(
                "operator_collector.agent.run_job",
                return_value={"preview_paths": [str(preview)]},
            ):
                agent._execute({"id": "job-4", "kind": "import", "payload": {}})

        self.assertFalse(any(path.endswith("/fail") for path in paths))


if __name__ == "__main__":
    unittest.main()
