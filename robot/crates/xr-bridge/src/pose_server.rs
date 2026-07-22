//! TCP command server for the Operator v2 protocol (XR-facing).
//!
//! Copied from `robot/src/network/pose_server.rs` during the bridge/adapter
//! split, re-pointed at `teleop_protocol` types and the bridge-local
//! [`TimedCommand`]. Commands land in a `watch::Sender<Option<TimedCommand>>`
//! that the [`forward`](crate::forward) loop drains (sanitize → adapter); this
//! server no longer talks to a device directly.
//!
//! Listens on the configured port (default 63901) and accepts connections from
//! XR headsets. Protocol flow:
//!
//! 1. Headset sends "Hello" → Server responds with "DeviceDescriptor"
//! 2. Headset sends "DeviceCommand" → pushed into the command watch channel
//! 3. Server periodically sends "Telemetry" back to headset
//!
//! Testability: [`run`] binds the port then delegates to [`run_on`], which
//! takes a pre-bound [`TcpListener`] so a test can bind `127.0.0.1:0` and read
//! the OS-assigned address before spawning the server.

use std::sync::Arc;

use anyhow::Result;
use futures::{SinkExt, StreamExt};
use tokio::net::TcpListener;
use tokio::sync::{mpsc, watch};
use tokio::task::JoinHandle;
use tokio_util::codec::Framed;

use teleop_protocol::{
    DeviceCommand, DeviceDescriptor, DeviceTelemetry, XrStateFrame, XR_STATE_SCHEMA_VERSION,
};

use crate::latency::{self, LatencyRecorder};
use crate::protocol::{CommandCodec, CommandFrame};
use crate::sdk::XrStateSink;
use crate::wire_runtime::{build_descriptor_frame, TimedCommand};

/// Tokio tasks detach when their handle is dropped. Connection-local tasks
/// must instead be cancelled with their parent so they release socket halves
/// when a newer SDK headset takes ownership.
struct AbortTaskOnDrop(JoinHandle<()>);

impl Drop for AbortTaskOnDrop {
    fn drop(&mut self) {
        self.0.abort();
    }
}

/// Run the command server, binding `port` on all interfaces. Never returns
/// under normal operation.
pub async fn run(
    port: u16,
    descriptor: Arc<DeviceDescriptor>,
    device_cmd_tx: watch::Sender<Option<TimedCommand>>,
    telemetry_rx: watch::Receiver<DeviceTelemetry>,
    latency: Arc<LatencyRecorder>,
) -> Result<()> {
    let listener = TcpListener::bind(("0.0.0.0", port)).await?;
    run_on(listener, descriptor, device_cmd_tx, telemetry_rx, latency).await
}

/// SDK variant of [`run`] that additionally publishes raw XR snapshots.
pub async fn run_with_xr_state(
    port: u16,
    descriptor: Arc<DeviceDescriptor>,
    device_cmd_tx: watch::Sender<Option<TimedCommand>>,
    telemetry_rx: watch::Receiver<DeviceTelemetry>,
    latency: Arc<LatencyRecorder>,
    xr_state_sink: XrStateSink,
) -> Result<()> {
    let listener = TcpListener::bind(("0.0.0.0", port)).await?;
    run_on_inner(
        listener,
        descriptor,
        device_cmd_tx,
        telemetry_rx,
        latency,
        Some(xr_state_sink),
    )
    .await
}

/// Test/embedder variant that accepts an already-bound listener.
pub async fn run_on_with_xr_state(
    listener: TcpListener,
    descriptor: Arc<DeviceDescriptor>,
    device_cmd_tx: watch::Sender<Option<TimedCommand>>,
    telemetry_rx: watch::Receiver<DeviceTelemetry>,
    latency: Arc<LatencyRecorder>,
    xr_state_sink: XrStateSink,
) -> Result<()> {
    run_on_inner(
        listener,
        descriptor,
        device_cmd_tx,
        telemetry_rx,
        latency,
        Some(xr_state_sink),
    )
    .await
}

