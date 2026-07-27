//! In-process XR state service used by the `pyoperator` Python extension.

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use anyhow::{Context, Result};
use tokio::net::{TcpListener, UdpSocket};
use tokio::sync::{oneshot, watch};

use teleop_protocol::{
    ControlSchema, DeviceDescriptor, DeviceInfo, DeviceTelemetry, XrStateFrame, XrStreamConfig,
    XR_STATE_SCHEMA_VERSION,
};

use crate::config::BridgeConfig;
use crate::latency::LatencyRecorder;
use crate::pose_udp_server::UdpDropStats;
use crate::service::{append_video_feed_infos, log_video_feeds, video_feed_relays};
use crate::wire_runtime::TimedCommand;
use crate::{discovery, latency, pose_server, pose_udp_server, telemetry_server, video};

#[derive(Debug, Default)]
pub struct XrStateStats {
    connected: AtomicBool,
    frames_received: AtomicU64,
    parse_errors: AtomicU64,
    last_frame_id: AtomicU64,
    last_timestamp_ns: AtomicU64,
    last_error: Mutex<Option<String>>,
}

impl XrStateStats {
    pub fn connected(&self) -> bool {
        self.connected.load(Ordering::Relaxed)
    }
    pub fn frames_received(&self) -> u64 {
        self.frames_received.load(Ordering::Relaxed)
    }
    pub fn parse_errors(&self) -> u64 {
        self.parse_errors.load(Ordering::Relaxed)
    }
    pub fn last_frame_id(&self) -> u64 {
        self.last_frame_id.load(Ordering::Relaxed)
    }
    pub fn last_timestamp_ns(&self) -> u64 {
        self.last_timestamp_ns.load(Ordering::Relaxed)
    }
    pub fn last_error(&self) -> Option<String> {
        self.last_error.lock().ok().and_then(|value| value.clone())
    }

    pub(crate) fn set_connected(&self, connected: bool) {
        self.connected.store(connected, Ordering::Relaxed);
    }

    pub(crate) fn clear_error(&self) {
        if let Ok(mut slot) = self.last_error.lock() {
            *slot = None;
        }
    }

    pub(crate) fn record_error(&self, error: impl Into<String>) {
        if let Ok(mut slot) = self.last_error.lock() {
            *slot = Some(error.into());
        }
    }

    pub(crate) fn record_frame(&self, frame: &XrStateFrame) {
        self.frames_received.fetch_add(1, Ordering::Relaxed);
        self.last_frame_id.store(frame.frame_id, Ordering::Relaxed);
        self.last_timestamp_ns
            .store(frame.timestamp_ns, Ordering::Relaxed);
    }

    pub(crate) fn record_parse_error(&self, error: impl Into<String>) {
        self.parse_errors.fetch_add(1, Ordering::Relaxed);
        self.record_error(error);
    }
}

#[derive(Clone)]
pub struct XrStateSink {
    pub(crate) frame_tx: watch::Sender<Option<Arc<XrStateFrame>>>,
    pub stats: Arc<XrStateStats>,
}

/// Latest-wins publication: slow consumers lose complete frames and never
/// block the headset socket or observe a field-by-field update.
pub fn state_channel() -> (XrStateSink, watch::Receiver<Option<Arc<XrStateFrame>>>) {
    let (frame_tx, frame_rx) = watch::channel(None);
    (
        XrStateSink {
            frame_tx,
            stats: Arc::new(XrStateStats::default()),
        },
        frame_rx,
    )
}

/// Run the adapter-free SDK service until `shutdown` becomes true.
pub async fn run_sdk_mode(
    config: BridgeConfig,
    sink: XrStateSink,
    shutdown: watch::Receiver<bool>,
) -> Result<()> {
    run_sdk_mode_inner(config, sink, shutdown, None).await
}

/// SDK service variant that reports whether all startup resources were
/// acquired. Embedders can wait for this signal instead of treating a spawned
/// thread as a successfully started service.
pub async fn run_sdk_mode_with_startup(
    config: BridgeConfig,
    sink: XrStateSink,
    shutdown: watch::Receiver<bool>,
    startup: oneshot::Sender<std::result::Result<(), String>>,
) -> Result<()> {
    run_sdk_mode_inner(config, sink, shutdown, Some(startup)).await
}

