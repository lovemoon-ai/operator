//! `DummyDevice` — accepts every command and reflects state in telemetry.
//!
//! Used for end-to-end testing of the adapter server without real hardware.
//! It records the last command it saw (axis/button/pose counts plus the last
//! `"gripper"` axis value if present) and counts emergency stops. Those
//! counters are exposed through a cheaply-cloneable [`DummyHandle`] so that an
//! out-of-process integration test can assert, e.g., that `emergency_stop` was
//! invoked after a `Stop` was sent over the boundary protocol.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::Result;
use async_trait::async_trait;

use teleop_protocol::{
    ControlSchema, DeviceCommand, DeviceDescriptor, DeviceInfo, DeviceTelemetry, TelemetryValue,
};

use crate::device::Device;

/// Observable shared state for a [`DummyDevice`].
///
/// Cheap to clone (it's an `Arc` internally). Hand a clone to a test before
/// the device is boxed into the server, then assert on the counters after
/// driving the boundary protocol.
#[derive(Debug, Clone, Default)]
pub struct DummyHandle {
    inner: Arc<DummyState>,
}

#[derive(Debug, Default)]
struct DummyState {
    connected: AtomicBool,
    /// Number of commands received.
    command_count: AtomicU64,
    /// Number of axes in the most recent command.
    last_axes: AtomicU64,
    /// Number of buttons in the most recent command.
    last_buttons: AtomicU64,
    /// Number of poses in the most recent command.
    last_poses: AtomicU64,
    /// Last `"gripper"` axis value (bits of an `f64`), if any command had one.
    last_gripper_bits: AtomicU64,
    /// Whether a `"gripper"` axis has ever been seen.
    has_gripper: AtomicBool,
    /// Number of emergency stops triggered.
    estop_count: AtomicU64,
}

impl DummyHandle {
    /// Whether the device is currently connected.
    pub fn is_connected(&self) -> bool {
        self.inner.connected.load(Ordering::SeqCst)
    }

    /// Total commands received so far.
    pub fn command_count(&self) -> u64 {
        self.inner.command_count.load(Ordering::SeqCst)
    }

    /// Axis count of the most recent command.
    pub fn last_axes(&self) -> u64 {
        self.inner.last_axes.load(Ordering::SeqCst)
    }

    /// Button count of the most recent command.
    pub fn last_buttons(&self) -> u64 {
        self.inner.last_buttons.load(Ordering::SeqCst)
    }

    /// Pose count of the most recent command.
    pub fn last_poses(&self) -> u64 {
        self.inner.last_poses.load(Ordering::SeqCst)
    }

    /// Last observed `"gripper"` axis value, if any command ever carried one.
    pub fn last_gripper(&self) -> Option<f64> {
        if self.inner.has_gripper.load(Ordering::SeqCst) {
            Some(f64::from_bits(self.inner.last_gripper_bits.load(Ordering::SeqCst)))
        } else {
            None
        }
    }

    /// Number of emergency stops triggered.
    pub fn estop_count(&self) -> u64 {
        self.inner.estop_count.load(Ordering::SeqCst)
    }
}

/// A dummy device that logs commands without controlling any hardware.
pub struct DummyDevice {
    descriptor: DeviceDescriptor,
    handle: DummyHandle,
}

impl DummyDevice {
    /// Construct a `DummyDevice` from a descriptor, also returning the
    /// observable [`DummyHandle`] (clone it before boxing the device).
    pub fn with_handle(descriptor: DeviceDescriptor) -> (Self, DummyHandle) {
        let handle = DummyHandle::default();
        tracing::info!("DummyDevice created: {}", descriptor.device.name);
        let device = Self {
            descriptor,
            handle: handle.clone(),
        };
        (device, handle)
    }

    /// Construct a `DummyDevice`, discarding the handle.
    pub fn new(descriptor: DeviceDescriptor) -> Self {
        Self::with_handle(descriptor).0
    }

    /// The observable handle for this device.
    pub fn handle(&self) -> DummyHandle {
        self.handle.clone()
    }

    /// A minimal built-in dummy descriptor (no controls/telemetry schema).
    pub fn default_descriptor() -> DeviceDescriptor {
        DeviceDescriptor {
            device: DeviceInfo {
                device_type: "dummy".to_string(),
                name: "Dummy Device".to_string(),
                icon: String::new(),
                model_url: String::new(),
            },
            control_schema: ControlSchema::default(),
            input_mapping: Vec::new(),
            telemetry_schema: Default::default(),
            video_feeds: Vec::new(),
            safety: Default::default(),
        }
    }
}

#[async_trait]
impl Device for DummyDevice {
    fn descriptor(&self) -> &DeviceDescriptor {
        &self.descriptor
    }

    async fn connect(&mut self) -> Result<()> {
        self.handle.inner.connected.store(true, Ordering::SeqCst);
        tracing::info!("DummyDevice connected");
        Ok(())
    }

