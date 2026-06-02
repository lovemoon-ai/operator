//! Map an end-effector [`Pose6D`] (position + quaternion) to joint angles.
//!
//! Refactored from `robot/src/control/pose_mapping.rs`. The original read
//! `pose.right_controller.position` / `.rotation` off a bulky `HeadsetPose`;
//! since the bridge already extracts the right-controller pose into a
//! `teleop_protocol::Pose6D` and forwards it as the `end_effector` pose in a
//! `DeviceCommand`, this version operates directly on `Pose6D`. The mapping math
//! (deg_per_meter = 300*scale, per-axis mirror sign, euler-from-quaternion for
//! the wrist joints, nalgebra w,x,y,z order) is preserved exactly.

use nalgebra::UnitQuaternion;

use crate::config::PoseMappingConfig;
use crate::control::JointAngles;
use teleop_protocol::Pose6D;

/// Maps end-effector pose data to robot joint angles.
pub struct PoseMapper {
    /// Mapping mode.
    mode: MappingMode,
    /// Position scale factor.
    scale: f64,
    /// Whether to mirror the left/right axis.
    mirror: bool,
    /// Number of joints on the arm.
    num_joints: usize,
    /// Reference (calibration) position captured when tracking starts.
    reference_pose: Option<[f64; 3]>,
    /// Home joint angles (all zeros for now).
    home_angles: Vec<f64>,
}

#[derive(Debug, Clone, Copy)]
enum MappingMode {
    Direct,
    Ik,
    Retarget,
}

impl PoseMapper {
    /// Create a new pose mapper from configuration.
    pub fn new(config: &PoseMappingConfig, num_joints: usize) -> Self {
        let mode = match config.mode.as_str() {
            "ik" => MappingMode::Ik,
            "retarget" => MappingMode::Retarget,
            _ => MappingMode::Direct,
        };

        Self {
            mode,
            scale: config.scale,
            mirror: config.mirror,
            num_joints,
            reference_pose: None,
            home_angles: vec![0.0; num_joints],
        }
    }

    /// Set the calibration reference pose. Called once when tracking starts to
    /// record the controller's "home" position.
    pub fn set_reference(&mut self, pose: &Pose6D) {
        self.reference_pose = Some(pose.position);
        tracing::info!("Calibration reference set: {:?}", pose.position);
    }

    /// Map an end-effector pose to joint angles.
    pub fn map(&self, pose: &Pose6D) -> JointAngles {
        match self.mode {
            MappingMode::Direct => self.map_direct(pose),
            MappingMode::Ik => self.map_ik_stub(pose),
            MappingMode::Retarget => self.map_retarget_stub(pose),
        }
    }

    /// Direct mapping: controller position deltas mapped to joint angle deltas.
    ///
    /// - delta_x -> joint 0 (base rotation)
    /// - delta_y -> joint 1 (shoulder)
    /// - delta_z -> joint 2 (elbow)
    /// - Controller rotation (roll/pitch/yaw) -> joints 3, 4, 5 (wrist)
    fn map_direct(&self, pose: &Pose6D) -> JointAngles {
        let mut angles = self.home_angles.clone();

        let reference = self.reference_pose.unwrap_or(pose.position);
        let current = pose.position;

        // Position deltas (meters) -> angle deltas (degrees).
        // Using a simple linear mapping: 0.1m movement = 30 degrees.
        let deg_per_meter = 300.0 * self.scale;
        let dx = current[0] - reference[0];
        let dy = current[1] - reference[1];
        let dz = current[2] - reference[2];

        let mirror_sign = if self.mirror { -1.0 } else { 1.0 };

        // Map position deltas to base joints.
        if self.num_joints > 0 {
            angles[0] = dx * deg_per_meter * mirror_sign; // base rotation
        }
        if self.num_joints > 1 {
            angles[1] = dy * deg_per_meter; // shoulder
        }
        if self.num_joints > 2 {
            angles[2] = dz * deg_per_meter * mirror_sign; // elbow
        }

        // Map controller rotation to wrist joints.
        let rot = &pose.rotation;
        let quat = UnitQuaternion::from_quaternion(nalgebra::Quaternion::new(
            rot[3], rot[0], rot[1], rot[2], // nalgebra uses w,x,y,z order
        ));
        let euler = quat.euler_angles(); // (roll, pitch, yaw) in radians

        if self.num_joints > 3 {
            angles[3] = euler.0.to_degrees() * self.scale; // wrist roll
        }
        if self.num_joints > 4 {
            angles[4] = euler.1.to_degrees() * self.scale; // wrist pitch
        }
        if self.num_joints > 5 {
            angles[5] = euler.2.to_degrees() * self.scale; // wrist yaw
        }

        JointAngles { angles }
    }

