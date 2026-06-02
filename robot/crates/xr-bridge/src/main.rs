//! xr-bridge binary entry point.
//!
//! Normal mode connects to a robot-adapter, performs the handshake, then brings
//! up the XR-facing network stack and runs it concurrently:
//!
//! * connect to the adapter, `handshake()` → negotiated `DeviceDescriptor`,
//! * build the command `watch<Option<TimedCommand>>` (fed by pose_server +
//!   pose_udp_server, drained by the forward loop) and the XR-facing
//!   telemetry `watch<DeviceTelemetry>` (fed by the telemetry fan-in, read by
//!   pose_server + telemetry_server),
//! * spawn the telemetry fan-in (adapter watch → bridge telemetry watch),
//! * run discovery, pose_server, pose_udp_server, telemetry_server, and the
//!   forward loop (which owns the `AdapterClient`) under `tokio::try_join!`.
//!
//! `--video-only` skips the adapter handshake and synthesizes a descriptor from
//! the bridge config so a headset can consume RTSP-relayed video without a
//! robot-adapter process.

use std::path::PathBuf;
use std::str::FromStr;
use std::sync::atomic::AtomicU32;
use std::sync::Arc;

use anyhow::{bail, Context, Result};
use clap::Parser;
use tokio::sync::watch;
use tracing_subscriber::EnvFilter;

use teleop_protocol::{
    ControlSchema, DeviceDescriptor, DeviceInfo, DeviceTelemetry, Endpoint, VideoFeedInfo,
};
use xr_bridge::adapter_client::AdapterClient;
use xr_bridge::config::{BridgeConfig, VideoFeedConfig};
use xr_bridge::pose_udp_server::UdpDropStats;
use xr_bridge::video::{Codec, VideoFeed};
use xr_bridge::wire_runtime::TimedCommand;
use xr_bridge::{
    discovery, forward, latency, pose_server, pose_udp_server, runtime, telemetry_server, video,
};

/// XR-facing bridge: adapter-backed control path plus optional standalone video relay.
#[derive(Debug, Parser)]
#[command(name = "xr-bridge", version, about)]
struct Cli {
    /// Path to a YAML config file.
    #[arg(long)]
    config: Option<PathBuf>,

    /// Adapter endpoint, e.g. `uds:/tmp/teleop-adapter.sock` or
    /// `tcp:127.0.0.1:63910`. Overrides the config file value when set.
    #[arg(long)]
    adapter_endpoint: Option<String>,

    /// Run without robot-adapter and advertise only bridge-configured video feeds.
    #[arg(long)]
    video_only: bool,
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")),
        )
        .init();

    let cli = Cli::parse();

    // Start from config file (if any) or defaults, then apply CLI overrides.
    let mut config = match &cli.config {
        Some(path) => BridgeConfig::from_yaml_file(path)?,
        None => BridgeConfig::default(),
    };

    if cli.video_only {
        if cli.adapter_endpoint.is_some() {
            tracing::warn!("Ignoring --adapter-endpoint because --video-only does not connect to robot-adapter");
        }
        run_video_only_mode(config).await
    } else {
        if let Some(ep) = &cli.adapter_endpoint {
            config.adapter_endpoint = Endpoint::from_str(ep)
                .with_context(|| format!("invalid --adapter-endpoint {ep:?}"))?;
        }
        run_adapter_mode(config).await
    }
}

