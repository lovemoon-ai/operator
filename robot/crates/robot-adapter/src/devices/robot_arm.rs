//! Robot arm device — composes the adapter's `control::` subsystem (driver +
//! PoseMapper + joint Safety) behind the generic [`Device`] trait.
//!
//! Mirrors `robot/src/devices/robot_arm.rs`, but built on the shared
//! [`teleop_protocol`] types and the adapter's own joint-space control modules.
//! The bridge already sanitized the inbound command against the descriptor. In
//! direct mode this device maps the sanitized `end_effector` pose to safe joint
//! commands. In IK mode it sends a robot-frame end-effector target to the driver
//! so backend-specific IK can run next to the simulator or hardware model.

use std::collections::HashMap;
use std::sync::Arc;

use anyhow::Result;
use async_trait::async_trait;
use tokio::sync::Mutex;

use teleop_protocol::{
    AxisDef, ButtonDef, ControlSchema, DeviceCommand, DeviceDescriptor, DeviceInfo,
    DeviceTelemetry, InputMapping, Pose6D, PoseDef, TelemetrySchema, TelemetryValue,
    TelemetryValueDef,
};

use crate::config::ArmConfig;
use crate::control::drivers::{self, ArmDriver};
use crate::control::pose_mapping::PoseMapper;
use crate::control::safety::{Safety, SafetyResult};
use crate::control::teleop::{
    command_enable, command_reset, TeleopEndEffectorResult, TeleopPoseController, TeleopPoseResult,
    ENABLE_BUTTON, END_EFFECTOR_POSE, OPERATOR_FRAME_POSE, RESET_BUTTON,
};
use crate::device::Device;

const GRIPPER_AXIS: &str = "gripper";
/// Thumbstick fine-adjust axes/button (see so101_real_descriptor.yaml).
const NUDGE_X_AXIS: &str = "nudge_x";
const NUDGE_Y_AXIS: &str = "nudge_y";
const NUDGE_VERTICAL_BUTTON: &str = "nudge_vertical";
const GRIPPER_COMMAND_EPSILON: f64 = 0.01;

/// A robotic arm device backed by an [`ArmDriver`] (SO-101 sim or hardware).
pub struct RobotArmDevice {
    descriptor: DeviceDescriptor,
    /// Wrapped in a Mutex because ArmDriver is Send but not Sync.
    driver: Arc<Mutex<Box<dyn ArmDriver>>>,
    safety: Mutex<Safety>,
    mapper: Mutex<PoseMapper>,
    teleop: TeleopPoseController,
    connected: std::sync::atomic::AtomicBool,
    last_angles: Mutex<Vec<f64>>,
    num_joints: usize,
    /// Number of joints controlled by the controller pose. SO-101 reserves the
    /// final actuator for the gripper axis, so pose maps only the arm joints.
    pose_joint_count: usize,
    /// True when pose commands should be sent to the driver as end-effector
    /// targets instead of mapped to joints in Rust.
    use_end_effector_pose: bool,
    /// Latest end-effector pose reported by a driver-side IK backend.
    last_end_effector_pose: Mutex<Option<Pose6D>>,
    gripper_joint_index: Option<usize>,
    gripper_joint_limits: Option<[f64; 2]>,
    gripper_default: Option<f64>,
    last_gripper: Option<f64>,
    last_reset_button: bool,
    /// Last motion-intent state pushed to the driver, so the edge is published
    /// once rather than on every command frame.
    last_operator_driving: bool,
    /// One-shot latch for the "nudge does nothing in joint mode" warning.
    warned_joint_mode_nudge: bool,
    /// Maximum time a single driver write is allowed to block.
    driver_write_timeout: std::time::Duration,
    /// Counter of frames that exceeded `driver_write_timeout`.
    pub driver_write_timeout_count: std::sync::atomic::AtomicU64,
}

