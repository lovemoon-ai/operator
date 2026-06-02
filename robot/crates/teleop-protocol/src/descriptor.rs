//! Device self-description types.
//!
//! These replicate the descriptor shapes from `robot/src/device/traits.rs`
//! (serde representation identical, so the headset and existing configs keep
//! working). The `Device` trait itself deliberately does NOT live here — it
//! stays in `robo-agent` / the future `robot-adapter`. This crate only owns the
//! data the descriptor carries across the boundary.

use std::collections::HashMap;
use std::time::Duration;

use serde::{Deserialize, Serialize};

/// Full device self-description sent to the headset on connect.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DeviceDescriptor {
    /// Basic device info.
    pub device: DeviceInfo,
    /// What control inputs the device accepts.
    pub control_schema: ControlSchema,
    /// How VR inputs map to device controls (default mapping).
    #[serde(default)]
    pub input_mapping: Vec<InputMapping>,
    /// What telemetry values the device reports.
    #[serde(default)]
    pub telemetry_schema: TelemetrySchema,
    /// Available video feeds.
    #[serde(default)]
    pub video_feeds: Vec<VideoFeedInfo>,
    /// Safety configuration.
    #[serde(default)]
    pub safety: DeviceSafetyConfig,
}

/// Basic device identification.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DeviceInfo {
    /// Device type identifier (e.g. "robot_arm", "rc_car").
    #[serde(rename = "type")]
    pub device_type: String,
    /// Human-readable display name.
    pub name: String,
    /// Icon name for headset UI.
    #[serde(default)]
    pub icon: String,
    /// Optional 3D model URL for VR display.
    #[serde(default)]
    pub model_url: String,
}

/// Defines what control inputs the device accepts.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct ControlSchema {
    /// Continuous control axes (e.g. throttle, steering).
    #[serde(default)]
    pub axes: Vec<AxisDef>,
    /// Discrete buttons (e.g. horn, headlight).
    #[serde(default)]
    pub buttons: Vec<ButtonDef>,
    /// 6DOF pose inputs (e.g. end effector target).
    #[serde(default)]
    pub poses: Vec<PoseDef>,
}

/// Definition of a continuous control axis.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AxisDef {
    /// Axis name used as key in DeviceCommand.
    pub name: String,
    /// Human-readable display name.
    #[serde(default)]
    pub display: String,
    /// Valid range `[min, max]`.
    #[serde(default = "default_axis_range")]
    pub range: (f64, f64),
    /// Default value when no input is provided.
    #[serde(default)]
    pub default: f64,
    /// Dead zone threshold (values below this are treated as zero).
    #[serde(default)]
    pub dead_zone: f64,
}

fn default_axis_range() -> (f64, f64) {
    (-1.0, 1.0)
}

/// Definition of a discrete button.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ButtonDef {
    /// Button name used as key in DeviceCommand.
    pub name: String,
    /// Human-readable display name.
    #[serde(default)]
    pub display: String,
    /// Whether this is a toggle (true) or momentary (false) button.
    #[serde(default)]
    pub toggle: bool,
    /// Optional button group (radio-button behavior within group).
    #[serde(default)]
    pub group: Option<String>,
    /// Whether pressing this button requires confirmation.
    #[serde(default)]
    pub confirm: bool,
}

/// Definition of a 6DOF pose input.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PoseDef {
    /// Pose name used as key in DeviceCommand.
    pub name: String,
    /// Human-readable display name.
    #[serde(default)]
    pub display: String,
    /// Degrees of freedom (typically 6).
    #[serde(default = "default_dof")]
    pub dof: u8,
    /// Reference frame (e.g. "right_hand", "left_hand", "head").
    #[serde(default)]
    pub frame: String,
}

fn default_dof() -> u8 {
    6
}

/// A mapping from a VR input source to a device control target.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct InputMapping {
    /// VR input source (e.g. "left_joystick_y", "right_trigger").
    pub source: String,
    /// Device control target (e.g. "throttle", "gripper").
    pub target: String,
    /// Scale factor applied to the input value.
    #[serde(default = "default_scale")]
    pub scale: f64,
    /// Whether to invert the input value.
    #[serde(default)]
    pub invert: bool,
    /// Offset added after scaling.
    #[serde(default)]
    pub offset: f64,
    /// Mapping mode (e.g. "relative", "absolute").
    #[serde(default)]
    pub mode: String,
}

fn default_scale() -> f64 {
    1.0
}

/// Schema for telemetry values reported by the device.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct TelemetrySchema {
    /// Telemetry value definitions.
    #[serde(default)]
    pub values: Vec<TelemetryValueDef>,
}

