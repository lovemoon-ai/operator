"""MotionSession lifecycle: menu events, pipeline phases, live and replayed playback."""
import threading
import time
from types import SimpleNamespace

import numpy as np
import pytest

from light_o1_vr.controller import MotionSession, Phase
from light_o1_vr.generator import GenerationError
from light_o1_vr.rollout import SETTLE_TICKS
from fakes import FakeGenerator, FakeLightO1, FakeSimulator, blueprint_for_tests


class Clock:
    def __init__(self):
        self.now = 100.0

    def __call__(self):
        return self.now

    def advance(self, seconds):
        self.now += seconds
        return self.now


def event(action, value):
    return SimpleNamespace(action=action, value=value)


def make_session(generator=None, simulator=None, clock=None, prompts=("wave", "walk", "squat"), **kwargs):
    simulator = simulator or FakeSimulator()
    idle = np.concatenate((simulator.data.qpos[:7], simulator.data.qpos[7:]))
    kwargs.setdefault("prebuffer_s", 0.1)
    return MotionSession(generator=generator or FakeGenerator(frames=8), light_o1=FakeLightO1(),
                         simulator=simulator, prompts=prompts, idle_state=idle, clock=clock or Clock(),
                         **kwargs)


def wait_for(predicate, timeout=5.0):
    deadline = time.monotonic() + timeout
    while not predicate():
        if time.monotonic() > deadline:
            raise AssertionError("condition not met in time")
        time.sleep(0.005)


def join_pipeline(session):
    job = session._job
    if job is not None and job.thread is not None:
        job.thread.join(5.0)
        assert not job.thread.is_alive()


def test_idle_state_is_a_complete_valid_blueprint_snapshot():
    session = make_session()
    state = session.tick()
    blueprint_for_tests().validate_state_values(state)
    assert len(state["g1.joints"]) == 29 and state["g1.joints"][0] == 0.25
    assert state["g1.base"] == pytest.approx([0.0, 0.8, 0.0, 0.0, 0.0, 0.0, 1.0])
    assert state["g1.sample"] == 1 and session.tick()["g1.sample"] == 2
    assert state["ui.text"].startswith("Prompt 1/3: wave\nReady")
    assert state["motion.active"] is False and state["motion.replay_available"] is False
    assert state["prompt.cycle"] is False and session.phase is Phase.IDLE


def test_prompt_rows_cycle_and_unknown_events_are_ignored():
    session = make_session()
    assert session.handle_event(event("prompt.next", True)) and session.prompts.current == "walk"
    assert session.handle_event(event("prompt.prev", True)) and session.prompts.current == "wave"
    session.handle_event(event("prompt.prev", True))
    assert session.prompts.current == "squat" and "Prompt 3/3: squat" in session.tick()["ui.text"]
    assert not session.handle_event(event("connection.toggle", True))
    assert not session.handle_event(None)
    assert session.phase is Phase.IDLE


def test_generate_plays_live_then_completes_and_enables_replay():
    clock = Clock()
    generator = FakeGenerator(frames=8)  # 0.4 s -> 20 ticks after 75 settle ticks
    session = make_session(generator=generator, clock=clock, seed=3, thinking=False)
    assert session.handle_event(event("motion.toggle", True))
    join_pipeline(session)
    assert generator.calls == [("wave", 3, False)]
    trajectory = session._job.trajectory
    assert trajectory.ok and len(trajectory) == SETTLE_TICKS + 20
    state = session.tick()  # playback starts: enough frames are buffered
    assert session.phase is Phase.PLAYING and state["motion.active"] is True
    assert "Playing 0.0/1.9s" in state["ui.text"]
    clock.advance(0.5)
    state = session.tick()
    assert state["g1.base"][2] == pytest.approx(-0.01 * 26, abs=1e-9)  # frame 25, robot +X -> XR -Z
    assert state["g1.joints"][0] == 0.25  # still settling: joints hold the default pose
    clock.advance(1.07)  # 1.57 s -> frame 78 = tracking tick 3 of the first chunk
    state = session.tick()
    assert state["g1.joints"][0] == pytest.approx(0.55)
    clock.advance(10.0)
    state = session.tick()
    assert session.phase is Phase.DONE and state["motion.active"] is False
    assert state["motion.replay_available"] is True
    assert "Done - 0.4s, G1 stayed up" in state["ui.text"]
    last = np.array(state["g1.base"])
    assert session.tick()["g1.base"] == pytest.approx(last.tolist())  # holds the final pose
    blueprint_for_tests().validate_state_values(state)


def test_replay_reuses_the_last_trajectory_without_regenerating():
    clock = Clock()
    generator = FakeGenerator(frames=4)
    session = make_session(generator=generator, clock=clock)
    session.start()
    join_pipeline(session)
    session.tick()  # anchors live playback
    clock.advance(30)
    session.tick()
    assert session.phase is Phase.DONE
    assert session.replay() is not None and session.phase is Phase.PLAYING
    state = session.tick()
    assert "(replay)" in state["ui.text"] and state["motion.active"] is True
    assert state["g1.base"][2] == pytest.approx(-0.01)  # first recorded frame again
    clock.advance(30)
    assert session.tick()["motion.active"] is False and session.phase is Phase.DONE
    assert generator.calls == [("wave", 0, True)]
    assert session.handle_event(event("motion.replay", True)) and session.phase is Phase.PLAYING
    session.handle_event(event("motion.replay", False))
    assert session.phase is Phase.STOPPED


def test_replay_is_unavailable_before_a_successful_motion():
    session = make_session()
    assert session.replay() is None
    assert session.handle_event(event("motion.replay", True)) and session.phase is Phase.IDLE