impl RobotArmDevice {
    /// Create a new `RobotArmDevice` from a descriptor and the arm config.
    pub fn new(descriptor: DeviceDescriptor, arm_config: &ArmConfig) -> Result<Self> {
        let driver = drivers::create_driver(
            &arm_config.driver,
            arm_config.mujoco.as_ref(),
            arm_config.lerobot.as_ref(),
        )?;
        let safety = Safety::from_config(&arm_config.safety);
        let num_joints = arm_config.servo_ids.len();
        let gripper_joint_index = gripper_joint_index_for(&descriptor, num_joints);
        let pose_joint_count = pose_joint_count_for(&descriptor, num_joints);
        let use_end_effector_pose =
            mapping_uses_driver_end_effector_targets(&arm_config.pose_mapping.mode);
        if use_end_effector_pose && !driver.supports_end_effector_pose() {
            anyhow::bail!(
                "pose_mapping.mode='{}' requires a driver that supports end-effector pose targets",
                arm_config.pose_mapping.mode
            );
        }
        let gripper_joint_limits = gripper_joint_index
            .and_then(|idx| arm_config.safety.joint_limits_deg.get(idx).copied());
        let gripper_default = gripper_axis_default_for(&descriptor);
        let mapper = PoseMapper::new(&arm_config.pose_mapping, pose_joint_count);

        Ok(Self {
            descriptor,
            driver: Arc::new(Mutex::new(driver)),
            safety: Mutex::new(safety),
            mapper: Mutex::new(mapper),
            teleop: TeleopPoseController::new(),
            connected: std::sync::atomic::AtomicBool::new(false),
            last_angles: Mutex::new(vec![0.0; num_joints]),
            num_joints,
            pose_joint_count,
            use_end_effector_pose,
            last_end_effector_pose: Mutex::new(None),
            gripper_joint_index,
            gripper_joint_limits,
            gripper_default,
            last_gripper: None,
            last_reset_button: false,
            last_operator_driving: false,
            warned_joint_mode_nudge: false,
            driver_write_timeout: std::time::Duration::from_millis(
                arm_config.driver_write_timeout_ms,
            ),
            driver_write_timeout_count: std::sync::atomic::AtomicU64::new(0),
        })
    }

    /// Push a motion-intent edge to the driver. Best-effort and edge-triggered:
    /// this sits on the per-command path, and failing to announce intent must
    /// never abort the command itself.
    ///
    /// Intent is `deadman held OR stick nudging`. Gating it on the deadman alone
    /// made released-grip nudging a silent no-op: the driver told the plugin
    /// `enabled=false`, and the plugin then discarded the nudge target we had
    /// just gone to the trouble of computing.
    async fn publish_motion_allowed(&mut self, allowed: bool) {
        if self.last_operator_driving == allowed {
            return;
        }
        self.last_operator_driving = allowed;
        if let Err(e) = self.driver.lock().await.set_motion_allowed(allowed).await {
            tracing::warn!("RobotArmDevice: could not report motion_allowed={allowed}: {e}");
        }
    }

