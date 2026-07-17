"""Runnable Operator -> UDS -> external session smoke test, without Isaac Sim."""

from __future__ import annotations

import json
import socket
import tempfile
from pathlib import Path

from operator_isaacteleop.model import ControlSample, Pose
from operator_isaacteleop.protocol import Kind, WirePacket, encode_datagram, encode_payload
from operator_isaacteleop.receiver import LatestSampleStore, UnixDatagramReceiver
from operator_isaacteleop.session import ExternalTeleopSession


class FakeTeleopSession:
    def step(self, *, external_inputs, graph_time, execution_events):
        return {
            "action": [0.0, 0.1, 0.2],
            "input_names": sorted(external_inputs),
            "graph_time_ns": graph_time,
            "execution_state": execution_events.execution_state.value,
        }


def make_session() -> ExternalTeleopSession:
    """Factory accepted by ``operator-isaacteleop-receive``."""

    return ExternalTeleopSession(FakeTeleopSession())


def packet(kind, value, sequence):
    return encode_datagram(
        WirePacket(
            timestamp_ns=1_000_000 + sequence,
            sequence=sequence,
            token=42,
            descriptor_version=1,
            flags=0,
            reserved=0,
            kind=kind,
            payload=encode_payload(kind, value),
        )
    )


def main() -> None:
    # Keep the pathname short enough for macOS's AF_UNIX limit.
    with tempfile.TemporaryDirectory(prefix="oitp-", dir="/tmp") as directory:
        path = Path(directory) / "runtime.sock"
        receiver = UnixDatagramReceiver(
            path,
            store=LatestSampleStore(expected_token=42, max_age_ns=1_000_000_000),
        ).start(background=False)
        sender = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        try:
            sender.sendto(
                packet(Kind.HEAD, Pose(True, (0.1, 1.6, -0.2), (0.0, 0.0, 0.0, 1.0)), 1),
                str(path),
            )
            receiver.receive_once(timeout=0.2)
            sender.sendto(
                packet(Kind.CONTROL, ControlSample(False, True, False, True), 2), str(path)
            )
            receiver.receive_once(timeout=0.2)
            result = make_session().step(receiver.snapshot())
            print(json.dumps(result, sort_keys=True))
        finally:
            sender.close()
            receiver.close()


if __name__ == "__main__":
    main()
