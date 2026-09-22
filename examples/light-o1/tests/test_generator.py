"""Light-O1 HTTP clients against a scripted local server; no GPU, no Light-O1 code."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import io
import json
import threading
import zipfile

import numpy as np
import pytest

from light_o1_vr.generator import (
    ACTION_DIM, ControlServerClient, FileGenerator, GenerationCancelled, GenerationError, GpuApiClient,
    normalize_prompt, validate_action,
)


class Script:
    """Server behaviour shared with the handler: polls before done, terminal state, action."""

    def __init__(self, *, polls_until_done=2, final_state="done", action_frames=6, ready=True,
                 http_error=None):
        self.polls_until_done = polls_until_done
        self.final_state = final_state
        self.action = np.arange(action_frames * ACTION_DIM, dtype=np.float32).reshape(action_frames, ACTION_DIM)
        self.ready = ready
        self.http_error = http_error
        self.requests = []
        self.polls = 0
        self.lock = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    script: Script

    def log_message(self, *args):
        pass

    def _send(self, status, payload, content_type="application/json"):
        body = payload if isinstance(payload, bytes) else json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        script = self.script
        if self.path == "/api/health":
            return self._send(200, {"ok": True, "inference": {"ready": script.ready, "state": "ready"}})
        if self.path == "/health":
            return self._send(200 if script.ready else 503, {"ready": script.ready})
        if self.path == "/api/generations/gen1":
            with script.lock:
                script.polls += 1
                polls = script.polls
            if polls < script.polls_until_done:
                return self._send(200, {"generation_id": "gen1", "state": "running", "reasoning": ""})
            payload = {"generation_id": "gen1", "state": script.final_state, "reasoning": "raise the arm",
                       "num_frames": len(script.action), "error": None}
            if script.final_state == "error":
                payload["error"] = {"message": "vLLM exploded"}
            return self._send(200, payload)
        if self.path == "/api/generations/gen1/download":
            action_bytes = io.BytesIO()
            np.save(action_bytes, script.action, allow_pickle=False)
            archive = io.BytesIO()
            with zipfile.ZipFile(archive, "w") as bundle:
                bundle.writestr("action.npy", action_bytes.getvalue())
                bundle.writestr("reasoning.txt", "raise the arm")
            return self._send(200, archive.getvalue(), "application/zip")
        return self._send(404, {"detail": "Generation expired or not found"})

    def do_POST(self):
        script = self.script
        length = int(self.headers.get("Content-Length", "0"))
        body = json.loads(self.rfile.read(length) or b"{}")
        script.requests.append((self.path, body))
        if script.http_error is not None:
            status, detail = script.http_error
            return self._send(status, {"detail": detail})
        if self.path == "/api/generations":
            return self._send(202, {"generation_id": "gen1", "state": "running", "prompt": body["prompt"]})
        if self.path == "/api/generate":
            return self._send(200, {"schema_version": 1, "representation": "human_action_138_v1",
                                    "action": script.action.tolist(), "num_frames": len(script.action),
                                    "fps": 20, "reasoning": "swing"})
        return self._send(404, {"detail": "unknown"})


@pytest.fixture
def server():
    servers = []

    def start(**kwargs):
        script = Script(**kwargs)
        handler = type("ScriptedHandler", (Handler,), {"script": script})
        httpd = ThreadingHTTPServer(("127.0.0.1", 0), handler)
        thread = threading.Thread(target=httpd.serve_forever, daemon=True)
        thread.start()
        servers.append(httpd)
        return f"http://127.0.0.1:{httpd.server_address[1]}", script

    yield start
    for httpd in servers:
        httpd.shutdown()
        httpd.server_close()


def test_control_server_client_posts_polls_and_downloads(server):
    url, script = server(polls_until_done=3)
    client = ControlServerClient(url, poll_interval=0.01)
    assert client.ready()
    result = client.generate("  wave hello ", seed=7, thinking=False)
    assert script.requests == [("/api/generations", {"prompt": "wave hello", "seed": 7, "enable_thinking": False})]
    assert script.polls == 3
    assert result.prompt == "wave hello" and result.generation_id == "gen1"
    assert result.action.shape == (6, ACTION_DIM) and result.action.dtype == np.float32
    assert np.array_equal(result.action, script.action)
    assert result.reasoning == "raise the arm" and result.source == "light-deploy-server"
    assert result.frames == 6 and result.seconds == pytest.approx(0.3)


def test_control_server_client_reports_failed_generation(server):
    url, _ = server(final_state="error")
    with pytest.raises(GenerationError, match="vLLM exploded"):
        ControlServerClient(url, poll_interval=0.01).generate("x")


def test_control_server_client_surfaces_http_errors(server):
    url, _ = server(http_error=(503, "Inference service is not ready"))
    with pytest.raises(GenerationError, match="HTTP 503: Inference service is not ready"):
        ControlServerClient(url).generate("x")
    with pytest.raises(GenerationError, match="cannot reach"):
        ControlServerClient("http://127.0.0.1:9", request_timeout=1.0).generate("x")
    assert not ControlServerClient("http://127.0.0.1:9", request_timeout=1.0).ready()


def test_control_server_client_can_be_cancelled_while_polling(server):
    url, _ = server(polls_until_done=10_000)
    cancel = threading.Event()
    cancel.set()
    with pytest.raises(GenerationCancelled):
        ControlServerClient(url, poll_interval=0.01).generate("x", cancel=cancel)
    with pytest.raises(GenerationError, match="did not finish"):
        ControlServerClient(url, poll_interval=0.01, timeout=0.05).generate("x")


def test_control_server_client_rejects_bad_prompts_locally(server):
    url, script = server()
    client = ControlServerClient(url)
    with pytest.raises(GenerationError, match="empty"):
        client.generate("   ")
    with pytest.raises(GenerationError, match="seed"):
        client.generate("x", seed=-1)
    assert script.requests == []
    with pytest.raises(ValueError):
        ControlServerClient("localhost:8090")
    with pytest.raises(ValueError):
        ControlServerClient(url, timeout=0)


def test_gpu_api_client_uses_one_synchronous_request(server):
    url, script = server()
    client = GpuApiClient(url)
    assert client.ready()
    result = client.generate("punch", seed=1)
    assert script.requests == [("/api/generate", {"prompt": "punch", "seed": 1, "enable_thinking": True})]
    assert result.action.shape == (6, ACTION_DIM) and result.reasoning == "swing"
    assert result.source == "light-deploy-api"
    assert not GpuApiClient("http://127.0.0.1:9", timeout=1.0).ready()


def test_validate_action_rejects_wrong_shapes_and_values():
    assert validate_action(np.zeros((2, ACTION_DIM))).dtype == np.float32
    for bad in (np.zeros((ACTION_DIM,)), np.zeros((0, ACTION_DIM)), np.zeros((2, 10)), [["x"] * ACTION_DIM]):
        with pytest.raises(GenerationError):
            validate_action(bad)
    nan = np.zeros((1, ACTION_DIM))
    nan[0, 0] = np.nan
    with pytest.raises(GenerationError, match="non-finite"):
        validate_action(nan)


def test_file_generator_indexes_npy_files_and_run_directories(tmp_path):
    np.save(tmp_path / "wave_right_hand.npy", np.zeros((3, ACTION_DIM), np.float32))
    (tmp_path / "walk").mkdir()
    np.save(tmp_path / "walk" / "human_action.npy", np.ones((4, ACTION_DIM), np.float32))
    (tmp_path / "notes.txt").write_text("ignored")
    generator = FileGenerator(tmp_path)
    assert generator.prompts == ["walk", "wave right hand"]
    result = generator.generate("Wave  RIGHT hand!")
    assert result.action.shape == (3, ACTION_DIM) and result.source == "file"
    assert generator.generate("walk").action.shape == (4, ACTION_DIM)
    with pytest.raises(GenerationError, match="no saved action"):
        generator.generate("fly")
    with pytest.raises(FileNotFoundError):
        FileGenerator(tmp_path / "missing")
    (tmp_path / "empty").mkdir()
    with pytest.raises(FileNotFoundError):
        FileGenerator(tmp_path / "empty")
    assert normalize_prompt("  Wave, right-hand!! ") == "wave right hand"
