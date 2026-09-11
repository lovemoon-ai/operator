import json
import unittest

from pyoperator.blueprint import (
    Blueprint,
    BlueprintClient,
    BlueprintComponent,
    BlueprintEvent,
    BlueprintTransform,
    _matches_type,
    _is_wire_integer,
)
from pyoperator._blueprint_spec import SPEC, SPEC_SHA256


class FakeNative:
    def __init__(self) -> None:
        self.blueprints: list[dict] = []
        self.states: list[dict] = []
        self.events: list[str] = []
        self.clear_calls = 0

    def set_blueprint_json(self, payload: str) -> None:
        self.blueprints.append(json.loads(payload))

    def blueprint_spec_sha256(self) -> str:
        return SPEC_SHA256

    def clear_blueprint(self) -> None:
        self.clear_calls += 1

    def publish_blueprint_state_json(self, payload: str) -> None:
        self.states.append(json.loads(payload))

    def poll_blueprint_event_json(self, _timeout: float | None):
        return self.events.pop(0) if self.events else None


class BlueprintTests(unittest.TestCase):
    def test_generated_spec_matches_canonical_source(self) -> None:
        from pathlib import Path

        canonical = json.loads(
            (Path(__file__).resolve().parents[2] / "specs/blueprint/v1.json").read_text()
        )
        canonical["primitives"] = {
            name: {
                **primitive,
                "properties": {
                    **canonical["common_properties"],
                    **primitive.get("properties", {}),
                },
                "bindings": {
                    **canonical["common_bindings"],
                    **primitive.get("bindings", {}),
                },
            }
            for name, primitive in canonical["primitives"].items()
        }
        canonical.pop("common_properties")
        canonical.pop("common_bindings")
        self.assertEqual(SPEC, canonical)

    def test_component_defaults_come_from_the_generated_spec(self) -> None:
        transform = BlueprintTransform()
        self.assertEqual(list(transform.position), SPEC["transform"]["position"]["default"])
        self.assertEqual(list(transform.rotation), SPEC["transform"]["rotation"]["default"])
        self.assertEqual(list(transform.scale), SPEC["transform"]["scale"]["default"])

        menu = BlueprintComponent(
            id="menu",
            type="palm_menu",
            properties={"title": "Control", "action": "toggle"},
            bindings={"value": "control.enabled"},
        )
        self.assertEqual(
            menu.anchor,
            SPEC["primitives"]["palm_menu"]["default_anchor"],
        )
        self.assertEqual(
            menu.user_overridable,
            SPEC["primitives"]["palm_menu"]["user_visibility_override"],
        )

        helpers = (
            BlueprintComponent.label("label"),
            BlueprintComponent.status_lamp("status", state_binding="status"),
            BlueprintComponent.palm_menu(
                "menu_helper",
                title="Menu",
                action="toggle",
                value_binding="menu.enabled",
            ),
            BlueprintComponent.fingertip_tactile(
                "touch",
                left_bindings={
                    "normal": "touch.normal",
                    "tangential": "touch.tangential",
                    "direction": "touch.direction",
                    "proximity": "touch.proximity",
                    "status": "touch.status",
                },
            ),
            BlueprintComponent.video_panel(),
        )
        for component in helpers:
            with self.subTest(component=component.type):
                primitive = SPEC["primitives"][component.type]
                self.assertEqual(component.anchor, primitive["default_anchor"])
                for name, field_spec in primitive["properties"].items():
                    if "default" in field_spec and name in component.properties:
                        self.assertEqual(component.properties[name], field_spec["default"])

    def test_value_type_conformance_comes_from_the_generated_spec(self) -> None:
        for value_type, cases in SPEC["value_type_conformance"].items():
            for value in cases["valid"]:
                with self.subTest(value_type=value_type, value=value, valid=True):
                    self.assertTrue(_matches_type(value, value_type))
            for value in cases["invalid"]:
                with self.subTest(value_type=value_type, value=value, valid=False):
                    self.assertFalse(_matches_type(value, value_type))

        for value in SPEC["wire_integer_conformance"]["valid"]:
            with self.subTest(value=value, wire_integer=True):
                self.assertTrue(_is_wire_integer(value))
        for value in SPEC["wire_integer_conformance"]["invalid"]:
            with self.subTest(value=value, wire_integer=False):
                self.assertFalse(_is_wire_integer(value))

    def test_wire_envelope_requires_json_integers(self) -> None:
        with self.assertRaisesRegex(ValueError, "must be an integer"):
            Blueprint(blueprint_id="float-revision", revision=1.0, components=())
        with self.assertRaisesRegex(ValueError, "must be <="):
            Blueprint(
                blueprint_id="oversized-revision",
                revision=SPEC["limits"]["wire_integer_max"] + 1,
                components=(),
            )

    def test_blueprint_serializes_builtin_components(self) -> None:
        blueprint = Blueprint(
            blueprint_id="revo2.default",
            revision=2,
            components=(
                BlueprintComponent.label(
                    "status",
                    text="Waiting",
                    transform=BlueprintTransform(position=(0.0, 0.1, -0.5)),
                    text_binding="robot.status",
                ),
                BlueprintComponent.palm_menu(
                    "hand_control",
                    title="Hand control",
                    action="toggle_unlock",
                    value_binding="hand.unlocked",
                    anchor="right_palm",
                    available_binding="hand.available",
                    visible_binding="hand.menu_visible",
                    properties={"settings_label": "Hand control menu"},
                ),
                BlueprintComponent.fingertip_tactile(
                    "touch",
                    left_bindings={
                        "normal": "left.touch.normal",
                        "tangential": "left.touch.tangential",
                        "direction": "left.touch.direction",
                        "proximity": "left.touch.proximity",
                        "status": "left.touch.status",
                    },
                    sample_binding="touch.sample_ns",
                ),
                BlueprintComponent.video_panel(
                    follow_camera=False,
                    visible_binding="video.visible",
                    follow_camera_binding="video.follow_camera",
                    properties={"settings_label": "First-person video"},
                ),
                BlueprintComponent.controller_help(),
                BlueprintComponent.control_frame(),
                BlueprintComponent.operation_trajectory(),
            ),
        )

        value = blueprint.to_dict()
        self.assertEqual(value["schema"], "operator.blueprint.v1")
        self.assertEqual(value["components"][0]["type"], "label")
        self.assertEqual(value["components"][1]["anchor"], "right_palm")
        self.assertEqual(
            value["components"][1]["bindings"]["value"], "hand.unlocked"
        )
        self.assertEqual(
            value["components"][1]["properties"]["settings_label"],
            "Hand control menu",
        )
        self.assertEqual(value["components"][2]["type"], "fingertip_tactile")
        self.assertEqual(
            value["components"][2]["bindings"]["left_normal"],
            "left.touch.normal",
        )
        self.assertEqual(
            value["components"][2]["bindings"]["sample"], "touch.sample_ns"
        )
        self.assertEqual(value["components"][3]["type"], "video_panel")
        self.assertFalse(value["components"][3]["properties"]["follow_camera"])
        self.assertEqual(
            value["components"][3]["bindings"]["follow_camera"],
            "video.follow_camera",
        )
        self.assertEqual(value["components"][4]["type"], "controller_help")
        self.assertEqual(value["components"][5]["type"], "control_frame")
        self.assertEqual(value["components"][6]["type"], "operation_trajectory")

    def test_backend_spec_hash_must_match_before_publish(self) -> None:
        class MismatchedNative(FakeNative):
            def blueprint_spec_sha256(self) -> str:
                return "stale"

        client = BlueprintClient(MismatchedNative(), lambda: True)
        with self.assertRaisesRegex(RuntimeError, "primitive spec mismatch"):
            client.set_blueprint(Blueprint("demo", ()))

        client = BlueprintClient(object(), lambda: True)
        with self.assertRaisesRegex(RuntimeError, "does not expose"):
            client.set_blueprint(Blueprint("demo", ()))

    def test_component_validation_rejects_arbitrary_code(self) -> None:
        with self.assertRaisesRegex(ValueError, "id must not be empty"):
            BlueprintComponent(id=" ", type="label", anchor="head")
        with self.assertRaisesRegex(ValueError, "unsupported Blueprint component"):
            BlueprintComponent(id="bad", type="gdscript", anchor="head")
        with self.assertRaisesRegex(ValueError, "unsupported Blueprint anchor"):
            BlueprintComponent(id="bad", type="label", anchor="robot_magic")
        with self.assertRaisesRegex(ValueError, "non-empty"):
            BlueprintComponent(
                id="bad", type="label", anchor="head", bindings={"text": ""}
            )

    def test_optional_component_bindings_and_blueprint_validation(self) -> None:
        label = BlueprintComponent.label(
            "label", visible_binding="ui.label_visible"
        )
        lamp = BlueprintComponent.status_lamp(
            "lamp",
            state_binding="robot.state",
            text_binding="robot.name",
            visible_binding="ui.lamp_visible",
        )
        menu = BlueprintComponent.palm_menu(
            "menu",
            title="Menu",
            action="toggle",
            value_binding="menu.value",
        )
        self.assertEqual(label.bindings["visible"], "ui.label_visible")
        self.assertEqual(lamp.bindings["text"], "robot.name")
        self.assertEqual(lamp.bindings["visible"], "ui.lamp_visible")
        self.assertEqual(menu.anchor, "left_palm")

        with self.assertRaisesRegex(ValueError, "at least one hand"):
            BlueprintComponent.fingertip_tactile("touch")
        with self.assertRaisesRegex(ValueError, "missing"):
            BlueprintComponent.fingertip_tactile(
                "touch", left_bindings={"normal": "left.normal"}
            )

        with self.assertRaisesRegex(ValueError, "unsupported blueprint schema"):
            Blueprint("demo", (), schema="invalid")
        with self.assertRaisesRegex(ValueError, "blueprint_id"):
            Blueprint(" ", ())
        with self.assertRaisesRegex(ValueError, "revision"):
            Blueprint("demo", (), revision=0)
        with self.assertRaisesRegex(ValueError, "unique"):
            Blueprint("demo", (label, label))
        with self.assertRaisesRegex(ValueError, "singleton Blueprint primitive types"):
            Blueprint(
                "demo",
                (
                    BlueprintComponent.video_panel("video_a"),
                    BlueprintComponent.video_panel("video_b"),
                ),
            )

    def test_blueprint_publishes_latest_schema_and_sequences(self) -> None:
        native = FakeNative()
        client = BlueprintClient(native, lambda: True)
        definition = Blueprint(
            blueprint_id="demo",
            components=(
                BlueprintComponent.status_lamp(
                    "status",
                    state_binding="robot.state",
                    visible_binding="robot.ready",
                ),
            ),
        )
        client.set_blueprint(definition)
        self.assertEqual(native.blueprints[0]["blueprint_id"], "demo")

        with self.assertRaisesRegex(ValueError, "not bound"):
            client.update({"not_json": object()})
        with self.assertRaisesRegex(ValueError, "must be string"):
            client.update({"robot.state": float("nan")})

        first = client.update(
            {"robot.state": "active", "robot.ready": True}, timestamp_ns=100
        )
        second = client.update({"robot.state": "warning"}, timestamp_ns=200)
        self.assertEqual((first, second), (1, 2))
        self.assertEqual(native.states[-1]["sequence"], 2)
        self.assertEqual(native.states[-1]["blueprint_revision"], 1)
        self.assertTrue(native.states[-1]["values"]["robot.ready"])
        third = client.update({"robot.state": "active"})
        self.assertEqual(third, 3)
        self.assertGreater(native.states[-1]["timestamp_ns"], 0)
        self.assertNotIn("not_json", native.states[-1]["values"])

        client.clear()
        self.assertEqual(native.clear_calls, 1)
        with self.assertRaisesRegex(RuntimeError, "set_blueprint"):
            client.update({})

    def test_event_parsing_and_polling(self) -> None:
        native = FakeNative()
        native.events.append(
            json.dumps(
                {
                    "schema": "operator.blueprint_event.v1",
                    "blueprint_id": "demo",
                    "blueprint_revision": 1,
                    "sequence": 7,
                    "timestamp_ns": 900,
                    "component_id": "hand_control",
                    "action": "toggle_unlock",
                    "value": True,
                }
            )
        )
        blueprint = BlueprintClient(native, lambda: True)
        blueprint.set_blueprint(
            Blueprint(
                "demo",
                (
                    BlueprintComponent.palm_menu(
                        "hand_control",
                        title="Hand control",
                        action="toggle_unlock",
                        value_binding="hand.unlocked",
                    ),
                ),
            )
        )
        event = blueprint.poll_event(0.1)
        self.assertIsInstance(event, BlueprintEvent)
        assert event is not None
        self.assertEqual(event.component_id, "hand_control")
        self.assertTrue(event.value)

        self.assertIsNone(blueprint.poll_event(0.0))
        native.events.append("[]")
        with self.assertRaisesRegex(ValueError, "JSON object"):
            blueprint.poll_event(0.0)
        with self.assertRaisesRegex(ValueError, "unsupported Blueprint event schema"):
            BlueprintEvent.from_dict({"schema": "invalid"})

    def test_event_validation_and_iterator(self) -> None:
        base = {
            "schema": "operator.blueprint_event.v1",
            "blueprint_id": "demo",
            "blueprint_revision": 1,
            "sequence": 1,
            "timestamp_ns": 900,
            "component_id": "menu",
            "action": "toggle",
            "value": True,
        }
        invalid_cases = (
            ({**base, "blueprint_id": ""}, "blueprint_id"),
            ({**base, "blueprint_revision": 0}, "blueprint_revision"),
            ({**base, "sequence": 0}, "sequence"),
            ({**base, "component_id": ""}, "component_id"),
        )
        for payload, message in invalid_cases:
            with self.subTest(message=message):
                with self.assertRaisesRegex(ValueError, message):
                    BlueprintEvent.from_dict(payload)

        native = FakeNative()
        native.events.append(json.dumps(base))
        running = iter((True, False))
        blueprint = BlueprintClient(native, lambda: next(running))
        blueprint.set_blueprint(
            Blueprint(
                "demo",
                (
                    BlueprintComponent.palm_menu(
                        "menu",
                        title="Menu",
                        action="toggle",
                        value_binding="menu.enabled",
                    ),
                ),
            )
        )
        self.assertEqual([event.action for event in blueprint.events(0.0)], ["toggle"])

    def test_state_binding_constraints_are_enforced_before_publish(self) -> None:
        native = FakeNative()
        client = BlueprintClient(native, lambda: True)
        client.set_blueprint(
            Blueprint(
                "touch",
                (
                    BlueprintComponent.fingertip_tactile(
                        "touch",
                        left_bindings={
                            "normal": "left.normal",
                            "tangential": "left.tangential",
                            "direction": "left.direction",
                            "proximity": "left.proximity",
                            "status": "left.status",
                        },
                    ),
                ),
            )
        )
        with self.assertRaisesRegex(ValueError, "5 items"):
            client.update({"left.status": [0, 0, 0, 0]})
        client.update({"left.status": [0.0, 1.0, 0.0, 0.0, 0.0]})
        self.assertEqual(native.states[-1]["values"]["left.status"], [0.0, 1.0, 0.0, 0.0, 0.0])

    def test_conflicting_binding_contracts_fail_before_install(self) -> None:
        compatible = Blueprint(
            "compatible",
            (
                BlueprintComponent.label("label", text_binding="shared"),
                BlueprintComponent.status_lamp(
                    "status",
                    state_binding="shared",
                ),
            ),
        )
        self.assertEqual(compatible.binding_types()["shared"], "string")

        with self.assertRaisesRegex(ValueError, "conflicting contracts"):
            Blueprint(
                "conflict",
                (
                    BlueprintComponent.label("label", text_binding="shared"),
                    BlueprintComponent.palm_menu(
                        "menu",
                        title="Menu",
                        action="toggle",
                        value_binding="shared",
                    ),
                ),
            )
