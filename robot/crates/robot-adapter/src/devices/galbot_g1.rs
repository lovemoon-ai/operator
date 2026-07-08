use std::collections::{BTreeMap, HashMap};
use std::sync::Arc;

use anyhow::Result;
use async_trait::async_trait;
use tokio::sync::Mutex;

use teleop_protocol::{
    AxisDef, ButtonDef, ControlSchema, DeviceCommand, DeviceDescriptor, DeviceInfo,
    DeviceTelemetry, InputMapping, Pose6D, PoseDef, TelemetrySchema, TelemetryValue,
    TelemetryValueDef,
};

use crate::config::GalbotG1Config;
use crate::control::drivers::galbot_g1::{
    GalbotG1Driver, LEFT_ARM, LEFT_GRIPPER, RIGHT_ARM, RIGHT_GRIPPER,
};
use crate::control::pose_mapping::PoseMapper;
use crate::control::teleop::{
    TeleopEndEffectorResult, TeleopPoseController, ENABLE_BUTTON, END_EFFECTOR_POSE,
    OPERATOR_FRAME_POSE, RESET_BUTTON,
};
use crate::device::Device;

pub const LEFT_END_EFFECTOR_POSE: &str = "left_end_effector";
pub const RIGHT_END_EFFECTOR_POSE: &str = "right_end_effector";
pub const LEFT_ENABLE_BUTTON: &str = "left_enable";
pub const RIGHT_ENABLE_BUTTON: &str = "right_enable";
pub const LEFT_GRIPPER_AXIS: &str = "left_gripper";
pub const RIGHT_GRIPPER_AXIS: &str = "right_gripper";

const GRIPPER_COMMAND_EPSILON: f64 = 0.01;

pub struct GalbotG1Device {
    descriptor: DeviceDescriptor,
    driver: Arc<Mutex<GalbotG1Driver>>,
    left_mapper: Mutex<PoseMapper>,
    right_mapper: Mutex<PoseMapper>,
    left_teleop: TeleopPoseController,
    right_teleop: TeleopPoseController,
    connected: std::sync::atomic::AtomicBool,
    last_ee_poses: Mutex<BTreeMap<String, Pose6D>>,
    last_grippers: Mutex<BTreeMap<String, f64>>,
    last_joints: Mutex<Vec<f64>>,
    last_reset_button: bool,
    driver_write_timeout: std::time::Duration,
    pub driver_write_timeout_count: std::sync::atomic::AtomicU64,
}

impl GalbotG1Device {
    pub fn new(descriptor: DeviceDescriptor, cfg: &GalbotG1Config) -> Result<Self> {
        let driver = GalbotG1Driver::new(cfg)?;
        Ok(Self {
            descriptor,
            driver: Arc::new(Mutex::new(driver)),
            left_mapper: Mutex::new(PoseMapper::new(&cfg.pose_mapping, 7)),
            right_mapper: Mutex::new(PoseMapper::new(&cfg.pose_mapping, 7)),
            left_teleop: TeleopPoseController::new(),
            right_teleop: TeleopPoseController::new(),
            connected: std::sync::atomic::AtomicBool::new(false),
            last_ee_poses: Mutex::new(BTreeMap::new()),
            last_grippers: Mutex::new(BTreeMap::new()),
            last_joints: Mutex::new(Vec::new()),
            last_reset_button: false,
            driver_write_timeout: std::time::Duration::from_millis(cfg.driver_write_timeout_ms),
            driver_write_timeout_count: std::sync::atomic::AtomicU64::new(0),
        })
    }

