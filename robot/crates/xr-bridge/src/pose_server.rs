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

use std::future::pending;
use std::sync::Arc;

use anyhow::Result;
use futures::{SinkExt, StreamExt};
use tokio::net::TcpListener;
use tokio::sync::{mpsc, watch};
use tokio::task::JoinHandle;
use tokio_util::codec::Framed;

use teleop_protocol::{
    Blueprint, BlueprintEvent, BlueprintState, DeviceCommand, DeviceDescriptor, DeviceTelemetry,
    XrStateFrame, BLUEPRINT_CAPABILITY, BLUEPRINT_COMMAND, BLUEPRINT_EVENT_COMMAND,
    BLUEPRINT_SPEC_CAPABILITY, BLUEPRINT_STATE_COMMAND, XR_STATE_SCHEMA_VERSION,
};

use crate::latency::{self, LatencyRecorder};
use crate::protocol::{CommandCodec, CommandFrame};
use crate::sdk::{BlueprintStreams, XrStateSink};
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

struct ConnectionContext {
    descriptor: Arc<DeviceDescriptor>,
    device_cmd_tx: watch::Sender<Option<TimedCommand>>,
    telemetry_rx: watch::Receiver<DeviceTelemetry>,
    latency: Arc<LatencyRecorder>,
    xr_state_sink: Option<XrStateSink>,
    blueprint: Option<BlueprintStreams>,
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

/// Adapter-backed variant with source-authored Blueprint streams.
pub async fn run_with_blueprint(
    port: u16,
    descriptor: Arc<DeviceDescriptor>,
    device_cmd_tx: watch::Sender<Option<TimedCommand>>,
    telemetry_rx: watch::Receiver<DeviceTelemetry>,
    latency: Arc<LatencyRecorder>,
    blueprint: BlueprintStreams,
) -> Result<()> {
    let listener = TcpListener::bind(("0.0.0.0", port)).await?;
    run_on_inner(
        listener,
        descriptor,
        device_cmd_tx,
        telemetry_rx,
        latency,
        None,
        Some(blueprint),
    )
    .await
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
        None,
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
        None,
    )
    .await
}

