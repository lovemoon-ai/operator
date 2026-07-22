from dataclasses import replace
import json
import socket
import struct
import threading
import time
import unittest
import uuid

import pytest

from pyoperator.session import BridgeConfig, XrSession

try:
    from pyoperator import _native  # noqa: F401
except ImportError:
    HAS_NATIVE = False
else:
    HAS_NATIVE = True


pytestmark = pytest.mark.loopback


def _tcp_port() -> int:
    with socket.socket() as sock:
        sock.bind(("0.0.0.0", 0))
        return int(sock.getsockname()[1])


def _udp_port() -> int:
    with socket.socket(type=socket.SOCK_DGRAM) as sock:
        sock.bind(("0.0.0.0", 0))
        return int(sock.getsockname()[1])


def _send_frame(sock: socket.socket, command: str, payload: dict) -> None:
    _send_payload(sock, command, json.dumps(payload).encode())


def _send_payload(sock: socket.socket, command: str, data: bytes) -> None:
    command_bytes = command.encode()
    sock.sendall(
        struct.pack("<i", len(command_bytes))
        + command_bytes
        + struct.pack("<i", len(data))
        + data
    )


def _recv_exact(sock: socket.socket, size: int) -> bytes:
    chunks = []
    remaining = size
    while remaining:
        chunk = sock.recv(remaining)
        if not chunk:
            raise ConnectionError("socket closed before complete command frame")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def _recv_command(sock: socket.socket) -> tuple[str, bytes]:
    command_size = struct.unpack("<i", _recv_exact(sock, 4))[0]
    command = _recv_exact(sock, command_size).decode()
    data_size = struct.unpack("<i", _recv_exact(sock, 4))[0]
    return command, _recv_exact(sock, data_size)


def _connect_fake_headset(port: int) -> tuple[socket.socket, dict]:
    """Connect a host socket that imitates the headset wire protocol."""
    sock = socket.create_connection(("127.0.0.1", port), timeout=2.0)
    _send_frame(sock, "Hello", {"version": "2.0", "capabilities": ["xr_state_v1"]})
    command, payload = _recv_command(sock)
    if command != "DeviceDescriptor":
        raise AssertionError(f"unexpected handshake response: {command}")
    return sock, json.loads(payload)


def _wait_for_socket_close(sock: socket.socket, timeout: float = 2.0) -> bool:
    deadline = time.monotonic() + timeout
    sock.settimeout(0.1)
    while time.monotonic() < deadline:
        try:
            if not sock.recv(4096):
                return True
        except socket.timeout:
            continue
        except (ConnectionError, OSError):
            return True
    return False


def _frame(frame_id: int) -> dict:
    return {
        "schema_version": 1,
        "frame_id": frame_id,
        "timestamp_ns": frame_id * 1000,
        "coordinate_space": "godot_world",
        "controllers": {},
        "hands": {},
        "motion_trackers": [],
    }


def _config() -> BridgeConfig:
    return BridgeConfig(
        name=f"pyoperator-test-{uuid.uuid4().hex}",
        pose_port=_tcp_port(),
        discovery_port=_udp_port(),
        pose_udp_port=_udp_port(),
        telemetry_port=_tcp_port(),
    )


def _wait_until(predicate, timeout: float = 2.0) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.01)
    return bool(predicate())