    pub fn default_descriptor() -> DeviceDescriptor {
        DeviceDescriptor {
            device: DeviceInfo {
                device_type: "galbot_g1".to_string(),
                name: "Galbot G1".to_string(),
                icon: "robot_arm".to_string(),
                model_url: String::new(),
            },
            control_schema: ControlSchema {
                axes: vec![
                    gripper_axis(LEFT_GRIPPER_AXIS, "Left Gripper"),
                    gripper_axis(RIGHT_GRIPPER_AXIS, "Right Gripper"),
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
                        display: "Reset".to_string(),
                        toggle: false,
                        group: None,
                        confirm: false,
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
                pose_mapping("left_controller_pose", LEFT_END_EFFECTOR_POSE),
                pose_mapping("right_controller_pose", RIGHT_END_EFFECTOR_POSE),
                pose_mapping("head_pose", OPERATOR_FRAME_POSE),
                trigger_mapping("left_trigger", LEFT_GRIPPER_AXIS),
                trigger_mapping("right_trigger", RIGHT_GRIPPER_AXIS),
                button_mapping("left_grip", LEFT_ENABLE_BUTTON),
                button_mapping("right_grip", RIGHT_ENABLE_BUTTON),
                button_mapping("both_triggers_hold_2s", RESET_BUTTON),
            ],
            telemetry_schema: TelemetrySchema {
                values: vec![
                    TelemetryValueDef {
                        name: "connected".to_string(),
                        display: "Connected".to_string(),
                        unit: String::new(),
                        range: None,
                        warn_below: None,
                        value_type: Some("bool".to_string()),
                        length: None,
                    },
                    TelemetryValueDef {
                        name: "left_gripper".to_string(),
                        display: "Left Gripper".to_string(),
                        unit: String::new(),
                        range: Some((0.0, 1.0)),
                        warn_below: None,
                        value_type: Some("float".to_string()),
                        length: None,
                    },
                    TelemetryValueDef {
                        name: "right_gripper".to_string(),
                        display: "Right Gripper".to_string(),
                        unit: String::new(),
                        range: Some((0.0, 1.0)),
                        warn_below: None,
                        value_type: Some("float".to_string()),
                        length: None,
                    },
                    TelemetryValueDef {
                        name: "left_end_effector_pose".to_string(),
                        display: "Left End Effector Pose".to_string(),
                        unit: String::new(),
                        range: None,
                        warn_below: None,
                        value_type: Some("array".to_string()),
                        length: Some(7),
                    },
                    TelemetryValueDef {
                        name: "right_end_effector_pose".to_string(),
                        display: "Right End Effector Pose".to_string(),
                        unit: String::new(),
                        range: None,
                        warn_below: None,
                        value_type: Some("array".to_string()),
                        length: Some(7),
                    },
                    TelemetryValueDef {
                        name: "joint_positions".to_string(),
                        display: "Joint Positions".to_string(),
                        unit: "rad".to_string(),
                        range: None,
                        warn_below: None,
                        value_type: Some("array".to_string()),
                        length: None,
                    },
                ],
            },
            video_feeds: Vec::new(),
            safety: teleop_protocol::DeviceSafetyConfig {
                disconnect_action: "stop".to_string(),
                command_timeout_ms: 500,
                limits: HashMap::from([
                    (LEFT_GRIPPER_AXIS.to_string(), (0.0, 1.0)),
                    (RIGHT_GRIPPER_AXIS.to_string(), (0.0, 1.0)),
                ]),
            },
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
                    .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                tracing::warn!(
                    "GalbotG1Device: driver write '{label}' exceeded {:?}, dropping frame",
                    self.driver_write_timeout
                );
                Ok(())
            }
        }
    }

    async fn handle_reset_button(&mut self, cmd: &DeviceCommand) -> Result<bool> {
        let pressed = cmd.buttons.get(RESET_BUTTON).copied().unwrap_or(false);
        let rising_edge = pressed && !self.last_reset_button;
        self.last_reset_button = pressed;
        if !rising_edge {
            return Ok(false);
        }
        self.reset_to_initial_pose().await?;
        Ok(true)
    }