async fn run_sdk_mode_inner(
    config: BridgeConfig,
    sink: XrStateSink,
    mut shutdown: watch::Receiver<bool>,
    startup: Option<oneshot::Sender<std::result::Result<(), String>>>,
) -> Result<()> {
    let mut descriptor = DeviceDescriptor {
        device: DeviceInfo {
            device_type: "pyoperator".to_string(),
            name: config.name.clone(),
            icon: "headset".to_string(),
            model_url: String::new(),
        },
        control_schema: ControlSchema::default(),
        input_mapping: Vec::new(),
        telemetry_schema: Default::default(),
        video_feeds: Vec::new(),
        safety: Default::default(),
        xr_stream: Some(XrStreamConfig {
            schema_version: XR_STATE_SCHEMA_VERSION,
            rate_hz: 72,
            streams: vec![
                "head".into(),
                "controllers".into(),
                "hands".into(),
                "body".into(),
                "motion_trackers".into(),
            ],
        }),
        ..DeviceDescriptor::default()
    };
    append_video_feed_infos(&mut descriptor, &config.video.feeds);
    let video_feeds = video_feed_relays(&config.video.feeds);
    log_video_feeds(&video_feeds);

    let device_type = descriptor.device.device_type.clone();
    let device_name = descriptor.device.name.clone();
    let descriptor = Arc::new(descriptor);
    let (device_cmd_tx, _device_cmd_rx) = watch::channel::<Option<TimedCommand>>(None);
    let (_telemetry_tx, telemetry_rx) = watch::channel(DeviceTelemetry::default());
    let latency = LatencyRecorder::new();
    let session_token = Arc::new(std::sync::atomic::AtomicU32::new(0));
    let udp_stats = UdpDropStats::new();

    let prepared = async {
        let pose_listener = TcpListener::bind(("0.0.0.0", config.pose_port))
            .await
            .with_context(|| format!("binding XR pose TCP port {}", config.pose_port))?;
        let pose_udp_socket = UdpSocket::bind(("0.0.0.0", config.pose_udp_port))
            .await
            .with_context(|| format!("binding XR pose UDP port {}", config.pose_udp_port))?;
        let telemetry_listener = TcpListener::bind(("0.0.0.0", config.telemetry_port))
            .await
            .with_context(|| format!("binding XR telemetry TCP port {}", config.telemetry_port))?;
        let discovery = discovery::prepare(&config, &device_type, &device_name)
            .await
            .context("starting XR discovery")?;
        Ok::<_, anyhow::Error>((
            pose_listener,
            pose_udp_socket,
            telemetry_listener,
            discovery,
        ))
    }
    .await;

    let (pose_listener, pose_udp_socket, telemetry_listener, discovery) = match prepared {
        Ok(prepared) => {
            if let Some(startup) = startup {
                let _ = startup.send(Ok(()));
            }
            prepared
        }
        Err(error) => {
            if let Some(startup) = startup {
                let _ = startup.send(Err(format!("{error:#}")));
            }
            return Err(error);
        }
    };

    tracing::info!(
        "pyoperator network up: pose={} discovery={}",
        config.pose_port,
        config.discovery_port
    );

    let stack = async {
        tokio::try_join!(
            discovery::run_prepared(discovery),
            pose_server::run_on_with_xr_state(
                pose_listener,
                descriptor,
                device_cmd_tx.clone(),
                telemetry_rx.clone(),
                latency.clone(),
                sink,
            ),
            pose_udp_server::run_on(
                pose_udp_socket,
                device_cmd_tx,
                latency.clone(),
                session_token,
                udp_stats,
            ),
            telemetry_server::run_on(telemetry_listener, telemetry_rx),
            latency::run_aggregator(latency),
            video::run(video_feeds),
        )?;
        Ok::<(), anyhow::Error>(())
    };

    tokio::select! {
        result = stack => result,
        _ = async {
            while !*shutdown.borrow() {
                if shutdown.changed().await.is_err() { break; }
            }
        } => Ok(()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::TcpListener as StdTcpListener;

    #[tokio::test]
    async fn startup_reports_pose_bind_failure() {
        let occupied = StdTcpListener::bind(("0.0.0.0", 0)).unwrap();
        let occupied_port = occupied.local_addr().unwrap().port();
        let config = BridgeConfig {
            pose_port: occupied_port,
            pose_udp_port: 0,
            telemetry_port: 0,
            ..BridgeConfig::default()
        };
        let (sink, _frame_rx) = state_channel();
        let (_shutdown_tx, shutdown_rx) = watch::channel(false);
        let (startup_tx, startup_rx) = oneshot::channel();

        let (service, startup) = tokio::join!(
            run_sdk_mode_with_startup(config, sink, shutdown_rx, startup_tx),
            startup_rx,
        );

        let startup_error = startup
            .expect("service should report startup")
            .expect_err("occupied pose port must fail startup");
        assert!(startup_error.contains(&format!("pose TCP port {occupied_port}")));
        assert!(service
            .expect_err("service must stop after startup failure")
            .to_string()
            .contains(&format!("pose TCP port {occupied_port}")));
    }
}
