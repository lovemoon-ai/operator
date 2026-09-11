"""Declarative Blueprint API shared by every Operator XR mode."""

from __future__ import annotations

from dataclasses import dataclass, field
import json
import math
import re
import threading
import time
from types import MappingProxyType
from typing import Any, Callable, Iterator, Mapping

from ._blueprint_spec import (
    ANCHORS as SUPPORTED_ANCHORS,
    LIMITS,
    PRIMITIVES,
    SPEC,
    SPEC_SHA256,
    WIRE,
)

BLUEPRINT_SCHEMA = WIRE["blueprint_schema"]
BLUEPRINT_STATE_SCHEMA = WIRE["state_schema"]
BLUEPRINT_EVENT_SCHEMA = WIRE["event_schema"]
SUPPORTED_PRIMITIVES = frozenset(PRIMITIVES)
_TRANSFORM_SPEC = SPEC["transform"]


def _primitive_default_anchor(component_type: str) -> str:
    return str(PRIMITIVES[component_type]["default_anchor"])


def _primitive_property_default(component_type: str, property_name: str) -> Any:
    return PRIMITIVES[component_type]["properties"][property_name]["default"]


_LABEL_DEFAULT_ANCHOR = _primitive_default_anchor("label")
_LABEL_DEFAULT_TEXT = str(_primitive_property_default("label", "text"))
_STATUS_LAMP_DEFAULT_ANCHOR = _primitive_default_anchor("status_lamp")
_STATUS_LAMP_DEFAULT_TEXT = str(_primitive_property_default("status_lamp", "text"))
_PALM_MENU_DEFAULT_ANCHOR = _primitive_default_anchor("palm_menu")
_PALM_MENU_LOCKED_TEXT = str(_primitive_property_default("palm_menu", "locked_text"))
_PALM_MENU_UNLOCKED_TEXT = str(_primitive_property_default("palm_menu", "unlocked_text"))
_PALM_MENU_UNAVAILABLE_TEXT = str(
    _primitive_property_default("palm_menu", "unavailable_text")
)
_FINGERTIP_TACTILE_DEFAULT_ANCHOR = _primitive_default_anchor("fingertip_tactile")
_FINGERTIP_TACTILE_REFRESH_BINDING = next(
    name
    for name, field_spec in PRIMITIVES["fingertip_tactile"]["bindings"].items()
    if field_spec.get("semantics") == "refresh_token"
)
_VIDEO_PANEL_FOLLOW_CAMERA = bool(
    _primitive_property_default("video_panel", "follow_camera")
)


def _default_position() -> tuple[float, float, float]:
    values = _TRANSFORM_SPEC["position"]["default"]
    return (float(values[0]), float(values[1]), float(values[2]))


def _default_rotation() -> tuple[float, float, float, float]:
    values = _TRANSFORM_SPEC["rotation"]["default"]
    return (
        float(values[0]),
        float(values[1]),
        float(values[2]),
        float(values[3]),
    )


def _default_scale() -> tuple[float, float, float]:
    values = _TRANSFORM_SPEC["scale"]["default"]
    return (float(values[0]), float(values[1]), float(values[2]))


def _mapping(value: Mapping[str, Any] | None) -> Mapping[str, Any]:
    return MappingProxyType(dict(value or {}))


def _is_number(value: Any) -> bool:
    return (
        isinstance(value, (int, float))
        and not isinstance(value, bool)
        and math.isfinite(float(value))
    )


def _is_color_string(value: Any) -> bool:
    return isinstance(value, str) and re.fullmatch(
        r"#[0-9a-fA-F]{3}(?:[0-9a-fA-F]|[0-9a-fA-F]{3}|[0-9a-fA-F]{5})?",
        value,
    ) is not None


def _is_integer_value(value: Any) -> bool:
    return _is_number(value) and float(value).is_integer()


def _is_wire_integer(value: Any) -> bool:
    return (
        isinstance(value, int)
        and not isinstance(value, bool)
        and 0 <= value <= int(LIMITS["wire_integer_max"])
    )