@unittest.skipUnless(HAS_NATIVE, "requires the built pyoperator native extension")
class NativeLifecycleTests(unittest.TestCase):
    def test_start_raises_when_pose_port_is_in_use(self) -> None:
        with socket.socket() as occupied:
            occupied.bind(("0.0.0.0", 0))
            occupied.listen()
            config = BridgeConfig(
                name=f"pyoperator-test-{uuid.uuid4().hex}",
                pose_port=int(occupied.getsockname()[1]),
                discovery_port=_udp_port(),
                pose_udp_port=_udp_port(),
                telemetry_port=_tcp_port(),
            )
            session = XrSession(config)
            with self.assertRaisesRegex(RuntimeError, "binding XR pose TCP port"):
                session.start()
            self.assertFalse(session.is_running)

    def test_start_raises_when_udp_or_telemetry_port_is_in_use(self) -> None:
        with socket.socket(type=socket.SOCK_DGRAM) as occupied_udp:
            occupied_udp.bind(("0.0.0.0", 0))
            session = XrSession(
                replace(_config(), pose_udp_port=int(occupied_udp.getsockname()[1]))
            )
            with self.assertRaisesRegex(RuntimeError, "binding XR pose UDP port"):
                session.start()
            self.assertFalse(session.is_running)

        with socket.socket() as occupied_telemetry:
            occupied_telemetry.bind(("0.0.0.0", 0))
            occupied_telemetry.listen()
            session = XrSession(
                replace(
                    _config(), telemetry_port=int(occupied_telemetry.getsockname()[1])
                )
            )
            with self.assertRaisesRegex(RuntimeError, "binding XR telemetry TCP port"):
                session.start()
            self.assertFalse(session.is_running)

    @pytest.mark.fake_headset
    def test_restart_clears_stale_frame_and_accepts_reset_frame_id(self) -> None:
        config = _config()
        session = XrSession(config).start()
        first_headset, descriptor = _connect_fake_headset(config.pose_port)
        try:
            self.assertEqual(descriptor["xr_stream"]["schema_version"], 1)
            self.assertEqual(descriptor["xr_stream"]["rate_hz"], 72)
            self.assertIn("controllers", descriptor["xr_stream"]["streams"])
            _send_frame(first_headset, "XrStateFrame", _frame(900))
            self.assertEqual(session.wait_next(timeout=1.0).frame_id, 900)
            self.assertEqual(session.latest().frame_id, 900)
            self.assertTrue(session.stats().connected)
        finally:
            first_headset.close()
            session.close()

        session.start()
        try:
            self.assertIsNone(session.latest())
            self.assertIsNone(session.wait_next(0, timeout=0.0))
            self.assertEqual(session.stats().frames_received, 0)

            second_headset, _descriptor = _connect_fake_headset(config.pose_port)
            try:
                _send_frame(second_headset, "XrStateFrame", _frame(1))
                self.assertEqual(session.wait_next(0, timeout=1.0).frame_id, 1)
            finally:
                second_headset.close()
        finally:
            session.close()

    @pytest.mark.fake_headset
    def test_headset_reconnect_accepts_reset_frame_id_without_session_restart(self) -> None:
        config = _config()
        session = XrSession(config).start()
        first_headset, _descriptor = _connect_fake_headset(config.pose_port)
        try:
            _send_frame(first_headset, "XrStateFrame", _frame(900))
            self.assertEqual(session.wait_next(0, timeout=1.0).frame_id, 900)
            first_headset.close()
            self.assertTrue(_wait_until(lambda: not session.stats().connected))

            second_headset, _descriptor = _connect_fake_headset(config.pose_port)
            try:
                _send_frame(second_headset, "XrStateFrame", _frame(1))
                reset = session.wait_next(900, timeout=1.0)
                self.assertIsNotNone(reset)
                self.assertEqual(reset.frame_id, 1)
                self.assertIsNone(session.wait_next(1, timeout=0.0))
            finally:
                second_headset.close()
        finally:
            first_headset.close()
            session.close()

    @pytest.mark.fake_headset
    def test_sdk_rejects_headset_without_xr_state_capability(self) -> None:
        config = _config()
        session = XrSession(config).start()
        headset = socket.create_connection(("127.0.0.1", config.pose_port), timeout=2.0)
        try:
            _send_frame(headset, "Hello", {"version": "2.0", "capabilities": []})
            self.assertTrue(_wait_for_socket_close(headset))
            self.assertTrue(
                _wait_until(
                    lambda: "xr_state_v1" in (session.stats().last_error or "")
                )
            )
            self.assertFalse(session.stats().connected)
            self.assertEqual(session.stats().frames_received, 0)
        finally:
            headset.close()
            session.close()

    @pytest.mark.fake_headset
    def test_new_sdk_headset_replaces_previous_connection(self) -> None:
        config = _config()
        session = XrSession(config).start()
        first_headset, _descriptor = _connect_fake_headset(config.pose_port)
        second_headset = None
        try:
            second_headset, _descriptor = _connect_fake_headset(config.pose_port)
            self.assertTrue(_wait_for_socket_close(first_headset))
            self.assertTrue(session.stats().connected)

            _send_frame(second_headset, "XrStateFrame", _frame(7))
            self.assertEqual(session.wait_next(0, timeout=1.0).frame_id, 7)
            self.assertTrue(session.stats().connected)
        finally:
            first_headset.close()
            if second_headset is not None:
                second_headset.close()
            session.close()

    def test_invalid_timeout_and_discovery_target_are_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "invalid discovery target"):
            XrSession(BridgeConfig(discovery_unicast_targets=("not-an-ip",)))

        session = XrSession(_config()).start()
        try:
            with self.assertRaisesRegex(ValueError, "finite and non-negative"):
                session.wait_next(timeout=-0.1)
            with self.assertRaisesRegex(ValueError, "finite and non-negative"):
                session.wait_next(timeout=float("nan"))
        finally:
            session.close()

    @pytest.mark.fake_headset
    def test_parse_errors_are_observable_and_valid_stream_recovers(self) -> None:
        config = _config()
        session = XrSession(config).start()
        headset, _descriptor = _connect_fake_headset(config.pose_port)
        try:
            unsupported = _frame(1)
            unsupported["schema_version"] = 99
            _send_frame(headset, "XrStateFrame", unsupported)
            _send_payload(headset, "XrStateFrame", b"{")
            self.assertTrue(_wait_until(lambda: session.stats().parse_errors == 2))
            stats = session.stats()
            self.assertEqual(stats.frames_received, 0)
            self.assertIsNotNone(stats.last_error)

            _send_frame(headset, "XrStateFrame", _frame(2))
            self.assertEqual(session.wait_next(timeout=1.0).frame_id, 2)
            stats = session.stats()
            self.assertEqual(stats.frames_received, 1)
            self.assertEqual(stats.parse_errors, 2)
            self.assertEqual(stats.last_frame_id, 2)
            self.assertEqual(stats.last_timestamp_ns, 2000)
        finally:
            headset.close()
            session.close()

    @pytest.mark.fake_headset
    def test_disconnect_updates_stats_and_close_unblocks_waiter(self) -> None:
        config = _config()
        session = XrSession(config).start()
        headset, _descriptor = _connect_fake_headset(config.pose_port)
        self.assertTrue(session.stats().connected)
        headset.close()
        self.assertTrue(_wait_until(lambda: not session.stats().connected))

        result = []
        waiter = threading.Thread(target=lambda: result.append(session.wait_next(timeout=None)))
        waiter.start()
        self.assertTrue(waiter.is_alive())
        session.close()
        waiter.join(timeout=2.0)
        self.assertFalse(waiter.is_alive())
        self.assertEqual(result, [None])
        self.assertFalse(session.is_running)

    def test_start_and_close_are_idempotent(self) -> None:
        session = XrSession(_config())
        session.start()
        session.start()
        self.assertTrue(session.is_running)
        session.close()
        session.close()
        self.assertFalse(session.is_running)


if __name__ == "__main__":
    unittest.main()
