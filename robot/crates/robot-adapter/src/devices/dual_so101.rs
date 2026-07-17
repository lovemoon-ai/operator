use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result};
use async_trait::async_trait;
use tokio::sync::Mutex;

use teleop_protocol::{
    AxisDef, ButtonDef, ControlSchema, DeviceCommand, DeviceDescriptor, DeviceInfo,
    DeviceTelemetry, InputMapping, Pose6D, PoseDef, TelemetrySchema, TelemetryValue,
    TelemetryValueDef,
};

use crate::config::{ArmConfig, DualArmConfig};
use crate::control::drivers::{self, ArmDriver};
use crate::control::pose_mapping::PoseMapper;
use crate::control::safety::{Safety, SafetyResult};
use crate::control::teleop::{
    command_enable, command_reset, TeleopEndEffectorResult, TeleopPoseController, TeleopPoseResult,
    ENABLE_BUTTON, END_EFFECTOR_POSE, OPERATOR_FRAME_POSE, RESET_BUTTON,
};
use crate::device::Device;

const LEFT_END_EFFECTOR_POSE: &str = "left_end_effector";
const RIGHT_END_EFFECTOR_POSE: &str = "right_end_effector";
const LEFT_GRIPPER_AXIS: &str = "left_gripper";
const RIGHT_GRIPPER_AXIS: &str = "right_gripper";
const LEFT_ENABLE_BUTTON: &str = "left_enable";
const RIGHT_ENABLE_BUTTON: &str = "right_enable";
const GRIPPER_COMMAND_EPSILON: f64 = 0.01;
const ENABLE_AXIS_THRESHOLD: f64 = 0.5;

/// Dual SO-101 teleop device: one XR session controls two independent arms.
///
/// Each side owns a separate [`ArmDriver`] / Python hardware control process,
/// but both sides share the same adapter and descriptor. The descriptor maps
/// XR left/right controller poses into side-specific command names; internally
/// each side is translated back to the single-arm teleop controller contract.
pub struct DualSo101Device {
    descriptor: DeviceDescriptor,
    left: ArmRuntime,
    right: ArmRuntime,
    connected: AtomicBool,
    last_reset_button: bool,
}

struct ArmRuntime {
    name: &'static str,
    pose_name: &'static str,
    enable_button: &'static str,
    gripper_axis: &'static str,
    driver: Arc<Mutex<Box<dyn ArmDriver>>>,
    safety: Mutex<Safety>,
    mapper: Mutex<PoseMapper>,
    teleop: TeleopPoseController,
    last_angles: Mutex<Vec<f64>>,
    num_joints: usize,
    pose_joint_count: usize,
    use_end_effector_pose: bool,
    last_end_effector_pose: Mutex<Option<Pose6D>>,
    gripper_joint_index: Option<usize>,
    gripper_joint_limits: Option<[f64; 2]>,
    gripper_default: Option<f64>,
    last_gripper: Option<f64>,
    driver_write_timeout: Duration,
    driver_write_timeout_count: AtomicU64,
}

impl DualSo101Device {
    pub fn new(descriptor: DeviceDescriptor, cfg: &DualArmConfig) -> Result<Self> {
        let left = ArmRuntime::new(
            "left",
            LEFT_END_EFFECTOR_POSE,
            LEFT_ENABLE_BUTTON,
            LEFT_GRIPPER_AXIS,
            &descriptor,
            &cfg.left,
        )
        .context("initialising left SO-101 arm")?;
        let right = ArmRuntime::new(
            "right",
            RIGHT_END_EFFECTOR_POSE,
            RIGHT_ENABLE_BUTTON,
            RIGHT_GRIPPER_AXIS,
            &descriptor,
            &cfg.right,
        )
        .context("initialising right SO-101 arm")?;

        Ok(Self {
            descriptor,
            left,
            right,
            connected: AtomicBool::new(false),
            last_reset_button: false,
        })
    }