def _matches_type(value: Any, value_type: str) -> bool:
    if value_type == "boolean":
        return isinstance(value, bool)
    if value_type == "string":
        return isinstance(value, str)
    if value_type == "integer":
        return _is_integer_value(value)
    if value_type == "number":
        return _is_number(value)
    if value_type == "color":
        return _is_color_string(value) or (
            isinstance(value, (list, tuple))
            and len(value) in (3, 4)
            and all(_is_number(channel) for channel in value)
        )
    if value_type == "color_map":
        return isinstance(value, Mapping) and all(
            isinstance(key, str) and _matches_type(color, "color")
            for key, color in value.items()
        )
    if value_type in ("number_array", "integer_array"):
        item_type = "number" if value_type == "number_array" else "integer"
        return isinstance(value, (list, tuple)) and all(
            _matches_type(item, item_type) for item in value
        )
    return False


def _validate_value(name: str, value: Any, field_spec: Mapping[str, Any]) -> None:
    value_type = str(field_spec["type"])
    if not _matches_type(value, value_type):
        raise ValueError(f"Blueprint field {name!r} must be {value_type}")
    if _is_number(value):
        minimum = field_spec.get("minimum")
        maximum = field_spec.get("maximum")
        if minimum is not None and value < minimum:
            raise ValueError(f"Blueprint field {name!r} must be >= {minimum}")
        if maximum is not None and value > maximum:
            raise ValueError(f"Blueprint field {name!r} must be <= {maximum}")
    length = field_spec.get("length")
    if length is not None and len(value) != int(length):
        raise ValueError(f"Blueprint field {name!r} must contain {length} items")


def _binding_value_contract(field_spec: Mapping[str, Any]) -> dict[str, Any]:
    return {
        key: value
        for key, value in field_spec.items()
        if key not in ("required", "semantics")
    }


def _required_wire_integer(name: str, value: Any, *, positive: bool) -> int:
    if not isinstance(value, int) or isinstance(value, bool):
        raise ValueError(f"Blueprint {name} must be an integer")
    parsed = int(value)
    if parsed > int(LIMITS["wire_integer_max"]):
        raise ValueError(
            f"Blueprint {name} must be <= {LIMITS['wire_integer_max']}"
        )
    if parsed < (1 if positive else 0):
        qualifier = "greater than zero" if positive else "non-negative"
        raise ValueError(f"Blueprint {name} must be {qualifier}")
    return parsed


@dataclass(frozen=True)
class BlueprintTransform:
    position: tuple[float, float, float] = field(default_factory=_default_position)
    rotation: tuple[float, float, float, float] = field(default_factory=_default_rotation)
    scale: tuple[float, float, float] = field(default_factory=_default_scale)

    def __post_init__(self) -> None:
        if len(self.position) != 3 or len(self.rotation) != 4 or len(self.scale) != 3:
            raise ValueError("Blueprint transform has invalid dimensions")
        values = (*self.position, *self.rotation, *self.scale)
        if any(not _is_number(value) for value in values):
            raise ValueError("Blueprint transform must contain numbers")
        if any(not math.isfinite(float(value)) for value in values):
            raise ValueError("Blueprint transform must contain finite values")
        if any(float(value) <= 0.0 for value in self.scale):
            raise ValueError("Blueprint transform scale must be positive")
        if sum(float(value) ** 2 for value in self.rotation) <= 1e-12:
            raise ValueError("Blueprint transform rotation must be non-zero")

    def to_dict(self) -> dict[str, Any]:
        return {
            "position": list(self.position),
            "rotation": list(self.rotation),
            "scale": list(self.scale),
        }