async fn run_adapter_mode(config: BridgeConfig) -> Result<()> {
    tracing::info!("Connecting to adapter at {}", config.adapter_endpoint);
    let mut client = AdapterClient::connect(&config.adapter_endpoint).await?;

    let mut descriptor = client.handshake().await.context("handshake failed")?;
    tracing::info!(
        "Connected. Device: {} ({}), {} axes / {} buttons / {} poses",
        descriptor.device.name,
        descriptor.device.device_type,
        descriptor.control_schema.axes.len(),
        descriptor.control_schema.buttons.len(),
        descriptor.control_schema.poses.len(),
    );

    append_video_feed_infos(&mut descriptor, &config.video.feeds);
    let video_feeds = video_feed_relays(&config.video.feeds);
    log_video_feeds(&video_feeds);

    let device_type = descriptor.device.device_type.clone();
    let device_name = descriptor.device.name.clone();
    let descriptor = Arc::new(descriptor);

    // Grab the adapter telemetry receiver BEFORE moving the client into the
    // forward loop.
    let adapter_telemetry = client.telemetry();

    // ── Channels shared across the XR-facing servers. ──
    // Command watch: latest-only so a slow consumer can never head-of-line
    // block. Fed by pose_server + pose_udp_server, drained by `forward`.
    let (device_cmd_tx, device_cmd_rx) = watch::channel::<Option<TimedCommand>>(None);
    // XR-facing telemetry watch: fed by the fan-in, read by pose_server +
    // telemetry_server.
    let (telemetry_tx, telemetry_rx) = watch::channel(DeviceTelemetry::default());

    // Control-path latency recorder, shared session token, UDP drop counters.
    let latency = latency::LatencyRecorder::new();
    let session_token = Arc::new(AtomicU32::new(0));
    let udp_stats = UdpDropStats::new();

    // Telemetry fan-in: adapter watch → bridge telemetry watch.
    tokio::spawn(runtime::telemetry_fanin(adapter_telemetry, telemetry_tx));

    tracing::info!(
        "XR network up: pose={} pose_udp={} telemetry={} discovery={}",
        config.pose_port,
        config.pose_udp_port,
        config.telemetry_port,
        config.discovery_port,
    );

    // Run all subsystems concurrently. The forward loop owns the client.
    tokio::try_join!(
        discovery::run(&config, &device_type, &device_name),
        pose_server::run(
            config.pose_port,
            descriptor.clone(),
            device_cmd_tx.clone(),
            telemetry_rx.clone(),
            latency.clone(),
        ),
        pose_udp_server::run(
            config.pose_udp_port,
            device_cmd_tx,
            latency.clone(),
            session_token,
            udp_stats,
        ),
        telemetry_server::run(config.telemetry_port, telemetry_rx),
        forward::run(descriptor, device_cmd_rx, client),
        latency::run_aggregator(latency.clone()),
        // Skips immediately (Ok) when no feeds are configured, so a no-video
        // bridge run is unaffected.
        video::run(video_feeds),
    )?;

    Ok(())
}

async fn run_video_only_mode(config: BridgeConfig) -> Result<()> {
    let descriptor = build_video_only_descriptor(&config)?;
    let video_feeds = video_feed_relays(&config.video.feeds);
    log_video_feeds(&video_feeds);

    let device_type = descriptor.device.device_type.clone();
    let device_name = descriptor.device.name.clone();
    let descriptor = Arc::new(descriptor);

    let (device_cmd_tx, _device_cmd_rx) = watch::channel::<Option<TimedCommand>>(None);
    let (_telemetry_tx, telemetry_rx) = watch::channel(DeviceTelemetry::default());
    let latency = latency::LatencyRecorder::new();
    let session_token = Arc::new(AtomicU32::new(0));
    let udp_stats = UdpDropStats::new();

    tracing::info!(
        "XR video-only network up: pose={} pose_udp={} telemetry={} discovery={}",
        config.pose_port,
        config.pose_udp_port,
        config.telemetry_port,
        config.discovery_port,
    );

    tokio::try_join!(
        discovery::run(&config, &device_type, &device_name),
        pose_server::run(
            config.pose_port,
            descriptor.clone(),
            device_cmd_tx.clone(),
            telemetry_rx.clone(),
            latency.clone(),
        ),
        pose_udp_server::run(
            config.pose_udp_port,
            device_cmd_tx,
            latency.clone(),
            session_token,
            udp_stats,
        ),
        telemetry_server::run(config.telemetry_port, telemetry_rx),
        latency::run_aggregator(latency.clone()),
        video::run(video_feeds),
    )?;

    Ok(())
}

