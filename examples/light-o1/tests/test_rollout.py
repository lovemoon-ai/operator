"""Trajectory recording and the Sonic rollout schedule, without MuJoCo or ONNX."""
import os
from pathlib import Path
import threading

import numpy as np
import pytest

from light_o1_vr.rollout import SETTLE_TICKS, SonicRollout, Trajectory, idle_state, robot_state
from fakes import JOINT_NAMES, FakeLightO1, FakeSimulator


def frame(x=0.0, joint0=0.0):
    values = np.zeros(36)
    values[0], values[2], values[3], values[7] = x, 0.8, 1.0, joint0
    return values


def test_trajectory_records_frames_and_clamps_reads(tmp_path):
    trajectory = Trajectory(JOINT_NAMES, prompt="wave", planned_s=2.0)
    assert len(trajectory) == 0 and trajectory.frame_dim == 36
    with pytest.raises(IndexError):
        trajectory.frame(0)
    trajectory.append(frame(0.0), settle=True)
    trajectory.append(frame(0.01, 0.5))
    assert len(trajectory) == 2 and trajectory.settle_frames == 1
    assert trajectory.frame(-5)[0] == 0.0 and trajectory.frame(99)[7] == 0.5
    assert trajectory.frames().shape == (2, 36)
    with pytest.raises(ValueError):
        trajectory.append(np.zeros(35))
    with pytest.raises(ValueError):
        trajectory.append(np.full(36, np.nan))
    assert not trajectory.ok
    trajectory.finish(survived_s=0.02)
    assert trajectory.ok and trajectory.duration_s == pytest.approx(0.04)
    with pytest.raises(ValueError):
        trajectory.save(tmp_path / "t.npy")
    saved = trajectory.save(tmp_path / "t.npz")
    loaded = Trajectory.load(saved)
    assert loaded.joint_names == JOINT_NAMES and loaded.prompt == "wave"
    assert np.array_equal(loaded.frames(), trajectory.frames())
    assert loaded.ok and loaded.settle_frames == 1 and loaded.planned_s == 2.0


def test_robot_state_and_idle_pose_follow_policy_joint_order():
    simulator = FakeSimulator()
    simulator.data.qpos[7] = 0.7
    state = robot_state(simulator)
    assert state.shape == (36,) and state[2] == 0.8 and state[3] == 1.0 and state[7] == 0.7
    idle = idle_state(simulator)
    assert simulator.resets == 2 and idle[7] == 0.25


def test_rollout_replays_light_o1_schedule_and_reports_metrics():
    light_o1, simulator = FakeLightO1(), FakeSimulator()
    action = np.zeros((20, 138), np.float32)  # 1.0 s at 20 FPS -> 50 control ticks
    trajectory = Trajectory(JOINT_NAMES, prompt="p", control_hz=light_o1.control_hz)
    result = SonicRollout(light_o1, simulator, light_o1.to_reference(action), trajectory).run()
    assert result is trajectory and trajectory.ok
    assert simulator.resets >= 2 and simulator.warmups == 1
    assert trajectory.settle_frames == SETTLE_TICKS
    assert len(trajectory) == SETTLE_TICKS + 50
    assert trajectory.planned_s == pytest.approx(1.0) and trajectory.survived_s == pytest.approx(1.0)
    assert trajectory.fell_at is None
    # The pelvis advanced one centimetre per recorded tick.
    assert trajectory.frame(len(trajectory) - 1)[0] == pytest.approx(0.01 * len(trajectory))


def test_rollout_stops_and_reports_a_fall():
    light_o1 = FakeLightO1()
    simulator = FakeSimulator(fall_after_ticks=SETTLE_TICKS + 10)
    trajectory = Trajectory(JOINT_NAMES)
    SonicRollout(light_o1, simulator, light_o1.to_reference(np.zeros((40, 138))), trajectory).run()
    assert trajectory.done and trajectory.ok
    assert trajectory.fell_at == pytest.approx(11 / 50)
    assert len(trajectory) == SETTLE_TICKS + 11
    assert trajectory.survived_s == pytest.approx(11 / 50) and trajectory.planned_s == pytest.approx(2.0)


def test_rollout_honours_cancellation_between_ticks():
    light_o1, simulator = FakeLightO1(), FakeSimulator()
    cancel = threading.Event()
    trajectory = Trajectory(JOINT_NAMES)

    def hook(sim):
        if sim.steps == 5:
            cancel.set()

    simulator.step_hook = hook
    SonicRollout(light_o1, simulator, light_o1.to_reference(np.zeros((40, 138))), trajectory, cancel=cancel).run()
    assert trajectory.cancelled and trajectory.done and not trajectory.ok
    assert len(trajectory) == 5


def test_rollout_records_exceptions_instead_of_raising():
    light_o1 = FakeLightO1()
    reference = light_o1.to_reference(np.zeros((4, 138)))
    trajectory = Trajectory(JOINT_NAMES)

    class Broken(FakeSimulator):
        def warmup(self):
            raise RuntimeError("no policy")

    SonicRollout(light_o1, Broken(), reference, trajectory).run()
    assert trajectory.done and trajectory.error == "RuntimeError: no policy" and not trajectory.ok
    with pytest.raises(ValueError):
        SonicRollout(light_o1, FakeSimulator(), reference, Trajectory(JOINT_NAMES), replan_frames=0)
    with pytest.raises(ValueError):
        SonicRollout(light_o1, FakeSimulator(), reference, Trajectory(JOINT_NAMES), fall_height=2.0)


REAL = {key: os.environ.get(key) for key in ("LIGHT_O1_ROOT", "SONIC_TEST_CHECKPOINT", "LIGHT_O1_TEST_ACTION")}


@pytest.mark.skipif(not all(REAL.values()), reason="set LIGHT_O1_ROOT, SONIC_TEST_CHECKPOINT and "
                    "LIGHT_O1_TEST_ACTION (a human_action.npy) for the real Sonic rollout")
def test_real_sonic_rollout_tracks_a_saved_light_o1_action():
    from light_o1_vr.light_o1 import LightO1

    light_o1 = LightO1(REAL["LIGHT_O1_ROOT"])
    simulator = light_o1.simulator(REAL["SONIC_TEST_CHECKPOINT"])
    action = np.load(Path(REAL["LIGHT_O1_TEST_ACTION"]), allow_pickle=False)
    trajectory = Trajectory(light_o1.joint_names, prompt="saved", planned_s=len(action) / 20,
                            control_hz=light_o1.control_hz)
    SonicRollout(light_o1, simulator, light_o1.to_reference(action), trajectory).run()
    assert trajectory.error is None and trajectory.done
    assert trajectory.settle_frames == SETTLE_TICKS
    frames = trajectory.frames()
    assert frames.shape[1] == 36 and np.isfinite(frames).all()
    assert (frames[:, 2] > 0.3).all()  # pelvis height stays physical
    if trajectory.fell_at is None:
        assert len(trajectory) == SETTLE_TICKS + round(len(action) * 2.5)
    print(trajectory.summary())
