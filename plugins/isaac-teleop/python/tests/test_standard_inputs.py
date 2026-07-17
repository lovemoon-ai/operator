from enum import IntEnum
from types import SimpleNamespace

from operator_isaacteleop.isaac import LazyIsaacTeleopBindings
from operator_isaacteleop.model import (
    ControllerSample,
    ControlSample,
    ExternalInputBundle,
    JointSample,
    JointSetSample,
    Pose,
    TimedSample,
)
from operator_isaacteleop.protocol import Kind
from operator_isaacteleop.standard_inputs import IsaacStandardInputAdapter


class FakeType:
    def __init__(self, name, size):
        self.name = name
        self.size = size


class FakeOptionalType:
    def __init__(self, inner):
        self.inner = inner
        self.name = inner.name
        self.size = inner.size


class FakeGroup:
    def __init__(self, group_type):
        self.group_type = getattr(group_type, "inner", group_type)
        self.values = [None] * self.group_type.size
        self.is_none = True

    def __setitem__(self, index, value):
        self.values[int(index)] = value
        self.is_none = False

    def __getitem__(self, index):
        return self.values[int(index)]

    def set_none(self):
        self.is_none = True


class FakeTensorGroup(FakeGroup):
    def __init__(self, group_type):
        super().__init__(group_type)
        self.is_none = False


class FakeValueInput:
    VALUE = "value"

    def __init__(self, name, tensor_type):
        self.name = name
        self.tensor_type = tensor_type

    def output(self, name):
        return (self.name, name)


class HeadIndex(IntEnum):
    POSITION = 0
    ORIENTATION = 1
    IS_VALID = 2


class ControllerIndex(IntEnum):
    GRIP_POSITION = 0
    GRIP_ORIENTATION = 1
    GRIP_IS_VALID = 2
    AIM_POSITION = 3
    AIM_ORIENTATION = 4
    AIM_IS_VALID = 5
    PRIMARY_CLICK = 6
    SECONDARY_CLICK = 7
    THUMBSTICK_X = 8
    THUMBSTICK_Y = 9
    THUMBSTICK_CLICK = 10
    MENU_CLICK = 11
    SQUEEZE_VALUE = 12
    TRIGGER_VALUE = 13


class HandIndex(IntEnum):
    JOINT_POSITIONS = 0
    JOINT_ORIENTATIONS = 1
    JOINT_RADII = 2
    JOINT_VALID = 3


class BodyIndex(IntEnum):
    JOINT_POSITIONS = 0
    JOINT_ORIENTATIONS = 1
    JOINT_VALID = 2


class FakeArray:
    def __init__(self, data, dtype):
        self.data = data
        self.dtype = dtype


class FakeNumpy:
    float32 = "float32"
    uint8 = "uint8"

    @staticmethod
    def asarray(data, dtype):
        return FakeArray(data, dtype)

    @staticmethod
    def eye(size, dtype):
        return FakeArray(
            [[1.0 if row == column else 0.0 for column in range(size)] for row in range(size)],
            dtype,
        )


class FakePipeline:
    def __init__(self, manager, inputs):
        self.manager = manager
        self.inputs = inputs


class FakeDefaultStateManager:
    INPUT_KILL = "kill_button"
    INPUT_RUN_TOGGLE = "run_toggle_button"
    INPUT_RESET = "reset_button"

    def __init__(self, name):
        self.name = name

    def connect(self, inputs):
        return FakePipeline(self, inputs)


def make_bindings():
    calls = []
    interface = SimpleNamespace(
        TensorGroup=FakeTensorGroup,
        OptionalTensorGroup=FakeGroup,
        OptionalType=FakeOptionalType,
        ValueInput=FakeValueInput,
    )
    tensor_types = SimpleNamespace(
        HeadPose=lambda: FakeType("head", 3),
        HeadPoseIndex=HeadIndex,
        ControllerInput=lambda: FakeType("controller", 14),
        ControllerInputIndex=ControllerIndex,
        HandInput=lambda: FakeType("hand", 4),
        HandInputIndex=HandIndex,
        FullBodyInput=lambda: FakeType("body", 3),
        FullBodyInputIndex=BodyIndex,
        TransformMatrix=lambda: FakeType("transform", 1),
    )
    teleop = SimpleNamespace(
        DefaultTeleopStateManager=FakeDefaultStateManager,
        bool_signal=lambda name: FakeType(name, 1),
    )
    modules = {
        "isaacteleop.retargeting_engine.interface": interface,
        "isaacteleop.retargeting_engine.tensor_types": tensor_types,
        "isaacteleop.teleop_session_manager": teleop,
        "numpy": FakeNumpy,
    }

    def load(name):
        calls.append(name)
        return modules[name]

    return LazyIsaacTeleopBindings(load), calls


def timed(kind, value, sequence=1):
    return TimedSample(kind, value, 100, 200, 300, sequence, 7, 1)


def pose(seed=0.0, valid=True):
    return Pose(valid, (seed + 1.0, seed + 2.0, seed + 3.0), (0.0, 0.0, 0.0, 1.0))


