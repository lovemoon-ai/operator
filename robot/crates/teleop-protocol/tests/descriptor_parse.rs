//! Test 2 — descriptor deserialization + typed helper accessors.

use teleop_protocol::{DeviceDescriptor, DisconnectAction};

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

    // Safety defaults: action "stop", timeout 500ms.
    assert_eq!(
        desc.safety.parsed_disconnect_action(),
        DisconnectAction::Stop
    );
    assert_eq!(desc.safety.timeout().as_millis(), 500);
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
