"""Pure lifecycle tests; no sockets, headset runtime, or substitute policy."""
from types import SimpleNamespace
import pytest
from wbc.loop import ControlLoop
from wbc.controls import Gamepad
from wbc.tracking import TrackingUnavailable
from test_controls import buttons, AB


class LifecycleProbe:
    """Records lifecycle calls, not an implementation of robot control."""
    def __init__(self):
        self.calls = []
        self.gamepad = Gamepad()
        self.control_enabled = False
        self.simulation = SimpleNamespace(blueprint_state=lambda: {})

    def extract(self, frame):
        if frame.timestamp_ns is None:
            raise TrackingUnavailable("Missing body point")
        return frame

    def pause(self):
        self.calls.append("pause")
        self.control_enabled = False
        self.gamepad.invalidate()

    def reset(self):
        self.calls.append("reset")
        self.control_enabled = False

    def control_tick(self, frame, sample, now):
        commands = self.gamepad.update(frame)
        if commands.reset:
            self.reset()
            self.control_enabled = True
            self.calls.append("calibrate")
        if self.control_enabled:
            self.calls.append("advance")
        return "running" if self.control_enabled else "ABXY to initialize"


def sample(i, timestamp=None, chord=False):
    return SimpleNamespace(frame_id=i, timestamp_ns=timestamp if timestamp is not None else i * 10,
        controllers=buttons(AB if chord else None, AB if chord else None).controllers)


def started_loop():
    backend = LifecycleProbe(); loop = ControlLoop(backend, .25)
    loop.tick(None, True, None, 0.)
    loop.tick(sample(1, 100), True, None, .01)
    loop.tick(sample(2, 200, True), True, None, .02)
    assert backend.calls.count("calibrate") == 1
    return backend, loop


def test_cached_frame_held_buttons_and_old_blueprint_events_cannot_initialize():
    backend = LifecycleProbe(); loop = ControlLoop(backend, .25)
    event = SimpleNamespace(action="reset", value="old-dual-trigger-request")
    for i in (1, 2, 3):
        loop.tick(sample(i, chord=i != 3), True, event, i * .02)
        assert not loop.calibrated
    loop.tick(sample(4, chord=True), True, None, .08)
    assert loop.calibrated
    loop.tick(sample(4, chord=True), True, event, .08)
    assert backend.calls.count("calibrate") == 1


@pytest.mark.parametrize("failure", ["timeout", "partial", "clock", "disconnect", "sequence"])
def test_loss_pauses_and_requires_release_then_explicit_reset(failure):
    backend, loop = started_loop()
    advanced = backend.calls.count("advance")
    frame, now, connected = sample(2, 200, True), .4, True
    if failure == "partial":
        frame, now = sample(3), .04
        frame.timestamp_ns = None
    elif failure == "clock":
        frame, now = sample(3, 50, True), .04
    elif failure == "disconnect":
        connected = False
    elif failure == "sequence":
        frame, now = sample(1, 250, True), .04
    state = loop.tick(frame, connected, None, now)
    assert not loop.calibrated and state["g1.visible"]
    assert backend.calls.count("advance") == advanced
    for i in (4, 5):
        state = loop.tick(sample(i, 300+i, True), True, None, .5+i*.01)
        assert not loop.calibrated
    loop.tick(sample(6, 400), True, None, .56)
    state = loop.tick(sample(7, 500, True), True, None, .58)
    assert loop.calibrated
    assert backend.calls.count("calibrate") == 2


def test_repeated_source_timestamp_does_not_extend_tracking_freshness():
    _, loop = started_loop()
    state = loop.tick(sample(3, 200), True, None, .4)
    assert not loop.available and not loop.calibrated


def test_timeout_before_initialization_also_invalidates_button_baseline():
    backend = LifecycleProbe(); loop = ControlLoop(backend, .25)
    loop.tick(None, True, None, 0.)
    loop.tick(sample(1, 100), True, None, .02)
    loop.tick(sample(1, 100), True, None, .4)
    loop.tick(sample(2, 200, True), True, None, .42)
    assert not loop.calibrated and "calibrate" not in backend.calls
    loop.tick(sample(3, 300), True, None, .44)
    loop.tick(sample(4, 400, True), True, None, .46)
    assert loop.calibrated
