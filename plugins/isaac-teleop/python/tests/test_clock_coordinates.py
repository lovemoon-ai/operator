import math

import pytest

from operator_isaacteleop.clock import MonotonicOffsetEstimator
from operator_isaacteleop.coordinates import godot_to_isaac_pose
from operator_isaacteleop.model import Pose


def test_four_timestamp_offset_and_mapping():
    clock = MonotonicOffsetEstimator(smoothing=1.0)
    exchange = clock.observe_exchange(1_000, 1_110, 1_120, 1_030)
    assert exchange.offset_ns == 100
    assert exchange.round_trip_ns == 20
    assert clock.to_common(5_000) == 5_100


def test_injected_offset_and_invalid_exchange():
    clock = MonotonicOffsetEstimator(offset_ns=-50)
    assert clock.to_common(100) == 50
    with pytest.raises(ValueError, match="negative round trip"):
        clock.observe_exchange(0, 100, 200, 50)


def test_godot_position_and_identity_orientation_to_isaac():
    converted = godot_to_isaac_pose(Pose(True, (1.0, 2.0, 3.0), (0.0, 0.0, 0.0, 1.0)))
    assert converted.position == (-3.0, -1.0, 2.0)
    assert converted.orientation_xyzw == pytest.approx((0.0, 0.0, 0.0, 1.0), abs=1e-7)
    assert math.isclose(sum(v * v for v in converted.orientation_xyzw), 1.0)
