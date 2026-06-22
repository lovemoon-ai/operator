//! The adapter server: accept bridge connections and drive the device.
//!
//! For each accepted connection the server wraps the transport in a
//! `Framed<_, AdapterCodec>` and runs a per-connection loop that:
//!
//! * replies to `Hello` with the device [`Descriptor`](AdapterToBridge::Descriptor),
//! * forwards `Command` frames to [`Device::send_command`] (errors become an
//!   `Event{kind:"error"}`),
//! * triggers [`Device::emergency_stop`] on `Stop`,
//! * exits the connection loop on `Shutdown`,
//! * triggers [`Device::emergency_stop`] on EOF or transport failure,
//! * pushes [`Telemetry`](AdapterToBridge::Telemetry) at ~10 Hz.
//!
//! Only one connection is served at a time (single robot). When it closes the
//! server loops back to accept the next one. The device is connected once at
//! startup and stays connected across reconnections.

use std::time::Duration;

use anyhow::Result;
use futures::{SinkExt, StreamExt};
use tokio::time::{interval, MissedTickBehavior};
use tokio_util::codec::Framed;

use teleop_protocol::{AdapterCodec, AdapterToBridge, BridgeToAdapter, Conn, Listener};

use crate::device::Device;

/// Telemetry push interval (~10 Hz).
const TELEMETRY_PERIOD: Duration = Duration::from_millis(100);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ConnectionEnd {
    ShutdownRequested,
    PeerClosed,
}

/// Run the adapter server until the listener errors.
///
/// The `device` is connected once up front and reused across every bridge
/// connection. Accepting is serialized: one bridge connection is handled at a
/// time; when it closes the next is accepted.
pub async fn serve(listener: Listener, mut device: Box<dyn Device>) -> Result<()> {
    if !device.is_connected() {
        device.connect().await?;
    }

    tracing::info!("robot-adapter serving on {}", listener.endpoint());

    loop {
        let conn = match listener.accept().await {
            Ok(conn) => conn,
            Err(e) => {
                tracing::error!("accept failed: {e}");
                return Err(e.into());
            }
        };
        tracing::info!("bridge connected");

        match handle_conn(conn, device.as_mut()).await {
            Ok(ConnectionEnd::ShutdownRequested) => {
                tracing::info!("bridge requested shutdown");
            }
            Ok(ConnectionEnd::PeerClosed) => {
                tracing::warn!("bridge disconnected without Shutdown; emergency-stopping device");
                emergency_stop_after_disconnect(device.as_mut(), "bridge EOF").await;
            }
            Err(e) => {
                tracing::warn!("connection ended with error: {e}");
                emergency_stop_after_disconnect(device.as_mut(), "connection error").await;
            }
        }
    }
}

/// Handle a single bridge connection to completion.
async fn handle_conn(conn: Conn, device: &mut dyn Device) -> Result<ConnectionEnd> {
    let mut framed = Framed::new(conn, AdapterCodec::default());

    let mut tick = interval(TELEMETRY_PERIOD);
    // If we fall behind (slow device), skip rather than burst.
    tick.set_missed_tick_behavior(MissedTickBehavior::Delay);

    loop {
        tokio::select! {
            // Inbound message from the bridge.
            maybe_msg = framed.next() => {
                match maybe_msg {
                    Some(Ok(msg)) => {
                        if handle_message(msg, device, &mut framed).await? {
                            // Shutdown requested.
                            return Ok(ConnectionEnd::ShutdownRequested);
                        }
                    }
                    Some(Err(e)) => {
                        tracing::warn!("frame decode error: {e}");
                        return Err(e.into());
                    }
                    None => {
                        // EOF — bridge closed the connection.
                        return Ok(ConnectionEnd::PeerClosed);
                    }
                }
            }

            // Periodic telemetry push.
            _ = tick.tick() => {
                match device.get_telemetry().await {
                    Ok(tel) => {
                        if let Err(e) = framed.send(AdapterToBridge::Telemetry(tel)).await {
                            tracing::warn!("telemetry send failed: {e}");
                            return Err(e.into());
                        }
                    }
                    Err(e) => {
                        tracing::warn!("get_telemetry failed: {e}");
                    }
                }
            }
        }
    }
}

async fn emergency_stop_after_disconnect(device: &mut dyn Device, reason: &str) {
    if let Err(e) = device.emergency_stop().await {
        tracing::error!("emergency_stop after {reason} failed: {e}");
    }
}

/// Process one inbound message. Returns `Ok(true)` if the connection should
/// shut down.
async fn handle_message(
    msg: BridgeToAdapter,
    device: &mut dyn Device,
    framed: &mut Framed<Conn, AdapterCodec>,
) -> Result<bool> {
    match msg {
        BridgeToAdapter::Hello => {
            tracing::debug!("Hello -> Descriptor");
            framed
                .send(AdapterToBridge::Descriptor(device.descriptor().clone()))
                .await?;
        }
        BridgeToAdapter::Command(cmd) => {
            if let Err(e) = device.send_command(&cmd).await {
                tracing::warn!("send_command failed: {e}");
                framed
                    .send(AdapterToBridge::Event {
                        kind: "error".to_string(),
                        msg: format!("send_command failed: {e}"),
                    })
                    .await?;
            }
        }
        BridgeToAdapter::Stop { reason } => {
            tracing::warn!("Stop received: {reason}");
            if let Err(e) = device.emergency_stop().await {
                tracing::error!("emergency_stop failed: {e}");
                framed
                    .send(AdapterToBridge::Event {
                        kind: "error".to_string(),
                        msg: format!("emergency_stop failed: {e}"),
                    })
                    .await?;
            } else {
                framed
                    .send(AdapterToBridge::Event {
                        kind: "estop".to_string(),
                        msg: reason,
                    })
                    .await?;
            }
        }
        BridgeToAdapter::Shutdown => {
            tracing::info!("Shutdown received");
            return Ok(true);
        }
    }
    Ok(false)
}