    pub fn default_descriptor() -> DeviceDescriptor {
        DeviceDescriptor {
            device: DeviceInfo {
                device_type: "so101_dual_arm".to_string(),
                name: "Dual SO-101 Arms".to_string(),
                icon: "robot_arm".to_string(),
                model_url: String::new(),
            },
            control_schema: ControlSchema {
                axes: vec![
                    AxisDef {
                        name: LEFT_GRIPPER_AXIS.to_string(),
                        display: "Left Gripper".to_string(),
                        range: (0.0, 1.0),
                        default: 1.0,
                        dead_zone: 0.02,
                    },
                    AxisDef {
                        name: RIGHT_GRIPPER_AXIS.to_string(),
                        display: "Right Gripper".to_string(),
                        range: (0.0, 1.0),
                        default: 1.0,
                        dead_zone: 0.02,
                    },
                ],
                buttons: vec![
                    ButtonDef {
                        name: LEFT_ENABLE_BUTTON.to_string(),
                        display: "Left Enable".to_string(),
                        toggle: false,
                        group: None,
                        confirm: false,
                    },
                    ButtonDef {
                        name: RIGHT_ENABLE_BUTTON.to_string(),
                        display: "Right Enable".to_string(),
                        toggle: false,
                        group: None,
                        confirm: false,
                    },
                    ButtonDef {
                        name: RESET_BUTTON.to_string(),
                        display: "Reset Both Arms".to_string(),
                        toggle: false,
                        group: None,
                        confirm: true,
                    },
                ],
                poses: vec![
                    PoseDef {
                        name: LEFT_END_EFFECTOR_POSE.to_string(),
                        display: "Left End Effector Target".to_string(),
                        dof: 6,
                        frame: "left_hand".to_string(),
                    },
                    PoseDef {
                        name: RIGHT_END_EFFECTOR_POSE.to_string(),
                        display: "Right End Effector Target".to_string(),
                        dof: 6,
                        frame: "right_hand".to_string(),
                    },
                    PoseDef {
                        name: OPERATOR_FRAME_POSE.to_string(),
                        display: "Operator Alignment Frame".to_string(),
                        dof: 6,
                        frame: "head".to_string(),
                    },
                ],
            },
            input_mapping: vec![
                InputMapping {
                    source: "left_controller_pose".to_string(),
                    target: LEFT_END_EFFECTOR_POSE.to_string(),
                    scale: 1.0,
                    invert: false,
                    offset: 0.0,
                    mode: "absolute".to_string(),
                },
                InputMapping {
                    source: "right_controller_pose".to_string(),
                    target: RIGHT_END_EFFECTOR_POSE.to_string(),
                    scale: 1.0,
                    invert: false,
                    offset: 0.0,
                    mode: "absolute".to_string(),
                },
                InputMapping {
                    source: "head_pose".to_string(),
                    target: OPERATOR_FRAME_POSE.to_string(),
                    scale: 1.0,
                    invert: false,
                    offset: 0.0,
                    mode: "absolute".to_string(),
                },
                InputMapping {
                    source: "left_trigger".to_string(),
                    target: LEFT_GRIPPER_AXIS.to_string(),
                    scale: 1.0,
                    invert: true,
                    offset: 1.0,
                    mode: "absolute".to_string(),
                },
                InputMapping {
                    source: "right_trigger".to_string(),
                    target: RIGHT_GRIPPER_AXIS.to_string(),
                    scale: 1.0,
                    invert: true,
                    offset: 1.0,
                    mode: "absolute".to_string(),
                },
                InputMapping {
                    source: "left_grip".to_string(),
                    target: LEFT_ENABLE_BUTTON.to_string(),
                    scale: 1.0,
                    invert: false,
                    offset: 0.0,
                    mode: "momentary".to_string(),
                },
                InputMapping {
                    source: "right_grip".to_string(),
                    target: RIGHT_ENABLE_BUTTON.to_string(),
                    scale: 1.0,
                    invert: false,
                    offset: 0.0,
                    mode: "momentary".to_string(),
                },
                InputMapping {
                    source: "button_b".to_string(),
                    target: RESET_BUTTON.to_string(),
                    scale: 1.0,
                    invert: false,
                    offset: 0.0,
                    mode: "momentary".to_string(),
                },
            ],
            telemetry_schema: TelemetrySchema {
                values: vec![
                    TelemetryValueDef {
                        name: "left_joint_angles".to_string(),
                        display: "Left Joint Angles".to_string(),
                        unit: "deg".to_string(),
                        range: None,
                        warn_below: None,
                        value_type: Some("array".to_string()),
                        length: Some(6),
                    },
                    TelemetryValueDef {
                        name: "right_joint_angles".to_string(),
                        display: "Right Joint Angles".to_string(),
                        unit: "deg".to_string(),
                        range: None,
                        warn_below: None,
                        value_type: Some("array".to_string()),
                        length: Some(6),
                    },
                    TelemetryValueDef {
                        name: "joint_angles".to_string(),
                        display: "Joint Angles".to_string(),
                        unit: "deg".to_string(),
                        range: None,
                        warn_below: None,
                        value_type: Some("array".to_string()),
                        length: Some(12),
                    },
                    TelemetryValueDef {
                        name: "num_joints".to_string(),
                        display: "Number of Joints".to_string(),
                        unit: String::new(),
                        range: None,
                        warn_below: None,
                        value_type: Some("int".to_string()),
                        length: None,
                    },
                    TelemetryValueDef {
                        name: "num_joints_per_arm".to_string(),
                        display: "Joints Per Arm".to_string(),
                        unit: String::new(),
                        range: None,
                        warn_below: None,
                        value_type: Some("int".to_string()),
                        length: None,
                    },
                    TelemetryValueDef {
                        name: "connected".to_string(),
                        display: "Connected".to_string(),
                        unit: String::new(),
                        range: None,
                        warn_below: None,
                        value_type: Some("bool".to_string()),
                        length: None,
                    },
                ],
            },
            video_feeds: Vec::new(),
            safety: Default::default(),
        }
    }

    async fn reset_to_initial_pose(&mut self) -> Result<()> {
        tracing::info!("DualSo101Device: reset requested; returning both arms to initial pose");
        let (left_result, right_result) = {
            let left = &mut self.left;
            let right = &mut self.right;
            tokio::join!(left.reset_to_initial_pose(), right.reset_to_initial_pose())
        };
        left_result.context("resetting left SO-101 arm")?;
        right_result.context("resetting right SO-101 arm")?;
        Ok(())
    }

    async fn handle_reset_button(&mut self, cmd: &DeviceCommand) -> Result<bool> {
        let pressed = command_reset(cmd);
        let rising_edge = pressed && !self.last_reset_button;
        self.last_reset_button = pressed;
        if !rising_edge {
            return Ok(false);
        }

        self.reset_to_initial_pose().await?;
        Ok(true)
    }
}

