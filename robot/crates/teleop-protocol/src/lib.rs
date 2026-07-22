//! `teleop-protocol` — the bridge↔adapter boundary contract.
//!
//! Teleoperate-Anything has a boundary between two cooperating components:
//!
//! * **`xr-bridge`** — speaks the existing TCP/UDP wire protocol to the VR
//!   headset, owns video, input sanitization, and the liveness watchdog.
//! * **`robot-adapter`** — adapts one concrete robot form (dummy / sim / serial
//!   arm), owning kinematics, joint safety, and the device drivers.
//!
//! Production robot deployments usually run both components under the
//! `robot-service` binary. The boundary still exists so the components can also
//! run as separate binaries for debugging and cross-process tests.
//!
//! This crate is the *shared contract* between them. It contains no business
//! logic — only the data shapes and the framing/transport plumbing both halves
//! agree on:
//!
//! * [`wire`] — `DeviceCommand` / `DeviceTelemetry` / `Pose6D` /
//!   `TelemetryValue`. These are byte-for-byte JSON-compatible with the XR
//!   client and the legacy `robo-agent`.
//! * [`descriptor`] — `DeviceDescriptor` and friends; how a device describes
//!   its controls, telemetry, video feeds, and safety policy.
//! * [`adapter`] — the boundary message enums [`BridgeToAdapter`] /
//!   [`AdapterToBridge`] plus the paired [`BridgeCodec`] / [`AdapterCodec`]
//!   that frame them as `[4B len LE][JSON]`.
//! * [`transport`] — [`Endpoint`] (UDS or TCP, parseable from a string) plus
//!   [`listen`]/[`connect`] returning a transport-agnostic [`Conn`] you can
//!   drop straight into `tokio_util::codec::Framed`.
//!
//! `xr-bridge`, `robot-adapter`, and `robot-service` build on top of this crate;
//! the public API here is the verbatim integration surface they depend on.

pub mod adapter;
pub mod descriptor;
pub mod transport;
pub mod wire;
pub mod xr_state;

pub use adapter::*;
pub use descriptor::*;
pub use transport::*;
pub use wire::*;
pub use xr_state::*;
