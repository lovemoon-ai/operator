//! Client for the bridge→adapter boundary connection.
//!
//! [`AdapterClient`] owns the write half of a framed [`teleop_protocol`]
//! connection and spawns a background task that drains the read half. The
//! client sends [`BridgeToAdapter`] messages directly on `&mut self`; inbound
//! [`AdapterToBridge`] messages are fanned out to callers via two channels:
//!
//! * a `watch::Receiver<Option<DeviceTelemetry>>` holding the latest telemetry
//!   (drop-old semantics — callers only care about the freshest sample), and
//! * an `mpsc::Receiver<AdapterToBridge>` carrying a best-effort stream of
//!   inbound messages (telemetry, events) for diagnostics.
//!
//! Lifecycle: [`connect`](AdapterClient::connect) →
//! [`handshake`](AdapterClient::handshake) (sends `Hello`, awaits
//! `Descriptor`, then spawns the reader) →
//! [`send_command`](AdapterClient::send_command) /
//! [`stop`](AdapterClient::stop) / [`shutdown`](AdapterClient::shutdown).
//!
//! Implementation note: a `Framed` is both a `Stream` and a `Sink`. We use
//! [`futures::StreamExt::split`] to obtain an independent read half
//! (`SplitStream`) and write half (`SplitSink`). The handshake reads the first
//! frame (the descriptor) *before* splitting so callers see a fully-formed
//! descriptor synchronously, then moves the read half into the reader task.

use anyhow::{anyhow, Context, Result};
use futures::stream::{SplitSink, SplitStream};
use futures::{SinkExt, StreamExt};
use tokio::sync::{mpsc, watch};
use tokio_util::codec::Framed;

use teleop_protocol::{
    connect, AdapterToBridge, BridgeCodec, BridgeToAdapter, Conn, DeviceCommand, DeviceDescriptor,
    DeviceTelemetry, Endpoint,
};

/// The framed sink/stream over the boundary connection.
type FramedConn = Framed<Conn, BridgeCodec>;
type Sink = SplitSink<FramedConn, BridgeToAdapter>;
type Stream = SplitStream<FramedConn>;

/// Connected client to a robot-adapter.
pub struct AdapterClient {
    /// The connection, in one of two states:
    /// * `PreHandshake` — full `Framed`, before the descriptor exchange.
    /// * `Connected` — only the write half; the read half is owned by the
    ///   background reader task.
    state: ConnState,
    /// Latest telemetry watch sender (the reader task moves a clone in; we keep
    /// the original so the channel stays open even before the reader spawns).
    telemetry_tx: watch::Sender<Option<DeviceTelemetry>>,
    /// Kept alive so the watch channel never closes from the receiver side.
    telemetry_rx: watch::Receiver<Option<DeviceTelemetry>>,
    /// Best-effort inbound message fan-out sender (cloned into the reader task).
    events_tx: mpsc::Sender<AdapterToBridge>,
    /// The receiving end, handed out once via [`take_events`].
    events_rx: Option<mpsc::Receiver<AdapterToBridge>>,
    /// Reader task handle, present after handshake.
    reader: Option<tokio::task::JoinHandle<()>>,
}

enum ConnState {
    /// Before handshake: own the whole framed connection.
    PreHandshake(FramedConn),
    /// After handshake: own only the write half.
    Connected(Sink),
    /// Transient (never observed by callers).
    Empty,
}

impl AdapterClient {
    /// Dial `endpoint` and wrap the connection in the bridge codec.
    ///
    /// Does not send anything yet — call [`handshake`](Self::handshake) next.
    pub async fn connect(endpoint: &Endpoint) -> Result<AdapterClient> {
        let conn = connect(endpoint)
            .await
            .with_context(|| format!("connecting to adapter at {endpoint}"))?;
        let framed = Framed::new(conn, BridgeCodec);
        let (telemetry_tx, telemetry_rx) = watch::channel(None);
        let (events_tx, events_rx) = mpsc::channel(256);
        Ok(AdapterClient {
            state: ConnState::PreHandshake(framed),
            telemetry_tx,
            telemetry_rx,
            events_tx,
            events_rx: Some(events_rx),
            reader: None,
        })
    }