fn build_video_only_descriptor(config: &BridgeConfig) -> Result<DeviceDescriptor> {
    if config.video.feeds.is_empty() {
        bail!("--video-only requires at least one video.feeds entry in the bridge config");
    }

    let mut descriptor = DeviceDescriptor {
        device: DeviceInfo {
            device_type: "video_only".to_string(),
            name: config.name.clone(),
            icon: "camera".to_string(),
            model_url: String::new(),
        },
        control_schema: ControlSchema::default(),
        input_mapping: Vec::new(),
        telemetry_schema: Default::default(),
        video_feeds: Vec::new(),
        safety: Default::default(),
    };
    append_video_feed_infos(&mut descriptor, &config.video.feeds);
    Ok(descriptor)
}

fn video_feed_relays(feeds: &[VideoFeedConfig]) -> Vec<VideoFeed> {
    feeds.iter().map(feed_config_to_relay).collect()
}

fn append_video_feed_infos(descriptor: &mut DeviceDescriptor, feeds: &[VideoFeedConfig]) {
    for fc in feeds {
        descriptor.video_feeds.push(feed_config_to_info(fc));
    }
}

fn log_video_feeds(video_feeds: &[VideoFeed]) {
    if !video_feeds.is_empty() {
        tracing::info!(
            "Video relay: advertising {} feed(s): {}",
            video_feeds.len(),
            video_feeds
                .iter()
                .map(|f| f.name.as_str())
                .collect::<Vec<_>>()
                .join(", "),
        );
    }
}

/// Map a config feed to the relay's runtime `VideoFeed`.
fn feed_config_to_relay(fc: &VideoFeedConfig) -> VideoFeed {
    VideoFeed {
        name: fc.name.clone(),
        rtsp_url: fc.rtsp_url.clone(),
        tcp_port: fc.tcp_port,
        // Treat 0 as "no UDP" too, matching descriptor conventions.
        udp_port: fc.udp_port.filter(|&p| p != 0),
        codec: Codec::parse(&fc.codec),
    }
}

/// Map a config feed to the descriptor's `VideoFeedInfo` advertised to the headset.
fn feed_config_to_info(fc: &VideoFeedConfig) -> VideoFeedInfo {
    VideoFeedInfo {
        name: fc.name.clone(),
        display: fc.name.clone(),
        port: fc.tcp_port,
        width: fc.width,
        height: fc.height,
        fps: fc.fps,
        stereo: false,
        transport: fc.transport.clone(),
        udp_port: fc.udp_port.unwrap_or(0),
        // Normalise to the lower-case wire name so the headset's MIME lookup
        // is exact regardless of how the YAML spelled it.
        codec: Codec::parse(&fc.codec).as_str().to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn video_only_requires_at_least_one_feed() {
        let cfg = BridgeConfig::default();

        let err = build_video_only_descriptor(&cfg).unwrap_err().to_string();

        assert!(err.contains("video.feeds"));
    }

    #[test]
    fn video_only_descriptor_is_empty_shell_with_configured_video() {
        let cfg = BridgeConfig::from_yaml_str(
            r#"
name: "head-camera"
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
"#,
        )
        .unwrap();

        let descriptor = build_video_only_descriptor(&cfg).unwrap();

        assert_eq!(descriptor.device.device_type, "video_only");
        assert_eq!(descriptor.device.name, "head-camera");
        assert!(descriptor.control_schema.axes.is_empty());
        assert!(descriptor.control_schema.buttons.is_empty());
        assert!(descriptor.control_schema.poses.is_empty());
        assert!(descriptor.input_mapping.is_empty());
        assert!(descriptor.telemetry_schema.values.is_empty());
        assert_eq!(descriptor.video_feeds.len(), 1);

        let feed = &descriptor.video_feeds[0];
        assert_eq!(feed.name, "head");
        assert_eq!(feed.port, 12345);
        assert_eq!(feed.udp_port, 22345);
        assert_eq!(feed.width, 1920);
        assert_eq!(feed.height, 1080);
        assert_eq!(feed.fps, 60);
        assert_eq!(feed.transport, "udp");
    }
}
