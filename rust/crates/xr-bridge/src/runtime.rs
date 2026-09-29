//! Wiring that assembles the XR-facing network stack on top of an
//! [`AdapterClient`].
//!
//! Two pieces live here:
//!
//! * [`telemetry_fanin`] — copies the latest telemetry the [`AdapterClient`]
//!   surfaces (a `watch::Receiver<Option<DeviceTelemetry>>`) into a
//!   `watch::Sender<DeviceTelemetry>` that `pose_server` + `telemetry_server`
//!   read (they expect a non-`Option` `watch::Receiver<DeviceTelemetry>`).
//! * [`spawn_stack`] — binds `pose_server` on `127.0.0.1:0` (or the requested
//!   loopback addr), spawns the telemetry fan-in and the [`forward`] loop (which
//!   takes ownership of the [`AdapterClient`]), and returns the bound pose
//!   address. Used by the cross-process integration test; the production binary
//!   wires the full stack inline in `main.rs`.
//!
//! Ownership note: the [`forward`] loop OWNS the client, so callers must grab
//! `client.telemetry()` BEFORE handing the client to [`spawn_stack`] /
//! [`forward::run`].

use std::net::SocketAddr;
use std::sync::Arc;

use anyhow::Result;
use tokio::net::TcpListener;
use tokio::sync::watch;

use teleop_protocol::{DeviceDescriptor, DeviceTelemetry};

use crate::adapter_client::AdapterClient;
use crate::forward;
use crate::latency::LatencyRecorder;
use crate::pose_server;
use crate::wire_runtime::TimedCommand;

/// Copy the latest non-empty telemetry from the adapter client's watch into the
/// XR-facing telemetry watch the servers read. Returns when the source channel
/// closes (adapter disconnected).
pub async fn telemetry_fanin(
    mut adapter_rx: watch::Receiver<Option<DeviceTelemetry>>,
    bridge_tx: watch::Sender<DeviceTelemetry>,
) {
    loop {
        if adapter_rx.changed().await.is_err() {
            tracing::debug!("Adapter telemetry channel closed; fan-in exiting");
            break;
        }
        if let Some(t) = adapter_rx.borrow_and_update().clone() {
            // Ignore send errors: receivers may have all dropped, which is fine.
            let _ = bridge_tx.send(t);
        }
    }
}

/// Handle to the spawned XR-network stack: the bound pose-server address plus
/// the join handles for the background tasks. Dropping it does not stop the
/// tasks (they are detached `tokio::spawn`s); the handles are returned so a
/// test can `abort()` them deterministically.
pub struct StackHandle {
    /// The address `pose_server` actually bound (with the OS-assigned port).
    pub pose_addr: SocketAddr,
    /// The command-channel sender, kept alive so the channel doesn't close.
    pub cmd_tx: watch::Sender<Option<TimedCommand>>,
    tasks: Vec<tokio::task::JoinHandle<()>>,
}

impl StackHandle {
    /// Abort every spawned task. Used by tests for clean teardown.
    pub fn abort(self) {
        for t in self.tasks {
            t.abort();
        }
    }
}

/// Assemble a minimal XR-network stack — `pose_server` + telemetry fan-in +
/// the [`forward`] loop owning the client — bound to an ephemeral loopback
/// pose port. Returns a [`StackHandle`] with the bound address.
///
/// This is the helper the integration test uses; `main.rs` wires the full set
/// of servers (discovery, UDP, telemetry server) inline.
pub async fn spawn_stack(
    descriptor: Arc<DeviceDescriptor>,
    client: AdapterClient,
) -> Result<StackHandle> {
    // Grab the telemetry receiver BEFORE moving the client into `forward`.
    let adapter_telemetry = client.telemetry();

    // Command watch fed by pose_server, drained by forward.
    let (cmd_tx, cmd_rx) = watch::channel::<Option<TimedCommand>>(None);
    // XR-facing telemetry watch fed by the fan-in, read by pose_server.
    let (telemetry_tx, telemetry_rx) = watch::channel(DeviceTelemetry::default());
    let latency = LatencyRecorder::new();

    // Bind pose_server on an ephemeral loopback port so the test learns the addr.
    let listener = TcpListener::bind(("127.0.0.1", 0)).await?;
    let pose_addr = listener.local_addr()?;

    let mut tasks = Vec::new();

    // Telemetry fan-in: adapter watch -> bridge telemetry watch.
    tasks.push(tokio::spawn(telemetry_fanin(
        adapter_telemetry,
        telemetry_tx,
    )));

    // Clone the recorder for the forward loop before pose_server moves its own.
    let forward_latency = latency.clone();

    // pose_server on the pre-bound listener.
    {
        let descriptor = descriptor.clone();
        let cmd_tx = cmd_tx.clone();
        tasks.push(tokio::spawn(async move {
            if let Err(e) =
                pose_server::run_on(listener, descriptor, cmd_tx, telemetry_rx, latency).await
            {
                tracing::warn!("pose_server exited: {e}");
            }
        }));
    }

    // The forward loop owns the client.
    tasks.push(tokio::spawn(async move {
        if let Err(e) = forward::run(descriptor, cmd_rx, client, forward_latency).await {
            tracing::warn!("forward loop exited: {e}");
        }
    }));

    Ok(StackHandle {
        pose_addr,
        cmd_tx,
        tasks,
    })
}