impl ArmRuntime {
    fn new(
        name: &'static str,
        pose_name: &'static str,
        enable_button: &'static str,
        gripper_axis: &'static str,
        descriptor: &DeviceDescriptor,
        arm_config: &ArmConfig,
    ) -> Result<Self> {
        let driver = drivers::create_driver(
            &arm_config.driver,
            arm_config.mujoco.as_ref(),
            arm_config.lerobot.as_ref(),
        )?;
        let safety = Safety::from_config(&arm_config.safety);
        let num_joints = arm_config.servo_ids.len();
        let gripper_joint_index = gripper_joint_index_for(descriptor, gripper_axis, num_joints);
        let pose_joint_count = if gripper_joint_index.is_some() && num_joints > 0 {
            num_joints - 1
        } else {
            num_joints
        };
        let use_end_effector_pose =
            mapping_uses_driver_end_effector_targets(&arm_config.pose_mapping.mode);
        if use_end_effector_pose && !driver.supports_end_effector_pose() {
            anyhow::bail!(
                "{name} arm pose_mapping.mode='{}' requires a driver that supports end-effector pose targets",
                arm_config.pose_mapping.mode
            );
        }
        let gripper_joint_limits = gripper_joint_index
            .and_then(|idx| arm_config.safety.joint_limits_deg.get(idx).copied());
        let gripper_default = gripper_axis_default_for(descriptor, gripper_axis);
        let mapper = PoseMapper::new(&arm_config.pose_mapping, pose_joint_count);

        Ok(Self {
            name,
            pose_name,
            enable_button,
            gripper_axis,
            driver: Arc::new(Mutex::new(driver)),
            safety: Mutex::new(safety),
            mapper: Mutex::new(mapper),
            teleop: TeleopPoseController::new(),
            last_angles: Mutex::new(vec![0.0; num_joints]),
            num_joints,
            pose_joint_count,
            use_end_effector_pose,
            last_end_effector_pose: Mutex::new(None),
            gripper_joint_index,
            gripper_joint_limits,
            gripper_default,
            last_gripper: None,
            driver_write_timeout: Duration::from_millis(arm_config.driver_write_timeout_ms),
            driver_write_timeout_count: AtomicU64::new(0),
        })
    }

    async fn connect(&mut self) -> Result<()> {
        let (initial_angles, initial_end_effector_pose) = {
            let mut driver = self.driver.lock().await;
            driver.enable_torque().await?;
            (driver.last_joint_angles(), driver.last_end_effector_pose())
        };
        if let Some(joints) = initial_angles {
            let mut last_angles = self.last_angles.lock().await;
            *last_angles = joints.angles;
            last_angles.resize(self.num_joints, 0.0);
        }
        if self.use_end_effector_pose && initial_end_effector_pose.is_none() {
            anyhow::bail!(
                "{} arm driver-side IK mode requires an initial end-effector pose snapshot",
                self.name
            );
        }
        {
            let mut last_pose = self.last_end_effector_pose.lock().await;
            *last_pose = initial_end_effector_pose;
        }
        {
            let mut mapper = self.mapper.lock().await;
            self.teleop.reset(&mut mapper);
        }
        self.last_gripper = None;
        tracing::info!("DualSo101Device: {} arm connected", self.name);
        Ok(())
    }

    async fn disconnect(&mut self) -> Result<()> {
        self.driver.lock().await.emergency_stop().await?;
        {
            let mut mapper = self.mapper.lock().await;
            self.teleop.reset(&mut mapper);
        }
        self.safety.lock().await.reset();
        self.last_gripper = None;
        {
            let mut last_pose = self.last_end_effector_pose.lock().await;
            *last_pose = None;
        }
        tracing::info!("DualSo101Device: {} arm disconnected", self.name);
        Ok(())
    }

    async fn reset_to_initial_pose(&mut self) -> Result<()> {
        {
            let mut mapper = self.mapper.lock().await;
            self.teleop.reset(&mut mapper);
        }
        self.safety.lock().await.reset();
        self.last_gripper = None;

        let (latest_joints, latest_end_effector_pose) = {
            let mut driver = self.driver.lock().await;
            driver.reset_to_initial_pose().await?;
            (driver.last_joint_angles(), driver.last_end_effector_pose())
        };
        self.update_latest(latest_joints, latest_end_effector_pose)
            .await;
        Ok(())
    }

    async fn emergency_stop(&mut self) -> Result<()> {
        let (latest_joints, latest_end_effector_pose) = {
            let mut driver = self.driver.lock().await;
            driver.emergency_stop().await?;
            (driver.last_joint_angles(), driver.last_end_effector_pose())
        };
        self.update_latest(latest_joints, latest_end_effector_pose)
            .await;
        self.safety.lock().await.reset();
        {
            let mut mapper = self.mapper.lock().await;
            self.teleop.reset(&mut mapper);
        }
        self.last_gripper = None;
        Ok(())
    }

    async fn send_command(&mut self, cmd: &DeviceCommand) -> Result<()> {
        let gripper = cmd.axes.get(self.gripper_axis).copied();
        let scoped_cmd = self.scoped_command(cmd);

        if cmd.poses.contains_key(self.pose_name) {
            if self.use_end_effector_pose {
                self.send_end_effector_command(&scoped_cmd, gripper).await?;
            } else {
                self.send_joint_command(&scoped_cmd, gripper).await?;
            }
        } else if command_enable(&scoped_cmd) {
            self.maybe_set_gripper(gripper).await?;
        }

        Ok(())
    }

