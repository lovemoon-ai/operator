import json
import math
import unittest
import struct
import time
from unittest.mock import patch

from pyoperator.integrations.revo2 import (
    CHANNELS,
    COMMAND_FLAG_HOLD,
    CurrentEma,
    Revo2HandFeedback,
    axis_name,
    command_packet_v2,
    command_targets,
    gesture_targets,
    hand_enabled,
    merge_descriptor,
    target_packet_v2,
    telemetry_values,
)
from pyoperator.integrations.revo2_udp import Revo2UdpHostedAdapter, make_revo2_descriptor
from pyoperator.models import ControllerInput, ControllerState, HandState, Joint, Pose


def _joint(index: int, position: tuple[float, float, float]) -> Joint:
    return Joint(index, tracked=True, pose=Pose(valid=True, position=position))


def _hand(
    curled: bool,
    *,
    thumb_flexed: bool | None = None,
    thumb_opposed: bool | None = None,
) -> HandState:
    if thumb_flexed is None:
        thumb_flexed = curled
    if thumb_opposed is None:
        thumb_opposed = curled
    points: dict[int, tuple[float, float, float]] = {1: (0.0, -0.05, 0.0)}
    chains = (
        ((6, 7, 8, 9, 10), (-0.018, 0.0, 0.0)),
        ((11, 12, 13, 14, 15), (0.0, 0.0, 0.0)),
        ((16, 17, 18, 19, 20), (0.018, 0.0, 0.0)),
        ((21, 22, 23, 24, 25), (0.036, 0.0, 0.0)),
    )
    for indices, base in chains:
        bx, by, bz = base
        chain_points = (
            (
                (bx, by, bz),
                (bx, by + 0.022, bz),
                (bx + 0.016, by + 0.022, bz),
                (bx + 0.016, by + 0.006, bz),
                (bx + 0.003, by + 0.006, bz),
            )
            if curled
            else tuple((bx, by + 0.022 * offset, bz) for offset in range(len(indices)))
        )
        for index, point in zip(indices, chain_points):
            points[index] = point
    points[2] = (-0.035, 0.000, 0.0)
    if thumb_opposed:
        points[3] = (-0.030, 0.020, 0.0)
    else:
        points[3] = (-0.052, 0.008, 0.0)
    thumb_axis = tuple(points[3][axis] - points[2][axis] for axis in range(3))
    if thumb_flexed:
        points[4] = (points[3][0], points[3][1], points[3][2] + 0.017)
        points[5] = (points[4][0], points[4][1] - 0.017, points[4][2])
    else:
        points[4] = tuple(points[3][axis] + thumb_axis[axis] for axis in range(3))
        points[5] = tuple(points[4][axis] + thumb_axis[axis] for axis in range(3))
    joints = tuple(_joint(index, point) for index, point in points.items())
    return HandState(active=True, joints=joints)


