//! Test 1 — wire types JSON round-trip.

use std::collections::HashMap;

use teleop_protocol::{DeviceCommand, DeviceTelemetry, Pose6D, TelemetryValue};

#[test]
fn device_command_json_roundtrip() {
    let mut axes = HashMap::new();
    axes.insert("throttle".to_string(), 0.75);
    axes.insert("steering".to_string(), -0.2);

    let mut buttons = HashMap::new();
    buttons.insert("horn".to_string(), true);

    let mut poses = HashMap::new();
    poses.insert(
        "end_effector".to_string(),
        Pose6D {
            position: [1.0, 2.0, 3.0],
            rotation: [0.0, 0.0, 0.7071, 0.7071],
        },
    );

    let cmd = DeviceCommand {
        axes,
        buttons,
        poses,
        timestamp_ns: 1_234_567_890,
    };

    let json = serde_json::to_string(&cmd).unwrap();
    let back: DeviceCommand = serde_json::from_str(&json).unwrap();

    assert_eq!(back.axes, cmd.axes);
    assert_eq!(back.buttons, cmd.buttons);
    assert_eq!(back.timestamp_ns, cmd.timestamp_ns);
    let p = back.poses.get("end_effector").unwrap();
    assert_eq!(p.position, [1.0, 2.0, 3.0]);
    assert_eq!(p.rotation, [0.0, 0.0, 0.7071, 0.7071]);
}

#[test]
fn device_command_defaults_from_empty_json() {
    // All fields are #[serde(default)] — empty object must deserialize.
    let cmd: DeviceCommand = serde_json::from_str("{}").unwrap();
    assert!(cmd.axes.is_empty());
    assert!(cmd.buttons.is_empty());
    assert!(cmd.poses.is_empty());
    assert_eq!(cmd.timestamp_ns, 0);
}

#[test]
fn device_telemetry_json_roundtrip_with_array() {
    let mut values = HashMap::new();
    values.insert("battery".to_string(), TelemetryValue::Float(0.92));
    values.insert("ticks".to_string(), TelemetryValue::Int(42));
    values.insert("homed".to_string(), TelemetryValue::Bool(true));
    values.insert(
        "state".to_string(),
        TelemetryValue::Text("idle".to_string()),
    );
    values.insert(
        "joints".to_string(),
        TelemetryValue::Array(vec![0.1, -0.2, 0.3, 1.5]),
    );

    let tel = DeviceTelemetry {
        values,
        timestamp_ns: 99,
    };

    let json = serde_json::to_string(&tel).unwrap();
    let back: DeviceTelemetry = serde_json::from_str(&json).unwrap();

    assert_eq!(back.timestamp_ns, 99);
    match back.values.get("joints").unwrap() {
        TelemetryValue::Array(a) => assert_eq!(a, &vec![0.1, -0.2, 0.3, 1.5]),
        other => panic!("expected Array, got {other:?}"),
    }
    match back.values.get("battery").unwrap() {
        TelemetryValue::Float(f) => assert_eq!(*f, 0.92),
        other => panic!("expected Float, got {other:?}"),
    }
    match back.values.get("state").unwrap() {
        TelemetryValue::Text(s) => assert_eq!(s, "idle"),
        other => panic!("expected Text, got {other:?}"),
    }
}

#[test]
fn telemetry_value_untagged_serialization_is_bare() {
    // Untagged: a Float serializes as a bare number, not {"Float": ...}.
    let v = TelemetryValue::Float(1.5);
    assert_eq!(serde_json::to_string(&v).unwrap(), "1.5");
    let v = TelemetryValue::Bool(true);
    assert_eq!(serde_json::to_string(&v).unwrap(), "true");
    let v = TelemetryValue::Text("hi".into());
    assert_eq!(serde_json::to_string(&v).unwrap(), "\"hi\"");
}
