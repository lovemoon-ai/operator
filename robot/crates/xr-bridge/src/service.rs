//! Reusable XR-facing bridge service entry points.
//!
//! The `xr-bridge` binary and the combined `robot-service` binary both use
//! this module. Keeping the network stack here avoids copying bridge startup
//! logic across binaries.

use std::sync::atomic::AtomicU32;
use std::sync::Arc;

use anyhow::{bail, Context, Result};
use tokio::sync::{mpsc, watch};

use teleop_protocol::{
    ControlSchema, DeviceDescriptor, DeviceInfo, DeviceTelemetry, VideoFeedInfo,
};

use crate::adapter_client::AdapterClient;
use crate::config::{BridgeConfig, VideoFeedConfig};
use crate::pose_udp_server::UdpDropStats;
use crate::sdk::{BlueprintStreams, StreamsChannels};
use crate::video::{Codec, VideoFeed, VideoFeedSource};
use crate::wire_runtime::TimedCommand;
use crate::{
    discovery, forward, latency, pose_server, pose_udp_server, runtime, telemetry_server, video,
};
use teleop_protocol::{BLUEPRINT_CAPABILITY, BLUEPRINT_SPEC_HASH_CAPABILITY, SPEC_SHA256};

/// Run the normal adapter-backed XR bridge mode.
pub async fn run_adapter_mode(config: BridgeConfig) -> Result<()> {
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
    descriptor.normalize_for_outside();
    sanitize_capture_streams(&mut descriptor);
    let blueprint_compatible = client.blueprint_compatible();
    descriptor.capabilities.insert(
        BLUEPRINT_CAPABILITY.to_string(),
        serde_json::Value::Bool(blueprint_compatible),
    );
    if blueprint_compatible {
        descriptor.capabilities.insert(
            BLUEPRINT_SPEC_HASH_CAPABILITY.to_string(),
            serde_json::Value::String(SPEC_SHA256.to_string()),
        );
    } else {
        descriptor
            .capabilities
            .remove(BLUEPRINT_SPEC_HASH_CAPABILITY);
    }
    let video_feeds = video_feed_relays(&config.video.feeds)?;
    log_video_feeds(&video_feeds);

    let device_type = descriptor.device.device_type.clone();
    let device_name = descriptor.device.name.clone();
    let descriptor = Arc::new(descriptor);

    let adapter_telemetry = client.telemetry();
    let blueprint_rx = client.blueprint();
    let blueprint_state_rx = client.blueprint_state();
    let (blueprint_event_tx, blueprint_event_rx) = mpsc::channel(256);
    let blueprint = BlueprintStreams {
        blueprint_rx: blueprint_rx,
        state_rx: blueprint_state_rx,
        event_tx: blueprint_event_tx,
    };
    let streams = StreamsChannels::new();

    let (device_cmd_tx, device_cmd_rx) = watch::channel::<Option<TimedCommand>>(None);
    let (telemetry_tx, telemetry_rx) = watch::channel(DeviceTelemetry::default());

    let latency = latency::LatencyRecorder::new();
    let session_token = Arc::new(AtomicU32::new(0));
    let udp_stats = UdpDropStats::new();

    tokio::spawn(runtime::telemetry_fanin(adapter_telemetry, telemetry_tx));

    tracing::info!(
        "XR network up: pose={} pose_udp={} telemetry={} discovery={}",
        config.pose_port,
        config.pose_udp_port,
        config.telemetry_port,
        config.discovery_port,
    );

    tokio::try_join!(
        discovery::run(&config, &device_type, &device_name),
        pose_server::run_with_blueprint_and_streams(
            config.pose_port,
            descriptor.clone(),
            device_cmd_tx.clone(),
            telemetry_rx.clone(),
            latency.clone(),
            blueprint,
            streams.clone(),
        ),
        pose_udp_server::run(
            config.pose_udp_port,
            device_cmd_tx,
            latency.clone(),
            session_token,
            udp_stats,
        ),
        telemetry_server::run(config.telemetry_port, telemetry_rx),
        forward::run_with_blueprint_events_and_streams(
            descriptor,
            device_cmd_rx,
            client,
            latency.clone(),
            blueprint_event_rx,
            streams,
        ),
        latency::run_aggregator(latency.clone()),
        video::run(video_feeds),
    )?;

    Ok(())
}

/// Run without a robot adapter and expose only configured video feeds.
pub async fn run_video_only_mode(config: BridgeConfig) -> Result<()> {
    let descriptor = build_video_only_descriptor(&config)?;
    let video_feeds = video_feed_relays(&config.video.feeds)?;
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
        ..Default::default()
    };
    append_video_feed_infos(&mut descriptor, &config.video.feeds);
    descriptor.normalize_for_outside();
    Ok(descriptor)
}

