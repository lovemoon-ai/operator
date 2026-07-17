"""Protocol-level tests for the link codec and client state machine.

Pure protocol/unit tests: no adapter, no headset, no hardware, no placo. The
byte-exact frames below are transcribed from the Rust `LinkCodec` tests in
`robot/crates/robot-adapter/src/control/drivers/lerobot_link.rs`, so these fail
if either side's wire format drifts.
"""

import json
import socket
import struct

import pytest

from lerobot_teleoperator_vr_operator.link import (
    MAX_FRAME_LEN,
    ControlState,
    FrameDecoder,
    TargetSample,
    VRLink,
    encode_frame,
    parse_endpoint,
)

# Exactly what `serde_json` emits for these variants (compact, tag first).
RUST_TARGET_EE = (
    b'{"type":"Target","ee_pose":{"position":[0.1,0.2,0.3],'
    b'"rotation":[0.0,0.0,0.0,1.0]},"gripper":0.5,"seq":7,"ts_ns":42}'
)
RUST_TARGET_JOINTS = b'{"type":"Target","positions":[1.0,2.0,3.0,4.0,5.0],"seq":1,"ts_ns":0}'
RUST_CONTROL = b'{"type":"Control","enabled":true,"stopped":false,"reset_epoch":3}'


def rust_frame(body: bytes) -> bytes:
    """The `[4B len LE][JSON]` framing the Rust encoder produces."""
    return struct.pack("<I", len(body)) + body


# ---------------------------------------------------------------------------
# Codec
# ---------------------------------------------------------------------------


def test_encode_frame_matches_rust_framing():
    frame = encode_frame({"type": "Error", "msg": "IK did not converge"})
    (length,) = struct.unpack("<I", frame[:4])
    assert length == len(frame) - 4
    assert json.loads(frame[4:]) == {"type": "Error", "msg": "IK did not converge"}


def test_encode_frame_round_trips_through_the_decoder():
    hello = {
        "type": "Hello",
        "joint_names": ["shoulder_pan"],
        "positions": [0.0, -90.0, 90.0, 0.0, 0.0, 85.0],
        "ee": {"position": [0.25, 0.0, 0.2], "rotation": [0.0, 0.0, 0.0, 1.0]},
    }
    assert FrameDecoder().feed(encode_frame(hello)) == [hello]


def test_decoder_parses_byte_exact_rust_frames():
    decoder = FrameDecoder()
    messages = decoder.feed(
        rust_frame(RUST_CONTROL) + rust_frame(RUST_TARGET_EE) + rust_frame(RUST_TARGET_JOINTS)
    )
    assert [m["type"] for m in messages] == ["Control", "Target", "Target"]

    assert messages[0] == {"type": "Control", "enabled": True, "stopped": False, "reset_epoch": 3}

    ee_target = messages[1]
    assert ee_target["ee_pose"]["position"] == [0.1, 0.2, 0.3]
    # Quaternion is xyzw on the wire.
    assert ee_target["ee_pose"]["rotation"] == [0.0, 0.0, 0.0, 1.0]
    assert ee_target["gripper"] == 0.5
    # Direct-mode key is omitted entirely in IK mode (serde skips None).
    assert "positions" not in ee_target

    joint_target = messages[2]
    assert joint_target["positions"] == [1.0, 2.0, 3.0, 4.0, 5.0]
    assert "ee_pose" not in joint_target
    assert "gripper" not in joint_target


def test_decoder_handles_frames_split_across_reads():
    frame = rust_frame(RUST_TARGET_EE)
    decoder = FrameDecoder()

    assert decoder.feed(frame[:2]) == []  # partial length prefix
    assert decoder.feed(frame[2:4]) == []  # length prefix complete, no body
    assert decoder.feed(frame[4:20]) == []  # partial body
    messages = decoder.feed(frame[20:])
    assert len(messages) == 1
    assert messages[0]["seq"] == 7


def test_decoder_handles_two_frames_in_one_read_and_keeps_the_remainder():
    decoder = FrameDecoder()
    both = rust_frame(RUST_CONTROL) + rust_frame(RUST_TARGET_EE)
    # Cut mid-way through the second frame.
    messages = decoder.feed(both[: len(rust_frame(RUST_CONTROL)) + 5])
    assert [m["type"] for m in messages] == ["Control"]
    messages = decoder.feed(both[len(rust_frame(RUST_CONTROL)) + 5 :])
    assert [m["type"] for m in messages] == ["Target"]


def test_decoder_rejects_oversized_frame():
    decoder = FrameDecoder()
    with pytest.raises(ValueError, match="exceeds maximum"):
        decoder.feed(struct.pack("<I", MAX_FRAME_LEN + 1) + b"junk")


def test_decoder_reset_drops_a_truncated_frame():
    decoder = FrameDecoder()
    assert decoder.feed(rust_frame(RUST_CONTROL)[:6]) == []
    decoder.reset()
    # Without the reset, the stale partial would corrupt this frame.
    assert [m["type"] for m in decoder.feed(rust_frame(RUST_CONTROL))] == ["Control"]


# ---------------------------------------------------------------------------
# Endpoint parsing (must match the Rust `Endpoint` FromStr/Display)
# ---------------------------------------------------------------------------


def test_parse_endpoint_uds():
    assert parse_endpoint("uds:/tmp/lerobot-vr.sock") == (socket.AF_UNIX, "/tmp/lerobot-vr.sock")


def test_parse_endpoint_tcp():
    assert parse_endpoint("tcp:127.0.0.1:5555") == (socket.AF_INET, ("127.0.0.1", 5555))


@pytest.mark.parametrize(
    "endpoint",
    ["", "uds:", "http://x", "tcp:127.0.0.1", "/tmp/x.sock", "tcp:127.0.0.1:notaport"],
)
def test_parse_endpoint_rejects_bad_input(endpoint):
    with pytest.raises(ValueError):
        parse_endpoint(endpoint)


