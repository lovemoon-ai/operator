//! Concrete robot-form `Device` implementations.
//!
//! Ships [`dummy::DummyDevice`] and [`robot_arm::RobotArmDevice`] (the MuJoCo
//! SO-101 control chain). Serial-bus arms / rc_car land in later passes.

pub mod dummy;
pub mod robot_arm;

pub use dummy::{DummyDevice, DummyHandle};
pub use robot_arm::RobotArmDevice;

use anyhow::Result;

use crate::config::AdapterConfig;
use crate::device::Device;

/// Build the concrete [`Device`] for a config.
///
/// Dispatch on `device_type`:
/// * `"dummy"` → [`DummyDevice`].
/// * `"mujoco_so101"` → [`RobotArmDevice`] backed by the MuJoCo driver (needs
///   `cfg.arm` with a `mujoco` block).
/// * anything else → a `DummyDevice` (with a warning); serial arms migrate later.
///
/// The descriptor is resolved by the caller (via [`AdapterConfig::load_descriptor`])
/// and passed in so the same descriptor advertised over the boundary is the one
/// the device carries.
pub fn build_device(
    cfg: &AdapterConfig,
    descriptor: teleop_protocol::DeviceDescriptor,
) -> Result<Box<dyn Device>> {
    match cfg.device_type.as_str() {
        "mujoco_so101" => {
            let arm = cfg.arm.as_ref().ok_or_else(|| {
                anyhow::anyhow!(
                    "device_type 'mujoco_so101' requires an `arm:` section in the adapter config"
                )
            })?;
            let dev = RobotArmDevice::new(descriptor, arm)?;
            Ok(Box::new(dev))
        }
        "dummy" => Ok(Box::new(DummyDevice::new(descriptor))),
        other => {
            tracing::warn!("device_type {other:?} not supported; using dummy device");
            Ok(Box::new(DummyDevice::new(descriptor)))
        }
    }
}
