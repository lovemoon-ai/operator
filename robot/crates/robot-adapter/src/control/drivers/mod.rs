//! Arm driver abstraction and implementations (adapter side).
//!
//! The `ArmDriver` trait defines the interface that all arm drivers must
//! implement. SO-101 is supported through either the MuJoCo simulator driver
//! or the LeRobot link driver, which hands targets to a `vr_operator`
//! teleoperator plugin in a separate `lerobot-teleoperate` process.
//!
//! Both drivers sit *below* [`crate::control::pose_mapping::PoseMapper`], so
//! the operator→robot retarget stays a single implementation shared by sim and
//! real hardware. A driver only ever receives robot base-frame targets.

pub mod lerobot_link;
pub mod mujoco_so101;

use std::time::Duration;

use anyhow::{Context, Result};
use async_trait::async_trait;
use teleop_protocol::Pose6D;

use crate::config::{LerobotConfig, MujocoConfig};
use crate::control::JointAngles;
use lerobot_link::LerobotLinkDriver;
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

    /// Report whether the operator currently intends motion.
    ///
    /// This is `deadman held OR thumbstick nudging`, NOT the deadman alone: a
    /// far-side consumer that refuses to act on targets while this is false
    /// would otherwise silently drop nudge-only motion.
    ///
    /// Default: no-op — in-process drivers already see a disable as "no more
    /// setpoints". Drivers that forward control to a SEPARATE process must
    /// override this: otherwise the far side cannot distinguish "operator let
    /// go" from "link went quiet" and has to infer it from a staleness timeout,
    /// during which it keeps slewing toward the last target and the arm visibly
    /// keeps moving after release.
    async fn set_motion_allowed(&mut self, _allowed: bool) -> Result<()> {
        Ok(())
    }
}

/// Create a driver instance based on configuration.
///
/// Supports `driver_type == "mujoco_so101"` for the simulator and
/// `driver_type == "lerobot_link"` for real hardware driven by a LeRobot
/// `vr_operator` plugin.
pub fn create_driver(
    driver_type: &str,
    mujoco_cfg: Option<&MujocoConfig>,
    lerobot_cfg: Option<&LerobotConfig>,
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

    if driver_type == "lerobot_link" {
        let cfg = lerobot_cfg.ok_or_else(|| {
            anyhow::anyhow!(
                "driver 'lerobot_link' requires an [arm.lerobot] block in config (endpoint is mandatory)"
            )
        })?;
        let driver =
            LerobotLinkDriver::new(&cfg.endpoint, Duration::from_millis(cfg.hello_timeout_ms))
                .with_context(|| format!("failed to start LeRobot link on {}", cfg.endpoint))?;
        return Ok(Box::new(driver));
    }

    if driver_type == "so101_real" {
        anyhow::bail!(
            "driver 'so101_real' has been removed. Real SO-101 hardware is now driven by the \
             LeRobot `vr_operator` teleoperator plugin instead of the bundled \
             scripts/so101_real_control.py.\n\
             Migrate the config: set `arm.driver: \"lerobot_link\"` and replace the \
             `arm.so101:` block with `arm.lerobot:\\n  endpoint: \"uds:/tmp/lerobot-vr.sock\"`, \
             then run `lerobot-teleoperate --teleop.type=vr_operator` alongside robot-service. \
             See configs/so101_real.yaml."
        )
    }

    anyhow::bail!(
        "unsupported driver type '{driver_type}' in robot-adapter \
         (supported: 'mujoco_so101', 'lerobot_link')"
    )
}
