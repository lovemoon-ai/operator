"""Right-controller edge semantics; pure state machine, no headset."""
from types import SimpleNamespace

from pyoperator import ControllerInput, ControllerPair, ControllerState, Pose

from light_o1_vr.controls import Commands, Gamepad

A, B = {"ax_button": 1.0}, {"by_button": 1.0}


def frame(right=None, left=None, right_valid=True, left_valid=True):
    def controller(values, valid):
        return None if values is None else ControllerState(
            pose=Pose(valid=valid), input=ControllerInput(values=values))
    return SimpleNamespace(controllers=ControllerPair(controller(left, left_valid), controller(right, right_valid)))


def test_buttons_fire_once_per_press_after_a_released_baseline():
    pad = Gamepad()
    assert not pad.update(frame(A))  # held while connecting: nothing until released
    assert not pad.update(frame({}))
    assert pad.update(frame(A)) == Commands(generate=True)
    for _ in range(10):
        assert not pad.update(frame(A))  # holding never repeats
    assert not pad.update(frame({}))
    assert pad.update(frame(B)) == Commands(replay=True)
    assert pad.update(frame({**A, **B})) == Commands(generate=True)  # B still held, A is a new edge
    assert not pad.update(frame({**A, **B}))


def test_stick_steps_one_prompt_per_deflection_with_hysteresis():
    pad = Gamepad()
    pad.update(frame({}))
    assert pad.update(frame({"primary_x": 0.9})) == Commands(next=True)
    assert not pad.update(frame({"primary_x": 1.0}))
    assert not pad.update(frame({"primary_x": 0.5}))  # not back below the recentre band yet
    assert not pad.update(frame({"primary_x": 0.9}))
    assert not pad.update(frame({"primary_x": 0.1}))
    assert pad.update(frame({"primary_x": -0.7})) == Commands(prev=True)
    assert not pad.update(frame({"primary_x": -0.59}))
    assert not pad.update(frame({"primary_x": 0.2}))
    assert pad.update(frame({"primary_x": 0.61})) == Commands(next=True)
    assert not pad.update(frame({"primary_x": 0.4}))  # small values never step
    assert not pad.update(frame({"primary_x": float("nan")}))


def test_left_stick_also_selects_and_a_deflected_stick_blocks_arming():
    pad = Gamepad()
    assert not pad.update(frame({}, {"primary_x": 1.0}))  # deflected at connect: not armed yet
    assert not pad.update(frame({}, {"primary_x": 1.0}))
    pad.update(frame({}, {"primary_x": 0.0}))
    assert pad.update(frame({}, {"primary_x": -1.0})) == Commands(prev=True)
    pad.update(frame({}, {"primary_x": 0.0}))
    assert pad.update(frame({"primary_x": 0.9}, {"primary_x": -0.9})) == Commands(next=True)  # right wins


def test_tracking_loss_or_missing_right_controller_resets_the_baseline():
    pad = Gamepad()
    pad.update(frame({}))
    assert pad.update(frame(A)) == Commands(generate=True)
    assert not pad.update(frame(A, right_valid=False))
    assert not pad.update(frame(None))
    assert not pad.update(None)
    assert not pad.update(frame(A))  # held across the loss: needs a release first
    pad.update(frame({}))
    assert pad.update(frame(A)) == Commands(generate=True)
    pad.invalidate()
    assert not pad.update(frame(A))
    assert not Commands() and Commands(prev=True)
