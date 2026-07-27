import asyncio
import unittest
from dataclasses import dataclass, field
from typing import Any

from pyoperator.protocol.retargeting import ProtocolError
from pyoperator.services.retargeting import (
    MAX_PENDING_CONTROL_MESSAGES,
    MAX_PENDING_MESSAGES,
    RetargetingConnection,
    _receive_latest,
    _replace_latest,
)

from test_protocol_retargeting import hello_message


@dataclass
class FakeProfile:
    profile_id: str = "so101"
    input_type: str = "end_effector_pose_v1"
    output_type: str = "joint_positions_v1"
    model_hash: str = "sha256:abc"
    available: bool = True
    unavailable_reason: str = ""

    def public_dict(self) -> dict[str, Any]:
        return {
            "profile_id": self.profile_id,
            "input_type": self.input_type,
            "output_type": self.output_type,
            "model_hash": self.model_hash,
        }


@dataclass
class FakeSession:
    profile: FakeProfile
    healthy: bool = True
    resets: int = 0
    closed: bool = False
    solved: list = field(default_factory=list)

    def solve(self, source):
        self.solved.append(source)
        raise AssertionError("solving is covered by the runtime integration tests")

    def reset(self) -> None:
        self.resets += 1

    def close(self) -> None:
        self.closed = True

    def is_healthy(self) -> bool:
        return self.healthy


@dataclass
class FakeRuntime:
    """Stands in for retargeting.RetargetingRuntime, which owns solving."""

    profile: FakeProfile = field(default_factory=FakeProfile)
    session: FakeSession | None = None

    def describe_profile(self, profile_id: str) -> FakeProfile:
        if profile_id != self.profile.profile_id:
            raise KeyError(f"unknown profile '{profile_id}'")
        return self.profile

    def create_session(self, profile_id: str) -> FakeSession:
        self.session = FakeSession(self.describe_profile(profile_id))
        return self.session

    def list_profiles(self, include_unavailable: bool = True) -> list[FakeProfile]:
        if not include_unavailable and not self.profile.available:
            return []
        return [self.profile]


class HandshakeTests(unittest.TestCase):
    def setUp(self) -> None:
        self.runtime = FakeRuntime()
        self.connection = RetargetingConnection(self.runtime)

    def test_hello_opens_a_session_and_returns_the_profile(self) -> None:
        ack = self.connection.hello(hello_message())
        self.assertEqual(ack["type"], "hello_ack")
        self.assertEqual(ack["profile"]["profile_id"], "so101")
        self.assertIs(self.connection.profile, self.runtime.profile)

    def test_empty_client_hash_trusts_the_host(self) -> None:
        self.connection.hello(hello_message(model_hash=""))
        self.assertIsNotNone(self.runtime.session)

    def test_mismatching_model_hash_is_rejected(self) -> None:
        with self.assertRaises(ProtocolError) as caught:
            self.connection.hello(hello_message(model_hash="sha256:other"))
        self.assertEqual(caught.exception.code, "model_mismatch")
        self.assertIsNone(self.runtime.session)

    def test_unknown_profile_is_rejected(self) -> None:
        with self.assertRaises(ProtocolError) as caught:
            self.connection.hello(hello_message(profile_id="nope"))
        self.assertEqual(caught.exception.code, "unknown_profile")

    def test_unavailable_profile_reports_the_reason(self) -> None:
        self.runtime.profile.available = False
        self.runtime.profile.unavailable_reason = "worker missing"
        with self.assertRaises(ProtocolError) as caught:
            self.connection.hello(hello_message())
        self.assertEqual(caught.exception.code, "profile_unavailable")
        self.assertIn("worker missing", str(caught.exception))

    def test_input_type_mismatch_is_rejected(self) -> None:
        with self.assertRaises(ProtocolError) as caught:
            self.connection.hello(hello_message(input_type="skeleton_frame_v1"))
        self.assertEqual(caught.exception.code, "input_type_mismatch")

    def test_second_hello_is_rejected(self) -> None:
        self.connection.hello(hello_message())
        with self.assertRaises(ProtocolError):
            self.connection.hello(hello_message())

    def test_frames_before_hello_are_rejected(self) -> None:
        with self.assertRaises(ProtocolError) as caught:
            self.connection.handle({"type": "frame", "frame_id": 1, "timestamp_ns": 1, "payload": {}})
        self.assertEqual(caught.exception.code, "hello_required")


class SessionMessageTests(unittest.TestCase):
    def setUp(self) -> None:
        self.runtime = FakeRuntime()
        self.connection = RetargetingConnection(self.runtime)
        self.connection.hello(hello_message())

    def test_reset_forwards_to_the_session(self) -> None:
        self.assertEqual(self.connection.handle({"type": "reset"}), {"type": "reset_ack"})
        self.assertEqual(self.runtime.session.resets, 1)

    def test_unknown_message_types_are_rejected(self) -> None:
        with self.assertRaises(ProtocolError) as caught:
            self.connection.handle({"type": "ping"})
        self.assertEqual(caught.exception.code, "invalid_message")
        with self.assertRaises(ProtocolError):
            self.connection.handle("not-an-object")

    def test_health_follows_the_session(self) -> None:
        self.assertTrue(self.connection.is_healthy())
        self.runtime.session.healthy = False
        self.assertFalse(self.connection.is_healthy())

    def test_close_releases_the_session_once(self) -> None:
        session = self.runtime.session
        self.connection.close()
        self.connection.close()
        self.assertTrue(session.closed)
        self.assertTrue(self.connection.is_healthy())


