//! Test 2 — descriptor deserialization + typed helper accessors.

use teleop_protocol::{
    CaptureStreamsConfig, DeviceDescriptor, DisconnectAction, CURRENT_DEVICE_DESCRIPTOR_VERSION,
};

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

#[test]
fn descriptor_without_capture_streams_keeps_its_wire_shape() {
    let desc: DeviceDescriptor = serde_json::from_str(
        r#"{ "device": { "type": "robot_arm", "name": "Arm" }, "control_schema": {} }"#,
    )
    .unwrap();
    assert!(desc.capture_streams.is_none());
    let value = serde_json::to_value(&desc).unwrap();
    let mut keys: Vec<_> = value.as_object().unwrap().keys().cloned().collect();
    keys.sort();
    assert_eq!(
        keys,
        [
            "capabilities",
            "control_schema",
            "descriptor_version",
            "device",
            "execution",
            "input_contract",
            "input_mapping",
            "safety",
            "telemetry_schema",
            "video_feeds",
        ]
    );
}

#[test]
fn descriptor_with_capture_streams_and_unknown_fields_round_trips() {
    let json = r#"
    {
        "device": { "type": "pyoperator", "name": "Nav", "future_device_field": 1 },
        "control_schema": {},
        "future_top_level": { "anything": [1, 2, 3] },
        "capture_streams": {
            "schema_version": 1,
            "sink": { "protocol": "olcp.v1", "push_port": 63910, "result_port": 63912, "auth_token": "tok" },
            "streams": [
                { "name": "rgb.hevc", "required": true, "max_hz": 4, "max_bitrate_bps": 2000000, "eye": "left" }
            ],
            "local_tasks": [{ "kind": "upload", "endpoint_ref": "lab-ingest" }]
        }
    }
    "#;
    let mut desc: DeviceDescriptor = serde_json::from_str(json).unwrap();
    desc.normalize_for_outside();
    let capture = desc.capture_streams.as_ref().unwrap();
    capture.validate().unwrap();
    assert_eq!(capture.streams[0].name, "rgb.hevc");
    assert!(desc.media.is_none());

    let encoded = serde_json::to_string(&desc).unwrap();
    // The retired `sink` block still parses but is dropped.
    assert!(!encoded.contains("sink"));
    let decoded: DeviceDescriptor = serde_json::from_str(&encoded).unwrap();
    assert_eq!(decoded.capture_streams, desc.capture_streams);
    let reparsed: CaptureStreamsConfig =
        serde_json::from_value(serde_json::to_value(capture).unwrap()).unwrap();
    assert_eq!(&reparsed, capture);
}