    /// The built-in 6-DOF SO-101 arm descriptor: one robot `gripper` axis
    /// (0..1), teleop `enable` and `reset` buttons, one `end_effector` pose
    /// (frame `right_hand`), one `operator_frame` pose (frame `head`) used to
    /// align operator forward to robot +X, and `joint_angles` / `num_joints` /
    /// `connected` telemetry. Matches `config/device_robot_arm.yaml`.
    pub fn default_descriptor() -> DeviceDescriptor {
        DeviceDescriptor {
            device: DeviceInfo {
                device_type: "robot_arm".to_string(),
                name: "MuJoCo SO-101 Arm".to_string(),
                icon: "robot_arm".to_string(),
                model_url: String::new(),
            },
            control_schema: ControlSchema {
                axes: vec![
                    AxisDef {
                        name: "gripper".to_string(),
                        display: "Gripper".to_string(),
                        range: (0.0, 1.0),
                        default: 1.0,
                        dead_zone: 0.02,
                    },
                    AxisDef {
                        name: NUDGE_X_AXIS.to_string(),
                        display: "Nudge Lateral".to_string(),
                        range: (-1.0, 1.0),
                        default: 0.0,
                        dead_zone: 0.15,
                    },
                    AxisDef {
                        name: NUDGE_Y_AXIS.to_string(),
                        display: "Nudge Forward".to_string(),
                        range: (-1.0, 1.0),
                        default: 0.0,
                        dead_zone: 0.15,
                    },
                ],
                buttons: vec![
                    ButtonDef {
                        name: ENABLE_BUTTON.to_string(),
                        display: "Enable".to_string(),
                        toggle: false,
                        group: None,
                        confirm: false,
                    },
                    ButtonDef {
                        name: NUDGE_VERTICAL_BUTTON.to_string(),
                        display: "Nudge Vertical Mode".to_string(),
                        toggle: false,
                        group: None,
                        confirm: false,
                    },
                    ButtonDef {
                        name: RESET_BUTTON.to_string(),
                        display: "Reset".to_string(),
                        toggle: false,
                        group: None,
                        confirm: false,
                    },
                ],
                poses: vec![
                    PoseDef {
                        name: END_EFFECTOR_POSE.to_string(),
                        display: "End Effector Target".to_string(),
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
                    source: "active_controller_pose".to_string(),
                    target: END_EFFECTOR_POSE.to_string(),
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
                    source: "active_trigger".to_string(),
                    target: "gripper".to_string(),
                    scale: 1.0,
                    invert: true,
                    offset: 1.0,
                    mode: "absolute".to_string(),
                },
                InputMapping {
                    source: "active_grip".to_string(),
                    target: ENABLE_BUTTON.to_string(),
                    scale: 1.0,
                    invert: false,
                    offset: 0.0,
                    mode: "momentary".to_string(),
                },
                InputMapping {
                    source: "active_button_b".to_string(),
                    target: RESET_BUTTON.to_string(),
                    scale: 1.0,
                    invert: false,
                    offset: 0.0,
                    mode: "momentary".to_string(),
                },
                InputMapping {
                    source: "active_joystick_x".to_string(),
                    target: NUDGE_X_AXIS.to_string(),
                    scale: 1.0,
                    invert: false,
                    offset: 0.0,
                    mode: "absolute".to_string(),
                },
                InputMapping {
                    source: "active_joystick_y".to_string(),
                    target: NUDGE_Y_AXIS.to_string(),
                    scale: 1.0,
                    invert: false,
                    offset: 0.0,
                    mode: "absolute".to_string(),
                },
                InputMapping {
                    source: "active_joystick_click".to_string(),
                    target: NUDGE_VERTICAL_BUTTON.to_string(),
                    scale: 1.0,
                    invert: false,
                    offset: 0.0,
                    mode: "momentary".to_string(),
                },
            ],
            telemetry_schema: TelemetrySchema {
                values: vec![
                    TelemetryValueDef {
                        name: "joint_angles".to_string(),
                        display: "Joint Angles".to_string(),
                        unit: "deg".to_string(),
                        range: None,
                        warn_below: None,
                        value_type: Some("array".to_string()),
                        length: Some(6),
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
                        name: "connected".to_string(),
                        display: "Connected".to_string(),
                        unit: String::new(),
                        range: None,
                        warn_below: None,
                        value_type: Some("bool".to_string()),
                        length: None,
                    },
                    // Control-frame overlay data; must stay in step with what
                    // `telemetry()` inserts or the advertised schema understates
                    // the payload.
                    TelemetryValueDef {
                        name: "operator_frame".to_string(),
                        display: "Operator Alignment Frame".to_string(),
                        unit: String::new(),
                        range: None,
                        warn_below: None,
                        value_type: Some("array".to_string()),
                        length: Some(4),
                    },
                    TelemetryValueDef {
                        name: "pose_scale".to_string(),
                        display: "Pose Scale".to_string(),
                        unit: String::new(),
                        range: None,
                        warn_below: None,
                        value_type: Some("float".to_string()),
                        length: None,
                    },
                    TelemetryValueDef {
                        name: "pose_mirror".to_string(),
                        display: "Lateral Mirrored".to_string(),
                        unit: String::new(),
                        range: None,
                        warn_below: None,
                        value_type: Some("bool".to_string()),
                        length: None,
                    },
                    TelemetryValueDef {
                        name: "nudge_offset".to_string(),
                        display: "Stick Fine-Adjust Offset".to_string(),
                        unit: "m".to_string(),
                        range: None,
                        warn_below: None,
                        value_type: Some("array".to_string()),
                        length: Some(3),
                    },
                ],
            },
            video_feeds: Vec::new(),
            safety: Default::default(),
            ..Default::default()
        }
    }

    /// Run `f` (a driver write) bracketed by `driver_write_timeout`. If the
    /// timeout fires we log + bump a metric and return `Ok(())` instead of
    /// bubbling — the driver naturally "holds" its last setpoint.
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
                    .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                tracing::warn!(
                    "RobotArmDevice: driver write '{label}' exceeded {:?}, dropping frame (driver will hold)",
                    self.driver_write_timeout
                );
                Ok(())
            }
        }
    }

    fn prepare_gripper_command(&mut self, value: Option<f64>) -> Option<f32> {
        let Some(value) = value else {
            return None;
        };
        let value = value.clamp(0.0, 1.0);
        if self.last_gripper.is_none()
            && self
                .gripper_default
                .map(|default| (default - value).abs() < GRIPPER_COMMAND_EPSILON)
                .unwrap_or(false)
        {
            self.last_gripper = Some(value);
            tracing::debug!(
                "RobotArmDevice: seeded gripper default {:.2} without driver write",
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
        tracing::info!("RobotArmDevice: gripper command {:.2}", value);
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

    async fn reset_to_initial_pose(&mut self) -> Result<()> {
        tracing::info!("RobotArmDevice: reset requested; returning to initial pose");
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

        if let Some(joints) = latest_joints {
            let mut last_angles = self.last_angles.lock().await;
            *last_angles = joints.angles;
            last_angles.resize(self.num_joints, 0.0);
        }
        {
            let mut last_pose = self.last_end_effector_pose.lock().await;
            *last_pose = latest_end_effector_pose;
        }
        Ok(())
    }

    fn gripper_axis_to_joint_degrees(&self, value: f64) -> Option<f64> {
        let [lo, hi] = self.gripper_joint_limits?;
        Some(lo + value.clamp(0.0, 1.0) * (hi - lo))
    }
}

fn has_gripper_axis(descriptor: &DeviceDescriptor) -> bool {
    descriptor
        .control_schema
        .axes
        .iter()
        .any(|axis| axis.name == GRIPPER_AXIS)
}

fn gripper_axis_default_for(descriptor: &DeviceDescriptor) -> Option<f64> {
    descriptor
        .control_schema
        .axes
        .iter()
        .find(|axis| axis.name == GRIPPER_AXIS)
        .map(|axis| axis.default)
}

fn gripper_joint_index_for(descriptor: &DeviceDescriptor, num_joints: usize) -> Option<usize> {
    if has_gripper_axis(descriptor) && num_joints > 0 {
        Some(num_joints - 1)
    } else {
        None
    }
}

fn pose_joint_count_for(descriptor: &DeviceDescriptor, num_joints: usize) -> usize {
    if gripper_joint_index_for(descriptor, num_joints).is_some() {
        num_joints - 1
    } else {
        num_joints
    }
}

fn mapping_uses_driver_end_effector_targets(mode: &str) -> bool {
    !matches!(mode, "direct" | "retarget")
}

#[async_trait]
impl Device for RobotArmDevice {
    fn descriptor(&self) -> &DeviceDescriptor {
        &self.descriptor
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
            anyhow::bail!("driver-side IK mode requires an initial end-effector pose snapshot");
        }
        {
            let mut last_pose = self.last_end_effector_pose.lock().await;
            *last_pose = initial_end_effector_pose;
        }
        self.connected
            .store(true, std::sync::atomic::Ordering::SeqCst);
        {
            let mut mapper = self.mapper.lock().await;
            self.teleop.reset(&mut mapper);
        }
        self.last_gripper = None;
        self.last_reset_button = false;
        tracing::info!("RobotArmDevice connected (awaiting teleop enable)");
        Ok(())
    }

    async fn disconnect(&mut self) -> Result<()> {
        self.driver.lock().await.emergency_stop().await?;
        self.connected
            .store(false, std::sync::atomic::Ordering::SeqCst);
        {
            let mut mapper = self.mapper.lock().await;
            self.teleop.reset(&mut mapper);
        }
        self.last_gripper = None;
        {
            let mut last_pose = self.last_end_effector_pose.lock().await;
            *last_pose = None;
        }
        self.last_reset_button = false;
        tracing::info!("RobotArmDevice disconnected");
        Ok(())
    }

    async fn send_command(&mut self, cmd: &DeviceCommand) -> Result<()> {
        if self.handle_reset_button(cmd).await? {
            return Ok(());
        }

        // Extract end-effector pose and gripper value from the generic command.
        let gripper = cmd.axes.get(GRIPPER_AXIS).copied();

        if cmd.poses.contains_key(END_EFFECTOR_POSE) {
            if self.use_end_effector_pose {
                let Some(current_end_effector_pose) =
                    self.last_end_effector_pose.lock().await.clone()
                else {
                    if !command_enable(cmd) {
                        let mut mapper = self.mapper.lock().await;
                        self.teleop.reset(&mut mapper);
                    } else {
                        tracing::warn!(
                            "RobotArmDevice: no end-effector snapshot yet; dropping pose frame"
                        );
                    }
                    return Ok(());
                };

                // One mapper guard for the whole resolve. The stick is integrated
                // BEFORE the enable gate -- by product decision it trims the pose
                // whether or not the deadman is held, so it must not sit behind
                // the `Disabled` early return. When enabled the offset is folded
                // into the target by the mapper; when released it moves the last
                // target directly. The guard is dropped before publishing the
                // intent edge, which needs `&mut self`.
                let (nudge_delta, resolved) = {
                    let mut mapper = self.mapper.lock().await;
                    let nudge_delta = mapper.integrate_nudge(
                        cmd.axes.get(NUDGE_X_AXIS).copied().unwrap_or(0.0) as f64,
                        cmd.axes.get(NUDGE_Y_AXIS).copied().unwrap_or(0.0) as f64,
                        cmd.buttons
                            .get(NUDGE_VERTICAL_BUTTON)
                            .copied()
                            .unwrap_or(false),
                    );
                    let mapped = self.teleop.map_end_effector_command(
                        cmd,
                        &mut mapper,
                        &current_end_effector_pose,
                    );
                    let resolved = match mapped {
                        TeleopEndEffectorResult::Active(target) => Some(target),
                        TeleopEndEffectorResult::Disabled => {
                            // Hand contributes nothing, but the stick may still
                            // be trimming: move the last target by that delta.
                            if nudge_delta == [0.0; 3] {
                                None
                            } else {
                                mapper.nudge_last_target(nudge_delta)
                            }
                        }
                        TeleopEndEffectorResult::WaitingForPose => None,
                    };
                    (nudge_delta, resolved)
                };

                // Motion intent = deadman held OR the stick is nudging. The
                // plugin refuses to act on targets when this is false, so it
                // must cover the nudge-only case or released-grip nudging is
                // published and then silently discarded.
                let nudging = nudge_delta != [0.0; 3];
                let Some(target) = resolved else {
                    // Nothing to command this frame. Still drop intent when the
                    // operator is neither driving nor nudging, so the plugin
                    // freezes instead of coasting toward a stale target.
                    if !nudging {
                        self.publish_motion_allowed(false).await;
                    }
                    return Ok(());
                };
                self.publish_motion_allowed(true).await;

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
                if let Some(joints) = latest_joints {
                    let mut last_angles = self.last_angles.lock().await;
                    *last_angles = joints.angles;
                    last_angles.resize(self.num_joints, 0.0);
                }
                if let Some(pose) = latest_end_effector_pose {
                    let mut last_pose = self.last_end_effector_pose.lock().await;
                    *last_pose = Some(pose);
                }
                return Ok(());
            }

            let current_joint_target = self.last_angles.lock().await.clone();
            // Same as the end-effector path: drop the mapper guard before the
            // deadman edge, which needs `&mut self`.
            let mapped = {
                let mut mapper = self.mapper.lock().await;
                self.teleop
                    .map_command(cmd, &mut mapper, &current_joint_target)
            };
            // The stick nudge is a CARTESIAN end-effector offset and has no
            // meaning in joint space without IK, so it is not applied here. Warn
            // once rather than leaving an advertised control silently inert.
            if !self.warned_joint_mode_nudge
                && (cmd.axes.get(NUDGE_X_AXIS).is_some_and(|v| *v != 0.0)
                    || cmd.axes.get(NUDGE_Y_AXIS).is_some_and(|v| *v != 0.0))
            {
                self.warned_joint_mode_nudge = true;
                tracing::warn!(
                    "RobotArmDevice: thumbstick nudge ignored in joint-space mapping mode \
                     (it is a Cartesian end-effector offset); use pose_mapping.mode=ik to enable it"
                );
            }

            let joints = match mapped {
                TeleopPoseResult::Active(joints) => {
                    self.publish_motion_allowed(true).await;
                    joints
                }
                TeleopPoseResult::Disabled => {
                    self.publish_motion_allowed(false).await;
                    return Ok(());
                }
                TeleopPoseResult::WaitingForPose => return Ok(()),
            };

            let safety_result = self.safety.lock().await.validate(&joints);
            let (validated, was_clamped) = match safety_result {
                SafetyResult::Ok(v) => (v, false),
                SafetyResult::Clamped(v) => {
                    tracing::warn!("RobotArmDevice: joints clamped by safety limits");
                    (v, true)
                }
                SafetyResult::Rejected(reason) => {
                    tracing::error!("RobotArmDevice: safety rejection: {reason}");
                    self.emergency_stop().await?;
                    anyhow::bail!("safety rejection: {reason}");
                }
            };
            // Update last_angles *before* the timed write — the driver may time
            // out and silently hold, in which case the headset still wants to
            // see the latest commanded angle in telemetry.
            let _ = was_clamped; // currently informational only
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
            self.maybe_set_gripper(gripper).await?;
        } else if command_enable(cmd) {
            // No pose — maybe just a gripper command, still gated by enable.
            self.maybe_set_gripper(gripper).await?;
        }

        Ok(())
    }

    async fn get_telemetry(&self) -> Result<DeviceTelemetry> {
        // Sample the driver here rather than trusting the snapshot cached at
        // write time. The `lerobot_link` driver publishes targets and returns
        // without waiting, so the plugin's state arrives asynchronously and the
        // write-time snapshot is always a round trip stale. Harmless for the
        // MuJoCo driver, whose state is already fresh when a write returns.
        {
            let (latest_joints, latest_end_effector_pose) = {
                let driver = self.driver.lock().await;
                (driver.last_joint_angles(), driver.last_end_effector_pose())
            };
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

        let mut values = HashMap::new();
        let angles = self.last_angles.lock().await.clone();
        values.insert("joint_angles".into(), TelemetryValue::Array(angles));
        values.insert(
            "num_joints".into(),
            TelemetryValue::Int(self.num_joints as i64),
        );
        let connected = self.connected.load(std::sync::atomic::Ordering::SeqCst);
        values.insert("connected".into(), TelemetryValue::Bool(connected));

        // Control-frame overlay data. The headset draws an axis gizmo at the
        // controller showing which way the arm will actually move; publishing
        // the ADAPTER's live values (rather than re-deriving them client-side)
        // means a change to scale/mirror can never make the overlay lie.
        // `operator_frame` is absent while the deadman is released -- there is
        // no captured frame then, and the client hides the gizmo.
        {
            let mapper = self.mapper.lock().await;
            if let Some(q) = mapper.reference_frame_quat_xyzw() {
                values.insert(
                    "operator_frame".into(),
                    TelemetryValue::Array(q.to_vec()),
                );
            }
            values.insert("pose_scale".into(), TelemetryValue::Float(mapper.scale()));
            values.insert("pose_mirror".into(), TelemetryValue::Bool(mapper.mirror()));
            values.insert(
                "nudge_offset".into(),
                TelemetryValue::Array(mapper.nudge_offset().to_vec()),
            );
        }

        Ok(DeviceTelemetry {
            values,
            timestamp_ns: std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default()
                .as_nanos() as u64,
        })
    }

    async fn emergency_stop(&mut self) -> Result<()> {
        tracing::error!("RobotArmDevice: EMERGENCY STOP");
        let latest_end_effector_pose = {
            let mut driver = self.driver.lock().await;
            driver.emergency_stop().await?;
            driver.last_end_effector_pose()
        };
        if let Some(pose) = latest_end_effector_pose {
            let mut last_pose = self.last_end_effector_pose.lock().await;
            *last_pose = Some(pose);
        }
        self.safety.lock().await.reset();
        {
            let mut mapper = self.mapper.lock().await;
            self.teleop.reset(&mut mapper);
        }
        self.last_gripper = None;
        self.last_reset_button = false;
        Ok(())
    }

    fn is_connected(&self) -> bool {
        self.connected.load(std::sync::atomic::Ordering::SeqCst)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_descriptor_shape() {
        let d = RobotArmDevice::default_descriptor();
        assert_eq!(d.device.device_type, "robot_arm");
        assert_eq!(d.control_schema.poses.len(), 2);
        assert_eq!(d.control_schema.poses[0].name, "end_effector");
        assert_eq!(d.control_schema.poses[0].frame, "right_hand");
        assert_eq!(d.control_schema.poses[1].name, "operator_frame");
        assert_eq!(d.control_schema.poses[1].frame, "head");
        assert_eq!(d.control_schema.axes.len(), 3);
        assert_eq!(d.control_schema.axes[0].name, "gripper");
        assert_eq!(d.control_schema.axes[0].range, (0.0, 1.0));
        assert_eq!(d.control_schema.axes[0].default, 1.0);
        assert_eq!(d.control_schema.axes[1].name, NUDGE_X_AXIS);
        assert_eq!(d.control_schema.axes[2].name, NUDGE_Y_AXIS);
        assert_eq!(d.control_schema.buttons.len(), 3);
        assert_eq!(d.control_schema.buttons[0].name, "enable");
        assert_eq!(d.control_schema.buttons[1].name, NUDGE_VERTICAL_BUTTON);
        assert_eq!(d.control_schema.buttons[2].name, "reset");
        // Sources are hand-agnostic: `active_*` resolves client-side to whichever
        // controller is driving, so a rig with only the LEFT controller works.
        assert!(d
            .input_mapping
            .iter()
            .any(|m| m.source == "active_grip" && m.target == "enable"));
        assert!(d
            .input_mapping
            .iter()
            .any(|m| m.source == "active_button_b" && m.target == RESET_BUTTON));
        assert!(d
            .input_mapping
            .iter()
            .any(|m| m.source == "head_pose" && m.target == "operator_frame"));
        assert!(d
            .input_mapping
            .iter()
            .any(|m| m.source == "active_joystick_x" && m.target == NUDGE_X_AXIS));
        assert!(d
            .input_mapping
            .iter()
            .any(|m| m.source == "active_joystick_click" && m.target == NUDGE_VERTICAL_BUTTON));
        assert!(
            !d.input_mapping.iter().any(|m| m.source.starts_with("right_")),
            "built-in descriptor must not hardcode the right hand"
        );
        let trigger = d
            .input_mapping
            .iter()
            .find(|m| m.source == "active_trigger" && m.target == "gripper")
            .expect("active trigger gripper mapping");
        assert!(trigger.invert);
        assert_eq!(trigger.offset, 1.0);
        // Telemetry advertises joint_angles (array), num_joints, connected.
        let names: Vec<&str> = d
            .telemetry_schema
            .values
            .iter()
            .map(|v| v.name.as_str())
            .collect();
        assert!(names.contains(&"joint_angles"));
        assert!(names.contains(&"num_joints"));
        assert!(names.contains(&"connected"));
    }

    #[test]
    fn default_descriptor_reserves_last_joint_for_gripper() {
        let d = RobotArmDevice::default_descriptor();
        assert_eq!(gripper_joint_index_for(&d, 6), Some(5));
        assert_eq!(pose_joint_count_for(&d, 6), 5);
        assert_eq!(gripper_axis_default_for(&d), Some(1.0));
    }
}