    /// Send `Hello`, await the adapter's `Descriptor`, then spawn the
    /// background reader task that drains subsequent inbound messages.
    ///
    /// Returns the device descriptor advertised by the adapter.
    pub async fn handshake(&mut self) -> Result<DeviceDescriptor> {
        let mut framed = match std::mem::replace(&mut self.state, ConnState::Empty) {
            ConnState::PreHandshake(f) => f,
            ConnState::Connected(sink) => {
                // Already handshaked — restore and error.
                self.state = ConnState::Connected(sink);
                return Err(anyhow!("handshake called more than once"));
            }
            ConnState::Empty => return Err(anyhow!("client in invalid state")),
        };

        framed
            .send(BridgeToAdapter::Hello)
            .await
            .context("sending Hello")?;

        // The first meaningful inbound frame must be the descriptor.
        let descriptor = loop {
            match framed.next().await {
                Some(Ok(AdapterToBridge::Descriptor(desc))) => break desc,
                Some(Ok(AdapterToBridge::Telemetry(_))) => {
                    tracing::debug!("Telemetry received before descriptor; ignoring");
                }
                Some(Ok(AdapterToBridge::Event { kind, msg })) => {
                    tracing::debug!("Adapter event before descriptor: {kind}: {msg}");
                }
                Some(Err(e)) => return Err(anyhow!("decode error during handshake: {e}")),
                None => return Err(anyhow!("adapter closed connection during handshake")),
            }
        };

        // Split: write half stays on the client; read half goes to the reader.
        let (sink, stream) = framed.split();
        self.state = ConnState::Connected(sink);
        self.spawn_reader(stream);

        Ok(*descriptor)
    }

    /// Frame and send a single sanitized command to the adapter.
    pub async fn send_command(&mut self, cmd: &DeviceCommand) -> Result<()> {
        self.sink_mut()?
            .send(BridgeToAdapter::Command(cmd.clone()))
            .await
            .context("sending Command")
    }

    /// Ask the adapter to safe the device immediately (watchdog / E-stop).
    pub async fn stop(&mut self, reason: String) -> Result<()> {
        self.sink_mut()?
            .send(BridgeToAdapter::Stop { reason })
            .await
            .context("sending Stop")
    }

    /// Tell the adapter to shut down cleanly.
    pub async fn shutdown(&mut self) -> Result<()> {
        self.sink_mut()?
            .send(BridgeToAdapter::Shutdown)
            .await
            .context("sending Shutdown")
    }

    /// A receiver for the latest telemetry sample (drop-old semantics). The
    /// stored value is `None` until the first telemetry frame arrives.
    pub fn telemetry(&self) -> watch::Receiver<Option<DeviceTelemetry>> {
        self.telemetry_rx.clone()
    }

    /// Take the best-effort inbound-message receiver. Returns `None` if already
    /// taken.
    ///
    /// Callers that want diagnostic access to inbound `AdapterToBridge`
    /// messages use this; callers that only want the latest telemetry use
    /// [`telemetry`](Self::telemetry).
    pub fn take_events(&mut self) -> Option<mpsc::Receiver<AdapterToBridge>> {
        self.events_rx.take()
    }

    fn sink_mut(&mut self) -> Result<&mut Sink> {
        match &mut self.state {
            ConnState::Connected(sink) => Ok(sink),
            ConnState::PreHandshake(_) => Err(anyhow!(
                "send attempted before handshake; call handshake() first"
            )),
            ConnState::Empty => Err(anyhow!("client in invalid state")),
        }
    }

    /// Move the read half into a background task that forwards inbound messages
    /// to the telemetry watch (latest) and the events mpsc (best effort).
    fn spawn_reader(&mut self, mut stream: Stream) {
        let telemetry_tx = self.telemetry_tx.clone();
        let events_tx = self.events_tx.clone();
        let handle = tokio::spawn(async move {
            while let Some(item) = stream.next().await {
                match item {
                    Ok(msg) => {
                        if let AdapterToBridge::Telemetry(t) = &msg {
                            let _ = telemetry_tx.send(Some(t.clone()));
                        }
                        // The events channel is diagnostic. It must never
                        // backpressure the reader because that would also stall
                        // the telemetry watch used by the production bridge.
                        match events_tx.try_send(msg) {
                            Ok(()) => {}
                            Err(mpsc::error::TrySendError::Full(_)) => {
                                tracing::trace!("events receiver lagging; dropping adapter event");
                            }
                            Err(mpsc::error::TrySendError::Closed(_)) => {
                                tracing::trace!("events receiver dropped; telemetry-only mode");
                            }
                        }
                    }
                    Err(e) => {
                        tracing::warn!("Adapter read error: {e}; reader task exiting");
                        break;
                    }
                }
            }
            tracing::debug!("Adapter reader task finished (connection closed)");
        });
        self.reader = Some(handle);
    }
}

impl Drop for AdapterClient {
    fn drop(&mut self) {
        if let Some(reader) = self.reader.take() {
            reader.abort();
        }
    }
}