@dataclass(frozen=True)
class BlueprintComponent:
    id: str
    type: str
    anchor: str | None = None
    transform: BlueprintTransform = field(default_factory=BlueprintTransform)
    properties: Mapping[str, Any] = field(default_factory=lambda: _mapping(None))
    bindings: Mapping[str, str] = field(default_factory=lambda: _mapping(None))
    user_overridable: bool | None = None

    def __post_init__(self) -> None:
        if not isinstance(self.id, str) or not self.id.strip():
            raise ValueError("Blueprint component id must not be empty")
        if not isinstance(self.type, str) or self.type not in SUPPORTED_PRIMITIVES:
            raise ValueError(f"unsupported Blueprint component type {self.type!r}")
        primitive = PRIMITIVES[self.type]
        anchor = self.anchor
        if anchor is None:
            anchor = str(primitive["default_anchor"])
            object.__setattr__(self, "anchor", anchor)
        if anchor not in primitive["anchors"]:
            raise ValueError(f"unsupported Blueprint anchor {anchor!r}")
        user_overridable = self.user_overridable
        if user_overridable is None:
            user_overridable = bool(primitive["user_visibility_override"])
            object.__setattr__(self, "user_overridable", user_overridable)
        if not isinstance(user_overridable, bool):
            raise ValueError("Blueprint user_overridable must be boolean")
        if user_overridable and not bool(primitive["user_visibility_override"]):
            raise ValueError(
                f"{self.type} does not support headset visibility overrides"
            )
        object.__setattr__(self, "properties", _mapping(self.properties))
        object.__setattr__(self, "bindings", _mapping(self.bindings))
        if any(not isinstance(key, str) or not key.strip() for key in self.properties):
            raise ValueError("Blueprint property names must be non-empty strings")
        if any(
            not isinstance(key, str)
            or not key.strip()
            or not isinstance(value, str)
            or not value.strip()
            for key, value in self.bindings.items()
        ):
            raise ValueError("Blueprint bindings must use non-empty property and state keys")
        property_specs = primitive["properties"]
        binding_specs = primitive["bindings"]
        unknown_properties = set(self.properties) - set(property_specs)
        unknown_bindings = set(self.bindings) - set(binding_specs)
        if unknown_properties:
            raise ValueError(
                f"unsupported {self.type} properties: {', '.join(sorted(unknown_properties))}"
            )
        if unknown_bindings:
            raise ValueError(
                f"unsupported {self.type} bindings: {', '.join(sorted(unknown_bindings))}"
            )
        for name, field_spec in property_specs.items():
            if field_spec.get("required") and name not in self.properties:
                raise ValueError(f"{self.type} property {name!r} is required")
        for name, value in self.properties.items():
            _validate_value(name, value, property_specs[name])
        for name, field_spec in binding_specs.items():
            if field_spec.get("required") and name not in self.bindings:
                raise ValueError(f"{self.type} binding {name!r} is required")
        groups = primitive.get("binding_groups", {})
        complete_groups = 0
        for group_name, members in groups.items():
            present = [member in self.bindings for member in members]
            if any(present) and not all(present):
                raise ValueError(f"{self.type} binding group {group_name!r} must be complete")
            complete_groups += int(all(present))
        if (
            primitive.get("constraints", {}).get("at_least_one_complete_binding_group")
            and complete_groups == 0
        ):
            raise ValueError(f"{self.type} requires at least one complete binding group")

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "type": self.type,
            "anchor": self.anchor,
            "transform": self.transform.to_dict(),
            "properties": dict(self.properties),
            "bindings": dict(self.bindings),
            "user_overridable": self.user_overridable,
        }

    @classmethod
    def label(
        cls,
        id: str,
        *,
        text: str = _LABEL_DEFAULT_TEXT,
        anchor: str = _LABEL_DEFAULT_ANCHOR,
        transform: BlueprintTransform | None = None,
        text_binding: str | None = None,
        visible_binding: str | None = None,
        properties: Mapping[str, Any] | None = None,
        user_overridable: bool | None = None,
    ) -> "BlueprintComponent":
        component_properties = dict(properties or {})
        component_properties.setdefault("text", text)
        bindings: dict[str, str] = {}
        if text_binding:
            bindings["text"] = text_binding
        if visible_binding:
            bindings["visible"] = visible_binding
        return cls(
            id=id,
            type="label",
            anchor=anchor,
            transform=transform or BlueprintTransform(),
            properties=component_properties,
            bindings=bindings,
            user_overridable=user_overridable,
        )

    @classmethod
    def status_lamp(
        cls,
        id: str,
        *,
        text: str = _STATUS_LAMP_DEFAULT_TEXT,
        anchor: str = _STATUS_LAMP_DEFAULT_ANCHOR,
        transform: BlueprintTransform | None = None,
        state_binding: str,
        text_binding: str | None = None,
        visible_binding: str | None = None,
        properties: Mapping[str, Any] | None = None,
        user_overridable: bool | None = None,
    ) -> "BlueprintComponent":
        component_properties = dict(properties or {})
        component_properties.setdefault("text", text)
        bindings = {"state": state_binding}
        if text_binding:
            bindings["text"] = text_binding
        if visible_binding:
            bindings["visible"] = visible_binding
        return cls(
            id=id,
            type="status_lamp",
            anchor=anchor,
            transform=transform or BlueprintTransform(),
            properties=component_properties,
            bindings=bindings,
            user_overridable=user_overridable,
        )

    @classmethod
    def palm_menu(
        cls,
        id: str,
        *,
        title: str,
        action: str,
        value_binding: str,
        anchor: str = _PALM_MENU_DEFAULT_ANCHOR,
        available_binding: str | None = None,
        visible_binding: str | None = None,
        locked_text: str = _PALM_MENU_LOCKED_TEXT,
        unlocked_text: str = _PALM_MENU_UNLOCKED_TEXT,
        unavailable_text: str = _PALM_MENU_UNAVAILABLE_TEXT,
        properties: Mapping[str, Any] | None = None,
        user_overridable: bool | None = None,
    ) -> "BlueprintComponent":
        component_properties = dict(properties or {})
        component_properties.setdefault("title", title)
        component_properties.setdefault("action", action)
        component_properties.setdefault("locked_text", locked_text)
        component_properties.setdefault("unlocked_text", unlocked_text)
        component_properties.setdefault("unavailable_text", unavailable_text)
        bindings = {"value": value_binding}
        if available_binding:
            bindings["available"] = available_binding
        if visible_binding:
            bindings["visible"] = visible_binding
        return cls(
            id=id,
            type="palm_menu",
            anchor=anchor,
            properties=component_properties,
            bindings=bindings,
            user_overridable=user_overridable,
        )

    @classmethod
    def fingertip_tactile(
        cls,
        id: str,
        *,
        left_bindings: Mapping[str, str] | None = None,
        right_bindings: Mapping[str, str] | None = None,
        sample_binding: str | None = None,
        visible_binding: str | None = None,
        properties: Mapping[str, Any] | None = None,
        user_overridable: bool | None = None,
    ) -> "BlueprintComponent":
        bindings: dict[str, str] = {}
        for side, side_bindings in (
            ("left", left_bindings),
            ("right", right_bindings),
        ):
            if side_bindings is None:
                continue
            prefix = f"{side}_"
            channels = tuple(
                binding.removeprefix(prefix)
                for binding in PRIMITIVES["fingertip_tactile"]["binding_groups"][
                    f"{side}_hand"
                ]
            )
            missing = [channel for channel in channels if not side_bindings.get(channel)]
            if missing:
                raise ValueError(
                    f"{side} fingertip tactile bindings missing: {', '.join(missing)}"
                )
            for channel in channels:
                bindings[f"{side}_{channel}"] = str(side_bindings[channel])
        if not left_bindings and not right_bindings:
            raise ValueError("fingertip tactile requires at least one hand")
        if sample_binding:
            bindings[_FINGERTIP_TACTILE_REFRESH_BINDING] = sample_binding
        if visible_binding:
            bindings["visible"] = visible_binding
        return cls(
            id=id,
            type="fingertip_tactile",
            anchor=_FINGERTIP_TACTILE_DEFAULT_ANCHOR,
            properties=dict(properties or {}),
            bindings=bindings,
            user_overridable=user_overridable,
        )

    @classmethod
    def video_panel(
        cls,
        id: str = "video_panel",
        *,
        follow_camera: bool = _VIDEO_PANEL_FOLLOW_CAMERA,
        visible_binding: str | None = None,
        follow_camera_binding: str | None = None,
        properties: Mapping[str, Any] | None = None,
        user_overridable: bool | None = None,
    ) -> "BlueprintComponent":
        component_properties = dict(properties or {})
        component_properties.setdefault("follow_camera", follow_camera)
        bindings: dict[str, str] = {}
        if visible_binding:
            bindings["visible"] = visible_binding
        if follow_camera_binding:
            bindings["follow_camera"] = follow_camera_binding
        return cls(
            id=id,
            type="video_panel",
            properties=component_properties,
            bindings=bindings,
            user_overridable=user_overridable,
        )

    @classmethod
    def controller_help(
        cls,
        id: str = "controller_help",
        *,
        visible_binding: str | None = None,
        properties: Mapping[str, Any] | None = None,
        user_overridable: bool | None = None,
    ) -> "BlueprintComponent":
        return cls._builtin_view(
            id,
            "controller_help",
            visible_binding=visible_binding,
            properties=properties,
            user_overridable=user_overridable,
        )

    @classmethod
    def control_frame(
        cls,
        id: str = "control_frame",
        *,
        visible_binding: str | None = None,
        properties: Mapping[str, Any] | None = None,
        user_overridable: bool | None = None,
    ) -> "BlueprintComponent":
        return cls._builtin_view(
            id,
            "control_frame",
            visible_binding=visible_binding,
            properties=properties,
            user_overridable=user_overridable,
        )

    @classmethod
    def operation_trajectory(
        cls,
        id: str = "operation_trajectory",
        *,
        visible_binding: str | None = None,
        properties: Mapping[str, Any] | None = None,
        user_overridable: bool | None = None,
    ) -> "BlueprintComponent":
        return cls._builtin_view(
            id,
            "operation_trajectory",
            visible_binding=visible_binding,
            properties=properties,
            user_overridable=user_overridable,
        )

    @classmethod
    def _builtin_view(
        cls,
        id: str,
        component_type: str,
        *,
        visible_binding: str | None,
        properties: Mapping[str, Any] | None,
        user_overridable: bool | None,
    ) -> "BlueprintComponent":
        bindings = {"visible": visible_binding} if visible_binding else {}
        return cls(
            id=id,
            type=component_type,
            properties=dict(properties or {}),
            bindings=bindings,
            user_overridable=user_overridable,
        )


