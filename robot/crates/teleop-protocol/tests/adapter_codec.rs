//! Test 3 — adapter codec: paired encode/decode, partial buffer, oversized reject.

use std::collections::HashMap;

use bytes::BytesMut;
use teleop_protocol::{
    AdapterCodec, AdapterToBridge, BridgeCodec, BridgeToAdapter, DeviceCommand, DeviceDescriptor,
    DeviceTelemetry, Pose6D, TelemetryValue,
};
use tokio_util::codec::{Decoder, Encoder};

fn sample_command() -> DeviceCommand {
    let mut axes = HashMap::new();
    axes.insert("throttle".to_string(), 0.5);
    let mut poses = HashMap::new();
    poses.insert(
        "ee".to_string(),
        Pose6D {
            position: [1.0, 0.0, -1.0],
            rotation: [0.0, 0.0, 0.0, 1.0],
        },
    );
    DeviceCommand {
        axes,
        buttons: HashMap::new(),
        poses,
        timestamp_ns: 7,
    }
}

fn sample_descriptor() -> DeviceDescriptor {
    serde_json::from_str(
        r#"{ "device": { "type": "robot_arm", "name": "Arm" }, "control_schema": {} }"#,
    )
    .unwrap()
}

fn sample_telemetry() -> DeviceTelemetry {
    let mut values = HashMap::new();
    values.insert("battery".to_string(), TelemetryValue::Float(0.8));
    values.insert("joints".to_string(), TelemetryValue::Array(vec![0.1, 0.2]));
    DeviceTelemetry {
        values,
        timestamp_ns: 5,
    }
}

/// Encode each BridgeToAdapter variant with the BridgeCodec (encoder side),
/// then decode it with the AdapterCodec (decoder side) — must match.
#[test]
fn bridge_to_adapter_roundtrip_all_variants() {
    let variants = vec![
        BridgeToAdapter::Hello,
        BridgeToAdapter::Command(sample_command()),
        BridgeToAdapter::Stop {
            reason: "watchdog".to_string(),
        },
        BridgeToAdapter::Shutdown,
    ];

    for original in variants {
        let mut enc = BridgeCodec::default();
        let mut buf = BytesMut::new();
        enc.encode(original.clone(), &mut buf).unwrap();

        let mut dec = AdapterCodec::default();
        let decoded = dec.decode(&mut buf).unwrap().unwrap();
        assert_eq!(
            serde_json::to_value(&decoded).unwrap(),
            serde_json::to_value(&original).unwrap(),
            "variant mismatch: {original:?}"
        );
        // Buffer fully consumed.
        assert!(buf.is_empty());
    }
}

/// Encode each AdapterToBridge variant with the AdapterCodec (encoder side),
/// then decode it with the BridgeCodec (decoder side) — must match.
#[test]
fn adapter_to_bridge_roundtrip_all_variants() {
    let variants = vec![
        AdapterToBridge::Descriptor(sample_descriptor()),
        AdapterToBridge::Telemetry(sample_telemetry()),
        AdapterToBridge::Event {
            kind: "warn".to_string(),
            msg: "low battery".to_string(),
        },
    ];

    for original in variants {
        let mut enc = AdapterCodec::default();
        let mut buf = BytesMut::new();
        enc.encode(original.clone(), &mut buf).unwrap();

        let mut dec = BridgeCodec::default();
        let decoded = dec.decode(&mut buf).unwrap().unwrap();
        assert_eq!(
            serde_json::to_value(&decoded).unwrap(),
            serde_json::to_value(&original).unwrap(),
            "variant mismatch: {original:?}"
        );
        assert!(buf.is_empty());
    }
}

/// Feed the encoded frame in two chunks; decode must return Ok(None) until the
/// full frame is present.
#[test]
fn partial_buffer_returns_none_until_complete() {
    let original = BridgeToAdapter::Command(sample_command());
    let mut enc = BridgeCodec::default();
    let mut full = BytesMut::new();
    enc.encode(original.clone(), &mut full).unwrap();
    assert!(full.len() > 6, "frame should be more than a few bytes");

    let mut dec = AdapterCodec::default();

    // First chunk: only part of the frame -> None.
    let mut partial = full.split_to(full.len() / 2);
    assert!(dec.decode(&mut partial).unwrap().is_none());

    // Append the rest -> full frame decodes.
    partial.unsplit(full);
    let decoded = dec.decode(&mut partial).unwrap().unwrap();
    assert_eq!(
        serde_json::to_value(&decoded).unwrap(),
        serde_json::to_value(&original).unwrap()
    );
}

/// Length-prefix-only chunk (< 4 bytes) must also be tolerated.
#[test]
fn partial_length_prefix_returns_none() {
    let mut dec = AdapterCodec::default();
    let mut buf = BytesMut::from(&[1u8, 0u8][..]); // only 2 of 4 length bytes
    assert!(dec.decode(&mut buf).unwrap().is_none());
}

/// A length header claiming a frame larger than the max must be rejected with
/// an InvalidData error rather than allocating wildly.
#[test]
fn oversized_length_is_rejected() {
    let mut dec = AdapterCodec::default();
    // 32 MiB length prefix (LE) — exceeds the 16 MiB cap.
    let huge: u32 = 32 * 1024 * 1024;
    let mut buf = BytesMut::new();
    buf.extend_from_slice(&huge.to_le_bytes());
    buf.extend_from_slice(&[0u8; 16]); // some bytes after, irrelevant

    let err = dec.decode(&mut buf).unwrap_err();
    assert_eq!(err.kind(), std::io::ErrorKind::InvalidData);
}
