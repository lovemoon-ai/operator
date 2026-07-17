import dataclasses
import math

import pytest

from operator_isaacteleop.model import (
    ControllerSample,
    ControlSample,
    JointSample,
    JointSetSample,
    Pose,
)
from operator_isaacteleop.protocol import (
    HEADER_SIZE,
    Kind,
    ProtocolError,
    WirePacket,
    crc16_ccitt_false,
    decode_datagram,
    decode_payload,
    encode_datagram,
    encode_payload,
)


def assert_value_close(actual, expected):
    if dataclasses.is_dataclass(expected):
        for field in dataclasses.fields(expected):
            assert_value_close(getattr(actual, field.name), getattr(expected, field.name))
    elif isinstance(expected, tuple):
        assert len(actual) == len(expected)
        for left, right in zip(actual, expected, strict=True):
            assert_value_close(left, right)
    elif isinstance(expected, float):
        assert math.isclose(actual, expected, rel_tol=1e-6, abs_tol=1e-6)
    else:
        assert actual == expected


def pose(seed=0.0):
    return Pose(True, (1.0 + seed, 2.0 + seed, 3.0 + seed), (0.0, 0.0, 0.0, 1.0))


@pytest.mark.parametrize(
    ("kind", "value"),
    [
        (Kind.HEAD, pose()),
        (Kind.ANCHOR, pose(1.0)),
        (
            Kind.LEFT_CONTROLLER,
            ControllerSample(pose(), pose(0.5), True, False, True, False, 0.25, -0.5, 0.75, 1.0),
        ),
        (
            Kind.LEFT_HAND,
            JointSetSample(tuple(JointSample(pose(float(i)), 0.01) for i in range(26))),
        ),
        (Kind.BODY, JointSetSample(tuple(JointSample(pose(float(i)), 0.0) for i in range(24)))),
        (Kind.CONTROL, ControlSample(True, False, True, False)),
    ],
)
def test_payload_and_datagram_round_trip(kind, value):
    payload = encode_payload(kind, value)
    packet = WirePacket(10, 11, 12, 1, 3, 0, kind, payload)
    encoded = encode_datagram(packet)
    assert len(encoded) == HEADER_SIZE + len(payload)
    decoded = decode_datagram(encoded)
    assert decoded == packet
    assert_value_close(decode_payload(kind, decoded.payload), value)


def test_crc_known_vector_and_corruption():
    assert crc16_ccitt_false(b"123456789") == 0x29B1
    encoded = bytearray(encode_datagram(WirePacket(1, 2, 3, 1, 0, 0, Kind.CONTROL, b"\0\0\0\1")))
    encoded[-1] ^= 1
    with pytest.raises(ProtocolError, match="CRC mismatch"):
        decode_datagram(encoded)


def test_rejects_trailing_data_unknown_kind_and_invalid_boolean():
    packet = encode_datagram(WirePacket(1, 2, 3, 1, 0, 0, Kind.CONTROL, b"\0\0\0\1"))
    with pytest.raises(ProtocolError, match="length mismatch"):
        decode_datagram(packet + b"x")

    unknown = bytearray(packet)
    unknown[28:32] = b"NOPE"
    with pytest.raises(ProtocolError, match="unknown packet kind"):
        decode_datagram(unknown)

    with pytest.raises(ProtocolError, match="must be 0 or 1"):
        decode_payload(Kind.CONTROL, b"\2\0\0\1")


def test_rejects_schema_count_non_finite_radius_and_header_ranges():
    one_joint = JointSetSample((JointSample(pose(), 0.01),))
    with pytest.raises(ProtocolError, match="exactly 26"):
        encode_payload(Kind.LEFT_HAND, one_joint)

    bad_radius = JointSetSample(
        tuple(JointSample(pose(float(i)), -0.01 if i == 4 else 0.01) for i in range(26))
    )
    with pytest.raises(ProtocolError, match="radius"):
        encode_payload(Kind.RIGHT_HAND, bad_radius)

    with pytest.raises(ProtocolError, match="non-finite"):
        encode_payload(Kind.HEAD, Pose(True, (float("nan"), 0, 0), (0, 0, 0, 1)))

    with pytest.raises(ProtocolError, match="timestamp_ns"):
        encode_datagram(WirePacket(-1, 0, 0, 1, 0, 0, Kind.CONTROL, b"\0\0\0\1"))
