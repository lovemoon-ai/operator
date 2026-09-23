//! Host-declared headset capture streams.
//!
//! The host declares the capture-stream *envelope* in the descriptor
//! ([`CaptureStreamsConfig`], `DeviceDescriptor.capture_streams`): which
//! headset streams it wants and their upper limits. The user grants or denies
//! that envelope on the headset. Two ctrl-channel commands then run beside
//! `Hello` / `Blueprint` on the XR command TCP connection:
//!
//! * [`StreamsStatus`] (headset → host): the effective state of every declared
//!   stream and local task, sent after negotiation, permission changes, and
//!   every [`StreamsControl`].
//! * [`StreamsControl`] (host → headset): adjust parameters inside the granted
//!   envelope. The headset clips out-of-envelope values and reports `limit`.
//!
//! Granted media travels on the host session itself: xr-bridge injects a
//! session-owned [`MediaTransport`] (`DeviceDescriptor.media`) for a capable
//! headset; host applications never declare a transport.
//!
//! These are deliberately not Blueprint messages. All structs are
//! `#[serde(default)]`-tolerant and accept unknown fields so old and new
//! peers interoperate.

use std::collections::{BTreeMap, HashSet};

use serde::{Deserialize, Serialize};

/// Headset `Hello.capabilities` entry: the headset understands
/// `capture_streams`, `StreamsStatus`, and `StreamsControl`.
pub const CAPTURE_STREAMS_CAPABILITY: &str = "capture_streams_v1";
/// Current `capture_streams.schema_version`.
pub const CAPTURE_STREAMS_SCHEMA_VERSION: u16 = 1;
/// Frame format of the session-owned media transport (`MediaTransport`).
pub const MEDIA_PROTOCOL: &str = "olcp.v1";
/// Known capture stream vocabulary (OLCP stream names).
pub const CAPTURE_STREAM_NAMES: [&str; 6] = [
    "rgb.hevc",
    "depth.u16",
    "head_pose.json",
    "controller_pose.json",
    "controller_input.json",
    "hand_joints.json",
];
/// Valid values of `capture_streams.streams[].eye` and `StreamStatus.eye`.
pub const CAPTURE_STREAM_EYES: [&str; 3] = ["left", "mono", "stereo"];
/// Valid `capture_streams.local_tasks[].kind` values.
pub const LOCAL_TASK_KINDS: [&str; 2] = ["record", "upload"];

/// Ctrl command name of the headset → host status report.
pub const STREAMS_STATUS_COMMAND: &str = "StreamsStatus";
/// Ctrl command name of the host → headset in-envelope adjustment.
pub const STREAMS_CONTROL_COMMAND: &str = "StreamsControl";
pub const STREAMS_STATUS_SCHEMA: &str = "operator.streams_status.v1";
pub const STREAMS_CONTROL_SCHEMA: &str = "operator.streams_control.v1";

/// `StreamStatus.state` vocabulary.
pub const STREAM_STATES: [&str; 4] = ["pending", "active", "paused", "denied"];
/// `LocalTaskStatus.state` vocabulary.
pub const LOCAL_TASK_STATES: [&str; 5] = ["pending", "running", "idle", "denied", "failed"];
/// Optional `reason` vocabulary shared by streams and local tasks.
pub const STREAMS_REASONS: [&str; 5] = [
    "permission_denied",
    "revoked",
    "unsupported",
    "limit",
    "unknown_endpoint",
];

/// `Hello.capabilities` entry a headset advertises for each stream it can
/// produce, e.g. `stream.rgb.hevc`.
pub fn stream_capability(name: &str) -> String {
    format!("stream.{name}")
}

fn default_capture_schema_version() -> u16 {
    CAPTURE_STREAMS_SCHEMA_VERSION
}

/// `DeviceDescriptor.capture_streams`: the set of headset streams the host
/// requests and their upper limits (the permission envelope).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct CaptureStreamsConfig {
    #[serde(default = "default_capture_schema_version")]
    pub schema_version: u16,
    #[serde(default)]
    pub streams: Vec<CaptureStream>,
    #[serde(default)]
    pub local_tasks: Vec<LocalTask>,
}

impl Default for CaptureStreamsConfig {
    fn default() -> Self {
        Self {
            schema_version: CAPTURE_STREAMS_SCHEMA_VERSION,
            streams: Vec::new(),
            local_tasks: Vec::new(),
        }
    }
}

