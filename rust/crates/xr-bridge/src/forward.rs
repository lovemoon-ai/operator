//! The bridge control loop: sanitize headset commands and forward to the
//! adapter, with an inlined liveness watchdog.
//!
//! This is the genuinely new code in the XR-network migration. A single task
//! OWNS the [`AdapterClient`] (so there is no `Arc<Mutex>` around it) and runs
//! a `tokio::select!`:
//!
//! * On `cmd_rx.changed()` (the `watch::Receiver<Option<TimedCommand>>` fed by
//!   both `pose_server` and `pose_udp_server`): take the latest
//!   [`TimedCommand`], run it through [`DeviceSafety::validate`]; on `Rejected`
//!   log + skip; on `Ok`/`Clamped` forward the sanitized command to the
//!   adapter. Record `last_cmd_at` and clear the timed-out latch.
//! * On a watchdog interval tick: if `last_cmd_at.elapsed() > timeout` and we
//!   have not already fired for this idle period, send a single `Stop` to the
//!   adapter so the robot safes itself when the headset goes quiet. Re-arms
//!   when commands resume.
//!
//! Because the forwarder owns the client, grab `client.telemetry()` BEFORE
//! moving the client in here (see [`crate::runtime`]).
//!
//! The watchdog is inlined here (rather than reusing the standalone
//! [`crate::watchdog::Watchdog`]) so the single owning task can call
//! `&mut AdapterClient::stop` directly without boxing an async `StopAction`
//! that would need shared access to the client. The timeout/period constants
//! mirror that module and `robot/src/device/control_loop.rs`.

use std::future::pending;
use std::sync::Arc;

use anyhow::Result;
use tokio::sync::{mpsc, watch};
use tokio::time::{Duration, Instant, MissedTickBehavior};

use teleop_protocol::{BlueprintEvent, DeviceDescriptor, StreamsControl, StreamsStatus};

use crate::adapter_client::AdapterClient;
use crate::latency::{self, LatencyFrame, LatencyRecorder};
use crate::safety::{DeviceSafety, SafetyResult};
use crate::sdk::{StreamsChannels, StreamsControlError};
use crate::wire_runtime::TimedCommand;

/// Watchdog poll period: a quarter of the command timeout, clamped to a sane
/// 50–250 ms band (mirrors the legacy control loop and [`crate::watchdog`]).
fn watchdog_period(timeout: Duration) -> Duration {
    timeout
        .checked_div(4)
        .unwrap_or(Duration::from_millis(100))
        .clamp(Duration::from_millis(50), Duration::from_millis(250))
}

/// Run the forward/control loop. Owns `client`; never returns under normal
/// operation (until the command channel closes, which is treated as a clean
/// shutdown after a final safing `Stop`).
pub async fn run(
    descriptor: Arc<DeviceDescriptor>,
    cmd_rx: watch::Receiver<Option<TimedCommand>>,
    client: AdapterClient,
    latency: Arc<LatencyRecorder>,
) -> Result<()> {
    run_inner(descriptor, cmd_rx, client, latency, None, None).await
}

/// Run the control loop and forward robot-authored blueprint interactions.
pub async fn run_with_blueprint_events(
    descriptor: Arc<DeviceDescriptor>,
    cmd_rx: watch::Receiver<Option<TimedCommand>>,
    client: AdapterClient,
    latency: Arc<LatencyRecorder>,
    blueprint_event_rx: mpsc::Receiver<BlueprintEvent>,
) -> Result<()> {
    run_inner(
        descriptor,
        cmd_rx,
        client,
        latency,
        Some(blueprint_event_rx),
        None,
    )
    .await
}

/// [`run_with_blueprint_events`] plus capture-stream routing: headset
/// `StreamsStatus` goes to the adapter (only when its descriptor declared
/// `capture_streams`, so older adapters never see the new message) and
/// adapter `StreamsControl` goes to the headset via `streams`.
pub async fn run_with_blueprint_events_and_streams(
    descriptor: Arc<DeviceDescriptor>,
    cmd_rx: watch::Receiver<Option<TimedCommand>>,
    client: AdapterClient,
    latency: Arc<LatencyRecorder>,
    blueprint_event_rx: mpsc::Receiver<BlueprintEvent>,
    streams: StreamsChannels,
) -> Result<()> {
    run_inner(
        descriptor,
        cmd_rx,
        client,
        latency,
        Some(blueprint_event_rx),
        Some(streams),
    )
    .await
}

