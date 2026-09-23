//! In-process XR state service used by the `pyoperator` Python extension.

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use anyhow::{Context, Result};
use tokio::net::{TcpListener, UdpSocket};
use tokio::sync::{mpsc, oneshot, watch};

use teleop_protocol::{
    Blueprint, BlueprintEvent, BlueprintState, ControlSchema, DeviceDescriptor, DeviceInfo,
    DeviceTelemetry, StreamsControl, StreamsStatus, XrStateFrame, XrStreamConfig,
    BLUEPRINT_CAPABILITY, BLUEPRINT_SPEC_HASH_CAPABILITY, SPEC_SHA256, XR_STATE_SCHEMA_VERSION,
};

use crate::config::BridgeConfig;
use crate::latency::LatencyRecorder;
use crate::media::{MediaChannels, MediaListeners};
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

#[derive(Clone)]
pub struct BlueprintStreams {
    pub blueprint_rx: watch::Receiver<Option<Arc<Blueprint>>>,
    pub state_rx: watch::Receiver<Option<Arc<BlueprintState>>>,
    pub event_tx: mpsc::Sender<BlueprintEvent>,
}

/// Ordered host→headset `StreamsControl` queue depth per headset connection.
const STREAMS_CONTROL_QUEUE: usize = 16;

/// Capture-stream ctrl plumbing between the host side and the headset
/// connection that owns the host session: the latest headset
/// `StreamsStatus` (latest-wins) and an ordered `StreamsControl` queue.
///
/// The most recent headset handshake owns the session; when it ends, the
/// previous headset still connected owns it again with its last status.
/// Status is `None` while the owner has not reported.
#[derive(Clone)]
pub struct StreamsChannels {
    status_tx: watch::Sender<Option<Arc<StreamsStatus>>>,
    session: Arc<Mutex<StreamsSession>>,
    /// Session media relay; only the embedded SDK path serves media.
    media: Option<MediaChannels>,
}

#[derive(Default)]
struct StreamsSession {
    generation: u64,
    /// Attached headset connections, oldest first; the last owns the session.
    attached: Vec<AttachedHeadset>,
}

struct AttachedHeadset {
    generation: u64,
    /// Present only when the headset advertised `capture_streams_v1`.
    control_tx: Option<mpsc::Sender<StreamsControl>>,
    status: Option<Arc<StreamsStatus>>,
}

/// Why a `StreamsControl` could not be queued for the headset.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum StreamsControlError {
    Invalid(String),
    NotConnected,
    /// The connected headset did not advertise `capture_streams_v1`.
    Unsupported,
    QueueFull,
}

impl std::fmt::Display for StreamsControlError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Invalid(error) => write!(f, "invalid StreamsControl: {error}"),
            Self::NotConnected => f.write_str("no headset is connected"),
            Self::Unsupported => f.write_str(
                "connected headset does not advertise capture_streams_v1; update the Operator XR app",
            ),
            Self::QueueFull => f.write_str("StreamsControl queue is full"),
        }
    }
}

impl std::error::Error for StreamsControlError {}

impl Default for StreamsChannels {
    fn default() -> Self {
        Self::new()
    }
}

impl StreamsChannels {
    pub fn new() -> Self {
        let (status_tx, _) = watch::channel(None);
        Self {
            status_tx,
            session: Arc::new(Mutex::new(StreamsSession::default())),
            media: None,
        }
    }

    /// Channels that also carry granted media through `media`: the SDK
    /// service serves it when `capture_streams` is declared and injects the
    /// session-owned `DeviceDescriptor.media` block for capable headsets.
    pub fn with_media(media: MediaChannels) -> Self {
        Self {
            media: Some(media),
            ..Self::new()
        }
    }

    pub fn media(&self) -> Option<&MediaChannels> {
        self.media.as_ref()
    }

    /// Latest-wins headset `StreamsStatus`; `None` while no report is known.
    pub fn status(&self) -> watch::Receiver<Option<Arc<StreamsStatus>>> {
        self.status_tx.subscribe()
    }

    pub fn latest_status(&self) -> Option<Arc<StreamsStatus>> {
        self.status_tx.borrow().clone()
    }

    /// Whether the headset owning the session advertised `capture_streams_v1`.
    pub fn headset_supported(&self) -> bool {
        self.session
            .lock()
            .map(|session| {
                session
                    .attached
                    .last()
                    .is_some_and(|owner| owner.control_tx.is_some())
            })
            .unwrap_or(false)
    }

