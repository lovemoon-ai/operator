//! Concrete robot-form `Device` implementations.
//!
//! Ships [`dummy::DummyDevice`] and [`robot_arm::RobotArmDevice`] (SO-101 sim
//! and real hardware control chains). rc_car lands in a later pass.

pub mod dual_so101;
pub mod dummy;
pub mod robot_arm;

pub use dual_so101::DualSo101Device;
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
/// * `"so101_real"` → [`RobotArmDevice`] backed by the Python/LeRobot hardware
///   bridge (needs `cfg.arm` with a `so101` block).
/// * `"so101_dual_real"` → [`DualSo101Device`] with two independent SO-101
///   hardware control processes (needs `cfg.dual_arm.left/right`).
/// * anything else → a `DummyDevice` (with a warning).
///
/// The descriptor is resolved by the caller (via [`AdapterConfig::load_descriptor`])
/// and passed in so the same descriptor advertised over the boundary is the one
/// the device carries.
pub fn build_device(
    cfg: &AdapterConfig,
    descriptor: teleop_protocol::DeviceDescriptor,
) -> Result<Box<dyn Device>> {
    match cfg.device_type.as_str() {
        "mujoco_so101" | "so101_real" => {
            let arm = cfg.arm.as_ref().ok_or_else(|| {
                anyhow::anyhow!(
                    "device_type '{}' requires an `arm:` section in the adapter config",
                    cfg.device_type
                )
            })?;
            let dev = RobotArmDevice::new(descriptor, arm)?;
            Ok(Box::new(dev))
        }
        "so101_dual_real" | "dual_so101_real" => {
            let dual = cfg.dual_arm.as_ref().ok_or_else(|| {
                anyhow::anyhow!(
                    "device_type '{}' requires a `dual_arm:` section in the adapter config",
                    cfg.device_type
                )
            })?;
            let dev = DualSo101Device::new(descriptor, dual)?;
            Ok(Box::new(dev))
        }
        "dummy" => Ok(Box::new(DummyDevice::new(descriptor))),
        other => {
            tracing::warn!("device_type {other:?} not supported; using dummy device");
            Ok(Box::new(DummyDevice::new(descriptor)))
        }
    }
}
