//! Robot arm device — composes the adapter's `control::` subsystem (driver +
//! PoseMapper + joint Safety) behind the generic [`Device`] trait.
//!
//! Mirrors `robot/src/devices/robot_arm.rs`, but built on the shared
//! [`teleop_protocol`] types and the adapter's own joint-space control modules.
//! The bridge already sanitized the inbound command against the descriptor; this
//! device turns the sanitized `end_effector` pose into safe joint commands and
//! drives the MuJoCo SO-101 simulator subprocess.

use std::collections::HashMap;
use std::sync::Arc;

use anyhow::Result;
use async_trait::async_trait;
use tokio::sync::Mutex;

use teleop_protocol::{
    AxisDef, ControlSchema, DeviceCommand, DeviceDescriptor, DeviceInfo, DeviceTelemetry, Pose6D,
    PoseDef, TelemetrySchema, TelemetryValue, TelemetryValueDef,
};

use crate::config::ArmConfig;
use crate::control::drivers::{self, ArmDriver};
use crate::control::pose_mapping::PoseMapper;
use crate::control::safety::{Safety, SafetyResult};
use crate::device::Device;

/// A robotic arm device backed by an [`ArmDriver`] (this phase: the MuJoCo
/// SO-101 simulator).
pub struct RobotArmDevice {
    descriptor: DeviceDescriptor,
    /// Wrapped in a Mutex because ArmDriver is Send but not Sync.
    driver: Arc<Mutex<Box<dyn ArmDriver>>>,
    safety: Mutex<Safety>,
    mapper: Mutex<PoseMapper>,
    connected: std::sync::atomic::AtomicBool,
    last_angles: Mutex<Vec<f64>>,
    num_joints: usize,
    /// One-shot flag: cleared on connect, set after the first valid
    /// `end_effector` pose calibrates the `PoseMapper` reference. Without this,
    /// `PoseMapper::map_direct` collapses `reference = current` and the position
    /// deltas are always zero — effectively disabling the first three joints.
    reference_set: std::sync::atomic::AtomicBool,
    /// Maximum time a single driver write is allowed to block.
    driver_write_timeout: std::time::Duration,
    /// Counter of frames that exceeded `driver_write_timeout`.
    pub driver_write_timeout_count: std::sync::atomic::AtomicU64,
}

impl RobotArmDevice {
    /// Create a new `RobotArmDevice` from a descriptor and the arm config.
    pub fn new(descriptor: DeviceDescriptor, arm_config: &ArmConfig) -> Result<Self> {
        let driver = drivers::create_driver(&arm_config.driver, arm_config.mujoco.as_ref())?;
        let safety = Safety::from_config(&arm_config.safety);
        let mapper = PoseMapper::new(&arm_config.pose_mapping, arm_config.servo_ids.len());
        let num_joints = arm_config.servo_ids.len();

        Ok(Self {
            descriptor,
            driver: Arc::new(Mutex::new(driver)),
            safety: Mutex::new(safety),
            mapper: Mutex::new(mapper),
            connected: std::sync::atomic::AtomicBool::new(false),
            last_angles: Mutex::new(vec![0.0; num_joints]),
            num_joints,
            reference_set: std::sync::atomic::AtomicBool::new(false),
            driver_write_timeout: std::time::Duration::from_millis(
                arm_config.driver_write_timeout_ms,
            ),
            driver_write_timeout_count: std::sync::atomic::AtomicU64::new(0),
        })
    }

    /// The built-in 6-DOF SO-101 arm descriptor: one `gripper` axis (0..1), one
    /// `end_effector` pose (frame `right_hand`), and `joint_angles` /
    /// `num_joints` / `connected` telemetry. Matches `config/device_robot_arm.yaml`.
    pub fn default_descriptor() -> DeviceDescriptor {
        DeviceDescriptor {
            device: DeviceInfo {
                device_type: "robot_arm".to_string(),
                name: "MuJoCo SO-101 Arm".to_string(),
                icon: "robot_arm".to_string(),
                model_url: String::new(),
            },
            control_schema: ControlSchema {
                axes: vec![AxisDef {
                    name: "gripper".to_string(),
                    display: "Gripper".to_string(),
                    range: (0.0, 1.0),
                    default: 0.0,
                    dead_zone: 0.02,
                }],
                buttons: Vec::new(),
                poses: vec![PoseDef {
                    name: "end_effector".to_string(),
                    display: "End Effector Target".to_string(),
                    dof: 6,
                    frame: "right_hand".to_string(),
                }],
            },
            input_mapping: Vec::new(),
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
                ],
            },
            video_feeds: Vec::new(),
            safety: Default::default(),
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
}

