//! Stateful controller-side teleop gating.
//!
//! XR sends controller poses continuously, including frames where the operator
//! does not intend to drive the arm. This controller treats `buttons.enable` or
//! `axes.enable >= 0.5` as the deadman gate: pose frames are ignored until
//! enable is held. On the enable rising edge we capture both the controller pose
//! and the current joint target, then map later controller motion as a relative
//! offset from that baseline.

use teleop_protocol::DeviceCommand;
use teleop_protocol::Pose6D;

use crate::control::pose_mapping::PoseMapper;
use crate::control::JointAngles;

pub const ENABLE_BUTTON: &str = "enable";
pub const RESET_BUTTON: &str = "reset";
pub const END_EFFECTOR_POSE: &str = "end_effector";
pub const OPERATOR_FRAME_POSE: &str = "operator_frame";
const ENABLE_AXIS_THRESHOLD: f64 = 0.5;

#[derive(Debug, Clone)]
pub enum TeleopPoseResult {
    Disabled,
    WaitingForPose,
    Active(JointAngles),
}

#[derive(Debug, Clone)]
pub enum TeleopEndEffectorResult {
    Disabled,
    WaitingForPose,
    Active(Pose6D),
}

#[derive(Debug, Default)]
pub struct TeleopPoseController {
    enabled: bool,
}

impl TeleopPoseController {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn reset(&mut self, mapper: &mut PoseMapper) {
        self.enabled = false;
        mapper.clear_reference();
    }

    pub fn map_command(
        &mut self,
        cmd: &DeviceCommand,
        mapper: &mut PoseMapper,
        current_joint_target: &[f64],
    ) -> TeleopPoseResult {
        if !command_enable(cmd) {
            if self.enabled {
                tracing::info!("Teleop disabled; clearing pose reference");
                mapper.clear_reference();
            }
            self.enabled = false;
            return TeleopPoseResult::Disabled;
        }

        let Some(pose) = cmd.poses.get(END_EFFECTOR_POSE) else {
            return TeleopPoseResult::WaitingForPose;
        };

        if !self.enabled {
            mapper.set_base_angles(current_joint_target);
            mapper.set_reference(pose);
            self.enabled = true;
            tracing::info!("Teleop enabled; captured relative pose baseline");
        }

        TeleopPoseResult::Active(mapper.map(pose))
    }

    pub fn map_end_effector_command(
        &mut self,
        cmd: &DeviceCommand,
        mapper: &mut PoseMapper,
        current_end_effector_pose: &Pose6D,
    ) -> TeleopEndEffectorResult {
        if !command_enable(cmd) {
            if self.enabled {
                tracing::info!("Teleop disabled; clearing pose reference");
                mapper.clear_reference();
            }
            self.enabled = false;
            return TeleopEndEffectorResult::Disabled;
        }

        let Some(pose) = cmd.poses.get(END_EFFECTOR_POSE) else {
            return TeleopEndEffectorResult::WaitingForPose;
        };

        if !self.enabled {
            mapper.set_base_end_effector_pose(current_end_effector_pose);
            mapper.set_reference(pose);
            if let Some(operator_frame) = cmd.poses.get(OPERATOR_FRAME_POSE) {
                mapper.set_reference_frame(operator_frame);
            } else {
                mapper.set_reference_frame(pose);
            }
            self.enabled = true;
            tracing::info!("Teleop enabled; captured relative end-effector baseline");
        }

        TeleopEndEffectorResult::Active(mapper.map_end_effector_target(pose))
    }
}

pub fn command_enable(cmd: &DeviceCommand) -> bool {
    cmd.buttons.get(ENABLE_BUTTON).copied().unwrap_or(false)
        || cmd.axes.get(ENABLE_BUTTON).copied().unwrap_or(0.0) >= ENABLE_AXIS_THRESHOLD
}