# ---------------------------------------------------------------------------
# VRLink state slots (exercised directly, without a socket)
# ---------------------------------------------------------------------------


def make_link() -> VRLink:
    return VRLink("uds:/tmp/does-not-need-to-exist.sock", connect_timeout_s=0.01)


def test_link_starts_in_the_safe_state():
    link = make_link()
    assert link.control() == ControlState(enabled=False, stopped=False, reset_epoch=0)
    assert link.latest_target() is None
    assert not link.is_running


def test_link_applies_control_and_target_frames():
    link = make_link()
    for message in FrameDecoder().feed(rust_frame(RUST_CONTROL) + rust_frame(RUST_TARGET_EE)):
        link._apply(message)

    assert link.control() == ControlState(enabled=True, stopped=False, reset_epoch=3)
    target = link.latest_target()
    assert isinstance(target, TargetSample)
    assert target.ee_position == [0.1, 0.2, 0.3]
    assert target.gripper == 0.5
    assert target.seq == 7
    assert target.positions is None


def test_link_target_is_latest_wins():
    link = make_link()
    for message in FrameDecoder().feed(rust_frame(RUST_TARGET_EE) + rust_frame(RUST_TARGET_JOINTS)):
        link._apply(message)
    target = link.latest_target()
    assert target.seq == 1
    assert target.positions == [1.0, 2.0, 3.0, 4.0, 5.0]
    assert target.ee_position is None


def test_link_gripper_only_target_has_neither_pose_nor_positions():
    link = make_link()
    link._apply({"type": "Target", "gripper": 0.25, "seq": 9, "ts_ns": 0})
    target = link.latest_target()
    assert target.ee_position is None
    assert target.positions is None
    assert target.gripper == 0.25


def test_link_disconnect_reverts_to_the_safe_state_but_keeps_the_reset_epoch():
    link = make_link()
    link._apply({"type": "Control", "enabled": True, "stopped": False, "reset_epoch": 4})
    link._apply({"type": "Target", "positions": [1.0, 2.0, 3.0, 4.0, 5.0], "seq": 1, "ts_ns": 0})

    link._close_socket()

    # A dropped link must not leave `enabled=True` latched: the adapter re-sends
    # `Control` on reconnect, and until then the arm must hold.
    assert link.control().enabled is False
    assert link.latest_target() is None
    # The epoch is preserved so the reconnect's re-sent Control does not look
    # like a fresh reset edge and re-home the arm.
    assert link.control().reset_epoch == 4


def _control(epoch: int) -> dict:
    return {"type": "Control", "enabled": True, "stopped": False, "reset_epoch": epoch}


def test_reset_generation_first_control_is_baseline_not_an_edge():
    link = make_link()
    link._conn_has_reset_baseline = False  # what _connect_once sets per connection
    link._apply(_control(3))
    # The first Control of a connection is the baseline; no reset was requested.
    assert link.reset_generation() == 0


def test_reset_generation_bumps_on_each_within_connection_change():
    link = make_link()
    link._conn_has_reset_baseline = False
    link._apply(_control(3))  # baseline
    link._apply(_control(4))
    assert link.reset_generation() == 1
    link._apply(_control(4))  # unchanged: not an edge
    assert link.reset_generation() == 1
    link._apply(_control(5))
    assert link.reset_generation() == 2


def test_reset_generation_survives_an_adapter_restart():
    # Finding 2: comparing raw reset_epochs breaks when robot-service restarts and
    # its epoch counter returns to 0. The generation must keep working.
    link = make_link()
    link._conn_has_reset_baseline = False
    link._apply(_control(1))  # connection 1 baseline
    link._apply(_control(2))  # a reset
    link._apply(_control(3))  # another reset
    assert link.reset_generation() == 2

    # robot-service restarts; the plugin reconnects. _connect_once re-arms the
    # baseline, and the restarted adapter's epoch is back at 0.
    link._conn_has_reset_baseline = False
    link._apply(_control(0))  # connection 2 baseline (epoch reset to 0)
    assert link.reset_generation() == 2, "re-baselining must not read as a reset"
    link._apply(_control(1))  # a genuine reset after the restart
    assert link.reset_generation() == 3, "reset must still fire after an adapter restart"


def test_apply_all_survives_a_malformed_frame():
    # Finding 5: a bad frame must not kill the reader thread. A Target whose
    # ee_pose lacks "rotation" raises KeyError inside _apply; the guard must
    # swallow it and still apply the surrounding good frames.
    link = make_link()
    link._conn_has_reset_baseline = True
    good_before = _control(0)
    good_before["enabled"] = True
    bad = {"type": "Target", "ee_pose": {"position": [0.1, 0.2, 0.3]}, "seq": 1, "ts_ns": 0}
    good_after = {"type": "Target", "positions": [1.0, 2.0, 3.0, 4.0, 5.0], "seq": 2, "ts_ns": 0}

    link._apply_all([good_before, bad, good_after])  # must not raise

    assert link.control().enabled is True
    target = link.latest_target()
    assert target is not None and target.positions == [1.0, 2.0, 3.0, 4.0, 5.0]


def test_link_send_is_a_noop_while_disconnected():
    link = make_link()
    link.send({"type": "Error", "msg": "x"})  # must not raise


def test_link_start_requires_hello_first():
    link = make_link()
    with pytest.raises(RuntimeError, match="set_hello"):
        link.start()


def test_link_start_times_out_when_no_adapter_listens():
    link = make_link()
    link.set_hello({"type": "Hello", "positions": [], "ee": None})
    with pytest.raises(ConnectionError, match="could not connect"):
        link.start()
