use std::collections::HashMap;

use teleop_protocol::{
    blueprint_value_matches_type, blueprint_wire_integer_matches_type, Blueprint,
    BlueprintComponent, BlueprintEvent, BlueprintState, BLUEPRINT_EVENT_SCHEMA, BLUEPRINT_SCHEMA,
    BLUEPRINT_SPEC_JSON, BLUEPRINT_STATE_SCHEMA,
};

#[test]
fn menu_items_merge_only_by_explicit_consistent_identity() {
    let entry = serde_json::json!({"id": "primary", "type": "menu_item",
        "properties": {"title": "Robot", "action": "connection.toggle", "item_key": "shared",
            "locked_text": "Enable", "unlocked_text": "Disable", "unavailable_text": "Unavailable"},
        "bindings": {"value": "enabled", "available": "ready"}});
    let mut legacy = entry.clone();
    legacy["id"] = serde_json::json!("legacy");
    legacy["type"] = serde_json::json!("palm_menu");
    let mut blueprint: Blueprint = serde_json::from_value(serde_json::json!({
        "schema": BLUEPRINT_SCHEMA, "blueprint_id": "menus", "revision": 1,
        "components": [entry, legacy]
    })).unwrap();
    blueprint.validate().unwrap();
    blueprint.components[1].bindings.insert("value".into(), "different".into());
    assert!(blueprint.validate().unwrap_err().contains("conflicting shared menu"));
    blueprint.components[1].properties.insert("item_key".into(), serde_json::json!("other"));
    blueprint.validate().unwrap();
}

#[test]
fn ground_grid_and_model_lighting_contract_round_trips() {
    let blueprint: Blueprint = serde_json::from_value(serde_json::json!({
        "schema": BLUEPRINT_SCHEMA, "blueprint_id": "stage", "revision": 1,
        "components": [
            {"id": "ground", "type": "ground_grid", "properties": {"spacing": 0.5, "placement_target": "g1"}},
            {"id": "lighting", "type": "model_lighting", "bindings": {"key_energy": "key", "fill_energy": "fill"}}
        ]
    })).unwrap();
    blueprint.validate().unwrap();
    let copy: Blueprint = serde_json::from_slice(&serde_json::to_vec(&blueprint).unwrap()).unwrap();
    assert_eq!(copy, blueprint);
    let mut state: BlueprintState = serde_json::from_value(serde_json::json!({
        "schema": BLUEPRINT_STATE_SCHEMA, "blueprint_id": "stage", "blueprint_revision": 1,
        "sequence": 1, "timestamp_ns": 1, "values": {"key": 1.6, "fill": 0.6}
    })).unwrap();
    blueprint.validate_state(&state).unwrap();
    state.values.insert("fill".into(), serde_json::json!(2.1));
    assert!(blueprint.validate_state(&state).is_err());
    let mut duplicate = blueprint.clone();
    let mut second_light = duplicate.components[1].clone();
    second_light.id = "other".into();
    duplicate.components.push(second_light);
    assert!(duplicate.validate().is_err());
    let mut bad = blueprint;
    bad.components[0].properties.insert("spacing".into(), serde_json::json!(0));
    assert!(bad.validate().is_err());
}

#[test]
fn controller_chord_and_menu_actions_have_distinct_contracts() {
    let blueprint: Blueprint = serde_json::from_value(serde_json::json!({
        "schema": BLUEPRINT_SCHEMA, "blueprint_id": "controls", "revision": 1,
        "components": [
            {"id":"reset","type":"input_binding","properties":{"action":"reset","hold_seconds":1},
             "bindings":{"available":"available","required":"required","acknowledged_request":"ack","success":"success"}},
            {"id":"menu","type":"controller_menu","properties":{"title":"Controls","action":"connection.toggle",
             "secondary_action":"view.recenter","secondary_text":"Recenter"},"bindings":{"value":"connected"}}
        ]
    })).unwrap();
    blueprint.validate().unwrap();
    let mut event: BlueprintEvent = serde_json::from_value(serde_json::json!({
        "schema": BLUEPRINT_EVENT_SCHEMA, "blueprint_id": "controls", "blueprint_revision": 1,
        "sequence": 1, "timestamp_ns": 1, "component_id": "reset", "action": "reset", "value": "request-id"
    })).unwrap();
    blueprint.validate_event(&event).unwrap();
    event.value = serde_json::json!(true);
    assert!(blueprint.validate_event(&event).is_err());
    event.component_id = "menu".into();
    event.action = "view.recenter".into();
    blueprint.validate_event(&event).unwrap();
    event.action = "arbitrary_local_action".into();
    assert!(blueprint.validate_event(&event).is_err());
}

