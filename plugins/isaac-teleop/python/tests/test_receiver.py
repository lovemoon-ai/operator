import socket
import tempfile
import time
from pathlib import Path

import pytest

from operator_isaacteleop.clock import MonotonicOffsetEstimator
from operator_isaacteleop.model import ControlSample, Pose
from operator_isaacteleop.protocol import (
    Kind,
    ProtocolError,
    WirePacket,
    encode_datagram,
    encode_payload,
)
from operator_isaacteleop.receiver import LatestSampleStore, UnixDatagramReceiver


def datagram(kind, value, *, sequence=1, token=7, timestamp=1_000):
    return encode_datagram(
        WirePacket(timestamp, sequence, token, 1, 0, 0, kind, encode_payload(kind, value))
    )


def test_latest_only_token_sequence_and_expiry():
    store = LatestSampleStore(
        expected_token=7,
        max_age_ns=100,
        clock=MonotonicOffsetEstimator(offset_ns=50),
        transform_coordinates=False,
    )
    head = Pose(True, (1, 2, 3), (0, 0, 0, 1))
    assert store.ingest(datagram(Kind.HEAD, head), available_time_ns=1_100) is not None
    assert store.ingest(datagram(Kind.HEAD, head, sequence=1), available_time_ns=1_101) is None
    assert (
        store.ingest(datagram(Kind.HEAD, head, sequence=2, token=8), available_time_ns=1_102)
        is None
    )
    snapshot = store.snapshot(now_ns=1_120)
    assert snapshot.get(Kind.HEAD).common_sample_time_ns == 1_050
    assert store.snapshot(now_ns=1_151).empty
    assert store.dropped_out_of_order == 1
    assert store.dropped_wrong_token == 1


def test_new_token_can_restart_sequence_when_token_is_not_pinned():
    store = LatestSampleStore(
        max_age_ns=1_000,
        clock=MonotonicOffsetEstimator(offset_ns=0),
        transform_coordinates=False,
    )
    head = Pose(True, (0, 0, 0), (0, 0, 0, 1))
    assert store.ingest(datagram(Kind.HEAD, head, sequence=99, token=1), available_time_ns=1_000)
    assert store.ingest(datagram(Kind.HEAD, head, sequence=1, token=2), available_time_ns=1_001)
    assert store.snapshot(now_ns=1_001).get(Kind.HEAD).token == 2


def test_default_store_preserves_native_openxr_coordinates():
    store = LatestSampleStore(
        max_age_ns=1_000,
        clock=MonotonicOffsetEstimator(offset_ns=0),
    )
    head = Pose(True, (1.0, 2.0, -3.0), (0.0, 0.0, 0.0, 1.0))
    sample = store.ingest(datagram(Kind.HEAD, head), available_time_ns=1_000)
    assert sample.value.position == head.position
    assert sample.value.orientation_xyzw == head.orientation_xyzw


def test_store_rejects_unknown_descriptor_version():
    store = LatestSampleStore(clock=MonotonicOffsetEstimator(offset_ns=0))
    payload = encode_payload(Kind.CONTROL, ControlSample())
    future = encode_datagram(WirePacket(1, 1, 7, 2, 0, 0, Kind.CONTROL, payload))
    with pytest.raises(ProtocolError, match="unsupported descriptor_version 2"):
        store.ingest(future, available_time_ns=1)


def test_control_edges_are_latched_until_one_snapshot():
    store = LatestSampleStore(
        max_age_ns=1_000,
        clock=MonotonicOffsetEstimator(offset_ns=0),
    )
    pulse = ControlSample(False, True, True, True)
    heartbeat = ControlSample(False, False, False, True)
    store.ingest(datagram(Kind.CONTROL, pulse, sequence=1), available_time_ns=1_000)
    store.ingest(datagram(Kind.CONTROL, heartbeat, sequence=2), available_time_ns=1_001)

    first = store.snapshot(now_ns=1_001).get(Kind.CONTROL).value
    assert first.run_toggle is True
    assert first.reset is True
    assert first.deadman is True

    second = store.snapshot(now_ns=1_002).get(Kind.CONTROL).value
    assert second.run_toggle is False
    assert second.reset is False


def test_unix_datagram_receiver():
    directory = tempfile.TemporaryDirectory(prefix="oitp-", dir="/tmp")
    path = Path(directory.name) / "teleop.sock"
    store = LatestSampleStore(
        max_age_ns=1_000_000_000,
        clock=MonotonicOffsetEstimator(offset_ns=0),
        transform_coordinates=False,
    )
    receiver = UnixDatagramReceiver(path, store=store).start(background=False)
    client = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
    try:
        client.sendto(datagram(Kind.CONTROL, ControlSample(False, True, False, True)), str(path))
        received = receiver.receive_once(timeout=0.2)
        assert received is not None
        assert received.kind is Kind.CONTROL

        client.sendto(b"bad", str(path))
        assert receiver.receive_once(timeout=0.2) is None
        assert receiver.invalid_datagrams == 1
        assert receiver.receive_once(timeout=0) is None
    finally:
        client.close()
        receiver.close()
        directory.cleanup()
    assert not path.exists()


def test_background_receiver():
    directory = tempfile.TemporaryDirectory(prefix="oitp-", dir="/tmp")
    path = Path(directory.name) / "background.sock"
    receiver = UnixDatagramReceiver(path).start()
    client = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
    try:
        client.sendto(datagram(Kind.CONTROL, ControlSample()), str(path))
        deadline = time.monotonic() + 1.0
        while receiver.snapshot().empty and time.monotonic() < deadline:
            time.sleep(0.005)
        assert not receiver.snapshot().empty
    finally:
        client.close()
        receiver.close()
        directory.cleanup()