    /// Queue `control` for the owning headset, preserving order.
    pub fn send_control(&self, control: StreamsControl) -> Result<(), StreamsControlError> {
        control.validate().map_err(StreamsControlError::Invalid)?;
        let session = self
            .session
            .lock()
            .map_err(|_| StreamsControlError::NotConnected)?;
        let owner = session
            .attached
            .last()
            .ok_or(StreamsControlError::NotConnected)?;
        let control_tx = owner
            .control_tx
            .as_ref()
            .ok_or(StreamsControlError::Unsupported)?;
        control_tx.try_send(control).map_err(|error| match error {
            mpsc::error::TrySendError::Full(_) => StreamsControlError::QueueFull,
            mpsc::error::TrySendError::Closed(_) => StreamsControlError::NotConnected,
        })
    }

    /// Make a newly handshaken headset the session owner. The returned
    /// guard detaches it when dropped, handing the session back to the
    /// previous headset still attached.
    pub(crate) fn attach(
        &self,
        capture_streams_supported: bool,
    ) -> (StreamsAttachment, Option<mpsc::Receiver<StreamsControl>>) {
        let (control_tx, control_rx) = if capture_streams_supported {
            let (tx, rx) = mpsc::channel(STREAMS_CONTROL_QUEUE);
            (Some(tx), Some(rx))
        } else {
            (None, None)
        };
        let generation = match self.session.lock() {
            Ok(mut session) => {
                session.generation += 1;
                let generation = session.generation;
                session.attached.push(AttachedHeadset {
                    generation,
                    control_tx,
                    status: None,
                });
                generation
            }
            Err(_) => 0,
        };
        self.status_tx.send_replace(None);
        (
            StreamsAttachment {
                channels: self.clone(),
                generation,
            },
            control_rx,
        )
    }
}

/// One headset connection's claim on [`StreamsChannels`].
pub(crate) struct StreamsAttachment {
    channels: StreamsChannels,
    generation: u64,
}

impl StreamsAttachment {
    pub(crate) fn publish(&self, status: StreamsStatus) {
        let Ok(mut session) = self.channels.session.lock() else {
            return;
        };
        let status = Arc::new(status);
        let owns = session.attached.last().map(|owner| owner.generation) == Some(self.generation);
        if let Some(entry) = session
            .attached
            .iter_mut()
            .find(|entry| entry.generation == self.generation)
        {
            entry.status = Some(status.clone());
        }
        if owns {
            self.channels.status_tx.send_replace(Some(status));
        }
    }
}

impl Drop for StreamsAttachment {
    fn drop(&mut self) {
        let Ok(mut session) = self.channels.session.lock() else {
            return;
        };
        let Some(index) = session
            .attached
            .iter()
            .position(|entry| entry.generation == self.generation)
        else {
            return;
        };
        session.attached.remove(index);
        if index == session.attached.len() {
            let status = session
                .attached
                .last()
                .and_then(|owner| owner.status.clone());
            drop(session);
            self.channels.status_tx.send_replace(status);
        }
    }
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
    run_sdk_mode_inner(config, sink, shutdown, None, None, None).await
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
    run_sdk_mode_inner(config, sink, shutdown, Some(startup), None, None).await
}

pub async fn run_sdk_mode_with_startup_and_blueprint(
    config: BridgeConfig,
    sink: XrStateSink,
    shutdown: watch::Receiver<bool>,
    startup: oneshot::Sender<std::result::Result<(), String>>,
    blueprint: BlueprintStreams,
) -> Result<()> {
    run_sdk_mode_inner(config, sink, shutdown, Some(startup), Some(blueprint), None).await
}

/// SDK service variant that also routes capture-stream `StreamsStatus` /
/// `StreamsControl` between `streams` and the headset, and serves session
/// media when `streams` carries [`MediaChannels`] and `capture_streams` is
/// declared (media ports bound with the other listeners).
pub async fn run_sdk_mode_with_startup_blueprint_and_streams(
    config: BridgeConfig,
    sink: XrStateSink,
    shutdown: watch::Receiver<bool>,
    startup: oneshot::Sender<std::result::Result<(), String>>,
    blueprint: BlueprintStreams,
    streams: StreamsChannels,
) -> Result<()> {
    run_sdk_mode_inner(
        config,
        sink,
        shutdown,
        Some(startup),
        Some(blueprint),
        Some(streams),
    )
    .await
}