async fn run_inner(
    descriptor: Arc<DeviceDescriptor>,
    mut cmd_rx: watch::Receiver<Option<TimedCommand>>,
    mut client: AdapterClient,
    latency: Arc<LatencyRecorder>,
    mut blueprint_event_rx: Option<mpsc::Receiver<BlueprintEvent>>,
    streams: Option<StreamsChannels>,
) -> Result<()> {
    let mut safety = DeviceSafety::new(&descriptor);
    let mut streams_status_rx = streams
        .as_ref()
        .filter(|_| descriptor.capture_streams.is_some())
        .map(StreamsChannels::status);
    // Both directions follow the same gate: an adapter that declared no
    // (or an invalid, stripped) `capture_streams` neither hears about the
    // headset's streams nor gets to control them.
    let mut streams_control_rx = match &streams {
        Some(_) if descriptor.capture_streams.is_some() => client.take_streams_control(),
        _ => None,
    };

    let timeout = descriptor.safety.timeout();
    let period = watchdog_period(timeout);
    let mut watchdog = tokio::time::interval(period);
    watchdog.set_missed_tick_behavior(MissedTickBehavior::Skip);

    let mut last_cmd_at: Option<Instant> = None;
    let mut timed_out = false;

    tracing::info!(
        "Forward loop running: timeout={:?}, watchdog_period={:?}",
        timeout,
        period
    );

    loop {
        tokio::select! {
            event = receive_blueprint_event(&mut blueprint_event_rx) => {
                match event {
                    Some(event) => {
                        if let Err(error) = client.send_blueprint_event(event).await {
                            tracing::error!("Forwarding blueprint event to adapter failed: {error}");
                        }
                    }
                    None => blueprint_event_rx = None,
                }
            }
            changed = optional_status_changed(&mut streams_status_rx) => {
                let Some(receiver) = streams_status_rx.as_mut().filter(|_| changed.is_ok()) else {
                    streams_status_rx = None;
                    continue;
                };
                // A cleared status (the reporting headset disconnected) is
                // forwarded too, so the adapter stops believing the last report.
                let status = receiver.borrow_and_update().clone();
                let status = status.map(|status| status.as_ref().clone());
                if let Err(error) = client.send_streams_status(status).await {
                    tracing::error!("Forwarding StreamsStatus to adapter failed: {error}");
                }
            }
            control = receive_streams_control(&mut streams_control_rx) => {
                let (Some(control), Some(streams)) = (control, &streams) else {
                    streams_control_rx = None;
                    continue;
                };
                match streams.send_control(control) {
                    Ok(()) => {}
                    Err(error @ (StreamsControlError::NotConnected | StreamsControlError::Unsupported)) => {
                        tracing::debug!("Dropping adapter StreamsControl: {error}");
                    }
                    Err(error) => tracing::warn!("Dropping adapter StreamsControl: {error}"),
                }
            }
            // Incoming command from the headset (via pose_server / pose_udp_server).
            changed = cmd_rx.changed() => {
                if changed.is_err() {
                    // All senders dropped — clean shutdown. Safe the device once.
                    tracing::warn!("Command channel closed; safing device and exiting forward loop");
                    if !timed_out {
                        let _ = client.stop("command channel closed".into()).await;
                    }
                    return Ok(());
                }
                let timed_opt = cmd_rx.borrow_and_update().clone();
                let Some(timed) = timed_opt else {
                    // Channel signalled change but value is None — ignore.
                    continue;
                };
                // Stamp the moment this command crossed the watch boundary into
                // the forward loop, so `rx -> dispatch` measures watch latency.
                let t_dispatch_ns = latency::wall_clock_ns();

                last_cmd_at = Some(Instant::now());
                if timed_out {
                    tracing::info!("Watchdog: command flow resumed");
                    timed_out = false;
                }

                let TimedCommand { cmd, seq, t_rx_ns } = timed;
                let t_xr_send_ns = cmd.timestamp_ns;
                match safety.validate(&cmd) {
                    SafetyResult::Rejected(reason) => {
                        tracing::warn!("Command rejected (seq={seq}): {reason}");
                    }
                    SafetyResult::Ok(sanitized) | SafetyResult::Clamped(sanitized) => {
                        // Bracket only the adapter write so `drv` measures the
                        // bridge->adapter handoff (the span the driver publish
                        // returns through), then complete the frame. This is the
                        // point wire_runtime::TimedCommand's doc-comment refers to.
                        let t_drv_start_ns = latency::wall_clock_ns();
                        if let Err(e) = client.send_command(&sanitized).await {
                            tracing::error!("Forwarding command to adapter failed (seq={seq}): {e}");
                        } else {
                            latency.record_complete(LatencyFrame {
                                seq,
                                t_xr_send_ns,
                                t_rx_ns,
                                t_dispatch_ns,
                                t_drv_start_ns,
                                t_drv_done_ns: latency::wall_clock_ns(),
                            });
                        }
                    }
                }
            }
            // Watchdog tick: detect command staleness.
            _ = watchdog.tick() => {
                if let Some(t) = last_cmd_at {
                    if !timed_out && t.elapsed() > timeout {
                        tracing::warn!(
                            "Watchdog: no command for {:?} (timeout={:?}); sending Stop",
                            t.elapsed(), timeout
                        );
                        if let Err(e) = client.stop("watchdog: headset quiet".into()).await {
                            tracing::error!("Watchdog Stop to adapter failed: {e}");
                        }
                        timed_out = true;
                    }
                }
            }
        }
    }
}

