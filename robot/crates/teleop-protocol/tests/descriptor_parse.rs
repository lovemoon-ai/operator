//! Test 2 — descriptor deserialization + typed helper accessors.

use teleop_protocol::{DeviceDescriptor, DisconnectAction, CURRENT_DEVICE_DESCRIPTOR_VERSION};

#[test]
fn deserialize_minimal_descriptor_json() {
    // Only the required fields; everything else relies on #[serde(default)].
    let json = r#"
    {
        "device": { "type": "robot_arm", "name": "Test Arm" },
        "control_schema": {
            "axes": [
                { "name": "gripper", "default": 0.0 }
            ]
        }
    }
    "#;

    let desc: DeviceDescriptor = serde_json::from_str(json).unwrap();
    assert_eq!(desc.device.device_type, "robot_arm");
    assert_eq!(desc.device.name, "Test Arm");
    assert_eq!(desc.control_schema.axes.len(), 1);
    assert_eq!(desc.control_schema.axes[0].name, "gripper");
    // Default axis range is (-1.0, 1.0).
    assert_eq!(desc.control_schema.axes[0].range, (-1.0, 1.0));
    assert_eq!(desc.descriptor_version, 1);
    assert_eq!(desc.execution.kind, "outside");
    assert_eq!(desc.execution.environment, "unknown");

    // Safety defaults: action "stop", timeout 500ms.
    assert_eq!(
        desc.safety.parsed_disconnect_action(),
        DisconnectAction::Stop
    );
    assert_eq!(desc.safety.timeout().as_millis(), 500);
}

#[test]
fn normalize_legacy_descriptor_builds_outside_contract() {
    let json = r#"
    {
        "device": { "type": "robot_arm", "name": "Legacy Arm" },
        "control_schema": {
            "axes": [{ "name": "gripper" }],
            "buttons": [{ "name": "enable" }, { "name": "reset" }],
            "poses": [{ "name": "end_effector", "frame": "right_hand" }]
        },
        "input_mapping": [
            { "source": "right_trigger", "target": "gripper" },
            { "source": "right_grip", "target": "enable" }
        ]
    }
    "#;
    let mut desc: DeviceDescriptor = serde_json::from_str(json).unwrap();

    desc.normalize_for_outside();

    assert_eq!(desc.descriptor_version, CURRENT_DEVICE_DESCRIPTOR_VERSION);
    assert_eq!(desc.execution.kind, "outside");
    assert_eq!(desc.input_contract.channels.len(), 4);
    assert_eq!(desc.input_contract.channels[0].name, "gripper");
    assert_eq!(desc.input_contract.channels[0].frame, "right_trigger");
    assert_eq!(desc.input_contract.channels[3].value_type, "pose6d");
    assert_eq!(desc.input_contract.channels[3].frame, "right_hand");
    assert_eq!(desc.capabilities["teleop"], true);
    assert_eq!(desc.capabilities["emergency_stop"], true);
    assert_eq!(desc.capabilities["deadman"], true);
    assert_eq!(desc.capabilities["reset"], true);
}

#[test]
fn normalize_preserves_explicit_environment_and_capability() {
    let json = r#"
    {
        "descriptor_version": 2,
        "execution": { "kind": "outside", "environment": "simulation" },
        "device": { "type": "robot_arm", "name": "Remote Sim" },
        "control_schema": {},
        "input_contract": {
            "rate_hz": 60.0,
            "coordinate_space": "world",
            "channels": [{ "name": "skeleton", "type": "skeleton", "joints": ["head"] }]
        },
        "capabilities": { "teleop": true, "custom_solver": "gmr" }
    }
    "#;
    let mut desc: DeviceDescriptor = serde_json::from_str(json).unwrap();

    desc.normalize_for_outside();

    assert_eq!(desc.execution.environment, "simulation");
    assert_eq!(desc.input_contract.channels[0].joints, ["head"]);
    assert_eq!(desc.capabilities["custom_solver"], "gmr");
}

#[test]
fn disconnect_action_parsing() {
    let json = r#"
    {
        "device": { "type": "rc_car", "name": "Car" },
        "control_schema": {},
        "safety": {
            "disconnect_action": "hold",
            "command_timeout_ms": 250
        }
    }
    "#;
    let desc: DeviceDescriptor = serde_json::from_str(json).unwrap();
    assert_eq!(
        desc.safety.parsed_disconnect_action(),
        DisconnectAction::Hold
    );
    assert_eq!(desc.safety.timeout().as_millis(), 250);
}

#[test]
fn unknown_disconnect_action_falls_back_to_stop() {
    let json = r#"
    {
        "device": { "type": "rc_car", "name": "Car" },
        "control_schema": {},
        "safety": { "disconnect_action": "explode" }
    }
    "#;
    let desc: DeviceDescriptor = serde_json::from_str(json).unwrap();
    assert_eq!(
        desc.safety.parsed_disconnect_action(),
        DisconnectAction::Stop
    );
}

#[test]
fn return_home_action_parsing() {
    let json = r#"
    {
        "device": { "type": "robot_arm", "name": "Arm" },
        "control_schema": {},
        "safety": { "disconnect_action": "return_home" }
    }
    "#;
    let desc: DeviceDescriptor = serde_json::from_str(json).unwrap();
    assert_eq!(
        desc.safety.parsed_disconnect_action(),
        DisconnectAction::ReturnHome
    );
}