async fn run_sdk_mode_inner(
    config: BridgeConfig,
    sink: XrStateSink,
    mut shutdown: watch::Receiver<bool>,
    startup: Option<oneshot::Sender<std::result::Result<(), String>>>,
    blueprint: Option<BlueprintStreams>,
    streams: Option<StreamsChannels>,
) -> Result<()> {
    let validated = crate::config::validate_xr_streams(&config.xr_streams).and_then(|()| {
        config.capture_streams.as_ref().map_or(Ok(()), |capture| {
            capture
                .validate()
                .map_err(|error| anyhow::anyhow!("invalid capture_streams: {error}"))
        })
    });
    if let Err(error) = validated {
        if let Some(startup) = startup {
            let _ = startup.send(Err(error.to_string()));
        }
        return Err(error);
    }
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
            streams: config.xr_streams.clone(),
        }),
        capture_streams: config.capture_streams.clone(),
        ..DeviceDescriptor::default()
    };
    if blueprint.is_some() {
        descriptor.capabilities.insert(
            BLUEPRINT_CAPABILITY.to_string(),
            serde_json::Value::Bool(true),
        );
        descriptor.capabilities.insert(
            BLUEPRINT_SPEC_HASH_CAPABILITY.to_string(),
            serde_json::Value::String(SPEC_SHA256.to_string()),
        );
    }
    append_video_feed_infos(&mut descriptor, &config.video.feeds);
    let video_feeds = video_feed_relays(&config.video.feeds)?;
    log_video_feeds(&video_feeds);
    // Media exists only to carry declared capture streams.
    let media = streams
        .as_ref()
        .and_then(StreamsChannels::media)
        .filter(|_| config.capture_streams.is_some())
        .cloned();

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
        let video_feeds = video::prepare(video_feeds).await?;
        let media_relay = match &media {
            Some(media) => MediaListeners::bind(config.media_up_port, config.media_down_port)
                .await?
                .map(|listeners| media.serve(listeners))
                .transpose()?,
            None => None,
        };
        Ok::<_, anyhow::Error>((
            pose_listener,
            pose_udp_socket,
            telemetry_listener,
            discovery,
            video_feeds,
            media_relay,
        ))
    }
    .await;

    let (pose_listener, pose_udp_socket, telemetry_listener, discovery, video_feeds, media_relay) =
        match prepared {
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
        "pyoperator network up: pose={} discovery={} media={}",
        config.pose_port,
        config.discovery_port,
        if media_relay.is_some() {
            format!("{}/{}", config.media_up_port, config.media_down_port)
        } else {
            "off".to_string()
        }
    );

    let stack = async {
        tokio::try_join!(
            discovery::run_prepared(discovery),
            pose_server::run_on_with_xr_state_blueprint_and_streams(
                pose_listener,
                descriptor,
                device_cmd_tx.clone(),
                telemetry_rx.clone(),
                latency.clone(),
                sink,
                blueprint,
                streams,
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
            video::run_prepared(video_feeds),
            async {
                match media_relay {
                    Some(relay) => relay.await,
                    None => Ok(()),
                }
            },
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

    fn status(schema: &str) -> StreamsStatus {
        StreamsStatus {
            schema: schema.to_string(),
            streams: Default::default(),
            local_tasks: Default::default(),
        }
    }

    #[test]
    fn the_previous_headset_owns_the_streams_again_when_the_newest_leaves() {
        let streams = StreamsChannels::new();
        let (first, first_rx) = streams.attach(true);
        first.publish(status("first"));
        let (second, _second_rx) = streams.attach(false);
        assert!(streams.latest_status().is_none());
        assert!(!streams.headset_supported());
        drop(second);
        assert_eq!(streams.latest_status().unwrap().schema, "first");
        assert!(streams.headset_supported());
        streams
            .send_control(StreamsControl::default())
            .expect("control reaches the previous headset");
        assert!(first_rx.is_some());
        drop(first);
        assert!(streams.latest_status().is_none());
        assert_eq!(
            streams.send_control(StreamsControl::default()),
            Err(StreamsControlError::NotConnected)
        );
    }

    #[tokio::test]
    async fn startup_rejects_ambiguous_streams_before_opening_network() {
        let config = BridgeConfig {
            xr_streams: vec![],
            ..BridgeConfig::default()
        };
        let (sink, _frames) = state_channel();
        let (_shutdown_tx, shutdown) = watch::channel(false);
        let (startup_tx, startup_rx) = oneshot::channel();
        let service = run_sdk_mode_with_startup(config, sink, shutdown, startup_tx).await;
        assert!(service.unwrap_err().to_string().contains("non-empty"));
        assert!(startup_rx.await.unwrap().unwrap_err().contains("non-empty"));
    }

    #[tokio::test]
    async fn startup_rejects_invalid_capture_streams_before_opening_network() {
        let config = BridgeConfig {
            capture_streams: Some(
                serde_json::from_str(r#"{"streams":[{"name":"rgb.hevc","eye":"right"}]}"#).unwrap(),
            ),
            ..BridgeConfig::default()
        };
        let (sink, _frames) = state_channel();
        let (_shutdown_tx, shutdown) = watch::channel(false);
        let (startup_tx, startup_rx) = oneshot::channel();
        let (blueprint_event_tx, _events) = mpsc::channel(1);
        let (_blueprint_tx, blueprint_rx) = watch::channel(None);
        let (_state_tx, state_rx) = watch::channel(None);
        let service = run_sdk_mode_with_startup_blueprint_and_streams(
            config,
            sink,
            shutdown,
            startup_tx,
            BlueprintStreams {
                blueprint_rx,
                state_rx,
                event_tx: blueprint_event_tx,
            },
            StreamsChannels::new(),
        )
        .await;
        assert!(service.unwrap_err().to_string().contains("capture_streams"));
        assert!(startup_rx.await.unwrap().unwrap_err().contains("eye"));
    }

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

    #[tokio::test]
    async fn startup_reports_media_bind_failure_when_capture_streams_are_declared() {
        let occupied = StdTcpListener::bind(("0.0.0.0", 0)).unwrap();
        let occupied_port = occupied.local_addr().unwrap().port();
        let config = BridgeConfig {
            pose_port: 0,
            discovery_port: 0,
            pose_udp_port: 0,
            telemetry_port: 0,
            media_up_port: occupied_port,
            media_down_port: 0,
            capture_streams: Some(
                serde_json::from_str(r#"{"streams":[{"name":"rgb.hevc"}]}"#).unwrap(),
            ),
            ..BridgeConfig::default()
        };
        let run = |config: BridgeConfig| async move {
            let (sink, _frames) = state_channel();
            let (shutdown_tx, shutdown) = watch::channel(false);
            let (startup_tx, startup_rx) = oneshot::channel();
            let (event_tx, _events) = mpsc::channel(1);
            let (_blueprint_tx, blueprint_rx) = watch::channel(None);
            let (_state_tx, state_rx) = watch::channel(None);
            let service = tokio::spawn(run_sdk_mode_with_startup_blueprint_and_streams(
                config,
                sink,
                shutdown,
                startup_tx,
                BlueprintStreams {
                    blueprint_rx,
                    state_rx,
                    event_tx,
                },
                StreamsChannels::with_media(crate::media::MediaChannels::new()),
            ));
            let startup = startup_rx.await.unwrap();
            let _ = shutdown_tx.send(true);
            let _ = service.await;
            startup
        };

        // `0` on either media port disables media: startup succeeds.
        run(config.clone()).await.unwrap();
        let error = run(BridgeConfig {
            media_down_port: 1,
            ..config
        })
        .await
        .unwrap_err();
        assert!(
            error.contains(&format!("media_up TCP port {occupied_port}")),
            "{error}"
        );
    }

    #[tokio::test]
    async fn startup_reports_video_bind_failure() {
        let occupied = StdTcpListener::bind(("0.0.0.0", 0)).unwrap();
        let occupied_port = occupied.local_addr().unwrap().port();
        let config = BridgeConfig {
            pose_port: 0,
            discovery_port: 0,
            pose_udp_port: 0,
            telemetry_port: 0,
            video: crate::config::VideoConfig {
                feeds: vec![crate::config::VideoFeedConfig {
                    name: "occupied".to_string(),
                    rtsp_url: None,
                    command: vec!["true".to_string()],
                    tcp_port: occupied_port,
                    udp_port: None,
                    width: 64,
                    height: 64,
                    fps: 30,
                    transport: "tcp".to_string(),
                    codec: "h264".to_string(),
                    stereo: false,
                }],
            },
            ..BridgeConfig::default()
        };
        let (sink, _frame_rx) = state_channel();
        let (_shutdown_tx, shutdown_rx) = watch::channel(false);
        let (startup_tx, startup_rx) = oneshot::channel();

        let (service, startup) = tokio::join!(
            run_sdk_mode_with_startup(config, sink, shutdown_rx, startup_tx),
            startup_rx,
        );

        let expected = format!("video TCP port {occupied_port}");
        let startup_error = startup
            .expect("service should report startup")
            .expect_err("occupied video port must fail startup");
        assert!(startup_error.contains(&expected));
        assert!(service
            .expect_err("service must stop after startup failure")
            .to_string()
            .contains(&expected));
    }
}