    async fn send_end_effector_command(
        &mut self,
        scoped_cmd: &DeviceCommand,
        gripper: Option<f64>,
    ) -> Result<()> {
        let Some(current_end_effector_pose) = self.last_end_effector_pose.lock().await.clone()
        else {
            if !command_enable(scoped_cmd) {
                let mut mapper = self.mapper.lock().await;
                self.teleop.reset(&mut mapper);
            } else {
                tracing::warn!(
                    "DualSo101Device: {} arm has no end-effector snapshot yet; dropping pose frame",
                    self.name
                );
            }
            return Ok(());
        };

        let target = {
            let mut mapper = self.mapper.lock().await;
            match self.teleop.map_end_effector_command(
                scoped_cmd,
                &mut mapper,
                &current_end_effector_pose,
            ) {
                TeleopEndEffectorResult::Active(target) => target,
                TeleopEndEffectorResult::Disabled => return Ok(()),
                TeleopEndEffectorResult::WaitingForPose => return Ok(()),
            }
        };

        let gripper_cmd = self.prepare_gripper_command(gripper);
        if let Some(value) = gripper_cmd {
            self.apply_gripper_telemetry(value as f64).await;
        }

        let driver = self.driver.clone();
        let target_for_driver = target.clone();
        self.with_write_timeout("set_end_effector_pose", move || async move {
            driver
                .lock()
                .await
                .set_end_effector_pose(&target_for_driver, gripper_cmd)
                .await
        })
        .await?;

        let (latest_joints, latest_end_effector_pose) = {
            let driver = self.driver.lock().await;
            (driver.last_joint_angles(), driver.last_end_effector_pose())
        };
        self.update_latest(latest_joints, latest_end_effector_pose)
            .await;
        Ok(())
    }

    async fn send_joint_command(
        &mut self,
        scoped_cmd: &DeviceCommand,
        gripper: Option<f64>,
    ) -> Result<()> {
        let current_joint_target = self.last_angles.lock().await.clone();
        let joints = {
            let mut mapper = self.mapper.lock().await;
            match self
                .teleop
                .map_command(scoped_cmd, &mut mapper, &current_joint_target)
            {
                TeleopPoseResult::Active(joints) => joints,
                TeleopPoseResult::Disabled => return Ok(()),
                TeleopPoseResult::WaitingForPose => return Ok(()),
            }
        };

        let safety_result = self.safety.lock().await.validate(&joints);
        let validated = match safety_result {
            SafetyResult::Ok(v) => v,
            SafetyResult::Clamped(v) => {
                tracing::warn!(
                    "DualSo101Device: {} arm joints clamped by safety limits",
                    self.name
                );
                v
            }
            SafetyResult::Rejected(reason) => {
                tracing::error!(
                    "DualSo101Device: {} arm safety rejection: {reason}",
                    self.name
                );
                self.emergency_stop().await?;
                anyhow::bail!("{} arm safety rejection: {reason}", self.name);
            }
        };

        {
            let mut last_angles = self.last_angles.lock().await;
            last_angles.resize(self.num_joints, 0.0);
            for (index, angle) in validated
                .angles
                .iter()
                .copied()
                .take(self.pose_joint_count)
                .enumerate()
            {
                last_angles[index] = angle;
            }
        }

        let driver = self.driver.clone();
        let validated_for_driver = validated;
        self.with_write_timeout("set_joints", move || async move {
            driver.lock().await.set_joints(&validated_for_driver).await
        })
        .await?;
        self.maybe_set_gripper(gripper).await
    }

    fn scoped_command(&self, cmd: &DeviceCommand) -> DeviceCommand {
        let mut scoped = DeviceCommand {
            timestamp_ns: cmd.timestamp_ns,
            ..Default::default()
        };
        if side_enable(cmd, self.enable_button) {
            scoped.buttons.insert(ENABLE_BUTTON.to_string(), true);
        }
        if let Some(pose) = cmd.poses.get(self.pose_name) {
            scoped
                .poses
                .insert(END_EFFECTOR_POSE.to_string(), pose.clone());
        }
        if let Some(operator_frame) = cmd.poses.get(OPERATOR_FRAME_POSE) {
            scoped
                .poses
                .insert(OPERATOR_FRAME_POSE.to_string(), operator_frame.clone());
        }
        scoped
    }

    async fn maybe_set_gripper(&mut self, value: Option<f64>) -> Result<()> {
        let Some(command) = self.prepare_gripper_command(value) else {
            return Ok(());
        };
        self.apply_gripper_telemetry(command as f64).await;

        let driver = self.driver.clone();
        self.with_write_timeout("set_gripper", move || async move {
            driver.lock().await.set_gripper(command).await
        })
        .await
    }

    fn prepare_gripper_command(&mut self, value: Option<f64>) -> Option<f32> {
        let value = value?.clamp(0.0, 1.0);
        if self.last_gripper.is_none()
            && self
                .gripper_default
                .map(|default| (default - value).abs() < GRIPPER_COMMAND_EPSILON)
                .unwrap_or(false)
        {
            self.last_gripper = Some(value);
            tracing::debug!(
                "DualSo101Device: {} arm seeded gripper default {:.2} without driver write",
                self.name,
                value
            );
            return None;
        }
        if self
            .last_gripper
            .map(|last| (last - value).abs() < GRIPPER_COMMAND_EPSILON)
            .unwrap_or(false)
        {
            return None;
        }
        self.last_gripper = Some(value);
        tracing::info!(
            "DualSo101Device: {} arm gripper command {:.2}",
            self.name,
            value
        );
        Some(value as f32)
    }