    async fn disconnect(&mut self) -> Result<()> {
        self.handle.inner.connected.store(false, Ordering::SeqCst);
        tracing::info!("DummyDevice disconnected");
        Ok(())
    }

    async fn send_command(&mut self, cmd: &DeviceCommand) -> Result<()> {
        let s = &self.handle.inner;
        s.command_count.fetch_add(1, Ordering::SeqCst);
        s.last_axes.store(cmd.axes.len() as u64, Ordering::SeqCst);
        s.last_buttons.store(cmd.buttons.len() as u64, Ordering::SeqCst);
        s.last_poses.store(cmd.poses.len() as u64, Ordering::SeqCst);
        if let Some(g) = cmd.axes.get("gripper") {
            s.last_gripper_bits.store(g.to_bits(), Ordering::SeqCst);
            s.has_gripper.store(true, Ordering::SeqCst);
        }
        tracing::debug!(
            "DummyDevice command: axes={}, buttons={}, poses={}",
            cmd.axes.len(),
            cmd.buttons.len(),
            cmd.poses.len()
        );
        Ok(())
    }

    async fn get_telemetry(&self) -> Result<DeviceTelemetry> {
        let s = &self.handle.inner;
        let mut values = HashMap::new();
        values.insert(
            "connected".into(),
            TelemetryValue::Bool(s.connected.load(Ordering::SeqCst)),
        );
        values.insert(
            "command_count".into(),
            TelemetryValue::Int(s.command_count.load(Ordering::SeqCst) as i64),
        );
        values.insert(
            "last_axes".into(),
            TelemetryValue::Int(s.last_axes.load(Ordering::SeqCst) as i64),
        );
        values.insert(
            "last_buttons".into(),
            TelemetryValue::Int(s.last_buttons.load(Ordering::SeqCst) as i64),
        );
        values.insert(
            "last_poses".into(),
            TelemetryValue::Int(s.last_poses.load(Ordering::SeqCst) as i64),
        );
        values.insert(
            "estop_count".into(),
            TelemetryValue::Int(s.estop_count.load(Ordering::SeqCst) as i64),
        );
        if let Some(g) = self.handle.last_gripper() {
            values.insert("last_gripper".into(), TelemetryValue::Float(g));
        }

        Ok(DeviceTelemetry {
            values,
            timestamp_ns: SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_nanos() as u64,
        })
    }

    async fn emergency_stop(&mut self) -> Result<()> {
        self.handle.inner.estop_count.fetch_add(1, Ordering::SeqCst);
        tracing::warn!("DummyDevice: emergency stop (no-op)");
        Ok(())
    }

    fn is_connected(&self) -> bool {
        self.handle.inner.connected.load(Ordering::SeqCst)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cmd_with_axes(pairs: &[(&str, f64)]) -> DeviceCommand {
        let mut cmd = DeviceCommand::default();
        for (k, v) in pairs {
            cmd.axes.insert((*k).to_string(), *v);
        }
        cmd
    }

    #[tokio::test]
    async fn send_command_reflected_in_telemetry() {
        let (mut dev, handle) = DummyDevice::with_handle(DummyDevice::default_descriptor());
        dev.connect().await.unwrap();
        assert!(dev.is_connected());

        let cmd = cmd_with_axes(&[("throttle", 0.5), ("gripper", 0.8)]);
        dev.send_command(&cmd).await.unwrap();

        // Handle reflects state.
        assert_eq!(handle.command_count(), 1);
        assert_eq!(handle.last_axes(), 2);
        assert_eq!(handle.last_buttons(), 0);
        assert_eq!(handle.last_gripper(), Some(0.8));

        // Telemetry reflects the same.
        let tel = dev.get_telemetry().await.unwrap();
        assert!(matches!(
            tel.values.get("connected"),
            Some(TelemetryValue::Bool(true))
        ));
        assert!(matches!(
            tel.values.get("last_axes"),
            Some(TelemetryValue::Int(2))
        ));
        assert!(matches!(
            tel.values.get("command_count"),
            Some(TelemetryValue::Int(1))
        ));
    }

    #[tokio::test]
    async fn emergency_stop_increments_counter() {
        let (mut dev, handle) = DummyDevice::with_handle(DummyDevice::default_descriptor());
        assert_eq!(handle.estop_count(), 0);
        dev.emergency_stop().await.unwrap();
        dev.emergency_stop().await.unwrap();
        assert_eq!(handle.estop_count(), 2);

        let tel = dev.get_telemetry().await.unwrap();
        assert!(matches!(
            tel.values.get("estop_count"),
            Some(TelemetryValue::Int(2))
        ));
    }

    #[tokio::test]
    async fn no_gripper_axis_is_none() {
        let (mut dev, handle) = DummyDevice::with_handle(DummyDevice::default_descriptor());
        dev.send_command(&cmd_with_axes(&[("throttle", 0.1)])).await.unwrap();
        assert_eq!(handle.last_gripper(), None);
    }
}
