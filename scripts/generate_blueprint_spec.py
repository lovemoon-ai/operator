#!/usr/bin/env python3
"""Generate language bindings from the canonical Blueprint primitive spec."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path
import pprint
import re
import sys


ROOT = Path(__file__).resolve().parents[1]
SPEC_PATH = ROOT / "specs/blueprint/v1.json"
FIELD_TYPES = {
    "boolean",
    "string",
    "integer",
    "number",
    "color",
    "color_map",
    "number_array",
    "integer_array",
}
HOST_TYPES = {"node3d", "external_view"}
TRACKING_TYPES = {"origin", "head", "controller", "hand"}
TOP_LEVEL_KEYS = {
    "schema",
    "version",
    "wire",
    "limits",
    "value_type_conformance",
    "wire_integer_conformance",
    "anchors",
    "transform",
    "common_properties",
    "common_bindings",
    "primitives",
}
WIRE_KEYS = {
    "capability",
    "spec_hash_capability",
    "blueprint_schema",
    "state_schema",
    "event_schema",
    "commands",
}
COMMAND_KEYS = {"blueprint", "state", "event"}
LIMIT_KEYS = {"components", "state_values", "wire_integer_max"}
CONFORMANCE_KEYS = {"valid", "invalid"}
ANCHOR_KEYS = {"tracking"}
TRANSFORM_FIELD_KEYS = {"type", "default"}
FIELD_SPEC_KEYS = {
    "type",
    "required",
    "default",
    "minimum",
    "maximum",
    "length",
    "semantics",
}
BINDING_SEMANTICS = {"refresh_token"}
PRIMITIVE_KEYS = {
    "host",
    "implementation",
    "singleton",
    "default_anchor",
    "anchors",
    "user_visibility_override",
    "properties",
    "bindings",
    "binding_groups",
    "constraints",
    "events",
}
CONSTRAINT_KEYS = {"at_least_one_complete_binding_group"}
EVENT_KEYS = {"action_property", "value_type"}
TARGETS = {
    "python": ROOT / "python/pyoperator/_blueprint_spec.py",
    "rust": ROOT / "robot/crates/teleop-protocol/src/blueprint_spec.rs",
    "godot": ROOT / "xr/scripts/contracts/blueprint/blueprint_spec.gd",
}


def _is_number(value: object) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def _is_color_string(value: object) -> bool:
    return isinstance(value, str) and re.fullmatch(
        r"#[0-9a-fA-F]{3}(?:[0-9a-fA-F]|[0-9a-fA-F]{3}|[0-9a-fA-F]{5})?",
        value,
    ) is not None


def _matches_type(value: object, value_type: str) -> bool:
    if value_type == "boolean":
        return isinstance(value, bool)
    if value_type == "string":
        return isinstance(value, str)
    if value_type == "integer":
        return _is_number(value) and math.isfinite(float(value)) and float(value).is_integer()
    if value_type == "number":
        return _is_number(value) and math.isfinite(float(value))
    if value_type == "color":
        return _is_color_string(value) or (
            isinstance(value, list)
            and len(value) in (3, 4)
            and all(_matches_type(channel, "number") for channel in value)
        )
    if value_type == "color_map":
        return isinstance(value, dict) and all(
            isinstance(key, str) and _matches_type(color, "color")
            for key, color in value.items()
        )
    if value_type in ("number_array", "integer_array"):
        item_type = "number" if value_type == "number_array" else "integer"
        return isinstance(value, list) and all(
            _matches_type(item, item_type) for item in value
        )
    return False


def _reject_unknown_keys(context: str, value: dict, allowed: set[str]) -> None:
    unknown = set(value) - allowed
    if unknown:
        raise ValueError(f"{context} has unsupported keys: {', '.join(sorted(unknown))}")


def _validate_field_spec(context: str, field_spec: object) -> None:
    if not isinstance(field_spec, dict) or field_spec.get("type") not in FIELD_TYPES:
        raise ValueError(f"{context} has an unsupported type")
    _reject_unknown_keys(context, field_spec, FIELD_SPEC_KEYS)
    value_type = str(field_spec["type"])
    if "required" in field_spec and not isinstance(field_spec["required"], bool):
        raise ValueError(f"{context} required must be boolean")
    if field_spec.get("required") and "default" in field_spec:
        raise ValueError(f"{context} cannot be both required and defaulted")
    minimum = field_spec.get("minimum")
    maximum = field_spec.get("maximum")
    if minimum is not None or maximum is not None:
        if value_type not in ("integer", "number"):
            raise ValueError(f"{context} numeric range requires a numeric type")
        if minimum is not None and not _matches_type(minimum, value_type):
            raise ValueError(f"{context} minimum has an invalid type")
        if maximum is not None and not _matches_type(maximum, value_type):
            raise ValueError(f"{context} maximum has an invalid type")
        if minimum is not None and maximum is not None and minimum > maximum:
            raise ValueError(f"{context} minimum exceeds maximum")
    length = field_spec.get("length")
    if length is not None:
        if value_type not in ("number_array", "integer_array"):
            raise ValueError(f"{context} length requires an array type")
        if not isinstance(length, int) or isinstance(length, bool) or length < 0:
            raise ValueError(f"{context} length must be a non-negative integer")
    if "default" in field_spec:
        default = field_spec["default"]
        if not _matches_type(default, value_type):
            raise ValueError(f"{context} default has an invalid type")
        if minimum is not None and default < minimum:
            raise ValueError(f"{context} default is below minimum")
        if maximum is not None and default > maximum:
            raise ValueError(f"{context} default is above maximum")
        if length is not None and len(default) != length:
            raise ValueError(f"{context} default has an invalid length")


def load_spec() -> dict:
    spec = json.loads(SPEC_PATH.read_text(encoding="utf-8"))
    _reject_unknown_keys("Blueprint primitive spec", spec, TOP_LEVEL_KEYS)
    if spec.get("schema") != "operator.blueprint_primitive_spec.v1":
        raise ValueError("unexpected Blueprint primitive spec schema")
    if not isinstance(spec.get("version"), int) or isinstance(spec["version"], bool):
        raise ValueError("Blueprint primitive spec version must be an integer")
    wire = spec.get("wire")
    if not isinstance(wire, dict):
        raise ValueError("Blueprint primitive spec must define wire metadata")
    _reject_unknown_keys("Blueprint wire metadata", wire, WIRE_KEYS)
    for key in (
        "capability",
        "spec_hash_capability",
        "blueprint_schema",
        "state_schema",
        "event_schema",
    ):
        if not isinstance(wire.get(key), str) or not wire[key].strip():
            raise ValueError(f"Blueprint wire field {key!r} must be a non-empty string")
    commands = wire.get("commands")
    if not isinstance(commands, dict):
        raise ValueError("Blueprint wire commands must be an object")
    _reject_unknown_keys("Blueprint wire commands", commands, COMMAND_KEYS)
    for key in ("blueprint", "state", "event"):
        if not isinstance(commands.get(key), str) or not commands[key].strip():
            raise ValueError(f"Blueprint command {key!r} must be a non-empty string")
    limits = spec.get("limits")
    if not isinstance(limits, dict):
        raise ValueError("Blueprint primitive spec must define limits")
    _reject_unknown_keys("Blueprint limits", limits, LIMIT_KEYS)
    for key in ("components", "state_values", "wire_integer_max"):
        value = limits.get(key)
        if not isinstance(value, int) or isinstance(value, bool) or value <= 0:
            raise ValueError(f"Blueprint limit {key!r} must be a positive integer")
    conformance = spec.get("value_type_conformance")
    if not isinstance(conformance, dict) or set(conformance) != FIELD_TYPES:
        raise ValueError("Blueprint value type conformance cases must cover every field type")
    for value_type, cases in conformance.items():
        if not isinstance(cases, dict):
            raise ValueError(f"Blueprint conformance cases for {value_type!r} must be an object")
        _reject_unknown_keys(
            f"Blueprint conformance cases for {value_type!r}",
            cases,
            CONFORMANCE_KEYS,
        )
        if not cases.get("valid") or not cases.get("invalid"):
            raise ValueError(
                f"Blueprint conformance cases for {value_type!r} must include valid and invalid values"
            )
        for value in cases.get("valid", []):
            if not _matches_type(value, value_type):
                raise ValueError(f"Blueprint valid {value_type!r} case is invalid: {value!r}")
        for value in cases.get("invalid", []):
            if _matches_type(value, value_type):
                raise ValueError(f"Blueprint invalid {value_type!r} case is valid: {value!r}")
    wire_integer_conformance = spec.get("wire_integer_conformance")
    if not isinstance(wire_integer_conformance, dict):
        raise ValueError("Blueprint wire integer conformance cases must be an object")
    _reject_unknown_keys(
        "Blueprint wire integer conformance cases",
        wire_integer_conformance,
        CONFORMANCE_KEYS,
    )
    if not wire_integer_conformance.get("valid") or not wire_integer_conformance.get("invalid"):
        raise ValueError(
            "Blueprint wire integer conformance cases must include valid and invalid values"
        )
    for value in wire_integer_conformance.get("valid", []):
        if (
            not isinstance(value, int)
            or isinstance(value, bool)
            or value < 0
            or value > limits["wire_integer_max"]
        ):
            raise ValueError(f"Blueprint valid wire integer case is invalid: {value!r}")
    for value in wire_integer_conformance.get("invalid", []):
        if (
            isinstance(value, int)
            and not isinstance(value, bool)
            and 0 <= value <= limits["wire_integer_max"]
        ):
            raise ValueError(f"Blueprint invalid wire integer case is valid: {value!r}")
    transform = spec.get("transform")
    if not isinstance(transform, dict):
        raise ValueError("Blueprint primitive spec must define transform fields")
    _reject_unknown_keys("Blueprint transform", transform, {"position", "rotation", "scale"})
    for field_name, field_type, size in (
        ("position", "vector3", 3),
        ("rotation", "quaternion", 4),
        ("scale", "positive_vector3", 3),
    ):
        field_spec = transform.get(field_name)
        if not isinstance(field_spec, dict) or field_spec.get("type") != field_type:
            raise ValueError(f"transform field {field_name!r} has an invalid type")
        _reject_unknown_keys(
            f"transform field {field_name!r}", field_spec, TRANSFORM_FIELD_KEYS
        )
        default = field_spec.get("default")
        if (
            not isinstance(default, list)
            or len(default) != size
            or any(
                not isinstance(value, (int, float)) or isinstance(value, bool)
                or not math.isfinite(float(value))
                for value in default
            )
        ):
            raise ValueError(f"transform field {field_name!r} has an invalid default")
        if field_type == "positive_vector3" and any(value <= 0 for value in default):
            raise ValueError(f"transform field {field_name!r} must default positive")
    primitives = spec.get("primitives")
    if not isinstance(primitives, dict) or not primitives:
        raise ValueError("Blueprint primitive spec must define primitives")
    anchors_value = spec.get("anchors")
    if not isinstance(anchors_value, dict) or not anchors_value:
        raise ValueError("Blueprint primitive spec must define anchors")
    anchors = set(anchors_value)
    for name, anchor in anchors_value.items():
        if not isinstance(name, str) or not name.strip():
            raise ValueError("Blueprint anchor names must be non-empty strings")
        if not isinstance(anchor, dict) or anchor.get("tracking") not in TRACKING_TYPES:
            raise ValueError(f"Blueprint anchor {name!r} has unsupported tracking metadata")
        _reject_unknown_keys(f"Blueprint anchor {name!r}", anchor, ANCHOR_KEYS)
    common_properties = spec.get("common_properties", {})
    common_bindings = spec.get("common_bindings", {})
    if not isinstance(common_properties, dict) or not isinstance(common_bindings, dict):
        raise ValueError("Blueprint common properties and bindings must be objects")
    normalized = dict(spec)
    normalized_primitives: dict[str, dict] = {}
    for name, primitive in primitives.items():
        if not isinstance(name, str) or not name.strip() or not isinstance(primitive, dict):
            raise ValueError("Blueprint primitives must use non-empty string names and objects")
        _reject_unknown_keys(f"primitive {name!r}", primitive, PRIMITIVE_KEYS)
        primitive_anchors = primitive.get("anchors", ())
        if not isinstance(primitive_anchors, list) or not primitive_anchors:
            raise ValueError(f"primitive {name!r} must declare at least one anchor")
        if not set(primitive_anchors).issubset(anchors):
            raise ValueError(f"primitive {name!r} uses an unknown anchor")
        default_anchor = primitive.get("default_anchor")
        if default_anchor not in primitive_anchors:
            raise ValueError(f"primitive {name!r} has an invalid default anchor")
        if primitive.get("host") not in HOST_TYPES:
            raise ValueError(f"primitive {name!r} has an unsupported host")
        if (
            not isinstance(primitive.get("implementation"), str)
            or not primitive["implementation"].strip()
        ):
            raise ValueError(f"primitive {name!r} must declare an implementation")
        if not isinstance(primitive.get("singleton"), bool):
            raise ValueError(f"primitive {name!r} must declare singleton as boolean")
        if not isinstance(primitive.get("user_visibility_override"), bool):
            raise ValueError(
                f"primitive {name!r} must declare user_visibility_override as boolean"
            )
        value = dict(primitive)
        value["properties"] = {**common_properties, **primitive.get("properties", {})}
        value["bindings"] = {**common_bindings, **primitive.get("bindings", {})}
        binding_semantics: set[str] = set()
        for field_group in ("properties", "bindings"):
            for field_name, field_spec in value[field_group].items():
                if not isinstance(field_name, str) or not field_name.strip():
                    raise ValueError(f"primitive {name!r} has an invalid {field_group} name")
                _validate_field_spec(
                    f"primitive {name!r} {field_group} field {field_name!r}",
                    field_spec,
                )
                if field_group == "properties" and not (
                    field_spec.get("required") or "default" in field_spec
                ):
                    raise ValueError(
                        f"primitive {name!r} property {field_name!r} must be required or defaulted"
                    )
                if field_group == "bindings" and "default" in field_spec:
                    raise ValueError(
                        f"primitive {name!r} binding {field_name!r} cannot declare a default"
                    )
                semantics = field_spec.get("semantics")
                if field_group == "properties" and semantics is not None:
                    raise ValueError(
                        f"primitive {name!r} property {field_name!r} cannot declare semantics"
                    )
                if field_group == "bindings" and semantics is not None:
                    if semantics not in BINDING_SEMANTICS:
                        raise ValueError(
                            f"primitive {name!r} binding {field_name!r} has unsupported semantics"
                        )
                    if semantics in binding_semantics:
                        raise ValueError(
                            f"primitive {name!r} declares duplicate binding semantics {semantics!r}"
                        )
                    binding_semantics.add(semantics)
        binding_groups = value.get("binding_groups", {})
        if not isinstance(binding_groups, dict):
            raise ValueError(f"primitive {name!r} binding_groups must be an object")
        for group_name, members in binding_groups.items():
            if (
                not isinstance(group_name, str)
                or not group_name.strip()
                or not isinstance(members, list)
                or not members
                or any(not isinstance(member, str) or not member.strip() for member in members)
                or not set(members).issubset(value["bindings"])
            ):
                raise ValueError(
                    f"primitive {name!r} binding group {group_name!r} is invalid"
                )
        constraints = value.get("constraints", {})
        if not isinstance(constraints, dict):
            raise ValueError(f"primitive {name!r} constraints must be an object")
        _reject_unknown_keys(f"primitive {name!r} constraints", constraints, CONSTRAINT_KEYS)
        for constraint_name, enabled in constraints.items():
            if not isinstance(enabled, bool):
                raise ValueError(
                    f"primitive {name!r} constraint {constraint_name!r} must be boolean"
                )
        events = value.get("events", {})
        if not isinstance(events, dict):
            raise ValueError(f"primitive {name!r} events must be an object")
        for event_name, event in events.items():
            if not isinstance(event_name, str) or not event_name.strip():
                raise ValueError(f"primitive {name!r} has an invalid event name")
            if not isinstance(event, dict) or event.get("value_type") not in FIELD_TYPES:
                raise ValueError(f"primitive {name!r} event {event_name!r} is invalid")
            _reject_unknown_keys(
                f"primitive {name!r} event {event_name!r}", event, EVENT_KEYS
            )
            action_property = event.get("action_property")
            if action_property not in value["properties"]:
                raise ValueError(
                    f"primitive {name!r} event {event_name!r} references an unknown property"
                )
            action_spec = value["properties"][action_property]
            if action_spec.get("type") != "string":
                raise ValueError(
                    f"primitive {name!r} event {event_name!r} action property must be string"
                )
            if not action_spec.get("required") and "default" not in action_spec:
                raise ValueError(
                    f"primitive {name!r} event {event_name!r} action property must be required or defaulted"
                )
        normalized_primitives[name] = value
    normalized["primitives"] = normalized_primitives
    normalized.pop("common_properties", None)
    normalized.pop("common_bindings", None)
    return normalized


def python_source(spec: dict, digest: str) -> str:
    rendered = pprint.pformat(spec, width=100, sort_dicts=False)
    return (
        '"""Generated from specs/blueprint/v1.json. Do not edit."""\n\n'
        f'SPEC_SHA256 = "{digest}"\n'
        f"SPEC = {rendered}\n"
        'WIRE = SPEC["wire"]\n'
        f'SPEC_CAPABILITY = WIRE["capability"] + "@sha256:{digest}"\n'
        'LIMITS = SPEC["limits"]\n'
        'WIRE_INTEGER_CONFORMANCE = SPEC["wire_integer_conformance"]\n'
        'ANCHOR_SPECS = SPEC["anchors"]\n'
        'ANCHORS = frozenset(SPEC["anchors"])\n'
        'PRIMITIVES = SPEC["primitives"]\n'
        'EXTERNAL_VIEW_TYPES = frozenset(\n'
        '    name for name, primitive in PRIMITIVES.items()\n'
        '    if primitive["host"] == "external_view"\n'
        ')\n'
    )


def rust_source(spec: dict, digest: str) -> str:
    wire = spec["wire"]
    limits = spec["limits"]
    transform = spec["transform"]
    def string_slice(values: list[str]) -> str:
        items = "".join(f"    {json.dumps(value)},\n" for value in values)
        return f"&[\n{items}]"

    anchors = string_slice(list(spec["anchors"]))
    primitives = string_slice(list(spec["primitives"]))
    external = string_slice(
        [
            name
            for name, primitive in spec["primitives"].items()
            if primitive["host"] == "external_view"
        ]
    )
    spec_json = json.dumps(spec, separators=(",", ":"), ensure_ascii=True)
    return f'''//! Generated from specs/blueprint/v1.json. Do not edit.\n\n\
pub const SPEC_SHA256: &str = "{digest}";\n\
pub const BLUEPRINT_SCHEMA: &str = {json.dumps(wire["blueprint_schema"])};\n\
pub const BLUEPRINT_STATE_SCHEMA: &str = {json.dumps(wire["state_schema"])};\n\
pub const BLUEPRINT_EVENT_SCHEMA: &str = {json.dumps(wire["event_schema"])};\n\
pub const BLUEPRINT_CAPABILITY: &str = {json.dumps(wire["capability"])};\n\
pub const BLUEPRINT_SPEC_CAPABILITY: &str =\n\
    {json.dumps(f'{wire["capability"]}@sha256:{digest}')};\n\
pub const BLUEPRINT_SPEC_HASH_CAPABILITY: &str = {json.dumps(wire["spec_hash_capability"])};\n\
pub const BLUEPRINT_COMMAND: &str = {json.dumps(wire["commands"]["blueprint"])};\n\
pub const BLUEPRINT_STATE_COMMAND: &str = {json.dumps(wire["commands"]["state"])};\n\
pub const BLUEPRINT_EVENT_COMMAND: &str = {json.dumps(wire["commands"]["event"])};\n\
pub const MAX_BLUEPRINT_COMPONENTS: usize = {limits["components"]};\n\
pub const MAX_BLUEPRINT_STATE_VALUES: usize = {limits["state_values"]};\n\
pub const MAX_BLUEPRINT_WIRE_INTEGER: u64 = {limits["wire_integer_max"]};\n\
pub const DEFAULT_BLUEPRINT_POSITION: [f64; 3] = {json.dumps(transform["position"]["default"])};\n\
pub const DEFAULT_BLUEPRINT_ROTATION: [f64; 4] = {json.dumps(transform["rotation"]["default"])};\n\
pub const DEFAULT_BLUEPRINT_SCALE: [f64; 3] = {json.dumps(transform["scale"]["default"])};\n\
pub const SUPPORTED_ANCHORS: &[&str] = {anchors};\n\
pub const SUPPORTED_PRIMITIVES: &[&str] = {primitives};\n\
pub const EXTERNAL_VIEW_PRIMITIVES: &[&str] = {external};\n\
pub const BLUEPRINT_SPEC_JSON: &str = r###"{spec_json}"###;\n'''


def gd_literal(value: object, indent: int = 0) -> str:
    if value is None:
        return "null"
    if value is True:
        return "true"
    if value is False:
        return "false"
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    if isinstance(value, (int, float)):
        return repr(value)
    if isinstance(value, list):
        if not value:
            return "[]"
        inner = ",\n".join(
            "\t" * (indent + 1) + gd_literal(item, indent + 1) for item in value
        )
        return "[\n" + inner + ",\n" + "\t" * indent + "]"
    if isinstance(value, dict):
        if not value:
            return "{}"
        inner = ",\n".join(
            "\t" * (indent + 1)
            + json.dumps(str(key), ensure_ascii=False)
            + ": "
            + gd_literal(item, indent + 1)
            for key, item in value.items()
        )
        return "{\n" + inner + ",\n" + "\t" * indent + "}"
    raise TypeError(f"unsupported value: {value!r}")


def godot_source(spec: dict, digest: str) -> str:
    wire = spec["wire"]
    limits = spec["limits"]
    return f'''class_name BlueprintPrimitiveSpec\n\
extends RefCounted\n\n\
## Generated from specs/blueprint/v1.json. Do not edit.\n\
const SPEC_SHA256 := "{digest}"\n\
const BLUEPRINT_SCHEMA := {json.dumps(wire["blueprint_schema"])}\n\
const STATE_SCHEMA := {json.dumps(wire["state_schema"])}\n\
const EVENT_SCHEMA := {json.dumps(wire["event_schema"])}\n\
const CAPABILITY := {json.dumps(wire["capability"])}\n\
const SPEC_CAPABILITY := {json.dumps(f'{wire["capability"]}@sha256:{digest}')}\n\
const SPEC_HASH_CAPABILITY := {json.dumps(wire["spec_hash_capability"])}\n\
const BLUEPRINT_COMMAND := {json.dumps(wire["commands"]["blueprint"])}\n\
const STATE_COMMAND := {json.dumps(wire["commands"]["state"])}\n\
const EVENT_COMMAND := {json.dumps(wire["commands"]["event"])}\n\
const MAX_COMPONENTS := {limits["components"]}\n\
const MAX_STATE_VALUES := {limits["state_values"]}\n\
const MAX_WIRE_INTEGER := {limits["wire_integer_max"]}\n\
const ANCHORS := {gd_literal(list(spec["anchors"]))}\n\
const ANCHOR_SPECS := {gd_literal(spec["anchors"])}\n\
const TRANSFORM := {gd_literal(spec["transform"])}\n\
const VALUE_TYPE_CONFORMANCE := {gd_literal(spec["value_type_conformance"])}\n\
const WIRE_INTEGER_CONFORMANCE := {gd_literal(spec["wire_integer_conformance"])}\n\
const PRIMITIVES := {gd_literal(spec["primitives"])}\n'''


def rendered_targets(spec: dict) -> dict[str, str]:
    canonical = json.dumps(spec, separators=(",", ":"), sort_keys=True).encode()
    digest = hashlib.sha256(canonical).hexdigest()
    return {
        "python": python_source(spec, digest),
        "rust": rust_source(spec, digest),
        "godot": godot_source(spec, digest),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    rendered = rendered_targets(load_spec())
    stale: list[Path] = []
    for name, path in TARGETS.items():
        content = rendered[name]
        if args.check:
            if not path.exists() or path.read_text(encoding="utf-8") != content:
                stale.append(path)
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding="utf-8")
    if stale:
        for path in stale:
            print(f"stale generated Blueprint binding: {path.relative_to(ROOT)}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