/// SDK variant with source-authored Blueprint streams.
pub async fn run_on_with_xr_state_and_blueprint(
    listener: TcpListener,
    descriptor: Arc<DeviceDescriptor>,
    device_cmd_tx: watch::Sender<Option<TimedCommand>>,
    telemetry_rx: watch::Receiver<DeviceTelemetry>,
    latency: Arc<LatencyRecorder>,
    xr_state_sink: XrStateSink,
    blueprint: Option<BlueprintStreams>,
) -> Result<()> {
    run_on_inner(
        listener,
        descriptor,
        device_cmd_tx,
        telemetry_rx,
        latency,
        Some(xr_state_sink),
        blueprint,
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
    blueprint: Option<BlueprintStreams>,
) -> Result<()> {
    tracing::info!("Command server listening on {}", listener.local_addr()?);
    let mut active_sdk_connection: Option<JoinHandle<()>> = None;

    loop {
        let (socket, addr) = listener.accept().await?;
        socket.set_nodelay(true)?;
        tracing::info!("Headset connected from {addr}");

        let context = ConnectionContext {
            descriptor: descriptor.clone(),
            device_cmd_tx: device_cmd_tx.clone(),
            telemetry_rx: telemetry_rx.clone(),
            latency: latency.clone(),
            xr_state_sink: xr_state_sink.clone(),
            blueprint: blueprint.clone(),
        };
        let sdk_mode = context.xr_state_sink.is_some();
        let connection_sink = context.xr_state_sink.clone();

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
            if let Err(e) = handle_connection(socket, addr, context).await {
                tracing::warn!("Connection error for {addr}: {e}");
            }
            if let Some(sink) = connection_sink {
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
    context: ConnectionContext,
) -> Result<()> {
    let ConnectionContext {
        descriptor,
        device_cmd_tx,
        telemetry_rx,
        latency,
        xr_state_sink,
        blueprint,
    } = context;
    let mut framed = Framed::new(socket, CommandCodec);
    let mut blueprint_enabled = false;
    let mut negotiated_blueprint_rx = None;
    let mut negotiated_state_rx = None;
    let mut negotiated_active_blueprint = None;
    let mut pending_initial_blueprint_state = None;

    // --- Phase 1: Handshake (sequential, before split) ---
    let handshake_timeout = tokio::time::Duration::from_secs(5);
    match tokio::time::timeout(handshake_timeout, framed.next()).await {
        Ok(Some(Ok(frame))) => {
            if frame.command == "Hello" {
                let headset_advertises_blueprint =
                    hello_supports_capability(&frame.data, BLUEPRINT_CAPABILITY);
                let headset_blueprint_spec_matches =
                    hello_supports_capability(&frame.data, BLUEPRINT_SPEC_CAPABILITY);
                let source_has_blueprint_stream = blueprint.is_some()
                    && descriptor
                        .capabilities
                        .get(BLUEPRINT_CAPABILITY)
                        .and_then(serde_json::Value::as_bool)
                        == Some(true)
                    && descriptor
                        .capabilities
                        .get(teleop_protocol::BLUEPRINT_SPEC_HASH_CAPABILITY)
                        .and_then(serde_json::Value::as_str)
                        == Some(teleop_protocol::SPEC_SHA256);
                blueprint_enabled = source_has_blueprint_stream
                    && headset_advertises_blueprint
                    && headset_blueprint_spec_matches;
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
                if source_has_blueprint_stream
                    && headset_advertises_blueprint
                    && !headset_blueprint_spec_matches
                {
                    tracing::warn!(
                        expected = BLUEPRINT_SPEC_CAPABILITY,
                        "Blueprint disabled for {addr}: headset primitive spec does not match bridge"
                    );
                }
                tracing::info!(
                    source_has_blueprint_stream,
                    headset_advertises_blueprint,
                    headset_blueprint_spec_matches,
                    blueprint_enabled,
                    "Blueprint capability negotiated for {addr}"
                );
                let resp = build_descriptor_frame(&descriptor);
                framed.send(resp).await?;
                tracing::info!("Sent DeviceDescriptor to {addr}");
                if blueprint_enabled {
                    if let Some(streams) = &blueprint {
                        let mut blueprint_rx = streams.blueprint_rx.clone();
                        let mut state_rx = streams.state_rx.clone();
                        let active_blueprint = blueprint_rx.borrow_and_update().clone();
                        negotiated_active_blueprint = active_blueprint.clone();
                        if let Some(blueprint) = &active_blueprint {
                            framed
                                .send(json_frame(BLUEPRINT_COMMAND, blueprint.as_ref())?)
                                .await?;
                            tracing::info!(
                                blueprint_id = %blueprint.blueprint_id,
                                revision = blueprint.revision,
                                components = blueprint.components.len(),
                                "Sent initial Blueprint to {addr}"
                            );
                        }
                        let state = state_rx.borrow_and_update().clone();
                        if let Some(state) = state {
                            if let Some(active_blueprint) = &active_blueprint {
                                match active_blueprint.validate_state(&state) {
                                    Ok(()) => {
                                        framed
                                            .send(json_frame(
                                                BLUEPRINT_STATE_COMMAND,
                                                state.as_ref(),
                                            )?)
                                            .await?;
                                        tracing::info!(
                                            blueprint_id = %state.blueprint_id,
                                            revision = state.blueprint_revision,
                                            sequence = state.sequence,
                                            values = state.values.len(),
                                            "Sent initial BlueprintState to {addr}"
                                        );
                                    }
                                    Err(error) => {
                                        tracing::warn!(
                                            "Deferring initial BlueprintState for {addr} until its Blueprint arrives: {error}"
                                        );
                                        pending_initial_blueprint_state = Some(state);
                                    }
                                }
                            } else {
                                pending_initial_blueprint_state = Some(state);
                            }
                        }
                        negotiated_blueprint_rx = Some(blueprint_rx);
                        negotiated_state_rx = Some(state_rx);
                    }
                }
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
    let (writer, mut reader) = framed.split();

    // Clock replies are ordered through a small queue. Blueprint state is
    // read directly from watch receivers by the writer so a slow socket sees
    // only the latest visual state instead of accumulating stale frames.
    let (outbound_tx, outbound_rx) = mpsc::channel::<CommandFrame>(16);
    let _writer_task = AbortTaskOnDrop(tokio::spawn(write_outbound(
        writer,
        outbound_rx,
        telemetry_rx,
        negotiated_blueprint_rx,
        negotiated_state_rx,
        negotiated_active_blueprint,
        pending_initial_blueprint_state,
    )));

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
                BLUEPRINT_EVENT_COMMAND => {
                    let Some(streams) = &blueprint else {
                        continue;
                    };
                    if !blueprint_enabled {
                        continue;
                    }
                    match serde_json::from_slice::<BlueprintEvent>(&frame.data) {
                        Ok(event) => {
                            let active_blueprint = streams.blueprint_rx.borrow().clone();
                            let Some(active_blueprint) = active_blueprint else {
                                tracing::warn!(
                                    "Dropping BlueprintEvent without an active Blueprint"
                                );
                                continue;
                            };
                            match active_blueprint.validate_event(&event) {
                                Ok(()) => {
                                    if let Err(error) = streams.event_tx.try_send(event) {
                                        tracing::warn!(
                                        "Dropping BlueprintEvent because the Python event queue is unavailable: {error}"
                                    );
                                    }
                                }
                                Err(error) => {
                                    tracing::warn!("Invalid BlueprintEvent: {error}")
                                }
                            }
                        }
                        Err(error) => {
                            tracing::warn!("Bad BlueprintEvent JSON: {error}")
                        }
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
    hello_supports_capability(data, "xr_state_v1")
}

fn hello_supports_capability(data: &[u8], expected: &str) -> bool {
    match serde_json::from_slice::<serde_json::Value>(data) {
        Ok(hello) => hello
            .get("capabilities")
            .and_then(serde_json::Value::as_array)
            .is_some_and(|capabilities| {
                capabilities
                    .iter()
                    .any(|capability| capability.as_str() == Some(expected))
            }),
        Err(_) => false,
    }
}

async fn write_outbound(
    mut writer: futures::stream::SplitSink<
        Framed<tokio::net::TcpStream, CommandCodec>,
        CommandFrame,
    >,
    mut direct_rx: mpsc::Receiver<CommandFrame>,
    mut telemetry_rx: watch::Receiver<DeviceTelemetry>,
    mut blueprint_rx: Option<watch::Receiver<Option<Arc<Blueprint>>>>,
    mut state_rx: Option<watch::Receiver<Option<Arc<BlueprintState>>>>,
    mut active_blueprint: Option<Arc<Blueprint>>,
    mut pending_state: Option<Arc<BlueprintState>>,
) {
    let mut interval = tokio::time::interval(tokio::time::Duration::from_millis(100));
    loop {
        if let (Some(blueprint), Some(state)) = (&active_blueprint, &pending_state) {
            if blueprint.validate_state(state).is_ok() {
                let frame = match json_frame(BLUEPRINT_STATE_COMMAND, state.as_ref()) {
                    Ok(frame) => frame,
                    Err(error) => {
                        tracing::warn!("Could not serialize deferred BlueprintState: {error}");
                        pending_state = None;
                        continue;
                    }
                };
                pending_state = None;
                if writer.send(frame).await.is_err() {
                    break;
                }
                continue;
            }
        }
        let frame = tokio::select! {
            biased;
            direct = direct_rx.recv() => {
                let Some(frame) = direct else { break; };
                frame
            }
            changed = optional_watch_changed(&mut blueprint_rx) => {
                if changed.is_err() {
                    blueprint_rx = None;
                    continue;
                }
                let blueprint = blueprint_rx
                    .as_mut()
                    .and_then(|receiver| receiver.borrow_and_update().clone());
                if blueprint.is_none() {
                    pending_state = None;
                }
                active_blueprint = blueprint.clone();
                match blueprint {
                    Some(blueprint) => match json_frame(BLUEPRINT_COMMAND, blueprint.as_ref()) {
                        Ok(frame) => frame,
                        Err(error) => {
                            tracing::warn!("Could not serialize Blueprint: {error}");
                            continue;
                        }
                    },
                    None => CommandFrame {
                        command: BLUEPRINT_COMMAND.to_string(),
                        data: b"null".to_vec(),
                    },
                }
            }
            changed = optional_watch_changed(&mut state_rx) => {
                if changed.is_err() {
                    state_rx = None;
                    continue;
                }
                let state = state_rx
                    .as_mut()
                    .and_then(|receiver| receiver.borrow_and_update().clone());
                let Some(state) = state else {
                    pending_state = None;
                    continue;
                };
                let Some(blueprint) = &active_blueprint else {
                    tracing::warn!("Deferring BlueprintState without an active Blueprint");
                    pending_state = Some(state);
                    continue;
                };
                if let Err(error) = blueprint.validate_state(&state) {
                    tracing::warn!(
                        "Deferring BlueprintState until its matching Blueprint arrives: {error}"
                    );
                    pending_state = Some(state);
                    continue;
                }
                match json_frame(BLUEPRINT_STATE_COMMAND, state.as_ref()) {
                    Ok(frame) => frame,
                    Err(error) => {
                        tracing::warn!("Could not serialize BlueprintState: {error}");
                        continue;
                    }
                }
            }
            _ = interval.tick() => {
                let telemetry = telemetry_rx.borrow_and_update().clone();
                match json_frame("Telemetry", &telemetry) {
                    Ok(frame) => frame,
                    Err(error) => {
                        tracing::warn!("Could not serialize Telemetry: {error}");
                        continue;
                    }
                }
            }
        };
        if writer.send(frame).await.is_err() {
            break;
        }
    }
}

async fn optional_watch_changed<T>(
    receiver: &mut Option<watch::Receiver<T>>,
) -> Result<(), watch::error::RecvError> {
    match receiver {
        Some(receiver) => receiver.changed().await,
        None => pending().await,
    }
}

fn json_frame(command: &str, value: &impl serde::Serialize) -> Result<CommandFrame> {
    Ok(CommandFrame {
        command: command.to_string(),
        data: serde_json::to_vec(value)?,
    })
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
    use tokio::net::TcpStream;

    fn test_blueprint(revision: u64) -> Blueprint {
        serde_json::from_value(serde_json::json!({
            "schema": teleop_protocol::BLUEPRINT_SCHEMA,
            "blueprint_id": "writer-order",
            "revision": revision,
            "components": [{
                "id": "menu",
                "type": "palm_menu",
                "properties": {"title": "Hand", "action": "toggle"},
                "bindings": {"value": "hand.unlocked"},
            }],
        }))
        .unwrap()
    }

    fn test_blueprint_state(revision: u64) -> BlueprintState {
        serde_json::from_value(serde_json::json!({
            "schema": teleop_protocol::BLUEPRINT_STATE_SCHEMA,
            "blueprint_id": "writer-order",
            "blueprint_revision": revision,
            "sequence": 1,
            "timestamp_ns": 1,
            "values": {"hand.unlocked": true},
        }))
        .unwrap()
    }

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

    #[tokio::test]
    async fn outbound_writer_sends_replacement_before_deferred_state() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let client = tokio::spawn(TcpStream::connect(address));
        let (server_socket, _) = listener.accept().await.unwrap();
        let client_socket = client.await.unwrap().unwrap();
        let (writer, _) = Framed::new(server_socket, CommandCodec).split();
        let mut client = Framed::new(client_socket, CommandCodec);
        let (direct_tx, direct_rx) = mpsc::channel(1);
        let (_telemetry_tx, telemetry_rx) = watch::channel(DeviceTelemetry::default());
        let (blueprint_tx, mut blueprint_rx) = watch::channel(Some(Arc::new(test_blueprint(1))));
        let initial_blueprint = blueprint_rx.borrow_and_update().clone();
        blueprint_tx.send_replace(Some(Arc::new(test_blueprint(2))));
        let (_state_tx, state_rx) = watch::channel(None);
        let writer_task = tokio::spawn(write_outbound(
            writer,
            direct_rx,
            telemetry_rx,
            Some(blueprint_rx),
            Some(state_rx),
            initial_blueprint,
            Some(Arc::new(test_blueprint_state(2))),
        ));

        let replacement = next_frame(&mut client).await;
        assert_eq!(replacement.command, BLUEPRINT_COMMAND);
        let replacement: Blueprint = serde_json::from_slice(&replacement.data).unwrap();
        assert_eq!(replacement.revision, 2);

        let state = next_frame(&mut client).await;
        assert_eq!(state.command, BLUEPRINT_STATE_COMMAND);
        let state: BlueprintState = serde_json::from_slice(&state.data).unwrap();
        assert_eq!(state.blueprint_revision, 2);

        drop(direct_tx);
        writer_task.abort();
    }

    async fn next_frame(framed: &mut Framed<TcpStream, CommandCodec>) -> CommandFrame {
        tokio::time::timeout(tokio::time::Duration::from_secs(1), framed.next())
            .await
            .expect("timed out waiting for outbound frame")
            .expect("writer closed")
            .expect("decode outbound frame")
    }
}