#[test]
fn controller_menu_event_contract_round_trips() {
    let blueprint: Blueprint = serde_json::from_value(serde_json::json!({
        "schema": BLUEPRINT_SCHEMA, "blueprint_id": "menu", "revision": 1,
        "components": [{
            "id": "calibrate", "type": "controller_menu",
            "properties": {"title": "ScaleBFM", "action": "calibrate"},
            "bindings": {"value": "calibrated", "available": "ready"}
        }]
    })).unwrap();
    blueprint.validate().unwrap();
    let event: BlueprintEvent = serde_json::from_value(serde_json::json!({
        "schema": BLUEPRINT_EVENT_SCHEMA, "blueprint_id": "menu", "blueprint_revision": 1,
        "sequence": 1, "timestamp_ns": 1, "component_id": "calibrate",
        "action": "calibrate", "value": true
    })).unwrap();
    blueprint.validate_event(&event).unwrap();
    let mut bad_event = event;
    bad_event.value = serde_json::json!("true");
    assert!(blueprint.validate_event(&bad_event).is_err());
    let mut duplicate = blueprint;
    let mut second = duplicate.components[0].clone();
    second.id = "second".into();
    duplicate.components.push(second);
    assert!(duplicate.validate().is_err());
}

#[test]
fn robot_model_state_contract_round_trips() {
    let blueprint: Blueprint = serde_json::from_value(serde_json::json!({
        "schema": BLUEPRINT_SCHEMA, "blueprint_id": "robot", "revision": 1,
        "components": [{
            "id": "g1", "type": "robot_model",
            "properties": {"asset_sha256": "a".repeat(64), "asset_size": 100, "asset_port": 63904, "joint_names": ["left_knee_joint"]},
            "bindings": {"joint_positions": "q", "base_pose": "base", "sample": "sample"}
        }]
    })).unwrap();
    blueprint.validate().unwrap();
    let mut state: BlueprintState = serde_json::from_value(serde_json::json!({
        "schema": BLUEPRINT_STATE_SCHEMA, "blueprint_id": "robot", "blueprint_revision": 1,
        "sequence": 1, "timestamp_ns": 10,
        "values": {"q": [0.2], "base": [0, 1, 0, 0, 0, 0, 1], "sample": 1}
    })).unwrap();
    blueprint.validate_state(&state).unwrap();
    state.values.insert("base".into(), serde_json::json!(vec![0; 6]));
    assert!(blueprint.validate_state(&state).is_err());
}