@dataclass(frozen=True)
class Blueprint:
    blueprint_id: str
    components: tuple[BlueprintComponent, ...]
    revision: int = 1
    schema: str = BLUEPRINT_SCHEMA

    def __post_init__(self) -> None:
        if self.schema != BLUEPRINT_SCHEMA:
            raise ValueError(f"unsupported blueprint schema {self.schema!r}")
        if not isinstance(self.blueprint_id, str) or not self.blueprint_id.strip():
            raise ValueError("blueprint_id must not be empty")
        _required_wire_integer("revision", self.revision, positive=True)
        if len(self.components) > int(LIMITS["components"]):
            raise ValueError("Blueprint component limit exceeded")
        ids = [component.id for component in self.components]
        if len(ids) != len(set(ids)):
            raise ValueError("Blueprint component ids must be unique")
        singleton_types = [
            component.type
            for component in self.components
            if bool(PRIMITIVES[component.type]["singleton"])
        ]
        if len(singleton_types) != len(set(singleton_types)):
            raise ValueError("singleton Blueprint primitive types must be unique")
        self.binding_specs()

    def to_dict(self) -> dict[str, Any]:
        return {
            "schema": self.schema,
            "blueprint_id": self.blueprint_id,
            "revision": self.revision,
            "components": [component.to_dict() for component in self.components],
        }

    def binding_types(self) -> dict[str, str]:
        return {
            state_key: str(field_spec["type"])
            for state_key, field_spec in self.binding_specs().items()
        }

    def binding_specs(self) -> dict[str, Mapping[str, Any]]:
        result: dict[str, Mapping[str, Any]] = {}
        for component in self.components:
            binding_specs = PRIMITIVES[component.type]["bindings"]
            for property_name, state_key in component.bindings.items():
                field_spec = binding_specs[property_name]
                previous = result.get(state_key)
                value_contract = _binding_value_contract(field_spec)
                if previous is not None and dict(previous) != value_contract:
                    raise ValueError(
                        f"Blueprint state key {state_key!r} has conflicting contracts"
                    )
                result[state_key] = value_contract
        return result

    def validate_state_values(self, values: Mapping[str, Any]) -> None:
        binding_specs = self.binding_specs()
        unknown = set(values) - set(binding_specs)
        if unknown:
            raise ValueError(
                "Blueprint state contains unbound keys: "
                + ", ".join(sorted(unknown))
            )
        for state_key, value in values.items():
            _validate_value(state_key, value, binding_specs[state_key])

    def validate_event(self, event: "BlueprintEvent") -> None:
        if event.blueprint_id != self.blueprint_id or event.blueprint_revision != self.revision:
            raise ValueError("Blueprint event does not target the active Blueprint revision")
        component = next(
            (item for item in self.components if item.id == event.component_id),
            None,
        )
        if component is None:
            raise ValueError(f"Blueprint event references unknown component {event.component_id!r}")
        primitive = PRIMITIVES[component.type]
        resolved_properties = {
            name: field_spec["default"]
            for name, field_spec in primitive["properties"].items()
            if "default" in field_spec
        }
        resolved_properties.update(component.properties)
        for event_spec in primitive.get("events", {}).values():
            action_property = str(event_spec["action_property"])
            if resolved_properties.get(action_property) == event.action:
                _validate_value(
                    "event value",
                    event.value,
                    {"type": event_spec["value_type"]},
                )
                return
        raise ValueError(
            f"Blueprint component {event.component_id!r} does not declare action {event.action!r}"
        )