/// `DeviceDescriptor.media`: the host session's own media transport.
///
/// Injected by xr-bridge into the descriptor it sends to a headset that
/// advertised `capture_streams_v1` when the host declares `capture_streams`;
/// never authored by a host application. The address is always the connected
/// peer. `auth_token` is issued per headset ctrl connection and is valid only
/// while that connection owns the session. Frames are OLCP: the headset pushes
/// to `push_port` (media_up) and pulls results from `result_port` (media_down).
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct MediaTransport {
    #[serde(default)]
    pub protocol: String,
    #[serde(default)]
    pub push_port: u16,
    #[serde(default)]
    pub result_port: u16,
    #[serde(default)]
    pub auth_token: String,
}

/// One declared stream and its envelope.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct CaptureStream {
    #[serde(default)]
    pub name: String,
    /// Only affects status/prompt priority; a denial never blocks the session.
    #[serde(default)]
    pub required: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_hz: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_bitrate_bps: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub eye: Option<String>,
}

/// A headset-local task the host asks for (`record` or `upload`).
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct LocalTask {
    #[serde(default)]
    pub kind: String,
    /// Record container; the headset treats `None` as `spatialmp4`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub container: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub streams: Vec<String>,
    /// Name of a headset-local, verified ingest endpoint. Never a URL.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub endpoint_ref: Option<String>,
}

impl CaptureStreamsConfig {
    /// Reject declarations the headset could never honour. Unknown stream
    /// names are allowed: the headset reports them `unsupported`.
    pub fn validate(&self) -> Result<(), String> {
        if self.schema_version != CAPTURE_STREAMS_SCHEMA_VERSION {
            return Err(format!(
                "unsupported capture_streams schema_version {}; expected {CAPTURE_STREAMS_SCHEMA_VERSION}",
                self.schema_version
            ));
        }
        let mut names = HashSet::with_capacity(self.streams.len());
        for stream in &self.streams {
            if stream.name.trim().is_empty() {
                return Err("capture stream name must not be empty".to_string());
            }
            if !names.insert(stream.name.as_str()) {
                return Err(format!("duplicate capture stream {:?}", stream.name));
            }
            if stream.max_hz.is_some_and(|hz| !hz.is_finite() || hz <= 0.0) {
                return Err(format!(
                    "capture stream {:?} max_hz must be finite and > 0",
                    stream.name
                ));
            }
            if stream.max_bitrate_bps == Some(0) {
                return Err(format!(
                    "capture stream {:?} max_bitrate_bps must be > 0",
                    stream.name
                ));
            }
            validate_eye(stream.eye.as_deref())?;
        }
        let mut kinds = HashSet::with_capacity(self.local_tasks.len());
        for task in &self.local_tasks {
            if !LOCAL_TASK_KINDS.contains(&task.kind.as_str()) {
                return Err(format!("unknown local task kind {:?}", task.kind));
            }
            if !kinds.insert(task.kind.as_str()) {
                return Err(format!("duplicate local task kind {:?}", task.kind));
            }
            if task.kind == "upload" && task.endpoint_ref.is_none() {
                return Err("upload local task requires endpoint_ref".to_string());
            }
            if let Some(endpoint_ref) = &task.endpoint_ref {
                if !is_endpoint_name(endpoint_ref) {
                    return Err(format!(
                        "endpoint_ref {endpoint_ref:?} must name a headset-local endpoint, not a URL or host"
                    ));
                }
            }
            if task.streams.iter().any(|name| name.trim().is_empty()) {
                return Err(format!(
                    "local task {:?} stream names must not be empty",
                    task.kind
                ));
            }
        }
        Ok(())
    }
}

fn is_endpoint_name(value: &str) -> bool {
    !value.trim().is_empty() && !value.contains('/') && !value.contains(':')
}

fn validate_eye(eye: Option<&str>) -> Result<(), String> {
    match eye {
        Some(eye) if !CAPTURE_STREAM_EYES.contains(&eye) => Err(format!(
            "eye {eye:?} must be one of {CAPTURE_STREAM_EYES:?}"
        )),
        _ => Ok(()),
    }
}

fn validate_reason(reason: Option<&str>) -> Result<(), String> {
    match reason {
        Some(reason) if !STREAMS_REASONS.contains(&reason) => Err(format!(
            "reason {reason:?} must be one of {STREAMS_REASONS:?}"
        )),
        _ => Ok(()),
    }
}

/// `StreamsStatus` ctrl command (headset → host).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct StreamsStatus {
    pub schema: String,
    #[serde(default)]
    pub streams: BTreeMap<String, StreamStatus>,
    #[serde(default)]
    pub local_tasks: BTreeMap<String, LocalTaskStatus>,
}