    async fn apply_gripper_telemetry(&self, value: f64) {
        if let Some(angle) = self.gripper_axis_to_joint_degrees(value) {
            if let Some(index) = self.gripper_joint_index {
                let mut last_angles = self.last_angles.lock().await;
                last_angles.resize(self.num_joints, 0.0);
                if let Some(slot) = last_angles.get_mut(index) {
                    *slot = angle;
                }
            }
        }
    }

    fn gripper_axis_to_joint_degrees(&self, value: f64) -> Option<f64> {
        let [lo, hi] = self.gripper_joint_limits?;
        Some(lo + value.clamp(0.0, 1.0) * (hi - lo))
    }

    /// Pull the driver's latest reported state into this arm's snapshot.
    ///
    /// Required by the `lerobot_link` driver: it publishes targets and returns
    /// without waiting, so the plugin's state arrives asynchronously and the
    /// snapshot taken at write time is always a round trip stale. Reading the
    /// driver at telemetry time instead makes telemetry reflect the plugin's
    /// most recent report. Harmless for the MuJoCo driver, whose state is
    /// already fresh by the time a write returns.
    async fn refresh_from_driver(&self) {
        let (latest_joints, latest_end_effector_pose) = {
            let driver = self.driver.lock().await;
            (driver.last_joint_angles(), driver.last_end_effector_pose())
        };
        self.update_latest(latest_joints, latest_end_effector_pose)
            .await;
    }

    async fn update_latest(
        &self,
        latest_joints: Option<crate::control::JointAngles>,
        latest_end_effector_pose: Option<Pose6D>,
    ) {
        if let Some(joints) = latest_joints {
            let mut last_angles = self.last_angles.lock().await;
            *last_angles = joints.angles;
            last_angles.resize(self.num_joints, 0.0);
        }
        if let Some(pose) = latest_end_effector_pose {
            let mut last_pose = self.last_end_effector_pose.lock().await;
            *last_pose = Some(pose);
        }
    }

    async fn with_write_timeout<F, Fut>(&self, label: &str, f: F) -> Result<()>
    where
        F: FnOnce() -> Fut,
        Fut: std::future::Future<Output = Result<()>>,
    {
        match tokio::time::timeout(self.driver_write_timeout, f()).await {
            Ok(Ok(())) => Ok(()),
            Ok(Err(e)) => Err(e),
            Err(_) => {
                self.driver_write_timeout_count
                    .fetch_add(1, Ordering::Relaxed);
                tracing::warn!(
                    "DualSo101Device: {} arm driver write '{label}' exceeded {:?}, dropping frame",
                    self.name,
                    self.driver_write_timeout
                );
                Ok(())
            }
        }
    }
}

#[async_trait]
impl Device for DualSo101Device {
    fn descriptor(&self) -> &DeviceDescriptor {
        &self.descriptor
    }

    async fn connect(&mut self) -> Result<()> {
        self.left
            .connect()
            .await
            .context("connecting left SO-101 arm")?;
        if let Err(e) = self.right.connect().await {
            let _ = self.left.disconnect().await;
            return Err(e).context("connecting right SO-101 arm");
        }
        self.connected.store(true, Ordering::SeqCst);
        self.last_reset_button = false;
        tracing::info!("DualSo101Device connected (awaiting per-arm teleop enable)");
        Ok(())
    }

    async fn disconnect(&mut self) -> Result<()> {
        let (left_result, right_result) = {
            let left = &mut self.left;
            let right = &mut self.right;
            tokio::join!(left.disconnect(), right.disconnect())
        };
        self.connected.store(false, Ordering::SeqCst);
        self.last_reset_button = false;
        left_result.context("disconnecting left SO-101 arm")?;
        right_result.context("disconnecting right SO-101 arm")?;
        tracing::info!("DualSo101Device disconnected");
        Ok(())
    }

    async fn send_command(&mut self, cmd: &DeviceCommand) -> Result<()> {
        if self.handle_reset_button(cmd).await? {
            return Ok(());
        }

        let (left_result, right_result) = {
            let left = &mut self.left;
            let right = &mut self.right;
            tokio::join!(left.send_command(cmd), right.send_command(cmd))
        };
        if left_result.is_ok() && right_result.is_ok() {
            return Ok(());
        }

        let mut errors = Vec::new();
        if let Err(err) = left_result {
            errors.push(format!("left arm: {err:#}"));
        }
        if let Err(err) = right_result {
            errors.push(format!("right arm: {err:#}"));
        }

        tracing::error!(
            "DualSo101Device: command failed ({}); emergency-stopping both arms",
            errors.join("; ")
        );
        if let Err(err) = self.emergency_stop().await {
            errors.push(format!("emergency stop: {err:#}"));
        }

        anyhow::bail!("dual SO-101 command failed; {}", errors.join("; "));
    }

