from __future__ import annotations

import numpy as np
import pytest
from operator_isaacteleop import (
    ControllerSample,
    ControlSample,
    ExternalInputBundle,
    Kind,
    Pose,
    TimedSample,
)

from operator_to_so101.config import OperatorControllerConfig
from operator_to_so101.operator_source import OperatorControllerSource


class SnapshotReceiver:
    def __init__(self) -> None:
        self.bundle = ExternalInputBundle()

    def start(self, *, background: bool = True):
        return self

    def snapshot(self, *, now_ns: int | None = None) -> ExternalInputBundle:
        return self.bundle


def timed(kind: Kind, value, *, sequence: int = 1) -> TimedSample:
    return TimedSample(
        kind=kind,
        value=value,
        raw_sample_time_ns=100,
        common_sample_time_ns=200,
        available_time_ns=250,
        sequence=sequence,
        token=0,
        descriptor_version=1,
    )


def controller(*, valid: bool = True, squeeze: float = 0.8) -> ControllerSample:
    pose = Pose(valid, (1.0, 2.0, 3.0), (0.0, 0.0, 0.0, 1.0))
    return ControllerSample(grip=pose, aim=pose, squeeze=squeeze, trigger=0.25)


def bundle(ctrl: ControlSample | None, *, valid: bool = True) -> ExternalInputBundle:
    samples = {Kind.RIGHT_CONTROLLER: timed(Kind.RIGHT_CONTROLLER, controller(valid=valid))}
    if ctrl is not None:
        samples[Kind.CONTROL] = timed(Kind.CONTROL, ctrl)
    return ExternalInputBundle(samples=samples, graph_time_ns=250)


def test_arm_deadman_reclutch_and_stale_control_disarms() -> None:
    receiver = SnapshotReceiver()
    source = OperatorControllerSource(OperatorControllerConfig(), receiver=receiver)  # type: ignore[arg-type]
    source.connect()

    receiver.bundle = bundle(ControlSample(run_toggle=True, deadman=True))
    frame = source.read(now_ns=300)
    assert frame.armed
    assert frame.engaged

    receiver.bundle = bundle(ControlSample(deadman=False))
    frame = source.read(now_ns=300)
    assert frame.armed
    assert not frame.engaged

    receiver.bundle = bundle(ControlSample(deadman=True))
    assert source.read(now_ns=300).engaged

    receiver.bundle = bundle(None)
    frame = source.read(now_ns=300)
    assert not frame.armed
    assert not frame.engaged


def test_v1_rejects_left_hand_control() -> None:
    with pytest.raises(ValueError, match="requires hand_side='right'"):
        OperatorControllerConfig(hand_side="left")


def test_reset_and_kill_disarm() -> None:
    receiver = SnapshotReceiver()
    source = OperatorControllerSource(OperatorControllerConfig(), receiver=receiver)  # type: ignore[arg-type]
    source.connect()
    receiver.bundle = bundle(ControlSample(run_toggle=True, deadman=True))
    assert source.read(now_ns=300).engaged

    receiver.bundle = bundle(ControlSample(reset=True, deadman=True))
    reset = source.read(now_ns=300)
    assert reset.reset
    assert not reset.armed
    assert not reset.engaged

    receiver.bundle = bundle(ControlSample(kill=True, deadman=False))
    killed = source.read(now_ns=300)
    assert killed.kill
    assert not killed.armed
    assert not killed.engaged


def test_invalid_grip_never_engages() -> None:
    receiver = SnapshotReceiver()
    source = OperatorControllerSource(OperatorControllerConfig(), receiver=receiver)  # type: ignore[arg-type]
    source.connect()
    receiver.bundle = bundle(ControlSample(run_toggle=True, deadman=True), valid=False)
    frame = source.read(now_ns=300)
    assert frame.armed
    assert not frame.tracking
    assert not frame.engaged


def test_grip_only_mode_ignores_run_toggle_and_zero_quaternion() -> None:
    receiver = SnapshotReceiver()
    source = OperatorControllerSource(
        OperatorControllerConfig(require_run_toggle=False),
        receiver=receiver,  # type: ignore[arg-type]
    )
    source.connect()
    receiver.bundle = bundle(ControlSample(run_toggle=True, deadman=True))
    assert source.read(now_ns=300).engaged

    invalid_pose = Pose(True, (0.0, 0.0, 0.0), (0.0, 0.0, 0.0, 0.0))
    invalid_controller = ControllerSample(
        grip=invalid_pose,
        aim=invalid_pose,
        squeeze=1.0,
    )
    receiver.bundle = ExternalInputBundle(
        samples={
            Kind.RIGHT_CONTROLLER: timed(Kind.RIGHT_CONTROLLER, invalid_controller),
            Kind.CONTROL: timed(Kind.CONTROL, ControlSample(deadman=True)),
        }
    )
    frame = source.read(now_ns=300)
    assert not frame.tracking
    assert not frame.engaged


def test_default_transform_matches_isaac_controller_transform() -> None:
    receiver = SnapshotReceiver()
    source = OperatorControllerSource(
        OperatorControllerConfig(require_run_toggle=False),
        receiver=receiver,  # type: ignore[arg-type]
    )
    source.connect()
    receiver.bundle = bundle(ControlSample(deadman=True))
    frame = source.read(now_ns=300)

    np.testing.assert_allclose(frame.grip_pos, [-3.0, -1.0, 2.0], atol=1e-6)
    expected_rotation = np.asarray([[0.0, 0.0, -1.0], [-1.0, 0.0, 0.0], [0.0, 1.0, 0.0]])
    np.testing.assert_allclose(quat_to_matrix(frame.grip_quat), expected_rotation, atol=1e-6)


def test_dataset_frame_keeps_exact_integer_timestamps() -> None:
    receiver = SnapshotReceiver()
    source = OperatorControllerSource(
        OperatorControllerConfig(require_run_toggle=False),
        receiver=receiver,  # type: ignore[arg-type]
    )
    source.connect()
    receiver.bundle = bundle(ControlSample(deadman=True))
    dataset_frame = source.read(now_ns=300).dataset_frame()

    assert dataset_frame["operator.timestamps_ns"].dtype == np.int64
    np.testing.assert_array_equal(dataset_frame["operator.timestamps_ns"], [100, 200, 250])
    np.testing.assert_array_equal(dataset_frame["operator.control_timestamps_ns"], [100, 200, 250])
    np.testing.assert_array_equal(dataset_frame["operator.control_sequence"], [1])
    assert dataset_frame["operator.status"].dtype == np.uint8
    assert dataset_frame["operator.pose"].shape == (7,)


def quat_to_matrix(quat: np.ndarray) -> np.ndarray:
    x, y, z, w = quat / np.linalg.norm(quat)
    return np.asarray(
        [
            [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
            [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
            [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)],
        ]
    )