    /// IK mapping stub — Phase 2.
    fn map_ik_stub(&self, _pose: &Pose6D) -> JointAngles {
        tracing::warn!("IK mapping not yet implemented, using home position");
        JointAngles {
            angles: self.home_angles.clone(),
        }
    }

    /// Retarget mapping stub — Phase 2.
    fn map_retarget_stub(&self, _pose: &Pose6D) -> JointAngles {
        tracing::warn!("Retarget mapping not yet implemented, using home position");
        JointAngles {
            angles: self.home_angles.clone(),
        }
    }
}

/// Extract Euler angles from a quaternion (utility for debugging).
#[allow(dead_code)]
pub fn quaternion_to_euler(qx: f64, qy: f64, qz: f64, qw: f64) -> (f64, f64, f64) {
    let q = UnitQuaternion::from_quaternion(nalgebra::Quaternion::new(qw, qx, qy, qz));
    let (roll, pitch, yaw) = q.euler_angles();
    (roll.to_degrees(), pitch.to_degrees(), yaw.to_degrees())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn mapper(mirror: bool, scale: f64) -> PoseMapper {
        PoseMapper::new(
            &PoseMappingConfig {
                mode: "direct".to_string(),
                scale,
                mirror,
            },
            6,
        )
    }

    fn pose(position: [f64; 3], rotation: [f64; 4]) -> Pose6D {
        Pose6D { position, rotation }
    }

    const IDENTITY_QUAT: [f64; 4] = [0.0, 0.0, 0.0, 1.0];

    #[test]
    fn x_delta_drives_joint0_with_mirror_sign() {
        // deg_per_meter = 300 * scale; mirror flips the sign on joint 0.
        let mut m = mapper(true, 1.0);
        m.set_reference(&pose([0.0, 0.0, 0.0], IDENTITY_QUAT));

        let out = m.map(&pose([0.1, 0.0, 0.0], IDENTITY_QUAT));
        // 0.1 m * 300 deg/m * (-1 mirror) = -30 deg.
        assert!(
            (out.angles[0] - (-30.0)).abs() < 1e-9,
            "joint0 = {} (expected -30)",
            out.angles[0]
        );

        // Without mirror, same delta is +30 deg.
        let mut m2 = mapper(false, 1.0);
        m2.set_reference(&pose([0.0, 0.0, 0.0], IDENTITY_QUAT));
        let out2 = m2.map(&pose([0.1, 0.0, 0.0], IDENTITY_QUAT));
        assert!(
            (out2.angles[0] - 30.0).abs() < 1e-9,
            "joint0 = {} (expected +30)",
            out2.angles[0]
        );
    }

    #[test]
    fn identity_rotation_zeroes_wrist_joints() {
        let mut m = mapper(true, 1.0);
        m.set_reference(&pose([0.0, 0.0, 0.0], IDENTITY_QUAT));
        let out = m.map(&pose([0.0, 0.0, 0.0], IDENTITY_QUAT));
        // Identity quaternion -> all euler angles zero -> wrist joints zero.
        assert!(out.angles[3].abs() < 1e-9, "wrist roll = {}", out.angles[3]);
        assert!(out.angles[4].abs() < 1e-9, "wrist pitch = {}", out.angles[4]);
        assert!(out.angles[5].abs() < 1e-9, "wrist yaw = {}", out.angles[5]);
    }

    #[test]
    fn y_and_z_deltas_drive_shoulder_and_elbow() {
        let mut m = mapper(true, 1.0);
        m.set_reference(&pose([0.0, 0.0, 0.0], IDENTITY_QUAT));
        // +0.1 m on y -> joint1 (shoulder), no mirror sign on y.
        // +0.1 m on z -> joint2 (elbow), mirror sign applies.
        let out = m.map(&pose([0.0, 0.1, 0.1], IDENTITY_QUAT));
        assert!(
            (out.angles[1] - 30.0).abs() < 1e-9,
            "shoulder = {} (expected +30)",
            out.angles[1]
        );
        assert!(
            (out.angles[2] - (-30.0)).abs() < 1e-9,
            "elbow = {} (expected -30 with mirror)",
            out.angles[2]
        );
    }

    #[test]
    fn no_reference_means_zero_position_delta() {
        // Without a set reference, map_direct uses `current` as the reference,
        // so position deltas collapse to zero (the bug the reference_set flag
        // guards against on the device side).
        let m = mapper(true, 1.0);
        let out = m.map(&pose([0.5, 0.5, 0.5], IDENTITY_QUAT));
        assert!(out.angles[0].abs() < 1e-9);
        assert!(out.angles[1].abs() < 1e-9);
        assert!(out.angles[2].abs() < 1e-9);
    }
}