def test_stop_freezes_playback_and_cancels_the_pipeline():
    clock = Clock()
    session = make_session(generator=FakeGenerator(frames=40), clock=clock)
    session.start()
    join_pipeline(session)
    session.tick()
    clock.advance(0.3)
    frozen = session.tick()["g1.base"]
    session.handle_event(event("motion.toggle", False))
    assert session.phase is Phase.STOPPED
    clock.advance(5)
    state = session.tick()
    assert state["g1.base"] == pytest.approx(frozen) and state["motion.active"] is False
    assert "Stopped" in state["ui.text"]
    assert state["motion.replay_available"] is True  # the finished rollout is still replayable


def test_stop_during_generation_cancels_and_reports_stopped():
    gate = threading.Event()
    session = make_session(generator=FakeGenerator(gate=gate))
    session.start()
    state = session.tick()
    assert session.phase is Phase.GENERATING and "Light-O1 generating" in state["ui.text"]
    assert state["g1.joints"][0] == 0.25  # idle pose while waiting
    session.stop()
    join_pipeline(session)
    assert session.phase is Phase.STOPPED and session.last_trajectory is None
    gate.set()


def test_generation_errors_are_shown_not_raised():
    session = make_session(generator=FakeGenerator(error=GenerationError("HTTP 503: not ready")))
    session.start()
    join_pipeline(session)
    state = session.tick()
    assert session.phase is Phase.FAILED and "Failed: HTTP 503: not ready" in state["ui.text"]
    assert state["motion.active"] is False and state["motion.replay_available"] is False
    blueprint_for_tests().validate_state_values(state)


def test_rollout_failures_and_bad_actions_fail_the_job():
    session = make_session(simulator=FakeSimulator(fall_after_ticks=SETTLE_TICKS + 3), generator=FakeGenerator(20))
    clock = session.clock
    session.start()
    join_pipeline(session)
    session.tick()  # anchors live playback
    clock.advance(30)
    state = session.tick()
    assert session.phase is Phase.DONE and "G1 fell at 0.1s" in state["ui.text"]
    broken = make_session(generator=FakeGenerator(4))
    broken.light_o1 = FakeLightO1(fail_reference=True)
    broken.start()
    join_pipeline(broken)
    assert broken.phase is Phase.FAILED and "ValueError: bad action" in broken.tick()["ui.text"]


def test_typed_prompt_is_added_selected_and_started():
    generator = FakeGenerator(frames=4)
    session = make_session(generator=generator)
    assert session.submit("  do a  backflip ") == "do a backflip"
    join_pipeline(session)
    assert session.prompts.current == "do a backflip" and len(session.prompts) == 4
    assert generator.calls[0][0] == "do a backflip"
    with pytest.raises(ValueError):
        session.submit("   ")


def test_new_generate_waits_for_the_previous_rollout_to_release_the_simulator():
    release = threading.Event()
    steps_seen = []

    def hook(sim):
        steps_seen.append(sim.steps)
        if sim.steps == 3:
            release.wait(5.0)

    simulator = FakeSimulator(step_hook=hook)
    session = make_session(generator=FakeGenerator(frames=40), simulator=simulator)
    first = session.start()
    wait_for(lambda: len(steps_seen) >= 3)
    second = session.start()  # cancels the first rollout, whose thread is blocked in step 3
    assert first.cancel.is_set() and session._job is second
    time.sleep(0.05)
    assert second.trajectory is None  # generation done, but the simulator is still held by the first job
    release.set()
    join_pipeline(session)
    assert first.trajectory.cancelled and second.trajectory.ok
    assert simulator.resets >= 3


def test_slow_simulation_holds_the_newest_frame_instead_of_skipping():
    clock = Clock()
    produced = threading.Event()
    resume = threading.Event()

    class SlowRollout:
        def __init__(self, reference, trajectory, cancel):
            self.trajectory = trajectory

        def run(self):
            for i in range(10):
                self.trajectory.append(np.concatenate(([0.01 * i, 0, 0.8, 1, 0, 0, 0], np.zeros(29))))
            produced.set()
            resume.wait(5.0)
            for i in range(10, 20):
                self.trajectory.append(np.concatenate(([0.01 * i, 0, 0.8, 1, 0, 0, 0], np.zeros(29))))
            self.trajectory.finish(survived_s=0.4)

    session = make_session(generator=FakeGenerator(frames=8), clock=clock,
                           rollout_factory=lambda r, t, c: SlowRollout(r, t, c))
    session.start()
    produced.wait(5.0)
    wait_for(lambda: session._job.trajectory is not None and len(session._job.trajectory) == 10)
    session.tick()  # 10 frames >= prebuffer (5): playback starts at frame 0
    assert session.phase is Phase.PLAYING
    clock.advance(1.0)  # would be frame 50, only 10 exist
    state = session.tick()
    assert state["g1.base"][2] == pytest.approx(-0.09) and session.phase is Phase.PLAYING
    resume.set()
    join_pipeline(session)
    clock.advance(0.02)  # exactly one tick later: the next frame, none skipped
    assert session.tick()["g1.base"][2] == pytest.approx(-0.10)
    clock.advance(5)
    assert session.tick()["g1.base"][2] == pytest.approx(-0.19) and session.phase is Phase.DONE


def test_close_stops_work_and_rejects_new_jobs():
    gate = threading.Event()
    session = make_session(generator=FakeGenerator(gate=gate))
    session.start()
    session.close(timeout=2.0)
    assert session.phase is Phase.STOPPED
    with pytest.raises(RuntimeError):
        session.start()
    gate.set()
    with pytest.raises(ValueError):
        make_session(prebuffer_s=-1)