#[test]
fn blueprint_round_trips_and_validates() {
    let blueprint = Blueprint {
        schema: BLUEPRINT_SCHEMA.to_string(),
        blueprint_id: "revo2.default".to_string(),
        revision: 3,
        components: vec![
            BlueprintComponent {
                id: "hand_control".to_string(),
                component_type: "palm_menu".to_string(),
                anchor: "left_palm".to_string(),
                transform: Default::default(),
                properties: HashMap::from([
                    (
                        "title".to_string(),
                        serde_json::Value::String("Hand control".to_string()),
                    ),
                    (
                        "action".to_string(),
                        serde_json::Value::String("toggle_unlock".to_string()),
                    ),
                ]),
                bindings: HashMap::from([
                    ("available".to_string(), "hand.available".to_string()),
                    ("value".to_string(), "hand.unlocked".to_string()),
                ]),
                user_overridable: true,
            },
            BlueprintComponent {
                id: "touch".to_string(),
                component_type: "fingertip_tactile".to_string(),
                anchor: "world".to_string(),
                transform: Default::default(),
                properties: HashMap::new(),
                bindings: HashMap::from([
                    ("left_normal".to_string(), "left.touch.normal".to_string()),
                    (
                        "left_tangential".to_string(),
                        "left.touch.tangential".to_string(),
                    ),
                    (
                        "left_direction".to_string(),
                        "left.touch.direction".to_string(),
                    ),
                    (
                        "left_proximity".to_string(),
                        "left.touch.proximity".to_string(),
                    ),
                    ("left_status".to_string(), "left.touch.status".to_string()),
                ]),
                user_overridable: true,
            },
            BlueprintComponent {
                id: "fpv".to_string(),
                component_type: "video_panel".to_string(),
                anchor: "world".to_string(),
                transform: Default::default(),
                properties: HashMap::from([(
                    "follow_camera".to_string(),
                    serde_json::Value::Bool(true),
                )]),
                bindings: HashMap::from([("visible".to_string(), "video.visible".to_string())]),
                user_overridable: true,
            },
        ],
    };
    blueprint.validate().unwrap();

    let json = serde_json::to_string(&blueprint).unwrap();
    let decoded: Blueprint = serde_json::from_str(&json).unwrap();
    assert_eq!(decoded, blueprint);
}

#[test]
fn blueprint_rejects_duplicate_components_and_unknown_types() {
    let component = BlueprintComponent {
        id: "status".to_string(),
        component_type: "label".to_string(),
        anchor: "head".to_string(),
        transform: Default::default(),
        properties: HashMap::new(),
        bindings: HashMap::new(),
        user_overridable: true,
    };
    let duplicate = Blueprint {
        schema: BLUEPRINT_SCHEMA.to_string(),
        blueprint_id: "duplicate".to_string(),
        revision: 1,
        components: vec![component.clone(), component],
    };
    assert!(duplicate.validate().unwrap_err().contains("duplicate"));

    let unknown = Blueprint {
        schema: BLUEPRINT_SCHEMA.to_string(),
        blueprint_id: "unknown".to_string(),
        revision: 1,
        components: vec![BlueprintComponent {
            id: "custom".to_string(),
            component_type: "arbitrary_gdscript".to_string(),
            anchor: "world".to_string(),
            transform: Default::default(),
            properties: HashMap::new(),
            bindings: HashMap::new(),
            user_overridable: true,
        }],
    };
    assert!(unknown.validate().unwrap_err().contains("unsupported"));

    let duplicate_builtin = Blueprint {
        schema: BLUEPRINT_SCHEMA.to_string(),
        blueprint_id: "duplicate-builtin".to_string(),
        revision: 1,
        components: vec![
            BlueprintComponent {
                id: "video-a".to_string(),
                component_type: "video_panel".to_string(),
                anchor: "world".to_string(),
                transform: Default::default(),
                properties: HashMap::new(),
                bindings: HashMap::new(),
                user_overridable: true,
            },
            BlueprintComponent {
                id: "video-b".to_string(),
                component_type: "video_panel".to_string(),
                anchor: "world".to_string(),
                transform: Default::default(),
                properties: HashMap::new(),
                bindings: HashMap::new(),
                user_overridable: true,
            },
        ],
    };
    assert!(duplicate_builtin
        .validate()
        .unwrap_err()
        .contains("duplicate singleton"));
}

#[test]
fn generated_spec_is_valid_json() {
    let spec: serde_json::Value = serde_json::from_str(BLUEPRINT_SPEC_JSON).unwrap();
    assert_eq!(spec["schema"], "operator.blueprint_primitive_spec.v1");
    assert_eq!(spec["wire"]["blueprint_schema"], BLUEPRINT_SCHEMA);
    assert!(spec["primitives"]["palm_menu"]["events"]["action"].is_object());
}

