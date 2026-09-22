"""Pure input state-machine tests, not a replacement for headset coverage."""
from types import SimpleNamespace
import numpy as np
import pytest
from operator_xr import ControllerInput, ControllerPair, ControllerState, Pose
from wbc.controls import Commands, ControlMode, Gamepad
from wbc.hands import hand_targets

AB = {"ax_button": 1., "by_button": 1.}


def buttons(left=None, right=None, valid=True):
    def controller(values):
        return ControllerState(pose=Pose(valid=valid), input=ControllerInput(values=values or {}))
    return SimpleNamespace(controllers=ControllerPair(controller(left), controller(right)))


def test_abxy_requires_release_and_has_priority_over_mode_click():
    pad = Gamepad()
    assert not pad.update(buttons(AB, AB)).reset
    pad.update(buttons())
    command = pad.update(buttons({**AB, "primary_click": 1.}, AB))
    assert command.reset and not command.cycle_mode
    for _ in range(20):
        command = pad.update(buttons(AB, AB))
        assert not command.reset and not command.cycle_mode
    pad.update(buttons(AB, {"ax_button": 1.}))
    assert not pad.update(buttons(AB, AB)).reset
    pad.update(buttons())
    assert pad.update(buttons(AB, AB)).reset
    pad.invalidate()
    assert not pad.update(buttons(AB, AB)).reset


def test_no_face_subchords_or_triggers_can_reset_or_switch_modes():
    pad = Gamepad(); pad.update(buttons())
    for left, right in ((AB, {}), ({}, AB), ({"ax_button": 1.}, {"ax_button": 1.}),
                        ({"by_button": 1.}, {"by_button": 1.}),
                        ({"trigger": 1., "grip": 1.}, {"trigger": 1., "grip": 1.})):
        command = pad.update(buttons(left, right))
        assert not command.reset and not command.cycle_mode


def test_modes_cycle_once_per_click_and_motion_requires_recentering():
    pad = Gamepad(); pad.update(buttons())
    assert pad.update(buttons({"primary_y": 1.})).vx == pytest.approx(.6)
    assert pad.update(buttons({"primary_y": 1., "primary_click": 1.})).cycle_mode
    command = pad.update(buttons({"primary_y": 1., "primary_click": 1.}))
    assert not command.cycle_mode and command.vx == 0.
    assert pad.update(buttons({"primary_y": 1.})).vx == 0.
    pad.update(buttons())
    assert pad.update(buttons({"primary_y": 1.})).vx == pytest.approx(.6)
    mode = ControlMode.LOCOMOTION
    assert [mode.value, mode.next().value, mode.next().next().value] == ["LOCOMOTION", "VR", "BODY"]
    assert mode.next().next().next() == mode


def test_velocity_units_signs_deadzone_bounds_and_invalid_sources():
    pad = Gamepad(); pad.update(buttons())
    command = pad.update(buttons({"primary_x": 1., "primary_y": 1.}, {"primary_x": 1.}))
    assert np.hypot(command.vx, command.vy) == pytest.approx(.6)
    assert command.vx > 0 and command.vy < 0 and command.vyaw == -1.5
    command = pad.update(buttons({"primary_x": .1}, {"primary_x": .1}))
    assert (command.vx, command.vy, command.vyaw) == (0., 0., 0.)
    assert pad.update(buttons(AB, AB, valid=False)) == Commands()
    assert pad.axis(float("nan")) == pad.axis(float("inf")) == 0.


def test_analog_hand_control_is_independent_for_each_side():
    left, right = hand_targets(Commands(left_trigger=.4))
    assert np.max(abs(left)) > 0 and not np.any(right)
    full_left, full_right = hand_targets(Commands(left_trigger=1., right_trigger=1.))
    np.testing.assert_allclose(full_left, -full_right)
    np.testing.assert_allclose(left, .4 * full_left)