/// Run the command server on a pre-bound [`TcpListener`]. Used by tests that
/// bind an ephemeral port and need to read `local_addr()` first.
pub async fn run_on(
    listener: TcpListener,
    descriptor: Arc<DeviceDescriptor>,
    device_cmd_tx: watch::Sender<Option<TimedCommand>>,
    telemetry_rx: watch::Receiver<DeviceTelemetry>,
    latency: Arc<LatencyRecorder>,
) -> Result<()> {
    run_on_inner(
        listener,
        descriptor,
        device_cmd_tx,
        telemetry_rx,
        latency,
        None,
    )
    .await
}

async fn run_on_inner(
    listener: TcpListener,
    descriptor: Arc<DeviceDescriptor>,
    device_cmd_tx: watch::Sender<Option<TimedCommand>>,
    telemetry_rx: watch::Receiver<DeviceTelemetry>,
    latency: Arc<LatencyRecorder>,
    xr_state_sink: Option<XrStateSink>,
) -> Result<()> {
    tracing::info!("Command server listening on {}", listener.local_addr()?);
    let mut active_sdk_connection: Option<JoinHandle<()>> = None;

    loop {
        let (socket, addr) = listener.accept().await?;
        socket.set_nodelay(true)?;
        tracing::info!("Headset connected from {addr}");

        let descriptor = descriptor.clone();
        let device_cmd_tx = device_cmd_tx.clone();
        let telemetry_rx = telemetry_rx.clone();
        let latency = latency.clone();
        let xr_state_sink = xr_state_sink.clone();
        let sdk_mode = xr_state_sink.is_some();

        // Stamp a fresh session id so any in-flight stale frames from a
        // previous connection get ignored by the aggregator.
        latency.new_session();

        // The SDK exports one atomic latest-state stream. Mixing two headset
        // producers would destroy that guarantee, so a newly accepted SDK
        // connection replaces the previous one. Normal robot-service mode
        // keeps its existing multi-client behavior.
        if sdk_mode {
            if let Some(active) = active_sdk_connection.take() {
                active.abort();
                let _ = active.await;
                if let Some(sink) = &xr_state_sink {
                    sink.stats.set_connected(false);
                }
                tracing::info!("Replaced previous SDK headset connection");
            }
        }

        let task = tokio::spawn(async move {
            if let Err(e) = handle_connection(
                socket,
                addr,
                descriptor,
                device_cmd_tx,
                telemetry_rx,
                latency,
                xr_state_sink.clone(),
            )
            .await
            {
                tracing::warn!("Connection error for {addr}: {e}");
            }
            if let Some(sink) = xr_state_sink {
                sink.stats.set_connected(false);
            }
            tracing::info!("Headset disconnected from {addr}");
        });
        if sdk_mode {
            active_sdk_connection = Some(task);
        }
    }
}