#[test]
fn generated_value_type_conformance_matches_rust_validation() {
    let spec: serde_json::Value = serde_json::from_str(BLUEPRINT_SPEC_JSON).unwrap();
    let cases = spec["value_type_conformance"].as_object().unwrap();
    for (value_type, cases) in cases {
        for value in cases["valid"].as_array().unwrap() {
            assert!(
                blueprint_value_matches_type(value, value_type),
                "expected {value_type} valid case {value:?} to pass"
            );
        }
        for value in cases["invalid"].as_array().unwrap() {
            assert!(
                !blueprint_value_matches_type(value, value_type),
                "expected {value_type} invalid case {value:?} to fail"
            );
        }
    }

    let wire_cases = spec["wire_integer_conformance"].as_object().unwrap();
    for value in wire_cases["valid"].as_array().unwrap() {
        assert!(
            blueprint_wire_integer_matches_type(value),
            "expected valid wire integer {value:?}"
        );
    }
    for value in wire_cases["invalid"].as_array().unwrap() {
        assert!(
            !blueprint_wire_integer_matches_type(value),
            "expected invalid wire integer {value:?}"
        );
    }
}

#[test]
fn component_defaults_come_from_generated_spec() {
    let menu: BlueprintComponent = serde_json::from_str(
        r#"{
            "id":"menu",
            "type":"palm_menu",
            "properties":{"title":"Menu","action":"toggle"},
            "bindings":{"value":"menu.enabled"}
        }"#,
    )
    .unwrap();
    assert_eq!(menu.anchor, "left_palm");
    assert!(menu.user_overridable);
    assert_eq!(menu.transform.position, [0.0, 0.0, 0.0]);
}

#[test]
fn optional_component_fields_reject_explicit_null() {
    assert!(serde_json::from_str::<Blueprint>(
        r#"{
            "schema":"operator.blueprint.v1",
            "blueprint_id":"null-anchor",
            "revision":1,
            "components":[{"id":"label","type":"label","anchor":null}]
        }"#,
    )
    .is_err());
    assert!(serde_json::from_str::<Blueprint>(
        r#"{
            "schema":"operator.blueprint.v1",
            "blueprint_id":"null-override",
            "revision":1,
            "components":[{"id":"label","type":"label","user_overridable":null}]
        }"#,
    )
    .is_err());
}

#[test]
fn schemas_are_required_on_the_wire() {
    assert!(serde_json::from_str::<Blueprint>(
        r#"{"blueprint_id":"demo","revision":1,"components":[]}"#
    )
    .is_err());
    assert!(serde_json::from_str::<BlueprintState>(
        r#"{"blueprint_id":"demo","blueprint_revision":1,"sequence":1,"timestamp_ns":0,"values":{}}"#
    )
    .is_err());
    assert!(serde_json::from_str::<BlueprintEvent>(
        r#"{"blueprint_id":"demo","blueprint_revision":1,"sequence":1,"timestamp_ns":0,"component_id":"menu","action":"toggle","value":true}"#
    )
    .is_err());
    assert!(serde_json::from_str::<Blueprint>(
        r#"{"schema":"operator.blueprint.v1","blueprint_id":"demo","revision":1.0,"components":[]}"#
    )
    .is_err());
}

#[test]
fn binding_requiredness_does_not_create_a_value_contract_conflict() {
    let blueprint: Blueprint = serde_json::from_str(
        r#"{
            "schema":"operator.blueprint.v1",
            "blueprint_id":"shared-string",
            "revision":1,
            "components":[
                {"id":"label","type":"label","bindings":{"text":"shared"}},
                {"id":"status","type":"status_lamp","bindings":{"state":"shared"}}
            ]
        }"#,
    )
    .unwrap();
    blueprint.validate().unwrap();
}