def joints(count):
    return JointSetSample(
        tuple(
            JointSample(pose(float(index), index % 2 == 0), index / 1000) for index in range(count)
        )
    )


def test_lazy_value_inputs_match_external_keys_and_missing_channels_are_optional():
    bindings, calls = make_bindings()
    adapter = IsaacStandardInputAdapter(
        bindings=bindings,
        include_kinds=(Kind.HEAD, Kind.LEFT_HAND, Kind.ANCHOR),
    )
    assert calls == []
    leaves = adapter.create_value_inputs()
    assert set(leaves) == {Kind.HEAD, Kind.LEFT_HAND, Kind.ANCHOR}
    assert leaves[Kind.HEAD].tensor_type.__class__ is FakeOptionalType
    assert leaves[Kind.ANCHOR].tensor_type.__class__ is FakeType

    external = adapter(ExternalInputBundle({}, 123))
    assert set(external) == {leaf.name for leaf in leaves.values()}
    assert external[leaves[Kind.HEAD].name]["value"].is_none
    assert external[leaves[Kind.LEFT_HAND].name]["value"].is_none
    anchor = external[leaves[Kind.ANCHOR].name]["value"]
    assert not anchor.is_none
    assert anchor[0].dtype == "float32"
    assert anchor[0].data[0] == [1.0, 0.0, 0.0, 0.0]

    invalid_anchor = adapter(
        ExternalInputBundle(
            {Kind.ANCHOR: timed(Kind.ANCHOR, Pose(False, (9, 8, 7), (0, 0, 0, 1)))},
            124,
        )
    )[leaves[Kind.ANCHOR].name]["value"][0]
    assert [row[3] for row in invalid_anchor.data[:3]] == [0.0, 0.0, 0.0]


def test_standard_tensor_values_use_indices_float32_and_uint8():
    bindings, _ = make_bindings()
    adapter = IsaacStandardInputAdapter(
        bindings=bindings,
        include_kinds=(
            Kind.HEAD,
            Kind.LEFT_CONTROLLER,
            Kind.RIGHT_HAND,
            Kind.BODY,
            Kind.ANCHOR,
        ),
    )
    controller = ControllerSample(pose(), pose(1), True, False, True, False, 0.2, -0.3, 0.4, 0.5)
    bundle = ExternalInputBundle(
        {
            Kind.HEAD: timed(Kind.HEAD, pose()),
            Kind.LEFT_CONTROLLER: timed(Kind.LEFT_CONTROLLER, controller),
            Kind.RIGHT_HAND: timed(Kind.RIGHT_HAND, joints(26)),
            Kind.BODY: timed(Kind.BODY, joints(24)),
            Kind.ANCHOR: timed(Kind.ANCHOR, pose()),
        },
        200,
    )
    external = adapter(bundle)
    leaves = adapter.create_value_inputs()
    head = external[leaves[Kind.HEAD].name]["value"]
    assert head[HeadIndex.POSITION].dtype == "float32"
    assert head[HeadIndex.IS_VALID] is True
    ctl = external[leaves[Kind.LEFT_CONTROLLER].name]["value"]
    assert ctl[ControllerIndex.PRIMARY_CLICK] == 1.0
    assert ctl[ControllerIndex.THUMBSTICK_X] == 0.2
    hand = external[leaves[Kind.RIGHT_HAND].name]["value"]
    assert hand[HandIndex.JOINT_POSITIONS].dtype == "float32"
    assert hand[HandIndex.JOINT_VALID].dtype == "uint8"
    assert len(hand[HandIndex.JOINT_VALID].data) == 26
    body = external[leaves[Kind.BODY].name]["value"]
    assert body[BodyIndex.JOINT_VALID].dtype == "uint8"
    anchor = external[leaves[Kind.ANCHOR].name]["value"][0]
    assert [row[3] for row in anchor.data[:3]] == [1.0, 2.0, 3.0]


def test_official_default_control_pipeline_and_deadman_fail_safe_mapping():
    bindings, _ = make_bindings()
    adapter = IsaacStandardInputAdapter(bindings=bindings, include_kinds=(Kind.HEAD,))
    control = adapter.create_default_control_pipeline()
    assert set(control.pipeline.inputs) == {"kill_button", "run_toggle_button", "reset_button"}
    assert set(control.value_inputs) == set(control.pipeline.inputs)

    bundle = ExternalInputBundle(
        {Kind.CONTROL: timed(Kind.CONTROL, ControlSample(False, True, True, False))}, 100
    )
    external = adapter(bundle)
    kill_leaf = control.value_inputs["kill_button"]
    run_leaf = control.value_inputs["run_toggle_button"]
    reset_leaf = control.value_inputs["reset_button"]
    assert external[kill_leaf.name]["value"][0] is True
    assert external[run_leaf.name]["value"][0] is True
    assert external[reset_leaf.name]["value"][0] is True

    missing = adapter(ExternalInputBundle({}, 101))
    assert missing[kill_leaf.name]["value"].is_none
    assert missing[run_leaf.name]["value"].is_none
    assert missing[reset_leaf.name]["value"].is_none