    async fn reset_to_initial_pose(&mut self) -> Result<()> {
        tracing::info!("GalbotG1Device: reset requested; returning Galbot to reset pose");
        {
            let mut mapper = self.left_mapper.lock().await;
            self.left_teleop.reset(&mut mapper);
        }
        {
            let mut mapper = self.right_mapper.lock().await;
            self.right_teleop.reset(&mut mapper);
        }

        let driver = self.driver.clone();
        self.with_write_timeout("reset_to_initial_pose", move || async move {
            driver.lock().await.reset_to_initial_pose().await
        })
        .await?;
        self.refresh_from_driver().await;
        Ok(())
    }

    async fn refresh_from_driver(&self) {
        let (poses, grippers, joints, connected) = {
            let driver = self.driver.lock().await;
            (
                driver.last_ee_poses(),
                driver
                    .last_grippers()
                    .into_iter()
                    .map(|(k, v)| (k, v as f64))
                    .collect::<BTreeMap<_, _>>(),
                driver.last_joints(),
                driver.is_connected(),
            )
        };
        if !poses.is_empty() {
            *self.last_ee_poses.lock().await = poses;
        }
        if !grippers.is_empty() {
            *self.last_grippers.lock().await = grippers;
        }
        if !joints.is_empty() {
            *self.last_joints.lock().await = joints;
        }
        self.connected
            .store(connected, std::sync::atomic::Ordering::SeqCst);
    }

    fn prepare_gripper_command(
        last_grippers: &mut BTreeMap<String, f64>,
        name: &str,
        value: Option<f64>,
    ) -> Option<f32> {
        let value = value?.clamp(0.0, 1.0);
        if last_grippers
            .get(name)
            .map(|last| (last - value).abs() < GRIPPER_COMMAND_EPSILON)
            .unwrap_or(false)
        {
            return None;
        }
        last_grippers.insert(name.to_string(), value);
        Some(value as f32)
    }

    async fn maybe_map_arm(
        teleop: &mut TeleopPoseController,
        mapper: &Mutex<PoseMapper>,
        cmd: &DeviceCommand,
        input_pose_name: &str,
        input_enable_name: &str,
        driver_arm_name: &str,
        current_pose: &Pose6D,
    ) -> Option<(String, Pose6D)> {
        let Some(input_pose) = cmd.poses.get(input_pose_name) else {
            return None;
        };

        let mut arm_cmd = DeviceCommand::default();
        arm_cmd.buttons.insert(
            ENABLE_BUTTON.to_string(),
            cmd.buttons.get(input_enable_name).copied().unwrap_or(false),
        );
        arm_cmd
            .poses
            .insert(END_EFFECTOR_POSE.to_string(), input_pose.clone());
        if let Some(operator_frame) = cmd.poses.get(OPERATOR_FRAME_POSE) {
            arm_cmd
                .poses
                .insert(OPERATOR_FRAME_POSE.to_string(), operator_frame.clone());
        }

        let mut mapper = mapper.lock().await;
        match teleop.map_end_effector_command(&arm_cmd, &mut mapper, current_pose) {
            TeleopEndEffectorResult::Active(target) => Some((driver_arm_name.to_string(), target)),
            TeleopEndEffectorResult::Disabled | TeleopEndEffectorResult::WaitingForPose => None,
        }
    }
}

fn gripper_axis(name: &str, display: &str) -> AxisDef {
    AxisDef {
        name: name.to_string(),
        display: display.to_string(),
        range: (0.0, 1.0),
        default: 1.0,
        dead_zone: 0.02,
    }
}

fn pose_mapping(source: &str, target: &str) -> InputMapping {
    InputMapping {
        source: source.to_string(),
        target: target.to_string(),
        scale: 1.0,
        invert: false,
        offset: 0.0,
        mode: "absolute".to_string(),
    }
}

