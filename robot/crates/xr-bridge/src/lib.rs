//! xr-bridge library.
//!
//! The XR-facing half of Teleoperate-Anything after the bridge/adapter split.
//!
//! * [`safety`] — input sanitization of commands coming from the headset
//!   (clamp/dead-zone, reject NaN/inf/unknown-name/non-unit-quaternion,
//!   stateful toggle/confirm/group button semantics). Sanitize *before*
//!   crossing the boundary to the adapter.
//! * [`adapter_client`] — connects to a `robot-adapter`, performs the
//!   `Hello`/`Descriptor` handshake, forwards sanitized commands, and surfaces
//!   telemetry/events back to the caller.
//! * [`watchdog`] — standalone liveness helper (fires a Stop action once when
//!   the headset goes quiet). The forward loop inlines equivalent logic.
//! * [`config`] — `BridgeConfig` (adapter endpoint + XR-facing ports).
//!
//! ── XR-facing network layer (migrated from `robot/src/network/`) ──
//! * [`protocol`] — the XR wire codecs (`CommandCodec`, video codecs, the UDP
//!   `PoseUdpPacket`).
//! * [`latency`] — control-path latency instrumentation (`LatencyRecorder`).
//! * [`discovery`] — mDNS + UDP-broadcast service beacon.
//! * [`pose_server`] — TCP command server (Hello handshake, command in,
//!   telemetry out, clock sync).
//! * [`pose_udp_server`] — UDP high-frequency pose data plane (drop-old by seq).
//! * [`isaac_teleop_gateway`] — validated, drop-old UDP-to-Unix-datagram
//!   passthrough for IsaacTeleop external-input records.
//! * [`telemetry_server`] — dedicated TCP telemetry push.
//! * [`wire_runtime`] — bridge-internal `TimedCommand` envelope +
//!   `build_descriptor_frame` handshake helper.
//! * [`forward`] — the control loop: owns the `AdapterClient`, sanitizes the
//!   command stream, forwards to the adapter, and runs the watchdog.
//! * [`runtime`] — telemetry fan-in + `spawn_stack` assembly helper.

pub mod adapter_client;
pub mod config;
pub mod discovery;
pub mod forward;
pub mod isaac_teleop_gateway;
pub mod latency;
pub mod pose_server;
pub mod pose_udp_server;
pub mod protocol;
pub mod runtime;
pub mod safety;
pub mod service;
pub mod telemetry_server;
pub mod video;
pub mod watchdog;
pub mod wire_runtime;