#[test]
fn blueprint_state_enforces_binding_contracts() {
    let blueprint: Blueprint = serde_json::from_str(
        r#"{
            "schema":"operator.blueprint.v1",
            "blueprint_id":"touch",
            "revision":1,
            "components":[{
                "id":"touch",
                "type":"fingertip_tactile",
                "bindings":{
                    "left_normal":"left.normal",
                    "left_tangential":"left.tangential",
                    "left_direction":"left.direction",
                    "left_proximity":"left.proximity",
                    "left_status":"left.status"
                }
            }]
        }"#,
    )
    .unwrap();
    blueprint.validate().unwrap();
    let mut state = BlueprintState {
        schema: BLUEPRINT_STATE_SCHEMA.to_string(),
        blueprint_id: "touch".to_string(),
        blueprint_revision: 1,
        sequence: 1,
        timestamp_ns: 1,
        values: HashMap::from([("left.status".to_string(), serde_json::json!([0, 0, 0, 0]))]),
    };
    assert!(blueprint
        .validate_state(&state)
        .unwrap_err()
        .contains("5 items"));
    state.values.insert(
        "left.status".to_string(),
        serde_json::json!([0.0, 1.0, 0.0, 0.0, 0.0]),
    );
    blueprint.validate_state(&state).unwrap();
    state
        .values
        .insert("left.typo".to_string(), serde_json::json!(true));
    assert!(blueprint
        .validate_state(&state)
        .unwrap_err()
        .contains("not bound"));
}

#[test]
fn blueprint_state_and_event_round_trip() {
    let state = BlueprintState {
        schema: BLUEPRINT_STATE_SCHEMA.to_string(),
        blueprint_id: "revo2.default".to_string(),
        blueprint_revision: 3,
        sequence: 10,
        timestamp_ns: 123,
        values: HashMap::from([
            ("hand.available".to_string(), serde_json::Value::Bool(true)),
            ("hand.unlocked".to_string(), serde_json::Value::Bool(false)),
        ]),
    };
    state.validate().unwrap();
    let decoded: BlueprintState =
        serde_json::from_str(&serde_json::to_string(&state).unwrap()).unwrap();
    assert_eq!(decoded, state);

    let event = BlueprintEvent {
        schema: BLUEPRINT_EVENT_SCHEMA.to_string(),
        blueprint_id: "revo2.default".to_string(),
        blueprint_revision: 3,
        sequence: 4,
        timestamp_ns: 456,
        component_id: "hand_control".to_string(),
        action: "toggle".to_string(),
        value: serde_json::Value::Bool(true),
    };
    event.validate().unwrap();
    let decoded: BlueprintEvent =
        serde_json::from_str(&serde_json::to_string(&event).unwrap()).unwrap();
    assert_eq!(decoded, event);
}

#[test]
fn blueprint_state_and_event_require_positive_sequences() {
    let mut state = BlueprintState {
        schema: BLUEPRINT_STATE_SCHEMA.to_string(),
        blueprint_id: "demo".to_string(),
        blueprint_revision: 1,
        sequence: 0,
        timestamp_ns: 0,
        values: HashMap::new(),
    };
    assert!(state.validate().unwrap_err().contains("sequence"));
    state.sequence = 1;
    state.validate().unwrap();

    let mut event = BlueprintEvent {
        schema: BLUEPRINT_EVENT_SCHEMA.to_string(),
        blueprint_id: "demo".to_string(),
        blueprint_revision: 1,
        sequence: 0,
        timestamp_ns: 0,
        component_id: "menu".to_string(),
        action: "toggle".to_string(),
        value: serde_json::Value::Null,
    };
    assert!(event.validate().unwrap_err().contains("sequence"));
    event.sequence = 1;
    event.validate().unwrap();

    state.timestamp_ns = u64::MAX;
    assert!(state.validate().unwrap_err().contains("integers"));
    event.timestamp_ns = u64::MAX;
    assert!(event.validate().unwrap_err().contains("integers"));
}