fn trigger_mapping(source: &str, target: &str) -> InputMapping {
    InputMapping {
        source: source.to_string(),
        target: target.to_string(),
        scale: 1.0,
        invert: true,
        offset: 1.0,
        mode: "absolute".to_string(),
    }
}

fn button_mapping(source: &str, target: &str) -> InputMapping {
    InputMapping {
        source: source.to_string(),
        target: target.to_string(),
        scale: 1.0,
        invert: false,
        offset: 0.0,
        mode: "momentary".to_string(),
    }
}

fn pose_to_array(pose: &Pose6D) -> Vec<f64> {
    vec![
        pose.position[0],
        pose.position[1],
        pose.position[2],
        pose.rotation[0],
        pose.rotation[1],
        pose.rotation[2],
        pose.rotation[3],
    ]
}

#[async_trait]
impl Device for GalbotG1Device {
    fn descriptor(&self) -> &DeviceDescriptor {
        &self.descriptor
    }

    async fn connect(&mut self) -> Result<()> {
        self.driver.lock().await.enable().await?;
        self.refresh_from_driver().await;
        let poses = self.last_ee_poses.lock().await.clone();
        if !poses.contains_key(LEFT_ARM) || !poses.contains_key(RIGHT_ARM) {
            anyhow::bail!("Galbot G1 bridge did not provide both initial end-effector poses");
        }
        {
            let mut mapper = self.left_mapper.lock().await;
            self.left_teleop.reset(&mut mapper);
        }
        {
            let mut mapper = self.right_mapper.lock().await;
            self.right_teleop.reset(&mut mapper);
        }
        self.last_reset_button = false;
        self.connected
            .store(true, std::sync::atomic::Ordering::SeqCst);
        tracing::info!("GalbotG1Device connected (awaiting left/right grip deadman)");
        Ok(())
    }

    async fn disconnect(&mut self) -> Result<()> {
        self.driver.lock().await.stop().await?;
        self.connected
            .store(false, std::sync::atomic::Ordering::SeqCst);
        {
            let mut mapper = self.left_mapper.lock().await;
            self.left_teleop.reset(&mut mapper);
        }
        {
            let mut mapper = self.right_mapper.lock().await;
            self.right_teleop.reset(&mut mapper);
        }
        self.last_reset_button = false;
        tracing::info!("GalbotG1Device disconnected");
        Ok(())
    }

    async fn send_command(&mut self, cmd: &DeviceCommand) -> Result<()> {
        if self.handle_reset_button(cmd).await? {
            return Ok(());
        }

        let current_poses = self.last_ee_poses.lock().await.clone();
        let mut targets: BTreeMap<String, Pose6D> = BTreeMap::new();

        if let Some(current_left) = current_poses.get(LEFT_ARM) {
            if let Some((name, target)) = Self::maybe_map_arm(
                &mut self.left_teleop,
                &self.left_mapper,
                cmd,
                LEFT_END_EFFECTOR_POSE,
                LEFT_ENABLE_BUTTON,
                LEFT_ARM,
                current_left,
            )
            .await
            {
                targets.insert(name, target);
            }
        }

        if let Some(current_right) = current_poses.get(RIGHT_ARM) {
            if let Some((name, target)) = Self::maybe_map_arm(
                &mut self.right_teleop,
                &self.right_mapper,
                cmd,
                RIGHT_END_EFFECTOR_POSE,
                RIGHT_ENABLE_BUTTON,
                RIGHT_ARM,
                current_right,
            )
            .await
            {
                targets.insert(name, target);
            }
        }

        let mut grippers: BTreeMap<String, f32> = BTreeMap::new();
        {
            let mut last_grippers = self.last_grippers.lock().await;
            if cmd
                .buttons
                .get(LEFT_ENABLE_BUTTON)
                .copied()
                .unwrap_or(false)
            {
                if let Some(value) = Self::prepare_gripper_command(
                    &mut last_grippers,
                    LEFT_GRIPPER,
                    cmd.axes.get(LEFT_GRIPPER_AXIS).copied(),
                ) {
                    grippers.insert(LEFT_GRIPPER.to_string(), value);
                }
            }
            if cmd
                .buttons
                .get(RIGHT_ENABLE_BUTTON)
                .copied()
                .unwrap_or(false)
            {
                if let Some(value) = Self::prepare_gripper_command(
                    &mut last_grippers,
                    RIGHT_GRIPPER,
                    cmd.axes.get(RIGHT_GRIPPER_AXIS).copied(),
                ) {
                    grippers.insert(RIGHT_GRIPPER.to_string(), value);
                }
            }
        }

        if targets.is_empty() && grippers.is_empty() {
            return Ok(());
        }

        let driver = self.driver.clone();
        self.with_write_timeout("set_targets", move || async move {
            driver.lock().await.set_targets(&targets, &grippers).await
        })
        .await?;
        self.refresh_from_driver().await;
        Ok(())
    }