class FakeSocket:
    """Replays a scripted client, then fails like a closed WebSocket."""

    def __init__(self, messages):
        self._messages = list(messages)

    async def receive_json(self):
        if not self._messages:
            raise RuntimeError("peer disconnected")
        message = self._messages.pop(0)
        if isinstance(message, Exception):
            raise message
        return message


class LatestOnlyQueueTests(unittest.TestCase):
    """A late solve must never make the operator's motion lag behind."""

    def test_a_newer_frame_evicts_the_one_still_waiting(self) -> None:
        async def scenario():
            queue: asyncio.Queue = asyncio.Queue(maxsize=MAX_PENDING_MESSAGES)
            _replace_latest(queue, {"type": "frame", "frame_id": 1})
            _replace_latest(queue, {"type": "frame", "frame_id": 2})
            self.assertEqual(queue.qsize(), 1)
            self.assertEqual((await queue.get())["frame_id"], 2)

        asyncio.run(scenario())

    def test_reset_is_not_evicted_by_the_next_frame(self) -> None:
        async def scenario():
            queue: asyncio.Queue = asyncio.Queue(maxsize=MAX_PENDING_MESSAGES)
            _replace_latest(queue, {"type": "reset"})
            _replace_latest(queue, {"type": "frame", "frame_id": 1})
            self.assertEqual((await queue.get())["type"], "reset")
            self.assertEqual((await queue.get())["frame_id"], 1)

        asyncio.run(scenario())

    def test_reset_remains_a_barrier_between_coalesced_frames(self) -> None:
        async def scenario():
            queue: asyncio.Queue = asyncio.Queue(maxsize=MAX_PENDING_MESSAGES)
            _replace_latest(queue, {"type": "frame", "frame_id": 1})
            _replace_latest(queue, {"type": "reset"})
            _replace_latest(queue, {"type": "frame", "frame_id": 2})
            self.assertEqual((await queue.get())["type"], "reset")
            self.assertEqual((await queue.get())["frame_id"], 2)

        asyncio.run(scenario())

    def test_receiver_keeps_only_the_newest_and_signals_disconnect(self) -> None:
        async def scenario():
            queue: asyncio.Queue = asyncio.Queue(maxsize=MAX_PENDING_MESSAGES)
            socket = FakeSocket(
                [
                    {"type": "frame", "frame_id": 1},
                    {"type": "frame", "frame_id": 2},
                    {"type": "frame", "frame_id": 3},
                ]
            )
            await _receive_latest(socket, queue)
            # Everything the peer sent was superseded before the solver woke up;
            # what remains is the disconnect that must break the solve loop.
            final = await queue.get()
            self.assertEqual(final["type"], "_disconnect")
            self.assertIn("disconnected", final["reason"])

        asyncio.run(scenario())

    def test_non_object_messages_report_a_protocol_error(self) -> None:
        async def scenario():
            queue: asyncio.Queue = asyncio.Queue(maxsize=MAX_PENDING_MESSAGES)
            await _receive_latest(FakeSocket([["not", "an", "object"]]), queue)
            error = await queue.get()
            self.assertEqual(error["type"], "_protocol_error")
            self.assertEqual(error["code"], "invalid_message")

        asyncio.run(scenario())

    def test_invalid_json_reports_a_protocol_error(self) -> None:
        async def scenario():
            queue: asyncio.Queue = asyncio.Queue(maxsize=MAX_PENDING_MESSAGES)
            await _receive_latest(FakeSocket([ValueError("bad json")]), queue)
            error = await queue.get()
            self.assertEqual(error["type"], "_protocol_error")
            self.assertEqual(error["code"], "invalid_json")

        asyncio.run(scenario())

    def test_unknown_message_type_reports_a_protocol_error(self) -> None:
        async def scenario():
            queue: asyncio.Queue = asyncio.Queue(maxsize=MAX_PENDING_MESSAGES)
            await _receive_latest(FakeSocket([{"type": "ping"}]), queue)
            error = await queue.get()
            self.assertEqual(error["type"], "_protocol_error")
            self.assertEqual(error["code"], "invalid_message")

        asyncio.run(scenario())

    def test_reset_flood_is_bounded_and_becomes_a_protocol_error(self) -> None:
        async def scenario():
            queue: asyncio.Queue = asyncio.Queue(maxsize=MAX_PENDING_MESSAGES)
            for _ in range(MAX_PENDING_CONTROL_MESSAGES):
                self.assertTrue(_replace_latest(queue, {"type": "reset"}))
            self.assertEqual(queue.qsize(), MAX_PENDING_CONTROL_MESSAGES)
            self.assertFalse(_replace_latest(queue, {"type": "reset"}))
            self.assertEqual(queue.qsize(), 1)
            error = await queue.get()
            self.assertEqual(error["type"], "_protocol_error")
            self.assertEqual(error["code"], "too_many_pending_messages")

        asyncio.run(scenario())
