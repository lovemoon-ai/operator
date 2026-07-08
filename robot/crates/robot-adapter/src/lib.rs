//! robot-adapter library.
//!
//! The `robot-adapter` process receives sanitized commands from the
//! `xr-bridge` over the [`teleop_protocol`] boundary protocol and drives a
//! concrete robot form (this pass: a `DummyDevice`).
//!
//! * [`device`] — the [`device::Device`] trait every robot form implements.
//! * [`devices`] — concrete implementations (currently just
//!   [`devices::DummyDevice`]).
//! * [`server`] — the accept loop / per-connection state machine
//!   ([`server::serve`]).
//! * [`config`] — [`config::AdapterConfig`], loadable from YAML and overridable
//!   by the CLI.

pub mod config;
pub mod control;
pub mod device;
pub mod devices;
pub mod server;

pub use config::AdapterConfig;
pub use device::Device;
pub use devices::{build_device, DummyDevice, DummyHandle, GalbotG1Device, RobotArmDevice};
pub use server::serve;
