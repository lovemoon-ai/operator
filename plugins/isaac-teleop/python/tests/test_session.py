from operator_isaacteleop.isaac import PortableExecutionState
from operator_isaacteleop.model import ControlSample, ExternalInputBundle, Pose, TimedSample
from operator_isaacteleop.protocol import Kind
from operator_isaacteleop.session import ExternalTeleopSession, OperatorIsaacTeleopDevice


def timed(kind, value, sequence=1):
    return TimedSample(kind, value, 100, 200, 300, sequence, 7, 1)


class FakeSession:
    def __init__(self):
        self.calls = []
        self.entered = False

    def __enter__(self):
        self.entered = True
        return self

    def __exit__(self, *args):
        self.entered = False

    def step(self, *, external_inputs, graph_time, execution_events):
        self.calls.append((external_inputs, graph_time, execution_events))
        return {"action": [b"fake-action"]}


def test_external_session_calls_public_step_signature_and_state_edges():
    fake = FakeSession()
    session = ExternalTeleopSession(fake)
    bundle = ExternalInputBundle(
        {
            Kind.HEAD: timed(Kind.HEAD, Pose(True, (0, 0, 0), (0, 0, 0, 1))),
            Kind.CONTROL: timed(Kind.CONTROL, ControlSample(False, True, False, True)),
        },
        1234,
    )
    result = session.step(bundle)
    assert result == {"action": [b"fake-action"]}
    inputs, graph_time, events = fake.calls[-1]
    assert set(inputs) == {"operator_head"}
    assert graph_time == 1234
    assert events.execution_state is PortableExecutionState.PAUSED

    # Held toggle has no second rising edge.
    session.step(bundle)
    assert fake.calls[-1][2].execution_state is PortableExecutionState.PAUSED

    released = ExternalInputBundle(
        {Kind.CONTROL: timed(Kind.CONTROL, ControlSample(False, False, False, True), 2)},
        1235,
    )
    session.step(released)
    session.step(
        ExternalInputBundle(
            {Kind.CONTROL: timed(Kind.CONTROL, ControlSample(False, True, False, True), 3)},
            1236,
        )
    )
    assert fake.calls[-1][2].execution_state is PortableExecutionState.RUNNING

    killed = ExternalInputBundle({Kind.CONTROL: timed(Kind.CONTROL, ControlSample(True), 4)}, 1237)
    session.step(killed)
    assert fake.calls[-1][2].execution_state is PortableExecutionState.STOPPED
    assert fake.calls[-1][2].reset is True


def test_injected_upstream_event_provider_bypasses_portable_state_manager():
    fake = FakeSession()
    upstream_event = object()
    controls = []
    session = ExternalTeleopSession(
        fake,
        execution_events_provider=lambda control: controls.append(control) or upstream_event,
    )
    bundle = ExternalInputBundle(
        {Kind.CONTROL: timed(Kind.CONTROL, ControlSample(False, False, False, True))}, 123
    )
    session.step(bundle)
    assert controls == [bundle.get(Kind.CONTROL).value]
    assert fake.calls[-1][2] is upstream_event


def test_session_control_pipeline_receives_none_execution_events():
    fake = FakeSession()
    session = ExternalTeleopSession(fake, session_control_pipeline=True)
    bundle = ExternalInputBundle(
        {Kind.CONTROL: timed(Kind.CONTROL, ControlSample(False, True, False, True))}, 123
    )
    session.step(bundle)
    assert fake.calls[-1][2] is None


class FakeReceiver:
    def __init__(self, bundle):
        self.bundle = bundle
        self.started = False

    def start(self, *, background=True):
        self.started = True

    def snapshot(self, *, now_ns=None):
        return self.bundle

    def close(self):
        self.started = False


def test_device_lifecycle_advance_and_callbacks():
    bundle = ExternalInputBundle(
        {Kind.CONTROL: timed(Kind.CONTROL, ControlSample(False, True, False, True))}, 100
    )
    receiver = FakeReceiver(bundle)
    raw = FakeSession()
    session = ExternalTeleopSession(raw)
    device = OperatorIsaacTeleopDevice(
        receiver, session, action_adapter=lambda result: result["action"][0]
    )
    steps = []
    device.add_callback("step", lambda: steps.append(True))
    with device:
        assert receiver.started
        assert raw.entered
        assert device.advance() == b"fake-action"
    assert not receiver.started
    assert not raw.entered
    assert steps == [True]


def test_device_steps_empty_snapshot_for_control_expiry_safety():
    receiver = FakeReceiver(ExternalInputBundle({}, 999))
    raw = FakeSession()
    session = ExternalTeleopSession(raw, session_control_pipeline=True)
    device = OperatorIsaacTeleopDevice(
        receiver, session, action_adapter=lambda result: result["action"][0]
    )
    assert device.advance() == b"fake-action"
    inputs, graph_time, execution_events = raw.calls[-1]
    assert inputs == {}
    assert graph_time == 999
    assert execution_events is None
