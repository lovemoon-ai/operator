//! Dedicated TCP server for `DeviceTelemetry` push (XR-facing).
//!
//! Copied from `robot/src/network/telemetry_server.rs` during the
//! bridge/adapter split, re-pointed at `teleop_protocol::DeviceTelemetry`.
//!
//! Spun up alongside [`pose_server`](crate::pose_server). XR clients that want
//! telemetry connect to this port; clients that don't won't pay any cost.
//! Multiple subscribers are supported (each gets a private clone of the
//! `watch::Receiver<DeviceTelemetry>`).
//!
//! Wire format: identical to the legacy telemetry frame on the pose port —
//! `[4B cmd_len LE]["Telemetry"][4B data_len LE][JSON]` — so the XR-side
//! decoder is unchanged. Only the socket address differs.
//!
//! Testability: [`run`] binds the port then delegates to [`run_on`], which
//! takes a pre-bound [`TcpListener`].

use anyhow::Result;
use futures::SinkExt;
use tokio::net::TcpListener;
use tokio::sync::watch;
use tokio_util::codec::Framed;

use teleop_protocol::DeviceTelemetry;

use crate::protocol::{CommandCodec, CommandFrame};

/// Push period for responsive hand feedback (~50 Hz). This runs on a dedicated
/// socket, so increasing visual feedback rate cannot delay the command stream.
const TELEMETRY_PERIOD: std::time::Duration = std::time::Duration::from_millis(20);

/// Run the telemetry server, binding `port` on all interfaces. Never returns
/// under normal operation.
pub async fn run(port: u16, telemetry_rx: watch::Receiver<DeviceTelemetry>) -> Result<()> {
    let listener = TcpListener::bind(("0.0.0.0", port)).await?;
    run_on(listener, telemetry_rx).await
}

/// Run the telemetry server on a pre-bound [`TcpListener`].
pub async fn run_on(
    listener: TcpListener,
    telemetry_rx: watch::Receiver<DeviceTelemetry>,
) -> Result<()> {
    tracing::info!("Telemetry server listening on {}", listener.local_addr()?);

    loop {
        let (socket, addr) = listener.accept().await?;
        // NODELAY here too — telemetry packets are tiny and we don't want
        // Nagle batching them with the next push.
        socket.set_nodelay(true)?;
        tracing::info!("Telemetry subscriber connected from {addr}");

        let telemetry_rx = telemetry_rx.clone();
        tokio::spawn(async move {
            if let Err(e) = serve_one(socket, telemetry_rx).await {
                tracing::warn!("Telemetry subscriber {addr} disconnected: {e}");
            } else {
                tracing::info!("Telemetry subscriber {addr} disconnected");
            }
        });
    }
}

/// Serve a single subscriber: push the latest `DeviceTelemetry` every
/// `TELEMETRY_PERIOD`. Returns when the socket closes.
async fn serve_one(
    socket: tokio::net::TcpStream,
    mut telemetry_rx: watch::Receiver<DeviceTelemetry>,
) -> Result<()> {
    let mut framed = Framed::new(socket, CommandCodec);
    let mut interval = tokio::time::interval(TELEMETRY_PERIOD);

    loop {
        interval.tick().await;
        let telemetry = telemetry_rx.borrow_and_update().clone();
        let json = serde_json::to_vec(&telemetry)?;
        let frame = CommandFrame {
            command: "Telemetry".to_string(),
            data: json,
        };
        framed.send(frame).await?;
    }
}
