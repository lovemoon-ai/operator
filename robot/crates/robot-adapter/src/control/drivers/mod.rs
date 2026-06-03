//! Arm driver abstraction and implementations (adapter side).
//!
//! The `ArmDriver` trait defines the interface that all arm drivers must
//! implement. This phase only the MuJoCo SO-101 simulator driver is ported;
//! serial-bus arms (dynamixel / feetech) land in a later phase.

pub mod mujoco_so101;

use anyhow::{Context, Result};
use async_trait::async_trait;
use teleop_protocol::Pose6D;

use crate::config::MujocoConfig;
use crate::control::JointAngles;
use mujoco_so101::MujocoSo101Driver;

/// Trait for controlling a robotic arm.
///
/// All operations are async to support subprocess / serial I/O without blocking
/// the tokio runtime.
#[async_trait]
pub trait ArmDriver: Send {
    /// Send target joint angles to the arm.
    async fn set_joints(&mut self, joints: &JointAngles) -> Result<()>;

    /// Set the gripper opening (0.0 = closed, 1.0 = open).
    async fn set_gripper(&mut self, value: f32) -> Result<()>;

    /// Whether this backend accepts end-effector pose targets and performs IK
    /// internally.
    fn supports_end_effector_pose(&self) -> bool {
        false
    }

    /// Send a robot base-frame end-effector target pose to the arm.
    ///
    /// Backends that implement this are responsible for their own IK and joint
    /// limit handling. `gripper` is an optional normalized command in `[0, 1]`
    /// so a single bridge round-trip can apply pose and gripper together.
    async fn set_end_effector_pose(
        &mut self,
        _target: &Pose6D,
        _gripper: Option<f32>,
    ) -> Result<()> {
        anyhow::bail!("driver does not support end-effector pose targets")
    }

    /// Latest known joint angles in degrees, if the backend can report them.
    fn last_joint_angles(&self) -> Option<JointAngles> {
        None
    }

    /// Latest known robot base-frame end-effector pose, if available.
    fn last_end_effector_pose(&self) -> Option<Pose6D> {
        None
    }

    /// Reset the backend to its configured initial/home pose.
    async fn reset_to_initial_pose(&mut self) -> Result<()> {
        anyhow::bail!("driver does not support reset_to_initial_pose")
    }

    /// Emergency stop: immediately disable all servo torque / freeze motion.
    async fn emergency_stop(&mut self) -> Result<()>;

    /// Enable torque on all servos (recover from e-stop).
    async fn enable_torque(&mut self) -> Result<()>;
}

/// Create a driver instance based on configuration.
///
/// This phase only supports `driver_type == "mujoco_so101"` (spawns the MuJoCo
/// bridge subprocess via [`MujocoSo101Driver`]; requires `mujoco_cfg`). Any
/// other driver type is an error — serial-bus arms migrate in a later phase.
pub fn create_driver(
    driver_type: &str,
    mujoco_cfg: Option<&MujocoConfig>,
) -> Result<Box<dyn ArmDriver>> {
    if driver_type == "mujoco_so101" {
        let cfg = mujoco_cfg.ok_or_else(|| {
            anyhow::anyhow!(
                "driver 'mujoco_so101' requires an [arm.mujoco] block in config (script path is mandatory)"
            )
        })?;
        let driver = MujocoSo101Driver::new(
            &cfg.script,
            &cfg.python,
            cfg.steps_per_write,
            &cfg.extra_args,
        )
        .with_context(|| {
            format!(
                "failed to spawn MuJoCo bridge: python={} script={}",
                cfg.python, cfg.script
            )
        })?;
        return Ok(Box::new(driver));
    }

    anyhow::bail!(
        "unsupported driver type '{driver_type}' in robot-adapter \
         (this phase only 'mujoco_so101' is migrated)"
    )
}