/// Effective state of one declared stream.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct StreamStatus {
    #[serde(default)]
    pub state: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub hz: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bitrate_bps: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub eye: Option<String>,
}

/// Effective state of one declared local task, keyed by task kind.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct LocalTaskStatus {
    #[serde(default)]
    pub state: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
}

impl StreamsStatus {
    pub fn validate(&self) -> Result<(), String> {
        if self.schema != STREAMS_STATUS_SCHEMA {
            return Err(format!(
                "unsupported StreamsStatus schema {:?}; expected {STREAMS_STATUS_SCHEMA}",
                self.schema
            ));
        }
        for (name, status) in &self.streams {
            if name.trim().is_empty() {
                return Err("StreamsStatus stream name must not be empty".to_string());
            }
            if !STREAM_STATES.contains(&status.state.as_str()) {
                return Err(format!(
                    "stream {name:?} state {:?} must be one of {STREAM_STATES:?}",
                    status.state
                ));
            }
            validate_reason(status.reason.as_deref())?;
            if status.hz.is_some_and(|hz| !hz.is_finite() || hz < 0.0) {
                return Err(format!("stream {name:?} hz must be finite and >= 0"));
            }
            validate_eye(status.eye.as_deref())?;
        }
        for (kind, status) in &self.local_tasks {
            if kind.trim().is_empty() {
                return Err("StreamsStatus local task kind must not be empty".to_string());
            }
            if !LOCAL_TASK_STATES.contains(&status.state.as_str()) {
                return Err(format!(
                    "local task {kind:?} state {:?} must be one of {LOCAL_TASK_STATES:?}",
                    status.state
                ));
            }
            validate_reason(status.reason.as_deref())?;
        }
        Ok(())
    }
}

/// `StreamsControl` ctrl command (host → headset). Every field is optional;
/// omitted fields keep their current value.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct StreamsControl {
    pub schema: String,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub streams: BTreeMap<String, StreamControl>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub local_tasks: BTreeMap<String, LocalTaskControl>,
}

