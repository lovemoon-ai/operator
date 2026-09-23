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

use std::sync::Arc;

use anyhow::{anyhow, Context, Result};
use futures::stream::{SplitSink, SplitStream};
use futures::{SinkExt, StreamExt};
use tokio::sync::{mpsc, watch};
use tokio_util::codec::Framed;

use teleop_protocol::{
    connect, AdapterToBridge, Blueprint, BlueprintEvent, BlueprintState, BridgeCodec,
    BridgeToAdapter, Conn, DeviceCommand, DeviceDescriptor, DeviceTelemetry, Endpoint,
    StreamsControl, StreamsStatus, BLUEPRINT_CAPABILITY, BLUEPRINT_SPEC_HASH_CAPABILITY,
    SPEC_SHA256,
};

/// Ordered adapter `StreamsControl` backlog before newer requests are dropped.
const STREAMS_CONTROL_QUEUE: usize = 16;

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
    blueprint_tx: watch::Sender<Option<Arc<Blueprint>>>,
    blueprint_rx: watch::Receiver<Option<Arc<Blueprint>>>,
    blueprint_state_tx: watch::Sender<Option<Arc<BlueprintState>>>,
    blueprint_state_rx: watch::Receiver<Option<Arc<BlueprintState>>>,
    /// Best-effort inbound message fan-out sender (cloned into the reader task).
    events_tx: mpsc::Sender<AdapterToBridge>,
    /// The receiving end, handed out once via [`take_events`].
    events_rx: Option<mpsc::Receiver<AdapterToBridge>>,
    /// Validated adapter `StreamsControl` requests, in order.
    streams_control_tx: mpsc::Sender<StreamsControl>,
    streams_control_rx: Option<mpsc::Receiver<StreamsControl>>,
    /// Reader task handle, present after handshake.
    reader: Option<tokio::task::JoinHandle<()>>,
    blueprint_compatible: bool,
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
        let (blueprint_tx, blueprint_rx) = watch::channel(None);
        let (blueprint_state_tx, blueprint_state_rx) = watch::channel(None);
        let (events_tx, events_rx) = mpsc::channel(256);
        let (streams_control_tx, streams_control_rx) = mpsc::channel(STREAMS_CONTROL_QUEUE);
        Ok(AdapterClient {
            state: ConnState::PreHandshake(framed),
            telemetry_tx,
            telemetry_rx,
            blueprint_tx,
            blueprint_rx,
            blueprint_state_tx,
            blueprint_state_rx,
            events_tx,
            events_rx: Some(events_rx),
            streams_control_tx,
            streams_control_rx: Some(streams_control_rx),
            reader: None,
            blueprint_compatible: false,
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
                Some(Ok(AdapterToBridge::Blueprint { .. })) => {
                    tracing::debug!("Blueprint received before descriptor; ignoring");
                }
                Some(Ok(AdapterToBridge::BlueprintState { .. })) => {
                    tracing::debug!("BlueprintState received before descriptor; ignoring");
                }
                Some(Ok(AdapterToBridge::StreamsControl { .. })) => {
                    tracing::debug!("StreamsControl received before descriptor; ignoring");
                }
                Some(Ok(AdapterToBridge::Event { kind, msg })) => {
                    tracing::debug!("Adapter event before descriptor: {kind}: {msg}");
                }
                Some(Err(e)) => return Err(anyhow!("decode error during handshake: {e}")),
                None => return Err(anyhow!("adapter closed connection during handshake")),
            }
        };

        // Split: write half stays on the client; read half goes to the reader.
        self.blueprint_compatible = descriptor
            .capabilities
            .get(BLUEPRINT_CAPABILITY)
            .and_then(serde_json::Value::as_bool)
            == Some(true)
            && descriptor
                .capabilities
                .get(BLUEPRINT_SPEC_HASH_CAPABILITY)
                .and_then(serde_json::Value::as_str)
                == Some(SPEC_SHA256);
        if descriptor
            .capabilities
            .get(BLUEPRINT_CAPABILITY)
            .and_then(serde_json::Value::as_bool)
            == Some(true)
            && !self.blueprint_compatible
        {
            tracing::warn!(
                expected = SPEC_SHA256,
                actual = descriptor
                    .capabilities
                    .get(BLUEPRINT_SPEC_HASH_CAPABILITY)
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or("missing"),
                "Adapter Blueprint spec does not match bridge; Blueprint stream disabled"
            );
        }

        let (sink, stream) = framed.split();
        self.state = ConnState::Connected(sink);
        self.spawn_reader(stream, self.blueprint_compatible);

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

    /// Forward one robot-authored blueprint interaction to the adapter.
    pub async fn send_blueprint_event(&mut self, event: BlueprintEvent) -> Result<()> {
        self.sink_mut()?
            .send(BridgeToAdapter::BlueprintEvent {
                event: Box::new(event),
            })
            .await
            .context("sending BlueprintEvent")
    }

    /// Forward the headset's latest capture-stream status to the adapter.
    /// `None` clears the adapter's view: the headset that reported is gone.
    pub async fn send_streams_status(&mut self, status: Option<StreamsStatus>) -> Result<()> {
        self.sink_mut()?
            .send(BridgeToAdapter::StreamsStatus {
                status: status.map(Box::new),
            })
            .await
            .context("sending StreamsStatus")
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

    /// Latest source-authored Blueprint definition, including clears.
    pub fn blueprint(&self) -> watch::Receiver<Option<Arc<Blueprint>>> {
        self.blueprint_rx.clone()
    }

    /// Latest source-authored Blueprint state.
    pub fn blueprint_state(&self) -> watch::Receiver<Option<Arc<BlueprintState>>> {
        self.blueprint_state_rx.clone()
    }

    pub fn blueprint_compatible(&self) -> bool {
        self.blueprint_compatible
    }

    /// Take the ordered receiver of validated adapter `StreamsControl`
    /// requests. Returns `None` if already taken.
    pub fn take_streams_control(&mut self) -> Option<mpsc::Receiver<StreamsControl>> {
        self.streams_control_rx.take()
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
    fn spawn_reader(&mut self, mut stream: Stream, blueprint_compatible: bool) {
        let telemetry_tx = self.telemetry_tx.clone();
        let blueprint_tx = self.blueprint_tx.clone();
        let blueprint_state_tx = self.blueprint_state_tx.clone();
        let events_tx = self.events_tx.clone();
        let streams_control_tx = self.streams_control_tx.clone();
        let handle = tokio::spawn(async move {
            let mut active_blueprint: Option<Arc<Blueprint>> = None;
            while let Some(item) = stream.next().await {
                match item {
                    Ok(msg) => {
                        match &msg {
                            AdapterToBridge::Telemetry(telemetry) => {
                                let _ = telemetry_tx.send(Some(telemetry.clone()));
                            }
                            AdapterToBridge::Blueprint { blueprint } => {
                                if !blueprint_compatible {
                                    tracing::warn!(
                                        "Dropping Blueprint from adapter with incompatible primitive spec"
                                    );
                                    continue;
                                }
                                let blueprint = blueprint
                                    .as_ref()
                                    .map(|value| Arc::new(value.as_ref().clone()));
                                if let Some(blueprint) = &blueprint {
                                    if let Err(error) = blueprint.validate() {
                                        tracing::warn!(
                                            "Dropping invalid Blueprint from adapter: {error}"
                                        );
                                        continue;
                                    }
                                    tracing::info!(
                                        blueprint_id = %blueprint.blueprint_id,
                                        revision = blueprint.revision,
                                        components = blueprint.components.len(),
                                        "Received Blueprint from adapter"
                                    );
                                } else {
                                    tracing::info!("Adapter cleared Blueprint");
                                }
                                // BlueprintState is scoped to one exact
                                // Blueprint id/revision. Clear it before
                                // publishing any replacement so a headset can
                                // never pair the new definition with stale
                                // values from the previous one.
                                let _ = blueprint_state_tx.send(None);
                                active_blueprint = blueprint.clone();
                                let _ = blueprint_tx.send(blueprint);
                            }
                            AdapterToBridge::BlueprintState { state } => {
                                if !blueprint_compatible {
                                    tracing::warn!(
                                        "Dropping BlueprintState from adapter with incompatible primitive spec"
                                    );
                                    continue;
                                }
                                let Some(blueprint) = &active_blueprint else {
                                    tracing::warn!(
                                        "Dropping BlueprintState without an active Blueprint"
                                    );
                                    continue;
                                };
                                if let Err(error) = blueprint.validate_state(state) {
                                    tracing::warn!(
                                        "Dropping invalid BlueprintState from adapter: {error}"
                                    );
                                    continue;
                                }
                                let _ =
                                    blueprint_state_tx.send(Some(Arc::new(state.as_ref().clone())));
                            }
                            AdapterToBridge::StreamsControl { control } => {
                                if let Err(error) = control.validate() {
                                    tracing::warn!(
                                        "Dropping invalid StreamsControl from adapter: {error}"
                                    );
                                    continue;
                                }
                                // Never backpressure the reader (it also feeds
                                // telemetry); a full queue drops the request.
                                if let Err(mpsc::error::TrySendError::Full(_)) =
                                    streams_control_tx.try_send(control.as_ref().clone())
                                {
                                    tracing::warn!(
                                        "Dropping StreamsControl from adapter: queue full"
                                    );
                                }
                            }
                            AdapterToBridge::Descriptor(_) | AdapterToBridge::Event { .. } => {}
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