@dataclass(frozen=True)
class BlueprintState:
    blueprint_id: str
    blueprint_revision: int
    sequence: int
    timestamp_ns: int
    values: Mapping[str, Any]
    schema: str = BLUEPRINT_STATE_SCHEMA

    def __post_init__(self) -> None:
        if self.schema != BLUEPRINT_STATE_SCHEMA:
            raise ValueError(f"unsupported Blueprint state schema {self.schema!r}")
        if not isinstance(self.blueprint_id, str) or not self.blueprint_id.strip():
            raise ValueError("Blueprint state blueprint_id must not be empty")
        _required_wire_integer("state blueprint_revision", self.blueprint_revision, positive=True)
        _required_wire_integer("state sequence", self.sequence, positive=True)
        _required_wire_integer("state timestamp_ns", self.timestamp_ns, positive=False)
        if len(self.values) > int(LIMITS["state_values"]):
            raise ValueError("Blueprint state value limit exceeded")
        if any(not isinstance(key, str) or not key.strip() for key in self.values):
            raise ValueError("Blueprint state keys must not be empty")
        object.__setattr__(self, "values", _mapping(self.values))

    def to_dict(self) -> dict[str, Any]:
        return {
            "schema": self.schema,
            "blueprint_id": self.blueprint_id,
            "blueprint_revision": self.blueprint_revision,
            "sequence": self.sequence,
            "timestamp_ns": self.timestamp_ns,
            "values": dict(self.values),
        }


