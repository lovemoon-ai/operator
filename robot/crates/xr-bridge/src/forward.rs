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

use std::sync::Arc;

use anyhow::Result;
use tokio::sync::watch;
use tokio::time::{Duration, Instant, MissedTickBehavior};

use teleop_protocol::DeviceDescriptor;

use crate::adapter_client::AdapterClient;
use crate::latency::{self, LatencyFrame, LatencyRecorder};
use crate::safety::{DeviceSafety, SafetyResult};
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
    mut cmd_rx: watch::Receiver<Option<TimedCommand>>,
    mut client: AdapterClient,
    latency: Arc<LatencyRecorder>,
) -> Result<()> {
    let mut safety = DeviceSafety::new(&descriptor);

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

#[cfg(test)]
mod tests {
    use super::*;

    use std::collections::HashMap;
    use std::time::Duration as StdDuration;

    use futures::{SinkExt, StreamExt};
    use tokio::sync::Mutex;
    use tokio_util::codec::Framed;

    use teleop_protocol::{
        listen, AdapterCodec, AdapterToBridge, AxisDef, BridgeToAdapter, ControlSchema,
        DeviceCommand, DeviceInfo, DeviceSafetyConfig, Endpoint, TelemetrySchema,
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
            let mut framed = Framed::new(conn, AdapterCodec::default());
            while let Some(item) = framed.next().await {
                let msg = match item {
                    Ok(m) => m,
                    Err(_) => break,
                };
                match msg {
                    BridgeToAdapter::Hello => {
                        framed
                            .send(AdapterToBridge::Descriptor(descriptor.clone()))
                            .await
                            .expect("send descriptor");
                    }
                    BridgeToAdapter::Command(cmd) => {
                        state_task.lock().await.commands.push(cmd);
                    }
                    BridgeToAdapter::Stop { .. } => {
                        state_task.lock().await.stops += 1;
                    }
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
        let forward = tokio::spawn(run(
            Arc::new(desc),
            cmd_rx,
            client,
            LatencyRecorder::new(),
        ));

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
        let forward = tokio::spawn(run(
            Arc::new(desc),
            cmd_rx,
            client,
            LatencyRecorder::new(),
        ));

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
        let forward = tokio::spawn(run(
            Arc::new(desc),
            cmd_rx,
            client,
            LatencyRecorder::new(),
        ));

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
}