/// Definition of a single telemetry value.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TelemetryValueDef {
    /// Value name used as key in DeviceTelemetry.
    pub name: String,
    /// Human-readable display name.
    #[serde(default)]
    pub display: String,
    /// Unit of measurement.
    #[serde(default)]
    pub unit: String,
    /// Expected range for display purposes.
    #[serde(default)]
    pub range: Option<(f64, f64)>,
    /// Warning threshold (warn if value drops below).
    #[serde(default)]
    pub warn_below: Option<f64>,
    /// Value type hint.
    #[serde(rename = "type", default)]
    pub value_type: Option<String>,
    /// Array length (if type is "array").
    #[serde(default)]
    pub length: Option<usize>,
}

/// Video feed information.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VideoFeedInfo {
    /// Feed name.
    pub name: String,
    /// Human-readable display name.
    #[serde(default)]
    pub display: String,
    /// TCP port for this video stream (also the UDP port if `transport`
    /// is set to "udp" or "auto" — the robot-side pipeline uses the same
    /// port number for both protocols by convention).
    pub port: u16,
    /// Resolution width.
    #[serde(default = "default_width")]
    pub width: u32,
    /// Resolution height.
    #[serde(default = "default_height")]
    pub height: u32,
    /// Frames per second.
    #[serde(default = "default_fps")]
    pub fps: u32,
    /// Whether this is a stereo feed.
    #[serde(default)]
    pub stereo: bool,
    /// Preferred transport for this feed: "tcp", "udp", or "auto".
    /// "auto" lets the headset pick — currently it prefers UDP if
    /// `udp_port` is also non-zero (Wi-Fi friendly), otherwise TCP.
    /// Defaults to "tcp" so legacy descriptors keep their old behavior.
    #[serde(default = "default_transport")]
    pub transport: String,
    /// Optional UDP port. If non-zero, the headset can choose UDP for
    /// this feed. If zero (default), only TCP is offered regardless of
    /// the `transport` field. The robot pipeline only opens a UDP
    /// listener when `VideoConfig.udp_port` is set, so this field is a
    /// pure descriptor-side advertisement of *what's available*.
    #[serde(default)]
    pub udp_port: u16,
    /// Codec family of the encoded stream: "h264" (AVC, default) or "hevc"
    /// (H.265). The headset uses this to pick the matching MediaCodec MIME
    /// (`video/avc` vs `video/hevc`) and codec-specific-data layout. Defaults
    /// to "h264" so descriptors that pre-date the field keep working.
    #[serde(default = "default_video_codec")]
    pub codec: String,
}

fn default_transport() -> String {
    "tcp".to_string()
}

fn default_video_codec() -> String {
    "h264".to_string()
}

fn default_width() -> u32 {
    1280
}
fn default_height() -> u32 {
    720
}
fn default_fps() -> u32 {
    30
}

/// Device-specific safety configuration.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DeviceSafetyConfig {
    /// Action on headset disconnect: "stop", "hold", "return_home".
    #[serde(default = "default_disconnect_action")]
    pub disconnect_action: String,
    /// Maximum time between commands before triggering disconnect action.
    #[serde(default = "default_command_timeout_ms")]
    pub command_timeout_ms: u64,
    /// Per-axis value limits: axis_name -> (min, max).
    #[serde(default)]
    pub limits: HashMap<String, (f64, f64)>,
}

fn default_disconnect_action() -> String {
    "stop".to_string()
}

fn default_command_timeout_ms() -> u64 {
    500
}

impl Default for DeviceSafetyConfig {
    fn default() -> Self {
        Self {
            disconnect_action: default_disconnect_action(),
            command_timeout_ms: default_command_timeout_ms(),
            limits: HashMap::new(),
        }
    }
}

impl DeviceSafetyConfig {
    /// Strongly-typed parse of the `disconnect_action` string field.
    /// Unknown values fall back to the safest option (`Stop`).
    pub fn parsed_disconnect_action(&self) -> DisconnectAction {
        match self.disconnect_action.as_str() {
            "hold" => DisconnectAction::Hold,
            "return_home" => DisconnectAction::ReturnHome,
            "stop" => DisconnectAction::Stop,
            other => {
                eprintln!("Unknown disconnect_action '{other}', defaulting to 'stop'");
                DisconnectAction::Stop
            }
        }
    }

    /// `command_timeout_ms` as a typed `Duration`.
    pub fn timeout(&self) -> Duration {
        Duration::from_millis(self.command_timeout_ms)
    }
}

/// What the device should do when the headset stops sending commands.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DisconnectAction {
    /// Send a neutral command and trigger emergency stop.
    Stop,
    /// Hold the last setpoint — driver keeps current position.
    Hold,
    /// Return to a safe "home" pose. Currently falls back to `Stop`
    /// until devices implement an explicit home-pose method.
    ReturnHome,
}