class Revo2IntegrationTests(unittest.TestCase):
    def test_gesture_mapping_and_controller_fallback(self) -> None:
        open_targets = gesture_targets(_hand(False))
        closed_targets = gesture_targets(_hand(True))
        flex_only = gesture_targets(_hand(False, thumb_flexed=True, thumb_opposed=False))
        oppose_only = gesture_targets(_hand(False, thumb_flexed=False, thumb_opposed=True))
        self.assertLess(open_targets[2], 0.1)
        self.assertGreater(closed_targets[2], 0.8)
        self.assertLessEqual(flex_only[0], 0.5)
        self.assertGreater(flex_only[0], 0.4)
        self.assertLess(flex_only[1], 0.1)
        self.assertLess(oppose_only[0], 0.1)
        self.assertGreater(oppose_only[1], 0.75)
        self.assertLessEqual(oppose_only[1], 0.85)

        controller = ControllerState(
            input=ControllerInput(values={"trigger": 0.7, "grip": 0.4})
        )
        self.assertEqual(gesture_targets(None, controller), (0.35, 0.35, 0.7, 0.4, 0.4, 0.4))

        hand_without_thumb_tip = HandState(
            active=True,
            joints=tuple(joint for joint in _hand(True).joints if joint.joint != 5),
        )
        self.assertEqual(
            gesture_targets(hand_without_thumb_tip, controller),
            (0.35, 0.35, 0.7, 0.4, 0.4, 0.4),
        )

    def test_command_extraction_and_deadman(self) -> None:
        channels = (
            "thumb_flex", "thumb_aux", "index_flex", "middle_flex", "ring_flex", "pinky_flex"
        )
        axes = {axis_name("left", channel): index / 5 for index, channel in enumerate(channels)}
        command = {"axes": axes, "buttons": {"left_enable": True, "right_enable": False}}
        self.assertEqual(command_targets(command, "left"), (0, 200, 400, 600, 800, 1000))
        self.assertTrue(hand_enabled(command, "left"))
        self.assertFalse(hand_enabled(command, "right"))
        self.assertEqual(command_targets({"axes": "bad"}, "right"), (0, 0, 0, 0, 0, 0))
        with self.assertRaises(ValueError):
            axis_name("center", "index_flex")
        with self.assertRaises(ValueError):
            axis_name("left", "unknown")

        packet = command_packet_v2(command, "left", 7, speed=0.25, timestamp_ns=123)
        unpacked = struct.unpack("<4sBBHIQ12f", packet)
        self.assertEqual(unpacked[:6], (b"BCH2", 2, 0, 0, 7, 123))
        self.assertAlmostEqual(unpacked[7], 0.2)
        self.assertEqual(unpacked[-6:], (0.25,) * 6)

        direct_packet = target_packet_v2(
            [0, 200, 400, 600, 800, 1000],
            "right",
            9,
            speed=[0.1, 0.2, 0.3, 0.4, 0.5, 0.6],
            timestamp_ns=456,
        )
        direct = struct.unpack("<4sBBHIQ12f", direct_packet)
        self.assertEqual(direct[:6], (b"BCH2", 2, 1, 0, 9, 456))
        self.assertAlmostEqual(direct[6], 0.0)
        self.assertAlmostEqual(direct[11], 1.0)
        for actual, expected in zip(direct[-6:], (0.1, 0.2, 0.3, 0.4, 0.5, 0.6)):
            self.assertAlmostEqual(actual, expected)

    def test_feedback_filter_and_flat_telemetry(self) -> None:
        ema = CurrentEma(0.5)
        self.assertEqual(ema.update([0] * 6), (0.0,) * 6)
        self.assertEqual(ema.update([100] * 6), (50.0,) * 6)
        with self.assertRaises(ValueError):
            CurrentEma(0.0)

        feedback = Revo2HandFeedback.from_sequences(
            target=[100] * 6,
            position=[90] * 6,
            current=[50] * 6,
            states=["MOTOR_IDLE", "MOTOR_STALL", 2, 0, 1, object()],
        )
        values = telemetry_values(left=feedback)
        self.assertEqual(values["revo2_left_position"], [90.0] * 6)
        self.assertEqual(values["revo2_left_stall"], [0.0, 1.0, 1.0, 0.0, 0.0, 0.0])
        self.assertNotIn("revo2_right_position", values)

        class MotorState:
            def __init__(self, q, tau_est, mode):
                self.q = q
                self.tau_est = tau_est
                self.mode = mode

        from_dds = Revo2HandFeedback.from_motor_states(
            target=[0.1] * 6,
            motor_states=[MotorState(0.2, -0.05, 2)] * 6,
        )
        self.assertEqual(from_dds.target, (100.0,) * 6)
        self.assertEqual(from_dds.position, (200.0,) * 6)
        self.assertEqual(from_dds.current, (-50.0,) * 6)
        self.assertEqual(from_dds.stall, (1.0,) * 6)
        with self.assertRaises(ValueError):
            Revo2HandFeedback.from_sequences(
                target=[0] * 5, position=[0] * 6, current=[0] * 6, states=[0] * 6
            )

    def test_descriptor_merge_is_idempotent(self) -> None:
        descriptor = {"device": {"name": "G1"}}
        merged = merge_descriptor(descriptor)
        merged_twice = merge_descriptor(merged)
        self.assertEqual(len(merged["control_schema"]["axes"]), 12)
        self.assertEqual(len(merged["input_mapping"]), 12)
        self.assertEqual(len(merged["telemetry_schema"]["values"]), 8)
        self.assertEqual(merged_twice, merged)
        self.assertNotIn("control_schema", descriptor)
        self.assertEqual(merged["control_schema"]["axes"][0]["range"], [0.0, 1.0])
        self.assertEqual(merged["telemetry_schema"]["values"][0]["type"], "array")

    def test_udp_adapter_deadman_release_sends_actual_hold(self) -> None:
        class CaptureSocket:
            def __init__(self) -> None:
                self.sent = []

            def sendto(self, payload, address) -> None:
                self.sent.append((payload, address))

        adapter = Revo2UdpHostedAdapter(command_host="192.0.2.10")
        capture = CaptureSocket()
        adapter._command_socket = capture
        adapter._values = {"revo2_left_position": [110, 210, 310, 410, 510, 610]}
        adapter._value_received_ns = {
            "revo2_left_position": time.monotonic_ns(),
        }
        adapter.handle_command(
            {
                "axes": {axis_name("left", channel): 0.5 for channel in CHANNELS},
                "buttons": {"left_enable": True},
            }
        )
        adapter.handle_command({"axes": {}, "buttons": {"left_enable": False}})
        adapter.handle_command({"axes": {}, "buttons": {"left_enable": False}})
        self.assertEqual(len(capture.sent), 5)
        active = struct.unpack("<4sBBHIQ12f", capture.sent[0][0])
        hold = struct.unpack("<4sBBHIQ12f", capture.sent[1][0])
        repeated_hold = struct.unpack("<4sBBHIQ12f", capture.sent[4][0])
        self.assertEqual(active[3], 0)
        self.assertEqual(hold[3], COMMAND_FLAG_HOLD)
        self.assertEqual(repeated_hold[3], COMMAND_FLAG_HOLD)
        self.assertEqual(active[6:12], (0.5,) * 6)
        for actual, expected in zip(hold[6:12], (0.11, 0.21, 0.31, 0.41, 0.51, 0.61)):
            self.assertAlmostEqual(actual, expected)

        descriptor = make_revo2_descriptor()
        self.assertEqual(descriptor["descriptor_version"], 2)
        self.assertEqual(descriptor["safety"]["command_timeout_ms"], 1000)
        self.assertEqual(len(descriptor["control_schema"]["axes"]), 12)
        self.assertEqual(len(descriptor["control_schema"]["buttons"]), 2)
        self.assertEqual(
            [mapping["source"] for mapping in descriptor["input_mapping"][:2]],
            ["left_hand_clutch", "right_hand_clutch"],
        )

    def test_udp_adapter_matches_speed_to_motion_and_tracking_error(self) -> None:
        adapter = Revo2UdpHostedAdapter(
            command_host="192.0.2.10",
            command_speed=0.08,
            max_command_speed=1.0,
            command_catchup_seconds=0.1,
        )
        adapter._values = {"revo2_right_position": [0, 0, 0, 0, 0, 0]}
        adapter._value_received_ns = {
            "revo2_right_position": time.monotonic_ns(),
        }
        adapter._last_targets["right"] = (0.0,) * 6
        adapter._last_command_ns["right"] = 1_000_000_000
        speeds = adapter._adaptive_speeds(
            "right",
            (10.0, 50.0, 100.0, 500.0, 1000.0, 0.0),
            1_100_000_000,
        )
        self.assertAlmostEqual(speeds[0], 0.1)
        self.assertAlmostEqual(speeds[1], 0.5)
        self.assertEqual(speeds[2:], (1.0, 1.0, 1.0, 0.08))

        with self.assertRaises(ValueError):
            Revo2UdpHostedAdapter(
                command_host="192.0.2.10",
                command_speed=0.5,
                max_command_speed=0.4,
            )

    def test_udp_adapter_hold_does_not_require_telemetry(self) -> None:
        class CaptureSocket:
            def __init__(self) -> None:
                self.sent = []

            def sendto(self, payload, address) -> None:
                self.sent.append((payload, address))

        adapter = Revo2UdpHostedAdapter(command_host="192.0.2.10")
        capture = CaptureSocket()
        adapter._command_socket = capture
        adapter.handle_command(
            {
                "axes": {axis_name("right", channel): 0.6 for channel in CHANNELS},
                "buttons": {"right_enable": True},
            }
        )
        adapter.handle_command({"axes": {}, "buttons": {"right_enable": False}})

        hold = struct.unpack("<4sBBHIQ12f", capture.sent[-1][0])
        self.assertEqual(hold[3], COMMAND_FLAG_HOLD)
        for actual in hold[6:12]:
            self.assertAlmostEqual(actual, 0.6)

    def test_udp_adapter_filters_stale_and_invalid_telemetry(self) -> None:
        class ReceiveSocket:
            def __init__(self, packets) -> None:
                self.packets = list(packets)

            def recvfrom(self, _size):
                if not self.packets:
                    raise OSError("done")
                return self.packets.pop(0)

        valid = json.dumps({
            "values": {"revo2_left_position": [100] * 6},
            "timestamp_ns": 123,
        }).encode()
        invalid_number = json.dumps({
            "values": {"revo2_left_position": [math.nan] * 6},
        }).encode()
        adapter = Revo2UdpHostedAdapter(
            command_host="192.0.2.10",
            telemetry_timeout_seconds=0.5,
        )
        adapter._allowed_telemetry_sources = {"192.0.2.10"}
        adapter._telemetry_socket = ReceiveSocket([
            (b"[]", ("192.0.2.10", 19092)),
            (valid, ("192.0.2.11", 19092)),
            (invalid_number, ("192.0.2.10", 19092)),
            (valid, ("192.0.2.10", 19092)),
        ])

        adapter._receive_telemetry()
        self.assertEqual(
            adapter.telemetry()["values"]["revo2_left_position"],
            [100.0] * 6,
        )
        received_ns = adapter._value_received_ns["revo2_left_position"]
        with patch(
            "pyoperator.integrations.revo2_udp.time.monotonic_ns",
            return_value=received_ns + adapter.telemetry_timeout_ns + 1,
        ):
            self.assertEqual(adapter.telemetry()["values"], {})


if __name__ == "__main__":
    unittest.main()