    async fn get_telemetry(&self) -> Result<DeviceTelemetry> {
        // Sample the drivers here rather than trusting the snapshot cached at
        // write time — see ArmRuntime::refresh_from_driver.
        self.left.refresh_from_driver().await;
        self.right.refresh_from_driver().await;

        let left_angles = self.left.last_angles.lock().await.clone();
        let right_angles = self.right.last_angles.lock().await.clone();
        let mut joint_angles = left_angles.clone();
        joint_angles.extend(right_angles.iter().copied());

        let mut values = HashMap::new();
        values.insert(
            "left_joint_angles".into(),
            TelemetryValue::Array(left_angles),
        );
        values.insert(
            "right_joint_angles".into(),
            TelemetryValue::Array(right_angles),
        );
        values.insert("joint_angles".into(), TelemetryValue::Array(joint_angles));
        values.insert(
            "num_joints".into(),
            TelemetryValue::Int((self.left.num_joints + self.right.num_joints) as i64),
        );
        values.insert(
            "num_joints_per_arm".into(),
            TelemetryValue::Int(self.left.num_joints as i64),
        );
        values.insert(
            "connected".into(),
            TelemetryValue::Bool(self.connected.load(Ordering::SeqCst)),
        );

        Ok(DeviceTelemetry {
            values,
            timestamp_ns: SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_nanos() as u64,
        })
    }

    async fn emergency_stop(&mut self) -> Result<()> {
        tracing::error!("DualSo101Device: EMERGENCY STOP");
        let (left_result, right_result) = {
            let left = &mut self.left;
            let right = &mut self.right;
            tokio::join!(left.emergency_stop(), right.emergency_stop())
        };
        self.last_reset_button = false;
        left_result.context("emergency-stopping left SO-101 arm")?;
        right_result.context("emergency-stopping right SO-101 arm")?;
        Ok(())
    }

    fn is_connected(&self) -> bool {
        self.connected.load(Ordering::SeqCst)
    }
}

fn side_enable(cmd: &DeviceCommand, button: &str) -> bool {
    cmd.buttons.get(button).copied().unwrap_or(false)
        || cmd.axes.get(button).copied().unwrap_or(0.0) >= ENABLE_AXIS_THRESHOLD
}

fn gripper_axis_default_for(descriptor: &DeviceDescriptor, axis_name: &str) -> Option<f64> {
    descriptor
        .control_schema
        .axes
        .iter()
        .find(|axis| axis.name == axis_name)
        .map(|axis| axis.default)
}

fn gripper_joint_index_for(
    descriptor: &DeviceDescriptor,
    axis_name: &str,
    num_joints: usize,
) -> Option<usize> {
    if descriptor
        .control_schema
        .axes
        .iter()
        .any(|axis| axis.name == axis_name)
        && num_joints > 0
    {
        Some(num_joints - 1)
    } else {
        None
    }
}

