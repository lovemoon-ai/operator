//! Bridge configuration: where to reach the robot-adapter plus XR-facing
//! network/video settings.
//!
//! Loadable from a legacy bridge-only YAML or a shared YAML with
//! `adapter_link` + `bridge` sections, and overridable from the CLI
//! (`--adapter-endpoint tcp:127.0.0.1:63910`).

use std::net::IpAddr;
use std::path::Path;
use std::str::FromStr;

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};

use teleop_protocol::Endpoint;

/// Default service name advertised over mDNS / UDP discovery.
pub const DEFAULT_NAME: &str = "xr-bridge";
/// Default TCP port for the XR command/pose channel.
pub const DEFAULT_POSE_PORT: u16 = 63901;
/// Default TCP port for the H.264 video stream.
pub const DEFAULT_VIDEO_PORT: u16 = 12345;
/// Default UDP port for discovery beacons.
pub const DEFAULT_DISCOVERY_PORT: u16 = 63900;
/// Default UDP port for the high-frequency pose data plane.
pub const DEFAULT_POSE_UDP_PORT: u16 = 63902;
/// Default TCP port for the dedicated telemetry stream.
pub const DEFAULT_TELEMETRY_PORT: u16 = 63903;

/// Top-level bridge configuration.
///
/// `Default` resolves the adapter endpoint to [`Endpoint::default`] (UDS) and
/// the XR-facing ports to their conventional defaults.
#[derive(Debug, Clone)]
pub struct BridgeConfig {
    /// Where the robot-adapter's boundary protocol is reachable. In the shared
    /// YAML format this comes from `adapter_link.endpoint`.
    pub adapter_endpoint: Endpoint,

    // ── XR-facing network ports (the side that talks to the headset). ──
    /// Human-readable service name (used in mDNS / UDP discovery beacons).
    pub name: String,
    /// TCP port the XR client connects to for commands (the pose channel).
    pub pose_port: u16,
    /// TCP port for the H.264 video stream.
    pub video_port: u16,
    /// UDP port for discovery beacons.
    pub discovery_port: u16,
    /// Optional headset IPs that should receive unicast discovery beacons.
    pub discovery_unicast_targets: Vec<IpAddr>,
    /// UDP port for the high-frequency pose data plane (drop-old by seq).
    pub pose_udp_port: u16,
    /// TCP port for the dedicated telemetry stream.
    pub telemetry_port: u16,
    /// Video relay configuration (RTSP → XR wire protocol). Empty = no video.
    pub video: VideoConfig,
}

/// Video relay configuration: a list of feeds the bridge pulls over RTSP and
/// re-publishes over the XR video wire protocol. Empty by default so a no-video
/// bridge run behaves exactly as before.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct VideoConfig {
    /// One entry per concurrent feed (e.g. wrist_left / wrist_right / head).
    #[serde(default)]
    pub feeds: Vec<VideoFeedConfig>,
}

/// One relayed video feed.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VideoFeedConfig {
    /// Feed identifier (e.g. "wrist_left"); surfaced to the headset.
    pub name: String,
    /// RTSP URL to pull from (e.g. `rtsp://127.0.0.1:8554/wrist_left`).
    pub rtsp_url: String,
    /// TCP port the headset connects to for this feed.
    pub tcp_port: u16,
    /// Optional UDP fan-out port. Omit (or 0) for TCP-only.
    #[serde(default)]
    pub udp_port: Option<u16>,
    /// Advertised resolution width (descriptor hint only — no transcode).
    #[serde(default = "default_video_width")]
    pub width: u32,
    /// Advertised resolution height.
    #[serde(default = "default_video_height")]
    pub height: u32,
    /// Advertised frames per second.
    #[serde(default = "default_video_fps")]
    pub fps: u32,
    /// Preferred transport advertised in the descriptor ("tcp" | "udp" | "auto").
    #[serde(default = "default_video_transport")]
    pub transport: String,
    /// Codec family the upstream RTSP stream carries: "h264" (default) or
    /// "hevc". The bridge never transcodes — this tells the relay which
    /// bitstream filter / muxer to copy through and how to classify NALs, and
    /// is advertised to the headset so it spins up the matching decoder. Omit
    /// for H.264 (back-compat with configs that pre-date the field).
    #[serde(default = "default_video_codec")]
    pub codec: String,
}

