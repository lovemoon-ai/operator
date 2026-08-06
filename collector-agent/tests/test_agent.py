from __future__ import annotations

import threading
import unittest
from unittest.mock import patch

from operator_collector.agent import CollectorAgent


class AgentTests(unittest.TestCase):
    def make_agent(self) -> CollectorAgent:
        with patch("operator_collector.agent.load_config", return_value={}):
            return CollectorAgent("http://station.invalid", open_browser=False)

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


if __name__ == "__main__":
    unittest.main()