fn mapping_uses_driver_end_effector_targets(mode: &str) -> bool {
    !matches!(mode, "direct" | "retarget")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;
    use std::process::Command as StdCommand;

    use crate::config::{LerobotConfig, PoseMappingConfig, SafetyConfig};
    use crate::device::Device;
    use teleop_protocol::Endpoint;

    const IDENTITY_QUAT: [f64; 4] = [0.0, 0.0, 0.0, 1.0];
    const SETTLE_TIMEOUT: Duration = Duration::from_secs(5);

    fn python_available() -> bool {
        StdCommand::new("python3")
            .arg("--version")
            .output()
            .map(|o| o.status.success())
            .unwrap_or(false)
    }

    fn stub_script() -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("tests")
            .join("fixtures")
            .join("stub_vr_plugin.py")
    }

    /// Unique per-test UDS path so concurrent test threads never collide.
    fn temp_endpoint(tag: &str) -> Endpoint {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path = std::env::temp_dir().join(format!(
            "dual-link-{tag}-{}-{nanos}.sock",
            std::process::id()
        ));
        format!("uds:{}", path.display()).parse().unwrap()
    }

    /// Kills the stub plugin on drop so a failing assertion cannot leak it.
    struct StubGuard(std::process::Child);

    impl Drop for StubGuard {
        fn drop(&mut self) {
            let _ = self.0.kill();
            let _ = self.0.wait();
        }
    }

    /// The adapter listens and the plugin dials in, so the *test* spawns the
    /// stub now — the driver no longer spawns a subprocess of its own.
    fn spawn_stub(endpoint: &Endpoint, extra: &[&str]) -> StubGuard {
        StubGuard(
            StdCommand::new("python3")
                .arg(stub_script())
                .arg("--endpoint")
                .arg(endpoint.to_string())
                .args(extra)
                .spawn()
                .expect("spawn stub plugin"),
        )
    }

    /// Poll telemetry until `pred` holds, or panic after `SETTLE_TIMEOUT`.
    ///
    /// Needed because the link driver is decoupled: a write publishes a target
    /// and returns without waiting, so plugin state lands a round trip later.
    async fn poll_telemetry(
        device: &DualSo101Device,
        label: &str,
        pred: impl Fn(&DeviceTelemetry) -> bool,
    ) -> DeviceTelemetry {
        let deadline = tokio::time::Instant::now() + SETTLE_TIMEOUT;
        loop {
            let t = device.get_telemetry().await.expect("telemetry");
            if pred(&t) {
                return t;
            }
            if tokio::time::Instant::now() > deadline {
                panic!(
                    "timed out waiting for {label}; last telemetry: {:?}",
                    t.values
                );
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    }

    fn arm_config(endpoint: &Endpoint, mirror: bool) -> ArmConfig {
        ArmConfig {
            driver: "lerobot_link".to_string(),
            serial_port: String::new(),
            baudrate: 0,
            servo_ids: vec![1, 2, 3, 4, 5, 6],
            safety: SafetyConfig {
                joint_limits_deg: vec![
                    [-105.0, 105.0],
                    [-95.0, 95.0],
                    [-92.0, 92.0],
                    [-90.0, 90.0],
                    [-150.0, 155.0],
                    [0.0, 100.0],
                ],
                max_velocity_deg_s: 1.0e9,
                max_acceleration_deg_s2: 1.0e9,
            },
            pose_mapping: PoseMappingConfig {
                mode: "ik".to_string(),
                scale: 0.5,
                mirror,
            },
            driver_write_timeout_ms: 1000,
            mujoco: None,
            lerobot: Some(LerobotConfig {
                endpoint: endpoint.clone(),
                hello_timeout_ms: 10_000,
            }),
        }
    }

    fn pose(position: [f64; 3]) -> Pose6D {
        Pose6D {
            position,
            rotation: IDENTITY_QUAT,
        }
    }

    fn telemetry_array<'a>(values: &'a HashMap<String, TelemetryValue>, key: &str) -> &'a Vec<f64> {
        match values.get(key).expect("telemetry key present") {
            TelemetryValue::Array(values) => values,
            other => panic!("expected array telemetry for {key}, got {other:?}"),
        }
    }

    #[test]
    fn default_descriptor_shape() {
        let d = DualSo101Device::default_descriptor();
        assert_eq!(d.device.device_type, "so101_dual_arm");
        assert_eq!(d.control_schema.axes.len(), 2);
        assert_eq!(d.control_schema.axes[0].name, LEFT_GRIPPER_AXIS);
        assert_eq!(d.control_schema.axes[1].name, RIGHT_GRIPPER_AXIS);
        assert!(d
            .control_schema
            .buttons
            .iter()
            .any(|button| button.name == LEFT_ENABLE_BUTTON));
        assert!(d
            .control_schema
            .buttons
            .iter()
            .any(|button| button.name == RIGHT_ENABLE_BUTTON));
        assert!(d
            .control_schema
            .poses
            .iter()
            .any(|pose| pose.name == LEFT_END_EFFECTOR_POSE && pose.frame == "left_hand"));
        assert!(d
            .control_schema
            .poses
            .iter()
            .any(|pose| pose.name == RIGHT_END_EFFECTOR_POSE && pose.frame == "right_hand"));
        assert!(d
            .input_mapping
            .iter()
            .any(|m| m.source == "left_controller_pose" && m.target == LEFT_END_EFFECTOR_POSE));
        assert!(d
            .input_mapping
            .iter()
            .any(|m| m.source == "right_controller_pose" && m.target == RIGHT_END_EFFECTOR_POSE));
        assert!(d
            .input_mapping
            .iter()
            .any(|m| m.source == "left_grip" && m.target == LEFT_ENABLE_BUTTON));
        assert!(d
            .input_mapping
            .iter()
            .any(|m| m.source == "right_grip" && m.target == RIGHT_ENABLE_BUTTON));
    }

    #[tokio::test]
    async fn dual_real_device_round_trips_against_stub_plugins() {
        if !python_available() {
            eprintln!("skipping dual SO-101 device test: python3 unavailable");
            return;
        }
        assert!(stub_script().exists(), "stub script missing");

        // Each arm gets its own endpoint: a dual-arm rig runs two independent
        // `lerobot-teleoperate` processes, one per follower.
        let left_ep = temp_endpoint("rt-left");
        let right_ep = temp_endpoint("rt-right");
        let cfg = DualArmConfig {
            left: arm_config(&left_ep, false),
            right: arm_config(&right_ep, true),
        };
        let mut device = DualSo101Device::new(DualSo101Device::default_descriptor(), &cfg)
            .expect("create dual device");

        let _left_stub = spawn_stub(&left_ep, &[]);
        let _right_stub = spawn_stub(&right_ep, &[]);

        device.connect().await.expect("connect dual device");

        let mut cmd = DeviceCommand::default();
        cmd.buttons.insert(LEFT_ENABLE_BUTTON.to_string(), true);
        cmd.buttons.insert(RIGHT_ENABLE_BUTTON.to_string(), true);
        // Both gripper axes default to 1.0 in the descriptor, and a first
        // command *at* the default is deliberately seeded without a driver
        // write. So use two non-default values here — otherwise the assertion
        // below passes without any gripper write ever happening.
        cmd.axes.insert(LEFT_GRIPPER_AXIS.to_string(), 0.0);
        cmd.axes.insert(RIGHT_GRIPPER_AXIS.to_string(), 0.75);
        cmd.poses
            .insert(LEFT_END_EFFECTOR_POSE.to_string(), pose([0.1, 0.0, 0.0]));
        cmd.poses
            .insert(RIGHT_END_EFFECTOR_POSE.to_string(), pose([-0.1, 0.0, 0.0]));
        cmd.poses
            .insert(OPERATOR_FRAME_POSE.to_string(), pose([0.0, 0.0, 0.0]));

        device.send_command(&cmd).await.expect("send dual command");

        // The link driver publishes and returns; plugin state lands a round
        // trip later, so poll rather than reading telemetry immediately.
        let telemetry = poll_telemetry(&device, "both grippers to land", |t| {
            let left = telemetry_array(&t.values, "left_joint_angles");
            let right = telemetry_array(&t.values, "right_joint_angles");
            left[5] == 0.0 && right[5] == 75.0
        })
        .await;

        let left = telemetry_array(&telemetry.values, "left_joint_angles");
        let right = telemetry_array(&telemetry.values, "right_joint_angles");
        let combined = telemetry_array(&telemetry.values, "joint_angles");
        assert_eq!(left.len(), 6);
        assert_eq!(right.len(), 6);
        assert_eq!(combined.len(), 12);
        // Gripper is RANGE_0_100 on the LeRobot side, not degrees: the old
        // 8..85 degree mapping lived in the deleted so101_real_control.py.
        assert_eq!(left[5], 0.0, "left gripper axis 0.0 -> 0 (closed)");
        assert_eq!(right[5], 75.0, "right gripper axis 0.75 -> 75");

        device.disconnect().await.expect("disconnect dual device");
    }

    #[tokio::test]
    async fn command_failure_emergency_stops_the_peer_arm() {
        if !python_available() {
            eprintln!("skipping dual SO-101 failure test: python3 unavailable");
            return;
        }
        assert!(stub_script().exists(), "stub script missing");

        let left_ep = temp_endpoint("fail-left");
        let right_ep = temp_endpoint("fail-right");
        let cfg = DualArmConfig {
            left: arm_config(&left_ep, false),
            right: arm_config(&right_ep, true),
        };
        let mut device = DualSo101Device::new(DualSo101Device::default_descriptor(), &cfg)
            .expect("create dual device");

        let _left_stub = spawn_stub(&left_ep, &[]);
        let _right_stub = spawn_stub(&right_ep, &["--fail-ee"]);

        device.connect().await.expect("connect dual device");

        let mut cmd = DeviceCommand::default();
        cmd.buttons.insert(LEFT_ENABLE_BUTTON.to_string(), true);
        cmd.buttons.insert(RIGHT_ENABLE_BUTTON.to_string(), true);
        cmd.poses
            .insert(LEFT_END_EFFECTOR_POSE.to_string(), pose([0.1, 0.0, 0.0]));
        cmd.poses
            .insert(RIGHT_END_EFFECTOR_POSE.to_string(), pose([0.1, 0.0, 0.0]));
        cmd.poses
            .insert(OPERATOR_FRAME_POSE.to_string(), pose([0.0, 0.0, 0.0]));

        // Writes are fire-and-forget, so a plugin-side failure cannot fail the
        // command that caused it — it surfaces on a subsequent write. At the
        // XR command rate (~72 Hz) that is one ~14 ms frame later.
        let deadline = tokio::time::Instant::now() + SETTLE_TIMEOUT;
        let err = loop {
            match device.send_command(&cmd).await {
                Err(e) => break e,
                Ok(()) => {
                    assert!(
                        tokio::time::Instant::now() < deadline,
                        "forced right arm failure never surfaced as a command error"
                    );
                    tokio::time::sleep(Duration::from_millis(10)).await;
                }
            }
        };
        assert!(
            err.to_string().contains("dual SO-101 command failed"),
            "unexpected error: {err:#}"
        );

        // The safety property under test is unchanged by the decoupling: when
        // one arm fails, the healthy peer must be safed.
        poll_telemetry(&device, "peer arm to be emergency-stopped", |t| {
            telemetry_array(&t.values, "left_joint_angles")[0] == -123.0
        })
        .await;
    }

    /// Was `left_and_right_commands_are_dispatched_in_parallel`, which guarded
    /// against the two arms' blocking writes being serialized. The link driver
    /// makes that stronger and moves where it is enforced: writes never block
    /// on the plugin at all, so a slow consumer cannot stall the ~72 Hz XR
    /// command path regardless of how the arms are dispatched.
    #[tokio::test]
    async fn a_slow_plugin_cannot_stall_the_command_path() {
        if !python_available() {
            eprintln!("skipping dual SO-101 slow-plugin test: python3 unavailable");
            return;
        }
        assert!(stub_script().exists(), "stub script missing");

        let left_ep = temp_endpoint("slow-left");
        let right_ep = temp_endpoint("slow-right");
        let cfg = DualArmConfig {
            left: arm_config(&left_ep, false),
            right: arm_config(&right_ep, true),
        };
        let mut device = DualSo101Device::new(DualSo101Device::default_descriptor(), &cfg)
            .expect("create dual device");

        let _left_stub = spawn_stub(&left_ep, &["--delay-ee-ms", "250"]);
        let _right_stub = spawn_stub(&right_ep, &["--delay-ee-ms", "250"]);

        device.connect().await.expect("connect dual device");

        let mut cmd = DeviceCommand::default();
        cmd.buttons.insert(LEFT_ENABLE_BUTTON.to_string(), true);
        cmd.buttons.insert(RIGHT_ENABLE_BUTTON.to_string(), true);
        cmd.poses
            .insert(LEFT_END_EFFECTOR_POSE.to_string(), pose([0.1, 0.0, 0.0]));
        cmd.poses
            .insert(RIGHT_END_EFFECTOR_POSE.to_string(), pose([0.1, 0.0, 0.0]));
        cmd.poses
            .insert(OPERATOR_FRAME_POSE.to_string(), pose([0.0, 0.0, 0.0]));

        let started = tokio::time::Instant::now();
        device.send_command(&cmd).await.expect("send dual command");
        let elapsed = started.elapsed();

        assert!(
            elapsed < Duration::from_millis(100),
            "dual command took {elapsed:?} against a 250 ms-per-frame plugin; \
             writes must not block on the consumer"
        );

        device.disconnect().await.expect("disconnect dual device");
    }
}