pub fn command_reset(cmd: &DeviceCommand) -> bool {
    cmd.buttons.get(RESET_BUTTON).copied().unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::PoseMappingConfig;
    use teleop_protocol::Pose6D;

    const IDENTITY_QUAT: [f64; 4] = [0.0, 0.0, 0.0, 1.0];

    fn mapper() -> PoseMapper {
        PoseMapper::new(
            &PoseMappingConfig {
                mode: "direct".to_string(),
                scale: 1.0,
                mirror: false,
            },
            6,
        )
    }

    fn command(enable_value: f64, position: [f64; 3]) -> DeviceCommand {
        let mut cmd = DeviceCommand::default();
        cmd.axes.insert(ENABLE_BUTTON.to_string(), enable_value);
        cmd.poses.insert(
            END_EFFECTOR_POSE.to_string(),
            Pose6D {
                position,
                rotation: IDENTITY_QUAT,
            },
        );
        cmd
    }

    #[test]
    fn disabled_pose_is_ignored() {
        let mut controller = TeleopPoseController::new();
        let mut mapper = mapper();
        let base = [10.0, 20.0, 30.0, 0.0, 0.0, 0.0];

        match controller.map_command(&command(0.0, [1.0, 0.0, 0.0]), &mut mapper, &base) {
            TeleopPoseResult::Disabled => {}
            other => panic!("expected disabled, got {other:?}"),
        }
    }

    #[test]
    fn first_enabled_pose_captures_baseline_and_holds_current_target() {
        let mut controller = TeleopPoseController::new();
        let mut mapper = mapper();
        let base = [10.0, 20.0, 30.0, 0.0, 0.0, 0.0];

        match controller.map_command(&command(1.0, [0.5, 0.0, 0.0]), &mut mapper, &base) {
            TeleopPoseResult::Active(joints) => assert_eq!(joints.angles, base),
            other => panic!("expected active joints, got {other:?}"),
        }
    }

    #[test]
    fn enabled_pose_maps_relative_to_enable_baseline() {
        let mut controller = TeleopPoseController::new();
        let mut mapper = mapper();
        let base = [10.0, 20.0, 30.0, 0.0, 0.0, 0.0];

        let _ = controller.map_command(&command(1.0, [0.5, 0.0, 0.0]), &mut mapper, &base);
        match controller.map_command(&command(1.0, [0.6, 0.0, 0.0]), &mut mapper, &base) {
            TeleopPoseResult::Active(joints) => {
                assert!((joints.angles[0] - 40.0).abs() < 1e-9);
                assert!((joints.angles[1] - 20.0).abs() < 1e-9);
                assert!((joints.angles[2] - 30.0).abs() < 1e-9);
            }
            other => panic!("expected active joints, got {other:?}"),
        }
    }

    #[test]
    fn reenable_recaptures_baseline() {
        let mut controller = TeleopPoseController::new();
        let mut mapper = mapper();
        let first_base = [10.0, 0.0, 0.0, 0.0, 0.0, 0.0];
        let second_base = [50.0, 0.0, 0.0, 0.0, 0.0, 0.0];

        let _ = controller.map_command(&command(1.0, [0.0, 0.0, 0.0]), &mut mapper, &first_base);
        let _ = controller.map_command(&command(0.0, [1.0, 0.0, 0.0]), &mut mapper, &first_base);

        match controller.map_command(&command(1.0, [1.0, 0.0, 0.0]), &mut mapper, &second_base) {
            TeleopPoseResult::Active(joints) => assert_eq!(joints.angles, second_base),
            other => panic!("expected active joints, got {other:?}"),
        }
    }

    #[test]
    fn grip_axis_below_threshold_is_disabled() {
        let mut controller = TeleopPoseController::new();
        let mut mapper = mapper();
        let base = [10.0, 20.0, 30.0, 0.0, 0.0, 0.0];

        match controller.map_command(&command(0.49, [0.5, 0.0, 0.0]), &mut mapper, &base) {
            TeleopPoseResult::Disabled => {}
            other => panic!("expected disabled, got {other:?}"),
        }
    }

    #[test]
    fn command_reset_reads_reset_button_only() {
        let mut cmd = DeviceCommand::default();
        assert!(!command_reset(&cmd));

        cmd.buttons.insert(ENABLE_BUTTON.to_string(), true);
        assert!(!command_reset(&cmd));

        cmd.buttons.insert(RESET_BUTTON.to_string(), true);
        assert!(command_reset(&cmd));
    }

    #[test]
    fn first_enabled_end_effector_pose_captures_baseline() {
        let mut controller = TeleopPoseController::new();
        let mut mapper = PoseMapper::new(
            &PoseMappingConfig {
                mode: "ik".to_string(),
                scale: 1.0,
                mirror: false,
            },
            5,
        );
        let current_ee = Pose6D {
            position: [1.0, 2.0, 3.0],
            rotation: IDENTITY_QUAT,
        };

        match controller.map_end_effector_command(
            &command(1.0, [0.5, 0.0, 0.0]),
            &mut mapper,
            &current_ee,
        ) {
            TeleopEndEffectorResult::Active(target) => assert_eq!(target.position, [1.0, 2.0, 3.0]),
            other => panic!("expected active target, got {other:?}"),
        }
    }

    #[test]
    fn enabled_end_effector_pose_maps_relative_to_enable_baseline() {
        let mut controller = TeleopPoseController::new();
        let mut mapper = PoseMapper::new(
            &PoseMappingConfig {
                mode: "ik".to_string(),
                scale: 1.0,
                mirror: false,
            },
            5,
        );
        let current_ee = Pose6D {
            position: [1.0, 2.0, 3.0],
            rotation: IDENTITY_QUAT,
        };

        let _ = controller.map_end_effector_command(
            &command(1.0, [0.5, 0.0, 0.0]),
            &mut mapper,
            &current_ee,
        );
        match controller.map_end_effector_command(
            &command(1.0, [0.6, 0.0, 0.0]),
            &mut mapper,
            &current_ee,
        ) {
            TeleopEndEffectorResult::Active(target) => {
                assert!((target.position[0] - 1.0).abs() < 1e-9);
                assert!((target.position[1] - 2.1).abs() < 1e-9);
                assert!((target.position[2] - 3.0).abs() < 1e-9);
            }
            other => panic!("expected active target, got {other:?}"),
        }
    }
}