async fn optional_status_changed(
    receiver: &mut Option<watch::Receiver<Option<Arc<StreamsStatus>>>>,
) -> Result<(), watch::error::RecvError> {
    match receiver {
        Some(receiver) => receiver.changed().await,
        None => pending().await,
    }
}

async fn receive_streams_control(
    receiver: &mut Option<mpsc::Receiver<StreamsControl>>,
) -> Option<StreamsControl> {
    match receiver {
        Some(receiver) => receiver.recv().await,
        None => pending().await,
    }
}

async fn receive_blueprint_event(
    receiver: &mut Option<mpsc::Receiver<BlueprintEvent>>,
) -> Option<BlueprintEvent> {
    match receiver {
        Some(receiver) => receiver.recv().await,
        None => pending().await,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    use std::collections::HashMap;
    use std::time::Duration as StdDuration;

    use futures::{SinkExt, StreamExt};
    use tokio::sync::Mutex;
    use tokio_util::codec::Framed;

    use teleop_protocol::{
        listen, AdapterCodec, AdapterToBridge, AxisDef, BridgeToAdapter, CaptureStreamsConfig,
        ControlSchema, DeviceCommand, DeviceInfo, DeviceSafetyConfig, Endpoint, TelemetrySchema,
    };

    /// What the mock adapter recorded from the bridge.
    #[derive(Default)]
    struct MockState {
        commands: Vec<DeviceCommand>,
        stops: usize,
    }

    /// Spin up a mock adapter on an ephemeral loopback port that replies to
    /// `Hello` with `descriptor` and records commands + stops.
    async fn spawn_mock_adapter(descriptor: DeviceDescriptor) -> (Endpoint, Arc<Mutex<MockState>>) {
        let listener = listen(&Endpoint::Tcp("127.0.0.1:0".parse().unwrap()))
            .await
            .expect("bind mock adapter");
        let endpoint = listener.endpoint();
        let state = Arc::new(Mutex::new(MockState::default()));
        let state_task = state.clone();

        tokio::spawn(async move {
            let conn = listener.accept().await.expect("accept");
            let mut framed = Framed::new(conn, AdapterCodec);
            while let Some(item) = framed.next().await {
                let msg = match item {
                    Ok(m) => m,
                    Err(_) => break,
                };
                match msg {
                    BridgeToAdapter::Hello => {
                        framed
                            .send(AdapterToBridge::Descriptor(Box::new(descriptor.clone())))
                            .await
                            .expect("send descriptor");
                    }
                    BridgeToAdapter::Command(cmd) => {
                        state_task.lock().await.commands.push(cmd);
                    }
                    BridgeToAdapter::Stop { .. } => {
                        state_task.lock().await.stops += 1;
                    }
                    BridgeToAdapter::BlueprintEvent { .. }
                    | BridgeToAdapter::StreamsStatus { .. } => {}
                    BridgeToAdapter::Shutdown => break,
                }
            }
        });

        (endpoint, state)
    }

    fn descriptor_with_throttle(timeout_ms: u64) -> DeviceDescriptor {
        DeviceDescriptor {
            device: DeviceInfo {
                device_type: "test".into(),
                name: "Forward Test".into(),
                icon: String::new(),
                model_url: String::new(),
            },
            control_schema: ControlSchema {
                axes: vec![AxisDef {
                    name: "throttle".into(),
                    display: String::new(),
                    range: (-1.0, 1.0),
                    default: 0.0,
                    dead_zone: 0.0,
                }],
                buttons: vec![],
                poses: vec![],
            },
            input_mapping: vec![],
            telemetry_schema: TelemetrySchema::default(),
            video_feeds: vec![],
            safety: DeviceSafetyConfig {
                disconnect_action: "stop".into(),
                command_timeout_ms: timeout_ms,
                limits: HashMap::new(),
            },
            ..Default::default()
        }
    }

    /// A command pushed into the watch with an out-of-range axis must reach the
    /// adapter CLAMPED to the declared range.
    #[tokio::test]
    async fn sanitizes_before_forwarding() {
        let desc = descriptor_with_throttle(500);
        let (endpoint, state) = spawn_mock_adapter(desc.clone()).await;

        let mut client = AdapterClient::connect(&endpoint).await.unwrap();
        client.handshake().await.unwrap();

        let (cmd_tx, cmd_rx) = watch::channel::<Option<TimedCommand>>(None);
        let forward = tokio::spawn(run(Arc::new(desc), cmd_rx, client, LatencyRecorder::new()));

        // Out-of-range throttle (5.0) → must arrive clamped to 1.0.
        let mut cmd = DeviceCommand::default();
        cmd.axes.insert("throttle".into(), 5.0);
        cmd_tx
            .send(Some(TimedCommand {
                cmd,
                seq: 1,
                t_rx_ns: 0,
            }))
            .unwrap();

        // Poll for the adapter to observe the clamped value.
        let ok = tokio::time::timeout(StdDuration::from_secs(2), async {
            loop {
                if let Some(c) = state.lock().await.commands.first() {
                    assert_eq!(*c.axes.get("throttle").unwrap(), 1.0);
                    return;
                }
                tokio::time::sleep(StdDuration::from_millis(5)).await;
            }
        })
        .await;
        assert!(ok.is_ok(), "adapter never received the clamped command");

        forward.abort();
    }

    /// A command with an unknown axis is rejected by safety and never reaches
    /// the adapter.
    #[tokio::test]
    async fn rejected_command_not_forwarded() {
        let desc = descriptor_with_throttle(500);
        let (endpoint, state) = spawn_mock_adapter(desc.clone()).await;

        let mut client = AdapterClient::connect(&endpoint).await.unwrap();
        client.handshake().await.unwrap();

        let (cmd_tx, cmd_rx) = watch::channel::<Option<TimedCommand>>(None);
        let forward = tokio::spawn(run(Arc::new(desc), cmd_rx, client, LatencyRecorder::new()));

        let mut cmd = DeviceCommand::default();
        cmd.axes.insert("nonexistent".into(), 0.5);
        cmd_tx
            .send(Some(TimedCommand {
                cmd,
                seq: 1,
                t_rx_ns: 0,
            }))
            .unwrap();

        // Give the forwarder a moment; the rejected command must not arrive.
        tokio::time::sleep(StdDuration::from_millis(200)).await;
        assert_eq!(state.lock().await.commands.len(), 0);

        forward.abort();
    }

    /// With no command for longer than the timeout, the watchdog sends exactly
    /// one `Stop` to the adapter.
    #[tokio::test]
    async fn watchdog_stops_once_when_headset_quiet() {
        // Short timeout so the test runs quickly under the real clock.
        let desc = descriptor_with_throttle(120);
        let (endpoint, state) = spawn_mock_adapter(desc.clone()).await;

        let mut client = AdapterClient::connect(&endpoint).await.unwrap();
        client.handshake().await.unwrap();

        let (cmd_tx, cmd_rx) = watch::channel::<Option<TimedCommand>>(None);
        let forward = tokio::spawn(run(Arc::new(desc), cmd_rx, client, LatencyRecorder::new()));

        // Send one command to start the idle timer.
        let mut cmd = DeviceCommand::default();
        cmd.axes.insert("throttle".into(), 0.2);
        cmd_tx
            .send(Some(TimedCommand {
                cmd,
                seq: 1,
                t_rx_ns: 0,
            }))
            .unwrap();

        // Wait well past the timeout (period <= 50ms, timeout 120ms): the
        // watchdog should fire exactly once.
        let stopped = tokio::time::timeout(StdDuration::from_secs(2), async {
            loop {
                if state.lock().await.stops >= 1 {
                    return;
                }
                tokio::time::sleep(StdDuration::from_millis(10)).await;
            }
        })
        .await;
        assert!(stopped.is_ok(), "watchdog never sent a Stop");

        // Stay idle a bit longer; it must NOT fire again.
        tokio::time::sleep(StdDuration::from_millis(400)).await;
        assert_eq!(
            state.lock().await.stops,
            1,
            "watchdog should fire exactly once per idle period"
        );

        forward.abort();
    }

    /// Headset status reaches a declaring adapter; adapter control reaches
    /// the capture-capable headset connection, in order.
    #[tokio::test]
    async fn routes_capture_streams_ctrl_between_adapter_and_headset() {
        let mut desc = descriptor_with_throttle(60_000);
        desc.capture_streams = Some(CaptureStreamsConfig::default());
        let listener = listen(&Endpoint::Tcp("127.0.0.1:0".parse().unwrap()))
            .await
            .unwrap();
        let endpoint = listener.endpoint();
        let adapter_desc = desc.clone();
        let (status_tx, mut status_rx) = mpsc::channel(4);
        let (go_tx, go_rx) = tokio::sync::oneshot::channel::<()>();
        tokio::spawn(async move {
            let conn = listener.accept().await.unwrap();
            let mut framed = Framed::new(conn, AdapterCodec);
            let mut go_rx = Some(go_rx);
            while let Some(Ok(message)) = framed.next().await {
                match message {
                    BridgeToAdapter::Hello => {
                        framed
                            .send(AdapterToBridge::Descriptor(Box::new(adapter_desc.clone())))
                            .await
                            .unwrap();
                        go_rx.take().unwrap().await.unwrap();
                        for hz in [2.0, 3.0] {
                            let mut control = StreamsControl::default();
                            control.streams.insert(
                                "rgb.hevc".into(),
                                teleop_protocol::StreamControl {
                                    hz: Some(hz),
                                    ..Default::default()
                                },
                            );
                            framed
                                .send(AdapterToBridge::StreamsControl {
                                    control: Box::new(control),
                                })
                                .await
                                .unwrap();
                        }
                    }
                    BridgeToAdapter::StreamsStatus { status } => {
                        status_tx.send(status.map(|status| *status)).await.unwrap();
                    }
                    _ => {}
                }
            }
        });

        let mut client = AdapterClient::connect(&endpoint).await.unwrap();
        client.handshake().await.unwrap();
        let streams = StreamsChannels::new();
        let (attachment, control_rx) = streams.attach(true);
        let mut control_rx = control_rx.expect("capture-capable headset gets a queue");
        let (_cmd_tx, cmd_rx) = watch::channel::<Option<TimedCommand>>(None);
        let (_event_tx, event_rx) = mpsc::channel(1);
        let forward = tokio::spawn(run_with_blueprint_events_and_streams(
            Arc::new(desc),
            cmd_rx,
            client,
            LatencyRecorder::new(),
            event_rx,
            streams.clone(),
        ));
        go_tx.send(()).unwrap();

        for hz in [2.0, 3.0] {
            let control = tokio::time::timeout(StdDuration::from_secs(2), control_rx.recv())
                .await
                .expect("StreamsControl did not reach the headset queue")
                .unwrap();
            assert_eq!(control.streams["rgb.hevc"].hz, Some(hz));
        }

        let status: StreamsStatus = serde_json::from_str(
            r#"{"schema":"operator.streams_status.v1","streams":{"rgb.hevc":{"state":"active","hz":3.0}}}"#,
        )
        .unwrap();
        attachment.publish(status.clone());
        let forwarded = tokio::time::timeout(StdDuration::from_secs(2), status_rx.recv())
            .await
            .expect("StreamsStatus did not reach the adapter")
            .unwrap();
        assert_eq!(forwarded, Some(status));

        // The reporting headset goes away: the adapter must be told, or it
        // keeps believing capture is still running.
        drop(attachment);
        let cleared = tokio::time::timeout(StdDuration::from_secs(2), status_rx.recv())
            .await
            .expect("cleared StreamsStatus did not reach the adapter")
            .unwrap();
        assert_eq!(cleared, None);
        forward.abort();
    }

    /// An adapter whose descriptor declares no capture streams (or whose
    /// declaration was stripped as invalid) may not steer the headset's
    /// camera: the control direction follows the same gate as status.
    #[tokio::test]
    async fn undeclared_adapter_cannot_control_capture_streams() {
        let desc = descriptor_with_throttle(60_000);
        assert!(desc.capture_streams.is_none());
        let listener = listen(&Endpoint::Tcp("127.0.0.1:0".parse().unwrap()))
            .await
            .unwrap();
        let endpoint = listener.endpoint();
        let adapter_desc = desc.clone();
        tokio::spawn(async move {
            let conn = listener.accept().await.unwrap();
            let mut framed = Framed::new(conn, AdapterCodec);
            while let Some(Ok(message)) = framed.next().await {
                if matches!(message, BridgeToAdapter::Hello) {
                    framed
                        .send(AdapterToBridge::Descriptor(Box::new(adapter_desc.clone())))
                        .await
                        .unwrap();
                    let mut control = StreamsControl::default();
                    control.streams.insert(
                        "rgb.hevc".into(),
                        teleop_protocol::StreamControl {
                            hz: Some(30.0),
                            ..Default::default()
                        },
                    );
                    framed
                        .send(AdapterToBridge::StreamsControl {
                            control: Box::new(control),
                        })
                        .await
                        .unwrap();
                }
            }
        });

        let mut client = AdapterClient::connect(&endpoint).await.unwrap();
        client.handshake().await.unwrap();
        let streams = StreamsChannels::new();
        let (_attachment, control_rx) = streams.attach(true);
        let mut control_rx = control_rx.expect("capture-capable headset gets a queue");
        let (_cmd_tx, cmd_rx) = watch::channel::<Option<TimedCommand>>(None);
        let (_event_tx, event_rx) = mpsc::channel(1);
        let forward = tokio::spawn(run_with_blueprint_events_and_streams(
            Arc::new(desc),
            cmd_rx,
            client,
            LatencyRecorder::new(),
            event_rx,
            streams.clone(),
        ));

        let queued = tokio::time::timeout(StdDuration::from_millis(300), control_rx.recv()).await;
        assert!(
            queued.is_err(),
            "an undeclared adapter must not reach the headset"
        );
        forward.abort();
    }

    #[tokio::test]
    async fn streams_channels_report_connection_and_capability_errors() {
        let streams = StreamsChannels::new();
        let control = StreamsControl::default();
        assert_eq!(
            streams.send_control(control.clone()),
            Err(StreamsControlError::NotConnected)
        );
        let (legacy, no_queue) = streams.attach(false);
        assert!(no_queue.is_none());
        assert!(!streams.headset_supported());
        assert_eq!(
            streams.send_control(control.clone()),
            Err(StreamsControlError::Unsupported)
        );
        let invalid = StreamsControl {
            schema: "wrong".into(),
            ..StreamsControl::default()
        };
        assert!(matches!(
            streams.send_control(invalid),
            Err(StreamsControlError::Invalid(_))
        ));

        // A newer capable headset takes over; the old guard no longer owns it.
        let (current, queue) = streams.attach(true);
        let _queue = queue.unwrap();
        drop(legacy);
        assert!(streams.headset_supported());
        let status: StreamsStatus =
            serde_json::from_str(r#"{"schema":"operator.streams_status.v1"}"#).unwrap();
        current.publish(status);
        assert!(streams.latest_status().is_some());
        for _ in 0..16 {
            streams.send_control(control.clone()).unwrap();
        }
        assert_eq!(
            streams.send_control(control),
            Err(StreamsControlError::QueueFull)
        );
        drop(current);
        assert!(!streams.headset_supported());
        assert!(streams.latest_status().is_none());
    }
}