fn default_video_width() -> u32 {
    1280
}
fn default_video_height() -> u32 {
    720
}
fn default_video_fps() -> u32 {
    30
}
fn default_video_transport() -> String {
    "tcp".to_string()
}
fn default_video_codec() -> String {
    "h264".to_string()
}

impl Default for BridgeConfig {
    fn default() -> Self {
        Self {
            adapter_endpoint: Endpoint::default(),
            name: DEFAULT_NAME.to_string(),
            pose_port: DEFAULT_POSE_PORT,
            video_port: DEFAULT_VIDEO_PORT,
            discovery_port: DEFAULT_DISCOVERY_PORT,
            discovery_unicast_targets: Vec::new(),
            pose_udp_port: DEFAULT_POSE_UDP_PORT,
            telemetry_port: DEFAULT_TELEMETRY_PORT,
            video: VideoConfig::default(),
        }
    }
}

/// Shared config section for the bridge/adapter boundary connection.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
struct AdapterLinkConfigFile {
    /// Endpoint used by the adapter to listen and by the bridge to dial.
    #[serde(default)]
    endpoint: Option<String>,
}

/// Shared YAML envelope:
///
/// ```yaml
/// adapter_link:
///   endpoint: "tcp:127.0.0.1:63910"
/// bridge:
///   name: "xr-bridge"
///   video: { feeds: [] }
/// adapter:
///   ...
/// ```
#[derive(Debug, Clone, Deserialize, Default)]
struct SharedConfigFile {
    #[serde(default)]
    adapter_link: Option<AdapterLinkConfigFile>,
    #[serde(default)]
    bridge: Option<BridgeConfigFile>,
    #[serde(default)]
    adapter: Option<serde_yaml::Value>,
}

/// Serde shape used for legacy bridge YAML parsing and the `bridge:` section in
/// shared YAML. Mirrors [`BridgeConfig`] but stores the endpoint as a string so
/// the YAML stays human-friendly (`adapter_endpoint: "tcp:127.0.0.1:63910"`).
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
struct BridgeConfigFile {
    /// Legacy bridge-only endpoint key. New shared configs should prefer
    /// `adapter_link.endpoint`.
    #[serde(default)]
    adapter_endpoint: Option<String>,
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    pose_port: Option<u16>,
    #[serde(default)]
    video_port: Option<u16>,
    #[serde(default)]
    discovery_port: Option<u16>,
    #[serde(default)]
    discovery_unicast_targets: Option<Vec<IpAddr>>,
    #[serde(default)]
    pose_udp_port: Option<u16>,
    #[serde(default)]
    telemetry_port: Option<u16>,
    #[serde(default)]
    video: Option<VideoConfig>,
}

impl BridgeConfig {
    /// Load configuration from a YAML file at `path`.
    pub fn from_yaml_file(path: &Path) -> Result<Self> {
        let text = std::fs::read_to_string(path)
            .with_context(|| format!("reading config file {}", path.display()))?;
        Self::from_yaml_str(&text)
            .with_context(|| format!("parsing config file {}", path.display()))
    }

    /// Parse configuration from a YAML string.
    pub fn from_yaml_str(text: &str) -> Result<Self> {
        let shared: SharedConfigFile = serde_yaml::from_str(text).context("invalid YAML")?;
        if shared.bridge.is_some() || shared.adapter_link.is_some() || shared.adapter.is_some() {
            let mut cfg = BridgeConfig::default();
            if let Some(file) = shared.bridge {
                apply_bridge_config_file(&mut cfg, file)?;
            }
            if let Some(link) = shared.adapter_link {
                apply_adapter_link_config(&mut cfg, link)?;
            }
            return Ok(cfg);
        }

        let file: BridgeConfigFile = serde_yaml::from_str(text).context("invalid YAML")?;
        let mut cfg = BridgeConfig::default();
        apply_bridge_config_file(&mut cfg, file)?;
        Ok(cfg)
    }
}

