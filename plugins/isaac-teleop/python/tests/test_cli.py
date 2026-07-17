from operator_isaacteleop.cli import _load_factory, _run_session_loop, _sample_telemetry
from operator_isaacteleop.model import ControlSample, ExternalInputBundle, TimedSample
from operator_isaacteleop.protocol import Kind


def test_sample_telemetry_and_file_factory():
    sample = TimedSample(Kind.CONTROL, ControlSample(), 10, 20, 30, 4, 5, 1)
    value = _sample_telemetry(sample, now_ns=35)
    assert value["kind"] == "CTRL"
    assert value["age_ns"] == 15

    factory = _load_factory("examples/fake_session.py:make_session")
    assert factory().__class__.__name__ == "ExternalTeleopSession"


def test_session_loop_ticks_without_any_packet():
    class SilentReceiver:
        def __init__(self):
            self.snapshots = 0

        def receive_once(self, *, timeout=None):
            return None

        def snapshot(self, *, now_ns=None):
            self.snapshots += 1
            return ExternalInputBundle({}, now_ns or 0)

    class CountingSession:
        def __init__(self):
            self.bundles = []

        def step(self, bundle):
            self.bundles.append(bundle)
            return {"action": []}

    receiver = SilentReceiver()
    session = CountingSession()
    assert _run_session_loop(receiver, session, step_hz=60.0, once=True) == 0
    assert receiver.snapshots == 1
    assert len(session.bundles) == 1
    assert session.bundles[0].empty
