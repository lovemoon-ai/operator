//! The `Device` trait for the robot-adapter.
//!
//! Mirrors the legacy `robot/src/device/traits.rs` `Device` trait, but built
//! on the shared `teleop_protocol` types instead of the in-tree ones. A
//! concrete robot form (dummy / simulator / serial arm) implements this trait;
//! the adapter [`crate::server`] drives it from inbound boundary-protocol
//! messages.
//!
//! Note: joint-space safety and kinematics are **not** modelled here. The
//! `xr-bridge` performs input sanitization upstream, so the adapter trusts the
//! commands it receives. Any per-device clamping/IK belongs inside the
//! concrete `Device` implementation, not in a shared layer.

use anyhow::Result;
use async_trait::async_trait;

use teleop_protocol::{DeviceCommand, DeviceDescriptor, DeviceTelemetry};

/// A concrete teleoperable robot form.
#[async_trait]
pub trait Device: Send + Sync {
    /// The device's self-description (controls, telemetry, video, safety).
    fn descriptor(&self) -> &DeviceDescriptor;

    /// Bring up the hardware / sim connection.
    async fn connect(&mut self) -> Result<()>;

    /// Tear down the connection cleanly.
    async fn disconnect(&mut self) -> Result<()>;

    /// Apply a (already-sanitized) control command.
    async fn send_command(&mut self, cmd: &DeviceCommand) -> Result<()>;

    /// Snapshot the device's current telemetry.
    async fn get_telemetry(&self) -> Result<DeviceTelemetry>;

    /// Immediately safe the device (E-stop / watchdog).
    async fn emergency_stop(&mut self) -> Result<()>;

    /// Whether the device is currently connected.
    fn is_connected(&self) -> bool;
}