impl Default for StreamsControl {
    fn default() -> Self {
        Self {
            schema: STREAMS_CONTROL_SCHEMA.to_string(),
            streams: BTreeMap::new(),
            local_tasks: BTreeMap::new(),
        }
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct StreamControl {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub hz: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bitrate_bps: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub paused: Option<bool>,
}

/// Start (`running: true`) or stop a declared local task.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct LocalTaskControl {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub running: Option<bool>,
}

impl StreamsControl {
    pub fn validate(&self) -> Result<(), String> {
        if self.schema != STREAMS_CONTROL_SCHEMA {
            return Err(format!(
                "unsupported StreamsControl schema {:?}; expected {STREAMS_CONTROL_SCHEMA}",
                self.schema
            ));
        }
        for (name, control) in &self.streams {
            if name.trim().is_empty() {
                return Err("StreamsControl stream name must not be empty".to_string());
            }
            if control.hz.is_some_and(|hz| !hz.is_finite() || hz <= 0.0) {
                return Err(format!("stream {name:?} hz must be finite and > 0"));
            }
            if control.bitrate_bps == Some(0) {
                return Err(format!("stream {name:?} bitrate_bps must be > 0"));
            }
        }
        if let Some(kind) = self
            .local_tasks
            .keys()
            .find(|kind| !LOCAL_TASK_KINDS.contains(&kind.as_str()))
        {
            return Err(format!("unknown local task kind {kind:?}"));
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn rfc_capture_streams() -> serde_json::Value {
        json!({
            "schema_version": 1,
            "streams": [
                {"name": "rgb.hevc", "required": true, "max_hz": 4, "max_bitrate_bps": 2000000, "eye": "left"},
                {"name": "depth.u16", "required": false, "max_hz": 5}
            ],
            "local_tasks": [
                {"kind": "record", "container": "spatialmp4", "streams": ["rgb.hevc", "head_pose.json"]},
                {"kind": "upload", "endpoint_ref": "lab-ingest"}
            ]
        })
    }

    fn capture(value: serde_json::Value) -> CaptureStreamsConfig {
        serde_json::from_value(value).unwrap()
    }

    #[test]
    fn rfc_capture_streams_round_trip_byte_for_byte() {
        let value = rfc_capture_streams();
        let config = capture(value.clone());
        config.validate().unwrap();
        assert_eq!(config.streams[0].max_hz, Some(4.0));
        assert_eq!(config.streams[1].eye, None);
        assert_eq!(
            config.local_tasks[1].endpoint_ref.as_deref(),
            Some("lab-ingest")
        );
        let mut expected = value;
        // f64 fields serialize as JSON floats; everything else is identical.
        expected["streams"][0]["max_hz"] = json!(4.0);
        expected["streams"][1]["max_hz"] = json!(5.0);
        assert_eq!(serde_json::to_value(&config).unwrap(), expected);
    }

    #[test]
    fn capture_streams_defaults_and_unknown_fields_are_tolerated() {
        // A retired `sink` block from older hosts is ignored like any unknown field.
        let config = capture(json!({
            "sink": {"push_port": 0},
            "streams": [{"name": "future.stream", "future_field": 1}],
            "future_block": {"x": 1}
        }));
        config.validate().unwrap();
        assert_eq!(config.schema_version, CAPTURE_STREAMS_SCHEMA_VERSION);
        assert!(serde_json::to_value(&config).unwrap().get("sink").is_none());
        assert!(!config.streams[0].required);
        assert_eq!(
            serde_json::to_value(&config.streams[0]).unwrap(),
            json!({"name": "future.stream", "required": false})
        );
        assert_eq!(
            serde_json::to_value(CaptureStreamsConfig::default()).unwrap(),
            json!({"schema_version": 1, "streams": [], "local_tasks": []})
        );
    }

    #[test]
    fn capture_streams_validation_rejects_invalid_envelopes() {
        let cases = [
            (json!({"schema_version": 2}), "schema_version"),
            (json!({"streams": [{"name": " "}]}), "empty"),
            (
                json!({"streams": [{"name": "rgb.hevc"}, {"name": "rgb.hevc"}]}),
                "duplicate",
            ),
            (
                json!({"streams": [{"name": "rgb.hevc", "max_hz": 0}]}),
                "max_hz",
            ),
            (
                json!({"streams": [{"name": "rgb.hevc", "max_hz": -1.5}]}),
                "max_hz",
            ),
            (
                json!({"streams": [{"name": "rgb.hevc", "max_bitrate_bps": 0}]}),
                "max_bitrate_bps",
            ),
            (
                json!({"streams": [{"name": "rgb.hevc", "eye": "right"}]}),
                "eye",
            ),
            (
                json!({"local_tasks": [{"kind": "stream"}]}),
                "unknown local task",
            ),
            (
                json!({"local_tasks": [{"kind": "record"}, {"kind": "record"}]}),
                "duplicate local task",
            ),
            (json!({"local_tasks": [{"kind": "upload"}]}), "endpoint_ref"),
            (
                json!({"local_tasks": [{"kind": "upload", "endpoint_ref": "https://x.example"}]}),
                "not a URL",
            ),
            (
                json!({"local_tasks": [{"kind": "upload", "endpoint_ref": "10.0.0.2:9000"}]}),
                "not a URL",
            ),
            (
                json!({"local_tasks": [{"kind": "upload", "endpoint_ref": "lab/ingest"}]}),
                "not a URL",
            ),
            (
                json!({"local_tasks": [{"kind": "record", "streams": [""]}]}),
                "must not be empty",
            ),
        ];
        for (value, expected) in cases {
            let error = capture(value.clone()).validate().unwrap_err();
            assert!(error.contains(expected), "{value}: {error}");
        }
        let mut non_finite = capture(json!({"streams": [{"name": "rgb.hevc"}]}));
        non_finite.streams[0].max_hz = Some(f64::NAN);
        assert!(non_finite.validate().unwrap_err().contains("max_hz"));
    }

    #[test]
    fn media_transport_round_trips() {
        let value = json!({"protocol": MEDIA_PROTOCOL, "push_port": 63905, "result_port": 63906, "auth_token": "t"});
        let media: MediaTransport = serde_json::from_value(value.clone()).unwrap();
        assert_eq!(media.push_port, 63905);
        assert_eq!(serde_json::to_value(&media).unwrap(), value);
    }

    #[test]
    fn stream_capability_prefixes_stream_names() {
        assert_eq!(stream_capability("rgb.hevc"), "stream.rgb.hevc");
        assert!(CAPTURE_STREAM_NAMES.contains(&"hand_joints.json"));
    }

    #[test]
    fn rfc_streams_status_parses_validates_and_round_trips() {
        let value = json!({
            "schema": STREAMS_STATUS_SCHEMA,
            "streams": {
                "rgb.hevc": {"state": "active", "hz": 4.0, "bitrate_bps": 2000000, "eye": "left"},
                "depth.u16": {"state": "denied", "reason": "permission_denied"}
            },
            "local_tasks": {
                "record": {"state": "running"},
                "upload": {"state": "denied", "reason": "unknown_endpoint"}
            }
        });
        let status: StreamsStatus = serde_json::from_value(value.clone()).unwrap();
        status.validate().unwrap();
        assert_eq!(status.streams["rgb.hevc"].bitrate_bps, Some(2_000_000));
        assert_eq!(serde_json::to_value(&status).unwrap(), value);
        // BTreeMap keys serialize deterministically.
        let text = serde_json::to_string(&status).unwrap();
        assert!(text.find("depth.u16").unwrap() < text.find("rgb.hevc").unwrap());
    }

    #[test]
    fn streams_status_validation_rejects_bad_vocabulary() {
        let status = |streams: serde_json::Value, local_tasks: serde_json::Value| {
            serde_json::from_value::<StreamsStatus>(json!({
                "schema": STREAMS_STATUS_SCHEMA,
                "streams": streams,
                "local_tasks": local_tasks,
            }))
            .unwrap()
        };
        let cases = [
            (
                status(json!({"rgb.hevc": {"state": "on"}}), json!({})),
                "state",
            ),
            (
                status(
                    json!({"rgb.hevc": {"state": "active", "reason": "busy"}}),
                    json!({}),
                ),
                "reason",
            ),
            (
                status(
                    json!({"rgb.hevc": {"state": "active", "hz": -1.0}}),
                    json!({}),
                ),
                "hz",
            ),
            (
                status(
                    json!({"rgb.hevc": {"state": "active", "eye": "both"}}),
                    json!({}),
                ),
                "eye",
            ),
            (status(json!({"": {"state": "active"}}), json!({})), "empty"),
            (
                status(json!({}), json!({"record": {"state": "active"}})),
                "state",
            ),
            (
                status(
                    json!({}),
                    json!({"record": {"state": "failed", "reason": "disk"}}),
                ),
                "reason",
            ),
            (status(json!({}), json!({"": {"state": "idle"}})), "empty"),
        ];
        for (status, expected) in cases {
            let error = status.validate().unwrap_err();
            assert!(error.contains(expected), "{status:?}: {error}");
        }
        let mut wrong_schema = status(json!({}), json!({}));
        wrong_schema.schema = "operator.streams_status.v2".to_string();
        assert!(wrong_schema.validate().unwrap_err().contains("schema"));
        // `limit` accompanies an active stream whose parameters were clipped.
        status(
            json!({"rgb.hevc": {"state": "active", "reason": "limit", "hz": 0.0}}),
            json!({"upload": {"state": "pending"}}),
        )
        .validate()
        .unwrap();
    }

    #[test]
    fn rfc_streams_control_round_trips_and_validates() {
        let value = json!({
            "schema": STREAMS_CONTROL_SCHEMA,
            "streams": {"rgb.hevc": {"hz": 2.0, "bitrate_bps": 1000000, "paused": false}},
            "local_tasks": {"record": {"running": true}}
        });
        let control: StreamsControl = serde_json::from_value(value.clone()).unwrap();
        control.validate().unwrap();
        assert_eq!(serde_json::to_value(&control).unwrap(), value);
        assert_eq!(
            serde_json::to_value(StreamsControl::default()).unwrap(),
            json!({"schema": STREAMS_CONTROL_SCHEMA})
        );

        let invalid = [
            (json!({"streams": {"rgb.hevc": {"hz": 0}}}), "hz"),
            (
                json!({"streams": {"rgb.hevc": {"bitrate_bps": 0}}}),
                "bitrate_bps",
            ),
            (json!({"streams": {" ": {"paused": true}}}), "empty"),
            (
                json!({"local_tasks": {"stream": {"running": true}}}),
                "unknown local task",
            ),
        ];
        for (mut value, expected) in invalid {
            value["schema"] = json!(STREAMS_CONTROL_SCHEMA);
            let control: StreamsControl = serde_json::from_value(value.clone()).unwrap();
            let error = control.validate().unwrap_err();
            assert!(error.contains(expected), "{value}: {error}");
        }
        let wrong_schema = StreamsControl {
            schema: STREAMS_STATUS_SCHEMA.to_string(),
            ..StreamsControl::default()
        };
        assert!(wrong_schema.validate().unwrap_err().contains("schema"));
    }
}