/// The headset must never see a capture-stream declaration it cannot honour;
/// an invalid adapter declaration is dropped rather than forwarded. The
/// `media` block is session-owned and the adapter path serves no media, so an
/// adapter-authored one is always removed: the headset then reports declared
/// streams `unsupported` (capture media requires the embedded `XrSession`).
fn sanitize_capture_streams(descriptor: &mut DeviceDescriptor) {
    if let Some(Err(error)) = descriptor.capture_streams.as_ref().map(|c| c.validate()) {
        tracing::warn!("Dropping invalid capture_streams from adapter descriptor: {error}");
        descriptor.capture_streams = None;
    }
    if descriptor.media.take().is_some() {
        tracing::warn!("Dropping adapter-authored media block; only the bridge issues media");
    }
}

pub(crate) fn video_feed_relays(feeds: &[VideoFeedConfig]) -> Result<Vec<VideoFeed>> {
    feeds.iter().map(feed_config_to_relay).collect()
}

pub(crate) fn append_video_feed_infos(
    descriptor: &mut DeviceDescriptor,
    feeds: &[VideoFeedConfig],
) {
    for fc in feeds {
        descriptor.video_feeds.push(feed_config_to_info(fc));
    }
    if !feeds.is_empty() {
        descriptor
            .capabilities
            .insert("video".to_string(), serde_json::Value::Bool(true));
    }
}

pub(crate) fn log_video_feeds(video_feeds: &[VideoFeed]) {
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

fn feed_config_to_relay(fc: &VideoFeedConfig) -> Result<VideoFeed> {
    let source = match (&fc.rtsp_url, fc.command.as_slice()) {
        (Some(url), []) if !url.trim().is_empty() => VideoFeedSource::Rtsp(url.clone()),
        (None, [program, args @ ..]) if !program.trim().is_empty() => {
            let mut command = Vec::with_capacity(args.len() + 1);
            command.push(program.clone());
            command.extend_from_slice(args);
            VideoFeedSource::Command(command)
        }
        _ => bail!(
            "video feed {:?} must configure exactly one of rtsp_url or command",
            fc.name
        ),
    };
    Ok(VideoFeed {
        name: fc.name.clone(),
        source,
        tcp_port: fc.tcp_port,
        udp_port: fc.udp_port.filter(|&p| p != 0),
        codec: Codec::parse(&fc.codec),
    })
}

fn feed_config_to_info(fc: &VideoFeedConfig) -> VideoFeedInfo {
    VideoFeedInfo {
        name: fc.name.clone(),
        display: fc.name.clone(),
        port: fc.tcp_port,
        width: fc.width,
        height: fc.height,
        fps: fc.fps,
        stereo: fc.stereo,
        transport: fc.transport.clone(),
        udp_port: fc.udp_port.unwrap_or(0),
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
      stereo: true
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
        assert!(feed.stereo);
        assert_eq!(feed.transport, "udp");
        assert_eq!(
            descriptor.capabilities.get("video"),
            Some(&serde_json::Value::Bool(true))
        );
    }

    #[test]
    fn adapter_capture_streams_survive_normalization_and_invalid_ones_are_dropped() {
        let capture: teleop_protocol::CaptureStreamsConfig =
            serde_json::from_value(serde_json::json!({
                "streams": [{"name": "rgb.hevc", "required": true, "max_hz": 4, "eye": "left"}],
                "local_tasks": [{"kind": "upload", "endpoint_ref": "lab-ingest"}]
            }))
            .unwrap();
        let mut descriptor: DeviceDescriptor = serde_json::from_value(serde_json::json!({
            "device": {"type": "hosted", "name": "Hosted"},
            "control_schema": {},
            "capture_streams": capture,
            "media": {"protocol": "olcp.v1", "push_port": 1, "result_port": 2, "auth_token": "adapter"}
        }))
        .unwrap();
        descriptor.normalize_for_outside();
        sanitize_capture_streams(&mut descriptor);
        let frame = crate::wire_runtime::build_descriptor_frame(&descriptor);
        let sent: serde_json::Value = serde_json::from_slice(&frame.data).unwrap();
        assert_eq!(
            sent["capture_streams"],
            serde_json::to_value(&capture).unwrap()
        );
        assert!(sent.get("media").is_none(), "adapters never author media");

        descriptor.capture_streams.as_mut().unwrap().local_tasks[0].endpoint_ref =
            Some("https://evil.example/upload".into());
        sanitize_capture_streams(&mut descriptor);
        assert!(descriptor.capture_streams.is_none());
        let frame = crate::wire_runtime::build_descriptor_frame(&descriptor);
        let sent: serde_json::Value = serde_json::from_slice(&frame.data).unwrap();
        assert!(sent.get("capture_streams").is_none());
    }
}