/// Handle a single headset connection:
/// 1. Wait for Hello, send DeviceDescriptor
/// 2. Split connection: read commands + write telemetry concurrently
async fn handle_connection(
    socket: tokio::net::TcpStream,
    addr: std::net::SocketAddr,
    descriptor: Arc<DeviceDescriptor>,
    device_cmd_tx: watch::Sender<Option<TimedCommand>>,
    mut telemetry_rx: watch::Receiver<DeviceTelemetry>,
    latency: Arc<LatencyRecorder>,
    xr_state_sink: Option<XrStateSink>,
) -> Result<()> {
    let mut framed = Framed::new(socket, CommandCodec);

    // --- Phase 1: Handshake (sequential, before split) ---
    let handshake_timeout = tokio::time::Duration::from_secs(5);
    match tokio::time::timeout(handshake_timeout, framed.next()).await {
        Ok(Some(Ok(frame))) => {
            if frame.command == "Hello" {
                if let Some(sink) = &xr_state_sink {
                    if !hello_supports_xr_state(&frame.data) {
                        let error = format!(
                            "headset {addr} does not advertise required capability xr_state_v1; update the Operator XR app"
                        );
                        sink.stats.record_error(error.clone());
                        anyhow::bail!(error);
                    }
                }
                tracing::info!("Hello received from {addr}");
                let resp = build_descriptor_frame(&descriptor);
                framed.send(resp).await?;
                tracing::info!("Sent DeviceDescriptor to {addr}");
                if let Some(sink) = &xr_state_sink {
                    sink.stats.clear_error();
                    sink.stats.set_connected(true);
                }
            } else {
                if let Some(sink) = &xr_state_sink {
                    let error = format!(
                        "expected Hello with xr_state_v1 capability from SDK headset, got '{}'",
                        frame.command
                    );
                    sink.stats.record_error(error.clone());
                    anyhow::bail!(error);
                }
                // Not a Hello — treat as DeviceCommand directly (no handshake).
                tracing::warn!(
                    "Expected Hello but got '{}', proceeding anyway",
                    frame.command
                );
                if frame.command == "DeviceCommand" {
                    if let Ok(cmd) = serde_json::from_slice::<DeviceCommand>(&frame.data) {
                        let t_rx_ns = latency::wall_clock_ns();
                        let seq = latency.record_rx(cmd.timestamp_ns, t_rx_ns);
                        // send_replace overwrites any prior unread value,
                        // implementing the "drop old" semantics that protects
                        // us from HOL when the consumer is slow.
                        let _ =
                            device_cmd_tx.send_replace(Some(TimedCommand { cmd, seq, t_rx_ns }));
                    }
                }
            }
        }
        Ok(Some(Err(e))) => {
            tracing::error!("Handshake decode error from {addr}: {e}");
            if let Some(sink) = &xr_state_sink {
                sink.stats
                    .record_error(format!("invalid SDK headset handshake: {e}"));
            }
            return Ok(());
        }
        Ok(None) => {
            tracing::info!("Client {addr} disconnected during handshake");
            return Ok(());
        }
        Err(_) => {
            if let Some(sink) = &xr_state_sink {
                let error = format!(
                    "headset {addr} did not send Hello with xr_state_v1 capability within 5 seconds"
                );
                sink.stats.record_error(error.clone());
                anyhow::bail!(error);
            }
            tracing::warn!("Handshake timeout from {addr}, proceeding without Hello");
        }
    }

    // --- Phase 2: Split into concurrent read/write ---
    let (mut writer, mut reader) = framed.split();

    // Single outbound channel that both the periodic telemetry task and the
    // reader (e.g. for ClockPong replies) can push frames into. Bounded so a
    // stuck socket doesn't grow memory unboundedly.
    let (outbound_tx, mut outbound_rx) = mpsc::channel::<CommandFrame>(64);

    // Writer task: forward anything sent on outbound_rx to the socket.
    let _writer_task = AbortTaskOnDrop(tokio::spawn(async move {
        while let Some(frame) = outbound_rx.recv().await {
            if writer.send(frame).await.is_err() {
                break;
            }
        }
    }));

    // Telemetry sender: push device state to headset at ~10Hz via the outbound
    // channel.
    let telemetry_outbound = outbound_tx.clone();
    let _telemetry_task = AbortTaskOnDrop(tokio::spawn(async move {
        let mut interval = tokio::time::interval(tokio::time::Duration::from_millis(100));
        loop {
            interval.tick().await;
            let telemetry = telemetry_rx.borrow_and_update().clone();
            let json = match serde_json::to_vec(&telemetry) {
                Ok(j) => j,
                Err(_) => continue,
            };
            let frame = CommandFrame {
                command: "Telemetry".to_string(),
                data: json,
            };
            if telemetry_outbound.send(frame).await.is_err() {
                break; // Outbound channel closed -> writer task exited.
            }
        }
    }));

    // Command receiver: read frames from headset.
    while let Some(result) = reader.next().await {
        match result {
            Ok(frame) => match frame.command.as_str() {
                "DeviceCommand" => match serde_json::from_slice::<DeviceCommand>(&frame.data) {
                    Ok(cmd) => {
                        let t_rx_ns = latency::wall_clock_ns();
                        let seq = latency.record_rx(cmd.timestamp_ns, t_rx_ns);
                        tracing::trace!(
                            "DeviceCommand seq={seq}: {} axes, {} buttons, {} poses",
                            cmd.axes.len(),
                            cmd.buttons.len(),
                            cmd.poses.len()
                        );
                        // send_replace overwrites any prior unread value.
                        let _ =
                            device_cmd_tx.send_replace(Some(TimedCommand { cmd, seq, t_rx_ns }));
                    }
                    Err(e) => tracing::warn!("Bad DeviceCommand JSON: {e}"),
                },
                "XrStateFrame" => {
                    let Some(sink) = &xr_state_sink else {
                        tracing::debug!("Ignoring XrStateFrame outside SDK mode");
                        continue;
                    };
                    match serde_json::from_slice::<XrStateFrame>(&frame.data) {
                        Ok(state) if state.schema_version == XR_STATE_SCHEMA_VERSION => {
                            sink.stats.record_frame(&state);
                            sink.frame_tx.send_replace(Some(Arc::new(state)));
                        }
                        Ok(state) => {
                            let error = format!(
                                "unsupported XrStateFrame schema {} (expected {})",
                                state.schema_version, XR_STATE_SCHEMA_VERSION
                            );
                            sink.stats.record_parse_error(error.clone());
                            tracing::warn!("{error}");
                        }
                        Err(error) => {
                            sink.stats.record_parse_error(error.to_string());
                            tracing::warn!("Bad XrStateFrame JSON: {error}");
                        }
                    }
                }
                "Heartbeat" => {
                    tracing::trace!("Heartbeat from {addr}");
                }
                "ClockPing" => {
                    // NTP-style clock sync. The XR side sends a payload that
                    // includes its `t_xr_send`. We respond *immediately*
                    // (before any awaits) so `t_robot_recv` and `t_robot_send`
                    // bracket only our minimal local processing time.
                    let t_robot_recv = wall_clock_ns_i64();
                    let t_xr_send = parse_clock_ping_t_send(&frame.data);
                    let t_robot_send = wall_clock_ns_i64();
                    if t_xr_send > 0 {
                        latency.set_clock_offset(t_xr_send - t_robot_recv);
                    }
                    let payload = format!(
                        "{{\"t_xr_send\":{},\"t_robot_recv\":{},\"t_robot_send\":{}}}",
                        t_xr_send, t_robot_recv, t_robot_send
                    );
                    let pong = CommandFrame {
                        command: "ClockPong".to_string(),
                        data: payload.into_bytes(),
                    };
                    if outbound_tx.send(pong).await.is_err() {
                        // Writer is gone. Break the loop on the next recv error.
                    }
                }
                other => {
                    tracing::debug!("Unknown command from {addr}: {other}");
                }
            },
            Err(e) => {
                tracing::error!("Decode error from {addr}: {e}");
                break;
            }
        }
    }

    Ok(())
}

