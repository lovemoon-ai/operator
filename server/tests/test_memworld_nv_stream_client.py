import socket
import tempfile
import threading
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import numpy as np

from server.memworld_chunks import LiveChunk, ProjectedSample
from server.memworld_stream_protocol import recv_message, send_message
from server.memworld_worker_client import (
    MemWorldNVStreamClient,
    MemWorldWorkerClient,
    build_worker_client,
)


class DummySlot:
    running = None


class FiniteSlot:
    def __init__(self, chunks):
        self._chunks = list(chunks)
        self._lock = threading.Lock()
        self.running = None

    def start_next(self):
        with self._lock:
            if self.running is not None or not self._chunks:
                return None
            self.running = self._chunks.pop(0)
            return self.running

    def finish(self, chunk_id):
        with self._lock:
            if self.running is None or self.running.chunk_id != chunk_id:
                raise ValueError("wrong running chunk")
            self.running = None


class FakeDecoder:
    def __init__(self, **_kwargs):
        self.persistent_decoder = False

    def feed_init(self, _payload):
        pass

    def decode_fragment(self, _payload, *, frame_count):
        return tuple(b"jpeg" for _ in range(frame_count))

    def close(self):
        pass


class MemWorldNVStreamClientTests(unittest.TestCase):
    def test_reconnect_uses_a_fresh_worker_session_id(self):
        self.assertEqual(
            MemWorldNVStreamClient._session_id_for_attempt("quest-abc", 0),
            "quest-abc",
        )
        self.assertEqual(
            MemWorldNVStreamClient._session_id_for_attempt("quest-abc", 3),
            "quest-abc-r3",
        )

    def test_stream_protocol_round_trip(self):
        left, right = socket.socketpair()
        received = {}

        def receiver():
            received["value"] = recv_message(right)

        thread = threading.Thread(target=receiver)
        thread.start()
        send_message(left, {"type": "test", "index": 3}, b"payload")
        thread.join(timeout=2)
        left.close()
        right.close()
        self.assertEqual(
            received["value"],
            (
                {
                    "index": 3,
                    "payload_bytes": 7,
                    "type": "test",
                },
                b"payload",
            ),
        )

    def test_worker_factory_selects_transport_from_url_scheme(self):
        common = {
            "session_start": {},
            "slot": DummySlot(),
            "on_result": lambda _result: None,
            "on_status": lambda _status, _error: None,
        }
        stream = build_worker_client(
            url="tcp://127.0.0.1:18768",
            **common,
        )
        websocket = build_worker_client(
            url="ws://127.0.0.1:18765",
            **common,
        )
        self.assertIsInstance(stream, MemWorldNVStreamClient)
        self.assertIsInstance(websocket, MemWorldWorkerClient)

    def test_nv_client_uploads_next_chunk_before_first_media_returns(self):
        listener = socket.socket()
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        port = listener.getsockname()[1]
        server_error = []
        received_actions = []

        def fake_worker():
            try:
                connection, _ = listener.accept()
                connection.settimeout(5)
                init, _ = recv_message(connection)
                send_message(connection, {
                    "type": "session.accepted",
                    "container": "fmp4",
                    "continuous_decoder": True,
                    "duplex_action_upload": True,
                    "output_fps": 20.0,
                    "checkpoint_sha256": "test",
                    "temporal_kv": "ABSENT",
                })
                while True:
                    header, _ = recv_message(connection)
                    if header["type"] == "action.frame":
                        received_actions.append(header["frame_index"])
                    elif header["type"] == "session.end":
                        break
                # Deliberately withhold all media until both input windows
                # arrive.  A request/response client deadlocks here.
                self.assertEqual(received_actions, list(range(33)))
                send_message(connection, {"type": "video.init"}, b"init")
                for chunk_index in range(2):
                    send_message(connection, {
                        "type": "video.fragment",
                        "chunk_index": chunk_index,
                        "encoded_frame_count": 16,
                        "fmp4_leading_frames": 0,
                        "audit": {
                            "future_rgb_frames": 0,
                            "unknown_rgb_frames": 0,
                            "teacher_forced_rgb_frames": 0,
                        },
                    }, b"fragment")
                send_message(connection, {
                    "type": "session.completed",
                    "chunks_completed": 2,
                })
                connection.close()
            except BaseException as exc:
                server_error.append(exc)
            finally:
                listener.close()

        samples = []
        for frame_id in range(33):
            samples.append(ProjectedSample(
                frame_id=frame_id,
                capture_time_ns=frame_id,
                server_received_ns=frame_id,
                calibration_id="test",
                c2w=np.eye(4, dtype=np.float32),
                keypoint_png=b"png",
            ))
        chunks = [
            LiveChunk(1, tuple(samples[:17]), 0),
            LiveChunk(2, tuple(samples[16:33]), 0),
        ]
        slot = FiniteSlot(chunks)
        results = []
        statuses = []
        worker_thread = threading.Thread(target=fake_worker)
        worker_thread.start()
        with tempfile.TemporaryDirectory() as temporary:
            initial = Path(temporary) / "frame0.png"
            initial.write_bytes(b"rgb")
            client = MemWorldNVStreamClient(
                url=f"tcp://127.0.0.1:{port}",
                session_start={
                    "session_id": "duplex-test",
                    "width": 640,
                    "height": 352,
                    "playback_fps": 20.0,
                    "worker_session_chunks": 2,
                    "initial_rgb": str(initial),
                    "ffmpeg_bin": "ffmpeg",
                },
                slot=slot,
                on_result=results.append,
                on_status=lambda status, error: statuses.append(
                    (status, error)
                ),
            )
            with patch(
                "server.memworld_worker_client.FragmentedMP4Decoder",
                FakeDecoder,
            ):
                client._run_blocking()
        worker_thread.join(timeout=5)
        self.assertFalse(worker_thread.is_alive())
        if server_error:
            raise server_error[0]
        self.assertEqual([item.chunk_id for item in results], [1, 2])
        self.assertEqual(statuses[-1], ("completed", ""))


if __name__ == "__main__":
    unittest.main()