@dataclass(frozen=True)
class BlueprintEvent:
    blueprint_id: str
    blueprint_revision: int
    sequence: int
    timestamp_ns: int
    component_id: str
    action: str
    value: Any = None
    schema: str = BLUEPRINT_EVENT_SCHEMA

    def __post_init__(self) -> None:
        if self.schema != BLUEPRINT_EVENT_SCHEMA:
            raise ValueError(f"unsupported Blueprint event schema {self.schema!r}")
        if not isinstance(self.blueprint_id, str) or not self.blueprint_id.strip():
            raise ValueError("Blueprint event blueprint_id must not be empty")
        _required_wire_integer("event blueprint_revision", self.blueprint_revision, positive=True)
        _required_wire_integer("event sequence", self.sequence, positive=True)
        _required_wire_integer("event timestamp_ns", self.timestamp_ns, positive=False)
        if (
            not isinstance(self.component_id, str)
            or not self.component_id.strip()
            or not isinstance(self.action, str)
            or not self.action.strip()
        ):
            raise ValueError("Blueprint event component_id and action must not be empty")

    @classmethod
    def from_dict(cls, value: Mapping[str, Any]) -> "BlueprintEvent":
        schema = str(value.get("schema", ""))
        if schema != BLUEPRINT_EVENT_SCHEMA:
            raise ValueError(f"unsupported Blueprint event schema {schema!r}")
        blueprint_revision = _required_wire_integer(
            "event blueprint_revision", value.get("blueprint_revision"), positive=True
        )
        sequence = _required_wire_integer("event sequence", value.get("sequence"), positive=True)
        timestamp_ns = _required_wire_integer(
            "event timestamp_ns", value.get("timestamp_ns"), positive=False
        )
        return cls(
            schema=schema,
            blueprint_id=value.get("blueprint_id", ""),
            blueprint_revision=blueprint_revision,
            sequence=sequence,
            timestamp_ns=timestamp_ns,
            component_id=value.get("component_id", ""),
            action=value.get("action", ""),
            value=value.get("value"),
        )