fn hello_supports_xr_state(data: &[u8]) -> bool {
    match serde_json::from_slice::<serde_json::Value>(data) {
        Ok(hello) => hello
            .get("capabilities")
            .and_then(serde_json::Value::as_array)
            .is_some_and(|capabilities| {
                capabilities
                    .iter()
                    .any(|capability| capability.as_str() == Some("xr_state_v1"))
            }),
        Err(_) => false,
    }
}

/// Wall-clock nanoseconds since UNIX epoch, signed (for the clock-sync
/// handshake offset arithmetic).
fn wall_clock_ns_i64() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos() as i64)
        .unwrap_or(0)
}

/// Parse a ClockPing payload of the form `{"t_xr_send":<ns>}` and return that
/// timestamp. Hand-rolled mini-parser — the payload is generated by us and the
/// format is fixed.
fn parse_clock_ping_t_send(data: &[u8]) -> i64 {
    let s = match std::str::from_utf8(data) {
        Ok(s) => s,
        Err(_) => return 0,
    };
    let needle = "\"t_xr_send\":";
    let Some(start) = s.find(needle) else {
        return 0;
    };
    let rest = &s[start + needle.len()..];
    let end = rest
        .find(|c: char| !c.is_ascii_digit() && c != '-')
        .unwrap_or(rest.len());
    rest[..end].parse::<i64>().unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_clock_ping_extracts_timestamp() {
        assert_eq!(
            parse_clock_ping_t_send(b"{\"t_xr_send\":1234567890}"),
            1234567890
        );
    }

    #[test]
    fn parse_clock_ping_missing_field_yields_zero() {
        assert_eq!(parse_clock_ping_t_send(b"{\"other\":1}"), 0);
    }

    #[test]
    fn sdk_capability_is_required_in_hello() {
        assert!(hello_supports_xr_state(
            br#"{"capabilities":["xr_state_v1","controller"]}"#
        ));
        assert!(!hello_supports_xr_state(br#"{"version":"2.0"}"#));
        assert!(!hello_supports_xr_state(b"not json"));
    }
}
