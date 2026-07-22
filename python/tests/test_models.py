import json
import unittest

from pyoperator.models import frame_from_dict, frame_from_json, frame_to_dict, frame_to_json


def sample_frame(frame_id: int = 1) -> dict:
    return {
        "schema_version": 1,
        "frame_id": frame_id,
        "timestamp_ns": 1000 + frame_id,
        "coordinate_space": "godot_world",
        "head": {
            "valid": True,
            "sample_timestamp_ns": 1000,
            "position": [0, 1.6, 0],
            "rotation": [0, 0, 0, 1],
        },
        "controllers": {
            "left": None,
            "right": {
                "pose": {
                    "valid": True,
                    "sample_timestamp_ns": 1001,
                    "position": [0.2, 1.1, -0.3],
                    "rotation": [0, 0, 0, 1],
                },
                "input": {"sample_timestamp_ns": 1001, "values": {"grip": 1.0}},
                "interaction_profile": "controller",
            },
        },
        "hands": {"left": None, "right": None},
        "body": None,
        "motion_trackers": [],
    }


def sample_full_frame(frame_id: int = 1) -> dict:
    data = sample_frame(frame_id)
    pose = {
        "valid": True,
        "sample_timestamp_ns": 2000,
        "position": [1.0, 2.0, 3.0],
        "rotation": [0.0, 0.0, 0.7071068, 0.7071068],
        "linear_velocity": [0.1, 0.2, 0.3],
        "angular_velocity": [0.4, 0.5, 0.6],
        "confidence": 0.75,
    }
    joint = {
        "joint": 4,
        "flags": 3,
        "tracked": True,
        "radius_m": 0.012,
        "pose": pose,
    }
    data["hands"] = {
        "left": {
            "active": True,
            "sample_timestamp_ns": 2000,
            "joints": [joint],
        },
        "right": None,
    }
    data["body"] = {
        "active": True,
        "sample_timestamp_ns": 2001,
        "joint_set": "pico_bd_24",
        "body_flags": 7,
        "joints": [{**joint, "joint": 10}],
    }
    data["motion_trackers"] = [
        {
            "id": "waist",
            "tracker_index": 2,
            "pose": pose,
            "battery_level": 0.65,
        }
    ]
    return data


class ModelTests(unittest.TestCase):
    def test_frame_is_atomic_and_round_trips(self) -> None:
        frame = frame_from_dict(sample_frame(7))
        self.assertEqual(frame.frame_id, 7)
        self.assertEqual(frame.head.sample_timestamp_ns, 1000)
        self.assertEqual(frame.controllers.right.pose.sample_timestamp_ns, 1001)
        self.assertEqual(frame_from_json(frame_to_json(frame)), frame)

    def test_complete_device_snapshot_round_trips_without_losing_optional_data(self) -> None:
        frame = frame_from_dict(sample_full_frame(11))
        self.assertEqual(frame.frame_id, 11)
        self.assertTrue(frame.hands.left.active)
        self.assertEqual(frame.hands.left.joints[0].joint, 4)
        self.assertEqual(frame.hands.left.joints[0].pose.linear_velocity, (0.1, 0.2, 0.3))
        self.assertEqual(frame.hands.left.joints[0].pose.angular_velocity, (0.4, 0.5, 0.6))
        self.assertEqual(frame.hands.left.joints[0].pose.confidence, 0.75)
        self.assertEqual(frame.body.joint_set, "pico_bd_24")
        self.assertEqual(frame.body.body_flags, 7)
        self.assertEqual(frame.motion_trackers[0].id, "waist")
        self.assertEqual(frame.motion_trackers[0].battery_level, 0.65)
        self.assertEqual(frame_from_dict(frame_to_dict(frame)), frame)

    def test_minimal_frame_uses_documented_defaults(self) -> None:
        frame = frame_from_dict({"schema_version": 1})
        self.assertEqual(frame.frame_id, 0)
        self.assertEqual(frame.timestamp_ns, 0)
        self.assertEqual(frame.coordinate_space, "openxr_stage")
        self.assertIsNone(frame.head)
        self.assertIsNone(frame.controllers.left)
        self.assertIsNone(frame.controllers.right)
        self.assertEqual(frame.motion_trackers, ())
        self.assertIsNone(frame_to_dict(frame)["head"])

    def test_json_bytes_and_controller_default_values(self) -> None:
        frame = frame_from_json(json.dumps(sample_frame()).encode())
        right = frame.controllers.right
        self.assertEqual(right.input.value("grip"), 1.0)
        self.assertEqual(right.input.value("missing", 0.25), 0.25)

    def test_input_mapping_is_read_only(self) -> None:
        values = frame_from_dict(sample_frame()).controllers.right.input.values
        with self.assertRaises(TypeError):
            values["grip"] = 0.0

    def test_nested_sequences_are_immutable(self) -> None:
        frame = frame_from_dict(sample_full_frame())
        with self.assertRaises(AttributeError):
            frame.motion_trackers.append("tracker")
        with self.assertRaises(AttributeError):
            frame.hands.left.joints.append("joint")

    def test_empty_controller_stream_deserializes_as_none(self) -> None:
        data = sample_frame()
        data["controllers"]["right"] = {}
        frame = frame_from_dict(data)
        self.assertIsNone(frame.controllers.right)
        self.assertIsNone(frame_from_json(frame_to_json(frame)).controllers.right)

    def test_unknown_schema_is_rejected(self) -> None:
        data = sample_frame()
        data["schema_version"] = 99
        with self.assertRaises(ValueError):
            frame_from_dict(data)