#[async_trait]
impl Device for RobotArmDevice {
    fn descriptor(&self) -> &DeviceDescriptor {
        &self.descriptor
    }

    async fn connect(&mut self) -> Result<()> {
        self.driver.lock().await.enable_torque().await?;
        self.connected
            .store(true, std::sync::atomic::Ordering::SeqCst);
        // Force a re-calibration on the next valid pose. Handles first connect
        // and reconnect-after-disconnect: the operator's hand is almost
        // certainly not where it was when the previous session ended.
        self.reference_set
            .store(false, std::sync::atomic::Ordering::SeqCst);
        tracing::info!("RobotArmDevice connected (awaiting first pose for calibration)");
        Ok(())
    }

    async fn disconnect(&mut self) -> Result<()> {
        self.driver.lock().await.emergency_stop().await?;
        self.connected
            .store(false, std::sync::atomic::Ordering::SeqCst);
        tracing::info!("RobotArmDevice disconnected");
        Ok(())
    }

    async fn send_command(&mut self, cmd: &DeviceCommand) -> Result<()> {
        // Extract end-effector pose and gripper value from the generic command.
        let gripper = cmd.axes.get("gripper").copied().unwrap_or(0.0);

        if let Some(pose) = cmd.poses.get("end_effector") {
            let pose: &Pose6D = pose;

            // First valid pose after (re)connect: capture it as the calibration
            // reference. Without this, `PoseMapper::map_direct` computes
            // `current - current = 0` for every frame and the
            // base/shoulder/elbow joints never move. compare_exchange makes the
            // calibration race-free across concurrent dispatches.
            if self
                .reference_set
                .compare_exchange(
                    false,
                    true,
                    std::sync::atomic::Ordering::SeqCst,
                    std::sync::atomic::Ordering::SeqCst,
                )
                .is_ok()
            {
                self.mapper.lock().await.set_reference(pose);
            }

            let joints = self.mapper.lock().await.map(pose);

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
            *self.last_angles.lock().await = validated.angles.clone();
            let driver = self.driver.clone();
            self.with_write_timeout("set_joints", move || async move {
                driver.lock().await.set_joints(&validated).await
            })
            .await?;
        } else {
            // No pose — maybe just a gripper command.
            let driver = self.driver.clone();
            let gripper_f = gripper as f32;
            self.with_write_timeout("set_gripper", move || async move {
                driver.lock().await.set_gripper(gripper_f).await
            })
            .await?;
        }

        Ok(())
    }

    async fn get_telemetry(&self) -> Result<DeviceTelemetry> {
        let mut values = HashMap::new();
        let angles = self.last_angles.lock().await.clone();
        values.insert("joint_angles".into(), TelemetryValue::Array(angles));
        values.insert(
            "num_joints".into(),
            TelemetryValue::Int(self.num_joints as i64),
        );
        let connected = self.connected.load(std::sync::atomic::Ordering::SeqCst);
        values.insert("connected".into(), TelemetryValue::Bool(connected));

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
        self.driver.lock().await.emergency_stop().await?;
        self.safety.lock().await.reset();
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
        assert_eq!(d.control_schema.poses.len(), 1);
        assert_eq!(d.control_schema.poses[0].name, "end_effector");
        assert_eq!(d.control_schema.poses[0].frame, "right_hand");
        assert_eq!(d.control_schema.axes.len(), 1);
        assert_eq!(d.control_schema.axes[0].name, "gripper");
        assert_eq!(d.control_schema.axes[0].range, (0.0, 1.0));
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
}
