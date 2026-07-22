//! Shared command and telemetry wire types.
//!
//! These shapes are byte-for-byte JSON-compatible with the types the existing
//! `robo-agent` uses in `robot/src/device/command.rs` and with the XR client.
//! They are the payloads carried *inside* adapter-protocol frames, but they are
//! also the shapes the XR<->bridge wire protocol speaks, so the serde
//! representation must not drift.

use std::collections::HashMap;

use serde::{Deserialize, Serialize};

/// A generic control command sent from the headset to the device.
///
/// Each field is optional — axes, buttons, and poses are keyed by the names
/// declared in the device's `ControlSchema`.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct DeviceCommand {
    /// Continuous axis values (e.g. "throttle" → 0.75).
    #[serde(default)]
    pub axes: HashMap<String, f64>,
    /// Discrete button states (e.g. "horn" → true).
    #[serde(default)]
    pub buttons: HashMap<String, bool>,
    /// 6-DOF pose inputs (e.g. "end_effector" → Pose6D).
    #[serde(default)]
    pub poses: HashMap<String, Pose6D>,
    /// Headset-side timestamp in nanoseconds.
    #[serde(default)]
    pub timestamp_ns: u64,
}

/// A 6-DOF pose: position `[x, y, z]` + rotation quaternion `[qx, qy, qz, qw]`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Pose6D {
    pub position: [f64; 3],
    /// Quaternion in `[x, y, z, w]` order.
    pub rotation: [f64; 4],
}

/// Telemetry data reported by the device back to the headset.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct DeviceTelemetry {
    /// Keyed telemetry values.
    pub values: HashMap<String, TelemetryValue>,
    /// Device-side timestamp in nanoseconds.
    pub timestamp_ns: u64,
}

/// A single telemetry value (untagged for compact JSON).
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(untagged)]
pub enum TelemetryValue {
    Float(f64),
    Int(i64),
    Bool(bool),
    Text(String),
    Array(Vec<f64>),
}