class BlueprintClient:
    """Non-blocking Blueprint publisher attached to one ``XrSession``."""

    def __init__(self, native: Any, is_running: Callable[[], bool]) -> None:
        self._native = native
        self._is_running = is_running
        self._lock = threading.Lock()
        self._blueprint_id = ""
        self._blueprint_revision = 0
        self._sequence = 0
        self._values: dict[str, Any] = {}
        self._binding_specs: dict[str, Mapping[str, Any]] = {}
        self._blueprint: Blueprint | None = None

    def set_blueprint(self, blueprint: Blueprint) -> None:
        spec_hash_reader = getattr(self._native, "blueprint_spec_sha256", None)
        if not callable(spec_hash_reader):
            raise RuntimeError(
                "Blueprint backend does not expose its primitive spec hash; "
                "rebuild or redeploy pyoperator"
            )
        native_spec_hash = spec_hash_reader()
        if native_spec_hash != SPEC_SHA256:
            raise RuntimeError(
                "Blueprint primitive spec mismatch between Python and backend: "
                f"python={SPEC_SHA256} backend={native_spec_hash!r}; "
                "rebuild or redeploy pyoperator from one checkout"
            )
        payload = blueprint.to_dict()
        binding_specs = blueprint.binding_specs()
        serialized = json.dumps(payload, separators=(",", ":"), allow_nan=False)
        with self._lock:
            self._native.set_blueprint_json(serialized)
            self._blueprint_id = blueprint.blueprint_id
            self._blueprint_revision = blueprint.revision
            self._sequence = 0
            self._values.clear()
            self._binding_specs = binding_specs
            self._blueprint = blueprint

    def clear(self) -> None:
        with self._lock:
            self._native.clear_blueprint()
            self._blueprint_id = ""
            self._blueprint_revision = 0
            self._sequence = 0
            self._values.clear()
            self._binding_specs.clear()
            self._blueprint = None

    def update(self, values: Mapping[str, Any], *, timestamp_ns: int | None = None) -> int:
        with self._lock:
            if not self._blueprint_id:
                raise RuntimeError("set_blueprint() must be called before blueprint.update()")
            next_values = dict(self._values)
            next_values.update(values)
            for key, value in next_values.items():
                field_spec = self._binding_specs.get(key)
                if field_spec is None:
                    raise ValueError(f"Blueprint state key {key!r} is not bound")
                _validate_value(key, value, field_spec)
            sequence = self._sequence + 1
            state = BlueprintState(
                blueprint_id=self._blueprint_id,
                blueprint_revision=self._blueprint_revision,
                sequence=sequence,
                timestamp_ns=time.time_ns() if timestamp_ns is None else timestamp_ns,
                values=next_values,
            )
            serialized = json.dumps(
                state.to_dict(), separators=(",", ":"), allow_nan=False
            )
            self._native.publish_blueprint_state_json(serialized)
            self._values = next_values
            self._sequence = sequence
            return sequence

    def poll_event(self, timeout: float | None = None) -> BlueprintEvent | None:
        payload = self._native.poll_blueprint_event_json(timeout)
        if payload is None:
            return None
        value = json.loads(payload)
        if not isinstance(value, dict):
            raise ValueError("Blueprint event must be a JSON object")
        event = BlueprintEvent.from_dict(value)
        with self._lock:
            if self._blueprint is None:
                raise ValueError("received Blueprint event without an active Blueprint")
            self._blueprint.validate_event(event)
        return event

    def events(self, timeout: float | None = None) -> Iterator[BlueprintEvent]:
        while self._is_running():
            event = self.poll_event(timeout)
            if event is not None:
                yield event