    async fn get_telemetry(&self) -> Result<DeviceTelemetry> {
        let mut values = HashMap::new();
        let connected = self.connected.load(std::sync::atomic::Ordering::SeqCst);
        values.insert("connected".into(), TelemetryValue::Bool(connected));

        let grippers = self.last_grippers.lock().await.clone();
        values.insert(
            "left_gripper".into(),
            TelemetryValue::Float(*grippers.get(LEFT_GRIPPER).unwrap_or(&1.0)),
        );
        values.insert(
            "right_gripper".into(),
            TelemetryValue::Float(*grippers.get(RIGHT_GRIPPER).unwrap_or(&1.0)),
        );

        let poses = self.last_ee_poses.lock().await.clone();
        if let Some(pose) = poses.get(LEFT_ARM) {
            values.insert(
                "left_end_effector_pose".into(),
                TelemetryValue::Array(pose_to_array(pose)),
            );
        }
        if let Some(pose) = poses.get(RIGHT_ARM) {
            values.insert(
                "right_end_effector_pose".into(),
                TelemetryValue::Array(pose_to_array(pose)),
            );
        }

        let joints = self.last_joints.lock().await.clone();
        if !joints.is_empty() {
            values.insert("joint_positions".into(), TelemetryValue::Array(joints));
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
        tracing::error!("GalbotG1Device: EMERGENCY STOP");
        self.driver.lock().await.stop().await?;
        self.connected
            .store(false, std::sync::atomic::Ordering::SeqCst);
        {
            let mut mapper = self.left_mapper.lock().await;
            self.left_teleop.reset(&mut mapper);
        }
        {
            let mut mapper = self.right_mapper.lock().await;
            self.right_teleop.reset(&mut mapper);
        }
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
        let d = GalbotG1Device::default_descriptor();
        assert_eq!(d.device.device_type, "galbot_g1");
        assert_eq!(d.control_schema.axes.len(), 2);
        assert!(d
            .control_schema
            .axes
            .iter()
            .any(|a| a.name == LEFT_GRIPPER_AXIS && a.default == 1.0));
        assert!(d
            .control_schema
            .buttons
            .iter()
            .any(|b| b.name == LEFT_ENABLE_BUTTON));
        assert!(d
            .control_schema
            .buttons
            .iter()
            .any(|b| b.name == RIGHT_ENABLE_BUTTON));
        assert!(d
            .control_schema
            .buttons
            .iter()
            .any(|b| b.name == RESET_BUTTON));
        assert!(d
            .input_mapping
            .iter()
            .any(|m| m.source == "both_triggers_hold_2s" && m.target == RESET_BUTTON));
        let left_trigger = d
            .input_mapping
            .iter()
            .find(|m| m.source == "left_trigger" && m.target == LEFT_GRIPPER_AXIS)
            .expect("left trigger gripper mapping");
        assert!(left_trigger.invert);
        assert_eq!(left_trigger.offset, 1.0);
    }
}
