//! Atomic XR device-state snapshots.
//!
//! A snapshot is sampled by the headset during one render tick and transported
//! as one wire message.  Consumers must replace the complete frame; fields are
//! never merged across frames.  Sub-samples retain their own timestamps because
//! hands, body tracking, and external trackers can update more slowly than the
//! headset pose.

use std::collections::HashMap;

use serde::{Deserialize, Serialize};

pub const XR_STATE_SCHEMA_VERSION: u16 = 1;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct XrStateFrame {
    pub schema_version: u16,
    pub frame_id: u64,
    /// Headset monotonic timestamp captured once at the start of the sample.
    pub timestamp_ns: u64,
    #[serde(default = "default_coordinate_space")]
    pub coordinate_space: String,
    #[serde(default)]
    pub head: Option<TrackedPose>,
    #[serde(default)]
    pub controllers: ControllerPair,
    #[serde(default)]
    pub hands: HandPair,
    #[serde(default)]
    pub body: Option<BodyState>,
    #[serde(default)]
    pub motion_trackers: Vec<MotionTrackerState>,
}

impl Default for XrStateFrame {
    fn default() -> Self {
        Self {
            schema_version: XR_STATE_SCHEMA_VERSION,
            frame_id: 0,
            timestamp_ns: 0,
            coordinate_space: default_coordinate_space(),
            head: None,
            controllers: ControllerPair::default(),
            hands: HandPair::default(),
            body: None,
            motion_trackers: Vec::new(),
        }
    }
}

fn default_coordinate_space() -> String {
    "openxr_stage".to_string()
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct TrackedPose {
    #[serde(default)]
    pub valid: bool,
    #[serde(default)]
    pub sample_timestamp_ns: u64,
    #[serde(default)]
    pub position: [f64; 3],
    /// Quaternion in `[x, y, z, w]` order.
    #[serde(default = "identity_rotation")]
    pub rotation: [f64; 4],
    #[serde(default)]
    pub linear_velocity: Option<[f64; 3]>,
    #[serde(default)]
    pub angular_velocity: Option<[f64; 3]>,
    #[serde(default)]
    pub confidence: Option<f64>,
}

impl Default for TrackedPose {
    fn default() -> Self {
        Self {
            valid: false,
            sample_timestamp_ns: 0,
            position: [0.0; 3],
            rotation: identity_rotation(),
            linear_velocity: None,
            angular_velocity: None,
            confidence: None,
        }
    }
}

fn identity_rotation() -> [f64; 4] {
    [0.0, 0.0, 0.0, 1.0]
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct ControllerPair {
    #[serde(default)]
    pub left: Option<ControllerState>,
    #[serde(default)]
    pub right: Option<ControllerState>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct ControllerState {
    #[serde(default)]
    pub pose: TrackedPose,
    #[serde(default)]
    pub input: ControllerInput,
    #[serde(default)]
    pub interaction_profile: String,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct ControllerInput {
    #[serde(default)]
    pub sample_timestamp_ns: u64,
    /// OpenXR action name to its normalized scalar value. Vector actions use
    /// `<name>_x` and `<name>_y` keys.
    #[serde(default)]
    pub values: HashMap<String, f64>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct HandPair {
    #[serde(default)]
    pub left: Option<HandState>,
    #[serde(default)]
    pub right: Option<HandState>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct HandState {
    #[serde(default)]
    pub active: bool,
    #[serde(default)]
    pub sample_timestamp_ns: u64,
    #[serde(default)]
    pub joints: Vec<TrackedJoint>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct TrackedJoint {
    pub joint: u16,
    #[serde(default)]
    pub flags: u64,
    #[serde(default)]
    pub tracked: bool,
    #[serde(default)]
    pub radius_m: f64,
    #[serde(default)]
    pub pose: TrackedPose,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct BodyState {
    #[serde(default)]
    pub active: bool,
    #[serde(default)]
    pub sample_timestamp_ns: u64,
    #[serde(default)]
    pub joint_set: String,
    #[serde(default)]
    pub body_flags: u64,
    #[serde(default)]
    pub joints: Vec<TrackedJoint>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct MotionTrackerState {
    pub id: String,
    #[serde(default)]
    pub tracker_index: u16,
    #[serde(default)]
    pub pose: TrackedPose,
    #[serde(default)]
    pub battery_level: Option<f64>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn state_frame_json_round_trip_preserves_atomic_identity() {
        let frame = XrStateFrame {
            frame_id: 42,
            timestamp_ns: 1_000,
            head: Some(TrackedPose {
                valid: true,
                sample_timestamp_ns: 999,
                position: [1.0, 2.0, 3.0],
                ..TrackedPose::default()
            }),
            ..XrStateFrame::default()
        };

        let json = serde_json::to_vec(&frame).unwrap();
        let decoded: XrStateFrame = serde_json::from_slice(&json).unwrap();

        assert_eq!(decoded, frame);
        assert_eq!(decoded.frame_id, 42);
        assert_eq!(decoded.head.unwrap().sample_timestamp_ns, 999);
    }
}