fn apply_adapter_link_config(cfg: &mut BridgeConfig, link: AdapterLinkConfigFile) -> Result<()> {
    if let Some(ep) = link.endpoint {
        cfg.adapter_endpoint = Endpoint::from_str(&ep)
            .with_context(|| format!("invalid adapter_link.endpoint {ep:?}"))?;
    }
    Ok(())
}

fn apply_bridge_config_file(cfg: &mut BridgeConfig, file: BridgeConfigFile) -> Result<()> {
    if let Some(ep) = file.adapter_endpoint {
        cfg.adapter_endpoint =
            Endpoint::from_str(&ep).with_context(|| format!("invalid adapter_endpoint {ep:?}"))?;
    }
    if let Some(name) = file.name {
        cfg.name = name;
    }
    if let Some(p) = file.pose_port {
        cfg.pose_port = p;
    }
    if let Some(p) = file.video_port {
        cfg.video_port = p;
    }
    if let Some(p) = file.discovery_port {
        cfg.discovery_port = p;
    }
    if let Some(targets) = file.discovery_unicast_targets {
        cfg.discovery_unicast_targets = targets;
    }
    if let Some(p) = file.pose_udp_port {
        cfg.pose_udp_port = p;
    }
    if let Some(p) = file.telemetry_port {
        cfg.telemetry_port = p;
    }
    if let Some(v) = file.video {
        cfg.video = v;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::SocketAddr;

    #[test]
    fn defaults_to_uds() {
        let cfg = BridgeConfig::default();
        assert_eq!(cfg.adapter_endpoint, Endpoint::default());
    }

    #[test]
    fn parses_tcp_endpoint_from_yaml() {
        let yaml = "adapter_endpoint: \"tcp:127.0.0.1:63910\"\n";
        let cfg = BridgeConfig::from_yaml_str(yaml).unwrap();
        let expect: SocketAddr = "127.0.0.1:63910".parse().unwrap();
        assert_eq!(cfg.adapter_endpoint, Endpoint::Tcp(expect));
    }

    #[test]
    fn empty_yaml_yields_defaults() {
        let cfg = BridgeConfig::from_yaml_str("{}").unwrap();
        assert_eq!(cfg.adapter_endpoint, Endpoint::default());
        assert_eq!(cfg.pose_port, DEFAULT_POSE_PORT);
        assert_eq!(cfg.video_port, DEFAULT_VIDEO_PORT);
        assert_eq!(cfg.discovery_port, DEFAULT_DISCOVERY_PORT);
        assert!(cfg.discovery_unicast_targets.is_empty());
        assert_eq!(cfg.pose_udp_port, DEFAULT_POSE_UDP_PORT);
        assert_eq!(cfg.telemetry_port, DEFAULT_TELEMETRY_PORT);
        assert_eq!(cfg.name, DEFAULT_NAME);
        assert!(cfg.video.feeds.is_empty());
    }

    #[test]
    fn parses_video_feeds_from_yaml() {
        let yaml = "\
video:
  feeds:
    - name: wrist_left
      rtsp_url: \"rtsp://127.0.0.1:8554/wrist_left\"
      tcp_port: 12345
      udp_port: 22345
      width: 640
      height: 480
      fps: 30
      transport: udp
    - name: head
      rtsp_url: \"rtsp://127.0.0.1:8554/head\"
      tcp_port: 12347
";
        let cfg = BridgeConfig::from_yaml_str(yaml).unwrap();
        assert_eq!(cfg.video.feeds.len(), 2);

        let wl = &cfg.video.feeds[0];
        assert_eq!(wl.name, "wrist_left");
        assert_eq!(wl.rtsp_url, "rtsp://127.0.0.1:8554/wrist_left");
        assert_eq!(wl.tcp_port, 12345);
        assert_eq!(wl.udp_port, Some(22345));
        assert_eq!(wl.width, 640);
        assert_eq!(wl.height, 480);
        assert_eq!(wl.transport, "udp");
        // Codec defaults to h264 when the field is absent.
        assert_eq!(wl.codec, "h264");

        // Defaults fill in for the second feed.
        let head = &cfg.video.feeds[1];
        assert_eq!(head.name, "head");
        assert_eq!(head.tcp_port, 12347);
        assert_eq!(head.udp_port, None);
        assert_eq!(head.width, 1280);
        assert_eq!(head.height, 720);
        assert_eq!(head.fps, 30);
        assert_eq!(head.transport, "tcp");
        assert_eq!(head.codec, "h264");
    }

    #[test]
    fn parses_explicit_hevc_codec() {
        let yaml = "\
video:
  feeds:
    - name: head
      rtsp_url: \"rtsp://127.0.0.1:8554/head\"
      tcp_port: 12345
      codec: hevc
";
        let cfg = BridgeConfig::from_yaml_str(yaml).unwrap();
        assert_eq!(cfg.video.feeds[0].codec, "hevc");
    }

    #[test]
    fn parses_xr_ports_from_yaml() {
        let yaml = "\
name: \"My Bridge\"
pose_port: 1111
video_port: 2222
discovery_port: 3333
discovery_unicast_targets:
  - 10.79.151.145
pose_udp_port: 4444
telemetry_port: 5555
";
        let cfg = BridgeConfig::from_yaml_str(yaml).unwrap();
        assert_eq!(cfg.name, "My Bridge");
        assert_eq!(cfg.pose_port, 1111);
        assert_eq!(cfg.video_port, 2222);
        assert_eq!(cfg.discovery_port, 3333);
        assert_eq!(
            cfg.discovery_unicast_targets,
            vec![IpAddr::from([10, 79, 151, 145])]
        );
        assert_eq!(cfg.pose_udp_port, 4444);
        assert_eq!(cfg.telemetry_port, 5555);
    }

    #[test]
    fn parses_shared_yaml_bridge_section_and_adapter_link() {
        let yaml = r#"
adapter_link:
  endpoint: "tcp:127.0.0.1:63910"

adapter:
  device_type: "dummy"

bridge:
  name: "Head Camera"
  adapter_endpoint: "tcp:127.0.0.1:1"
  pose_port: 1111
  pose_udp_port: 2222
  telemetry_port: 3333
  discovery_port: 4444
  video:
    feeds:
      - name: head
        rtsp_url: "rtsp://10.79.252.23:8554/head"
        tcp_port: 12345
        udp_port: 22345
        width: 1920
        height: 1080
        fps: 60
        transport: udp
"#;
        let cfg = BridgeConfig::from_yaml_str(yaml).unwrap();

        assert_eq!(
            cfg.adapter_endpoint,
            Endpoint::Tcp("127.0.0.1:63910".parse().unwrap())
        );
        assert_eq!(cfg.name, "Head Camera");
        assert_eq!(cfg.pose_port, 1111);
        assert_eq!(cfg.pose_udp_port, 2222);
        assert_eq!(cfg.telemetry_port, 3333);
        assert_eq!(cfg.discovery_port, 4444);
        assert_eq!(cfg.video.feeds.len(), 1);

        let head = &cfg.video.feeds[0];
        assert_eq!(head.name, "head");
        assert_eq!(head.rtsp_url, "rtsp://10.79.252.23:8554/head");
        assert_eq!(head.tcp_port, 12345);
        assert_eq!(head.udp_port, Some(22345));
        assert_eq!(head.width, 1920);
        assert_eq!(head.height, 1080);
        assert_eq!(head.fps, 60);
        assert_eq!(head.transport, "udp");
    }

    #[test]
    fn shipped_default_config_file_parses() {
        let path = std::path::Path::new(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../configs/xr-bridge-default.yaml"
        ));
        let cfg = BridgeConfig::from_yaml_file(path).expect("shipped config parses");

        assert_eq!(cfg.name, "xr-bridge");
        assert_eq!(cfg.video.feeds.len(), 3);
    }
}
