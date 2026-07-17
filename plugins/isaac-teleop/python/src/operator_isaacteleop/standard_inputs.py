"""Canonical values to IsaacTeleop's public standard TensorGroup types."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from .isaac import LazyIsaacTeleopBindings
from .model import ControllerSample, ControlSample, ExternalInputBundle, JointSetSample, Pose
from .protocol import Kind

DEFAULT_INPUT_NAMES = {
    Kind.HEAD: "operator_head",
    Kind.LEFT_CONTROLLER: "operator_left_controller",
    Kind.RIGHT_CONTROLLER: "operator_right_controller",
    Kind.LEFT_HAND: "operator_left_hand",
    Kind.RIGHT_HAND: "operator_right_hand",
    Kind.BODY: "operator_body",
    Kind.ANCHOR: "world_T_anchor",
}

TRACKING_KINDS = (
    Kind.HEAD,
    Kind.LEFT_CONTROLLER,
    Kind.RIGHT_CONTROLLER,
    Kind.LEFT_HAND,
    Kind.RIGHT_HAND,
    Kind.BODY,
    Kind.ANCHOR,
)


@dataclass(frozen=True, slots=True)
class DefaultControlPipeline:
    """Official state manager graph plus its external ValueInput leaves."""

    pipeline: Any
    value_inputs: dict[str, Any]


class IsaacStandardInputAdapter:
    """Build standard IsaacTeleop TensorGroups and matching ValueInput leaves.

    Tracking inputs are optional and are emitted as absent
    ``OptionalTensorGroup`` values when a channel is missing or expired. Anchor
    is required and defaults to identity until Operator sends ``ANCH``. If a
    default control pipeline is created, its three optional leaves are emitted
    on every call as well; missing ``CTRL`` therefore activates the upstream
    state manager's fail-safe STOPPED behavior.
    """

    def __init__(
        self,
        *,
        bindings: LazyIsaacTeleopBindings | None = None,
        input_names: dict[Kind, str] | None = None,
        include_kinds: tuple[Kind, ...] = TRACKING_KINDS,
    ) -> None:
        self.bindings = bindings or LazyIsaacTeleopBindings()
        self.input_names = {**DEFAULT_INPUT_NAMES, **(input_names or {})}
        self.include_kinds = tuple(include_kinds)
        if Kind.CONTROL in self.include_kinds:
            raise ValueError("CTRL is configured through create_default_control_pipeline()")
        self._api: dict[str, Any] | None = None
        self._types: dict[Kind, Any] = {}
        self._value_inputs: dict[Kind, Any] = {}
        self._control: DefaultControlPipeline | None = None

    def _load_api(self) -> dict[str, Any]:
        if self._api is not None:
            return self._api
        interface = self.bindings.module("isaacteleop.retargeting_engine.interface")
        tensor_types = self.bindings.module("isaacteleop.retargeting_engine.tensor_types")
        teleop = self.bindings.module("isaacteleop.teleop_session_manager")
        numpy = self.bindings.module("numpy")
        self._api = {
            "TensorGroup": interface.TensorGroup,
            "OptionalTensorGroup": interface.OptionalTensorGroup,
            "OptionalType": interface.OptionalType,
            "ValueInput": interface.ValueInput,
            "HeadPose": tensor_types.HeadPose,
            "HeadPoseIndex": tensor_types.HeadPoseIndex,
            "ControllerInput": tensor_types.ControllerInput,
            "ControllerInputIndex": tensor_types.ControllerInputIndex,
            "HandInput": tensor_types.HandInput,
            "HandInputIndex": tensor_types.HandInputIndex,
            "FullBodyInput": tensor_types.FullBodyInput,
            "FullBodyInputIndex": tensor_types.FullBodyInputIndex,
            "TransformMatrix": tensor_types.TransformMatrix,
            "DefaultTeleopStateManager": teleop.DefaultTeleopStateManager,
            "bool_signal": teleop.bool_signal,
            "np": numpy,
        }
        return self._api

    def _type_for(self, kind: Kind) -> Any:
        if kind in self._types:
            return self._types[kind]
        api = self._load_api()
        factories = {
            Kind.HEAD: api["HeadPose"],
            Kind.LEFT_CONTROLLER: api["ControllerInput"],
            Kind.RIGHT_CONTROLLER: api["ControllerInput"],
            Kind.LEFT_HAND: api["HandInput"],
            Kind.RIGHT_HAND: api["HandInput"],
            Kind.BODY: api["FullBodyInput"],
            Kind.ANCHOR: api["TransformMatrix"],
        }
        try:
            tensor_type = factories[kind]()
        except KeyError as exc:
            raise ValueError(f"no standard IsaacTeleop type for {kind.name}") from exc
        self._types[kind] = tensor_type
        return tensor_type

    def create_value_inputs(self) -> dict[Kind, Any]:
        """Return cached leaves whose names exactly match emitted input keys."""

        api = self._load_api()
        for kind in self.include_kinds:
            if kind in self._value_inputs:
                continue
            tensor_type = self._type_for(kind)
            leaf_type = tensor_type if kind is Kind.ANCHOR else api["OptionalType"](tensor_type)
            self._value_inputs[kind] = api["ValueInput"](self.input_names[kind], leaf_type)
        return dict(self._value_inputs)

    def create_default_control_pipeline(
        self, *, prefix: str = "operator_control"
    ) -> DefaultControlPipeline:
        """Create external bool leaves wired to upstream DefaultTeleopStateManager."""

        if self._control is not None:
            return self._control
        api = self._load_api()
        manager_type = api["DefaultTeleopStateManager"]
        fields = {
            manager_type.INPUT_KILL: "kill_button",
            manager_type.INPUT_RUN_TOGGLE: "run_toggle_button",
            manager_type.INPUT_RESET: "reset_button",
        }
        leaves: dict[str, Any] = {}
        for manager_input, suffix in fields.items():
            signal_type = api["OptionalType"](api["bool_signal"](manager_input))
            leaves[manager_input] = api["ValueInput"](f"{prefix}_{suffix}", signal_type)
        manager = manager_type(f"{prefix}_state_manager")
        pipeline = manager.connect(
            {name: leaf.output(api["ValueInput"].VALUE) for name, leaf in leaves.items()}
        )
        self._control = DefaultControlPipeline(pipeline, leaves)
        return self._control

    def source_outputs(self) -> dict[Kind, Any]:
        """Selectors used to replace ControllersSource/HandsSource in a graph."""

        api = self._load_api()
        return {
            kind: leaf.output(api["ValueInput"].VALUE)
            for kind, leaf in self.create_value_inputs().items()
        }

    def __call__(self, bundle: ExternalInputBundle) -> dict[str, Any]:
        api = self._load_api()
        leaves = self.create_value_inputs()
        external: dict[str, Any] = {}
        for kind, leaf in leaves.items():
            sample = bundle.get(kind)
            group = self._group_for(kind, sample.value if sample is not None else None)
            external[leaf.name] = {api["ValueInput"].VALUE: group}
        if self._control is not None:
            sample = bundle.get(Kind.CONTROL)
            control = sample.value if sample is not None else None
            if control is not None and not isinstance(control, ControlSample):
                raise TypeError("CTRL channel did not contain ControlSample")
            external.update(self._control_inputs(control))
        return external

    def _optional_group(self, kind: Kind, value: Any | None) -> Any:
        api = self._load_api()
        group = api["OptionalTensorGroup"](self._type_for(kind))
        if value is not None:
            self._populate_group(kind, group, value)
        else:
            group.set_none()
        return group

    def _group_for(self, kind: Kind, value: Any | None) -> Any:
        api = self._load_api()
        if kind is Kind.ANCHOR:
            group = api["TensorGroup"](self._type_for(kind))
            matrix = (
                self._pose_matrix(value)
                if isinstance(value, Pose) and value.valid
                else api["np"].eye(4, dtype=api["np"].float32)
            )
            # TransformMatrix currently has one field and no public index enum.
            group[0] = matrix
            return group
        return self._optional_group(kind, value)

    def _populate_group(self, kind: Kind, group: Any, value: Any) -> None:
        api = self._load_api()
        np = api["np"]
        if kind is Kind.HEAD:
            if not isinstance(value, Pose):
                raise TypeError("HEAD requires Pose")
            index = api["HeadPoseIndex"]
            group[index.POSITION] = np.asarray(value.position, dtype=np.float32)
            group[index.ORIENTATION] = np.asarray(value.orientation_xyzw, dtype=np.float32)
            group[index.IS_VALID] = bool(value.valid)
            return
        if kind in (Kind.LEFT_CONTROLLER, Kind.RIGHT_CONTROLLER):
            if not isinstance(value, ControllerSample):
                raise TypeError(f"{kind.name} requires ControllerSample")
            index = api["ControllerInputIndex"]
            group[index.GRIP_POSITION] = np.asarray(value.grip.position, dtype=np.float32)
            group[index.GRIP_ORIENTATION] = np.asarray(
                value.grip.orientation_xyzw, dtype=np.float32
            )
            group[index.GRIP_IS_VALID] = bool(value.grip.valid)
            group[index.AIM_POSITION] = np.asarray(value.aim.position, dtype=np.float32)
            group[index.AIM_ORIENTATION] = np.asarray(value.aim.orientation_xyzw, dtype=np.float32)
            group[index.AIM_IS_VALID] = bool(value.aim.valid)
            group[index.PRIMARY_CLICK] = float(value.primary)
            group[index.SECONDARY_CLICK] = float(value.secondary)
            group[index.THUMBSTICK_X] = float(value.thumb_x)
            group[index.THUMBSTICK_Y] = float(value.thumb_y)
            group[index.THUMBSTICK_CLICK] = float(value.thumb_click)
            group[index.MENU_CLICK] = float(value.menu)
            group[index.SQUEEZE_VALUE] = float(value.squeeze)
            group[index.TRIGGER_VALUE] = float(value.trigger)
            return
        if kind in (Kind.LEFT_HAND, Kind.RIGHT_HAND):
            if not isinstance(value, JointSetSample) or len(value.joints) != 26:
                raise TypeError(f"{kind.name} requires a 26-joint JointSetSample")
            index = api["HandInputIndex"]
            group[index.JOINT_POSITIONS] = np.asarray(
                [joint.pose.position for joint in value.joints], dtype=np.float32
            )
            group[index.JOINT_ORIENTATIONS] = np.asarray(
                [joint.pose.orientation_xyzw for joint in value.joints], dtype=np.float32
            )
            group[index.JOINT_RADII] = np.asarray(
                [joint.radius for joint in value.joints], dtype=np.float32
            )
            group[index.JOINT_VALID] = np.asarray(
                [int(joint.pose.valid) for joint in value.joints], dtype=np.uint8
            )
            return
        if kind is Kind.BODY:
            if not isinstance(value, JointSetSample) or len(value.joints) != 24:
                raise TypeError("BODY requires a 24-joint JointSetSample")
            index = api["FullBodyInputIndex"]
            group[index.JOINT_POSITIONS] = np.asarray(
                [joint.pose.position for joint in value.joints], dtype=np.float32
            )
            group[index.JOINT_ORIENTATIONS] = np.asarray(
                [joint.pose.orientation_xyzw for joint in value.joints], dtype=np.float32
            )
            group[index.JOINT_VALID] = np.asarray(
                [int(joint.pose.valid) for joint in value.joints], dtype=np.uint8
            )
            return
        raise TypeError(f"cannot populate standard group for {kind.name}")

    def _pose_matrix(self, value: Any) -> Any:
        if not isinstance(value, Pose):
            raise TypeError("ANCH requires Pose")
        api = self._load_api()
        x, y, z, w = value.orientation_xyzw
        xx, yy, zz = x * x, y * y, z * z
        xy, xz, yz = x * y, x * z, y * z
        wx, wy, wz = w * x, w * y, w * z
        px, py, pz = value.position
        return api["np"].asarray(
            [
                [1 - 2 * (yy + zz), 2 * (xy - wz), 2 * (xz + wy), px],
                [2 * (xy + wz), 1 - 2 * (xx + zz), 2 * (yz - wx), py],
                [2 * (xz - wy), 2 * (yz + wx), 1 - 2 * (xx + yy), pz],
                [0.0, 0.0, 0.0, 1.0],
            ],
            dtype=api["np"].float32,
        )

    def _control_inputs(self, control: ControlSample | None) -> dict[str, Any]:
        assert self._control is not None
        api = self._load_api()
        manager = api["DefaultTeleopStateManager"]
        values = (
            {
                manager.INPUT_KILL: bool(control.kill or not control.deadman),
                manager.INPUT_RUN_TOGGLE: bool(control.run_toggle),
                manager.INPUT_RESET: bool(control.reset),
            }
            if control is not None
            else {}
        )
        result: dict[str, Any] = {}
        for manager_input, leaf in self._control.value_inputs.items():
            signal_type = api["bool_signal"](manager_input)
            group = api["OptionalTensorGroup"](signal_type)
            if manager_input in values:
                group[0] = values[manager_input]
            else:
                group.set_none()
            result[leaf.name] = {api["ValueInput"].VALUE: group}
        return result


def create_default_control_pipeline(
    adapter: IsaacStandardInputAdapter, *, prefix: str = "operator_control"
) -> DefaultControlPipeline:
    """Convenience wrapper around the adapter-bound control builder."""

    return adapter.create_default_control_pipeline(prefix=prefix)
