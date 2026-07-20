//! Map XR controller poses into robot control targets.
//!
//! Direct mode still emits joint-space deltas for debugging and legacy tests.
//! IK mode is driver-side: this mapper only converts controller-relative motion
//! into a MuJoCo base-frame end-effector target pose. The MuJoCo bridge then
//! solves IK using MuJoCo Jacobians.

use nalgebra::{Matrix3, Rotation3, UnitQuaternion, Vector3};

use crate::config::PoseMappingConfig;
use crate::control::JointAngles;
use teleop_protocol::Pose6D;

/// Thumbstick fine-adjust speed at full deflection (metres/second).
const DEFAULT_NUDGE_RATE_M_S: f64 = 0.030;
/// Per-axis cap on the accumulated nudge since the last baseline. A stuck stick
/// therefore drifts a bounded distance instead of walking the arm away.
const DEFAULT_NUDGE_LIMIT_M: f64 = 0.15;
/// Largest integration step, so a stalled command stream cannot jump the offset.
const MAX_NUDGE_DT_S: f64 = 0.1;
/// Minimum gap between nudge-saturation warnings.
const NUDGE_WARN_EVERY: std::time::Duration = std::time::Duration::from_secs(2);

/// Maps controller pose data to joint angles or end-effector pose targets.
pub struct PoseMapper {
    /// Mapping mode.
    mode: MappingMode,
    /// Position scale factor.
    scale: f64,
    /// Whether to mirror the left/right axis.
    mirror: bool,
    /// Number of joints on the arm.
    num_joints: usize,
    /// Reference controller pose captured when teleop enable is pressed.
    reference_pose: Option<Pose6D>,
    /// Base joint angles captured when teleop enable is pressed.
    base_angles: Vec<f64>,
    /// Base end-effector pose captured when teleop enable is pressed.
    base_end_effector_pose: Option<Pose6D>,
    /// Yaw-only operator frame captured when teleop enable is pressed.
    ///
    /// This is normally derived from the HMD/head pose. Controller position
    /// deltas are first interpreted in this local frame, then mapped to the
    /// robot base frame so the operator's forward direction becomes robot +X.
    reference_frame_rotation: Option<UnitQuaternion<f64>>,

    // --- Thumbstick fine-adjust ("nudge") ---------------------------------
    //
    // A persistent end-effector offset in the ROBOT base frame, integrated from
    // the stick at `nudge_rate_m_s`. It is deliberately additive to the hand
    // mapping so the operator can trim a pose without moving their arm.
    //
    // It is zeroed whenever a new baseline is captured (see
    // `set_base_end_effector_pose`): the baseline is taken at the arm's CURRENT
    // pose, which already embodies every earlier nudge, so carrying the offset
    // across a re-squeeze would apply it twice. The nudge still "persists" in
    // the only sense that matters -- the arm stays where it was trimmed to.
    nudge_offset: [f64; 3],
    nudge_rate_m_s: f64,
    /// Runaway guard: total offset since the last baseline, per axis.
    nudge_limit_m: f64,
    last_nudge_at: Option<std::time::Instant>,
    /// Rate limit for the saturation warning.
    last_nudge_warn_at: Option<std::time::Instant>,
    /// Last end-effector target produced, so a nudge with the deadman released
    /// has something to move relative to.
    last_target_ee: Option<Pose6D>,
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
            "direct" => MappingMode::Direct,
            "retarget" => MappingMode::Retarget,
            _ => MappingMode::Ik,
        };

        Self {
            mode,
            scale: config.scale,
            mirror: config.mirror,
            num_joints,
            reference_pose: None,
            base_angles: vec![0.0; num_joints],
            base_end_effector_pose: None,
            reference_frame_rotation: None,
            nudge_offset: [0.0; 3],
            nudge_rate_m_s: DEFAULT_NUDGE_RATE_M_S,
            nudge_limit_m: DEFAULT_NUDGE_LIMIT_M,
            last_nudge_at: None,
            last_nudge_warn_at: None,
            last_target_ee: None,
        }
    }

    /// Set the controller calibration reference pose.
    pub fn set_reference(&mut self, pose: &Pose6D) {
        self.reference_pose = Some(pose.clone());
        tracing::info!(
            "Calibration reference set: position={:?} rotation={:?}",
            pose.position,
            pose.rotation
        );
    }

    /// Clear the controller pose reference and associated end-effector baseline.
    pub fn clear_reference(&mut self) {
        self.reference_pose = None;
        self.base_end_effector_pose = None;
        self.reference_frame_rotation = None;
    }

    /// Set the joint-space baseline that relative controller motion adds to.
    pub fn set_base_angles(&mut self, angles: &[f64]) {
        self.base_angles = angles.to_vec();
        self.base_angles.resize(self.num_joints, 0.0);
    }

    /// Set the end-effector pose baseline for driver-side IK.
    pub fn set_base_end_effector_pose(&mut self, pose: &Pose6D) {
        self.base_end_effector_pose = Some(pose.clone());
        // The new baseline already includes every nudge applied so far; keeping
        // the offset would double-count it on the next target.
        self.nudge_offset = [0.0; 3];
    }

    /// Integrate one tick of thumbstick fine-adjust into the persistent offset.
    ///
    /// `stick_x` is lateral and `stick_y` is forward/back, both -1..1 and
    /// already dead-zoned by the client. With `vertical` held, `stick_y` drives
    /// HEIGHT instead of forward/back (and lateral is ignored), which is the
    /// documented click-to-change-axis behaviour.
    ///
    /// Returns the delta actually applied this tick, so a caller can move the
    /// last target directly when the deadman is released and there is no
    /// baseline to rebuild from.
    pub fn integrate_nudge(&mut self, stick_x: f64, stick_y: f64, vertical: bool) -> [f64; 3] {
        let now = std::time::Instant::now();
        let dt = match self.last_nudge_at {
            // Clamp so a stalled/resumed command stream cannot integrate one
            // giant step, same reasoning as the plugin's rate limiter.
            Some(prev) => now.duration_since(prev).as_secs_f64().min(MAX_NUDGE_DT_S),
            None => 0.0,
        };
        self.last_nudge_at = Some(now);
        if dt <= 0.0 {
            return [0.0; 3];
        }

        let step = self.nudge_rate_m_s * dt;
        // Robot base frame: +X forward, +Y left, +Z up. Lateral uses the same
        // sign convention as the hand mapping so the stick and the hand agree.
        let lateral_sign = if self.mirror { -1.0 } else { 1.0 };
        let requested = if vertical {
            [0.0, 0.0, stick_y * step]
        } else {
            [stick_y * step, lateral_sign * stick_x * step, 0.0]
        };

        let mut applied = [0.0; 3];
        let mut saturated = false;
        for i in 0..3 {
            let before = self.nudge_offset[i];
            let after = (before + requested[i]).clamp(-self.nudge_limit_m, self.nudge_limit_m);
            self.nudge_offset[i] = after;
            applied[i] = after - before;
            // Requested motion that the clamp swallowed entirely.
            if requested[i] != 0.0 && applied[i] == 0.0 {
                saturated = true;
            }
        }
        // Otherwise the stick just stops working with no explanation: the offset
        // only resets when a new baseline is captured (a grip squeeze), so with
        // the deadman released an operator can sit at the cap indefinitely.
        if saturated && self.last_nudge_warn_at.is_none_or(|t| now.duration_since(t) > NUDGE_WARN_EVERY)
        {
            self.last_nudge_warn_at = Some(now);
            tracing::warn!(
                "Nudge offset saturated at the +/-{:.2}m guard; squeeze the deadman to recapture \
                 a baseline (which clears the offset) before trimming further",
                self.nudge_limit_m
            );
        }
        applied
    }

    /// Current persistent nudge offset (robot base frame, metres).
    pub fn nudge_offset(&self) -> [f64; 3] {
        self.nudge_offset
    }

    /// The captured yaw-only operator frame as an xyzw quaternion, if teleop is
    /// engaged. Published as telemetry so the headset can draw an axis gizmo
    /// showing the TRUE control directions instead of re-deriving the rule
    /// client-side (where a config change to `mirror`/`scale` would silently
    /// make the overlay lie).
    pub fn reference_frame_quat_xyzw(&self) -> Option<[f64; 4]> {
        self.reference_frame_rotation.as_ref().map(|f| {
            let q = f.quaternion();
            [q.i, q.j, q.k, q.w]
        })
    }

    /// Position scale applied to hand deltas.
    pub fn scale(&self) -> f64 {
        self.scale
    }

    /// Whether the lateral axis is mirrored.
    pub fn mirror(&self) -> bool {
        self.mirror
    }

    /// Last end-effector target produced by the mapper, if any.
    pub fn last_target_ee(&self) -> Option<&Pose6D> {
        self.last_target_ee.as_ref()
    }

    /// Move the last target by `delta` (robot frame). Used when the deadman is
    /// released: there is no baseline or hand delta, but the stick may still be
    /// trimming the pose.
    pub fn nudge_last_target(&mut self, delta: [f64; 3]) -> Option<Pose6D> {
        let mut target = self.last_target_ee.clone()?;
        target.position[0] += delta[0];
        target.position[1] += delta[1];
        target.position[2] += delta[2];
        self.last_target_ee = Some(target.clone());
        Some(target)
    }

    /// Capture the operator-local reference frame for relative teleop.
    ///
    /// Only yaw is used: head pitch/roll should not tilt the robot control
    /// plane. If the provided pose is degenerate, identity is used.
    pub fn set_reference_frame(&mut self, pose: &Pose6D) {
        let frame = yaw_frame_from_pose(pose);
        self.reference_frame_rotation = Some(frame);
        tracing::info!(
            "Operator alignment frame captured from pose rotation={:?}",
            pose.rotation
        );
    }

    /// Map an end-effector controller pose to joint angles.
    ///
    /// In IK mode, concrete IK is implemented by the driver/bridge, not Rust.
    /// Call [`Self::map_end_effector_target`] for that path.
    pub fn map(&self, pose: &Pose6D) -> JointAngles {
        match self.mode {
            MappingMode::Direct => self.map_direct(pose),
            MappingMode::Ik => self.map_ik_driver_side_stub(),
            MappingMode::Retarget => self.map_retarget_stub(),
        }
    }

    /// Convert a controller pose into a robot base-frame end-effector target.
    ///
    /// Axis convention after the positional delta is expressed in the captured
    /// operator frame:
    /// - operator forward (-Z) -> robot +X
    /// - operator right/left (+X) -> robot +/-Y, controlled by `mirror`
    /// - operator up (+Y) -> robot +Z
    ///
    /// Rotation is relative too, but it is interpreted in the same captured
    /// operator frame before being applied in robot base coordinates.
    pub fn map_end_effector_target(&mut self, pose: &Pose6D) -> Pose6D {
        let base = self
            .base_end_effector_pose
            .clone()
            .unwrap_or_else(|| pose.clone());
        let delta = self.controller_delta_robot(pose);
        let nudge = self.nudge_offset;
        let target = Pose6D {
            position: [
                base.position[0] + delta[0] + nudge[0],
                base.position[1] + delta[1] + nudge[1],
                base.position[2] + delta[2] + nudge[2],
            ],
            rotation: self.relative_target_rotation(pose, &base),
        };
        self.last_target_ee = Some(target.clone());
        target
    }

    /// Direct mapping: controller position deltas mapped to joint angle deltas.
    ///
    /// - delta_x -> joint 0 (base rotation)
    /// - delta_y -> joint 1 (shoulder)
    /// - delta_z -> joint 2 (elbow)
    /// - Controller rotation (roll/pitch/yaw) -> joints 3, 4, 5 (wrist)
    fn map_direct(&self, pose: &Pose6D) -> JointAngles {
        let mut angles = self.base_angles.clone();

        let reference = self.reference_pose.as_ref().unwrap_or(pose);
        let current = pose.position;

        // Position deltas (meters) -> angle deltas (degrees).
        // Using a simple linear mapping: 0.1m movement = 30 degrees.
        let deg_per_meter = 300.0 * self.scale;
        let dx = current[0] - reference.position[0];
        let dy = current[1] - reference.position[1];
        let dz = current[2] - reference.position[2];

        let mirror_sign = if self.mirror { -1.0 } else { 1.0 };

        if self.num_joints > 0 {
            angles[0] += dx * deg_per_meter * mirror_sign;
        }
        if self.num_joints > 1 {
            angles[1] += dy * deg_per_meter;
        }
        if self.num_joints > 2 {
            angles[2] += dz * deg_per_meter * mirror_sign;
        }

        let reference_quat = quat_from_xyzw(reference.rotation);
        let current_quat = quat_from_xyzw(pose.rotation);
        let relative_quat = reference_quat.inverse() * current_quat;
        let euler = relative_quat.euler_angles();

        if self.num_joints > 3 {
            angles[3] += euler.0.to_degrees() * self.scale;
        }
        if self.num_joints > 4 {
            angles[4] += euler.1.to_degrees() * self.scale;
        }
        if self.num_joints > 5 {
            angles[5] += euler.2.to_degrees() * self.scale;
        }

        JointAngles { angles }
    }

    fn map_ik_driver_side_stub(&self) -> JointAngles {
        tracing::warn!("IK mapping is driver-side; holding base joint angles");
        JointAngles {
            angles: self.base_angles.clone(),
        }
    }

    fn map_retarget_stub(&self) -> JointAngles {
        tracing::warn!("Retarget mapping not yet implemented, using home position");
        JointAngles {
            angles: self.base_angles.clone(),
        }
    }

    fn controller_delta_robot(&self, pose: &Pose6D) -> [f64; 3] {
        let reference = self.reference_pose.as_ref().unwrap_or(pose);
        let delta_world = Vector3::new(
            pose.position[0] - reference.position[0],
            pose.position[1] - reference.position[1],
            pose.position[2] - reference.position[2],
        );
        let frame = self.reference_frame_rotation();
        let delta_operator = frame.inverse_transform_vector(&delta_world);
        let lateral_sign = if self.mirror { -1.0 } else { 1.0 };
        [
            -delta_operator.z * self.scale,
            lateral_sign * delta_operator.x * self.scale,
            delta_operator.y * self.scale,
        ]
    }

    fn relative_target_rotation(&self, pose: &Pose6D, base: &Pose6D) -> [f64; 4] {
        let reference = self.reference_pose.as_ref().unwrap_or(pose);
        let reference_quat = quat_from_xyzw(reference.rotation);
        let current_quat = quat_from_xyzw(pose.rotation);
        let base_quat = quat_from_xyzw(base.rotation);
        let frame = self.reference_frame_rotation();
        let operator_to_robot = operator_to_robot_rotation();

        let delta_world = current_quat * reference_quat.inverse();
        let delta_operator = frame.inverse() * delta_world * frame;
        let delta_robot = operator_to_robot * delta_operator * operator_to_robot.inverse();
        let target = delta_robot * base_quat;
        let q = target.quaternion();
        [q.i, q.j, q.k, q.w]
    }

    fn reference_frame_rotation(&self) -> UnitQuaternion<f64> {
        self.reference_frame_rotation
            .as_ref()
            .cloned()
            .unwrap_or_else(UnitQuaternion::identity)
    }
}

fn quat_from_xyzw(rot: [f64; 4]) -> UnitQuaternion<f64> {
    UnitQuaternion::new_normalize(nalgebra::Quaternion::new(rot[3], rot[0], rot[1], rot[2]))
}

fn yaw_frame_from_pose(pose: &Pose6D) -> UnitQuaternion<f64> {
    let q = quat_from_xyzw(pose.rotation);
    let forward = q.transform_vector(&Vector3::new(0.0, 0.0, -1.0));
    let flat_forward = Vector3::new(forward.x, 0.0, forward.z);
    let Some(flat_forward) = flat_forward.try_normalize(1e-9) else {
        return UnitQuaternion::identity();
    };

    let up = Vector3::y_axis().into_inner();
    let right = flat_forward
        .cross(&up)
        .try_normalize(1e-9)
        .unwrap_or_else(|| Vector3::x_axis().into_inner());
    let back = -flat_forward;
    let matrix = Matrix3::from_columns(&[right, up, back]);
    UnitQuaternion::from_rotation_matrix(&Rotation3::from_matrix_unchecked(matrix))
}

fn operator_to_robot_rotation() -> UnitQuaternion<f64> {
    // Operator local axes are Godot/OpenXR style: +X right, +Y up, -Z forward.
    // Robot base axes for the SO-101 sim are: +X forward, +Z up, -Y right.
    let matrix = Matrix3::from_columns(&[
        Vector3::new(0.0, -1.0, 0.0),
        Vector3::new(0.0, 0.0, 1.0),
        Vector3::new(-1.0, 0.0, 0.0),
    ]);
    UnitQuaternion::from_rotation_matrix(&Rotation3::from_matrix_unchecked(matrix))
}

/// Extract Euler angles from a quaternion (utility for debugging).
#[allow(dead_code)]
pub fn quaternion_to_euler(qx: f64, qy: f64, qz: f64, qw: f64) -> (f64, f64, f64) {
    let q = UnitQuaternion::new_normalize(nalgebra::Quaternion::new(qw, qx, qy, qz));
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

    fn ik_mapper(mirror: bool, scale: f64) -> PoseMapper {
        PoseMapper::new(
            &PoseMappingConfig {
                mode: "ik".to_string(),
                scale,
                mirror,
            },
            5,
        )
    }

    fn pose(position: [f64; 3], rotation: [f64; 4]) -> Pose6D {
        Pose6D { position, rotation }
    }

    /// Drive the nudge integrator for a real elapsed interval. `integrate_nudge`
    /// derives dt from wall time, and the first call only primes the clock.
    fn nudge_for(m: &mut PoseMapper, x: f64, y: f64, vertical: bool, ms: u64) -> [f64; 3] {
        m.integrate_nudge(x, y, vertical);
        std::thread::sleep(std::time::Duration::from_millis(ms));
        m.integrate_nudge(x, y, vertical)
    }

    #[test]
    fn nudge_horizontal_maps_stick_to_robot_forward_and_lateral() {
        let mut m = ik_mapper(true, 0.5);
        // Stick forward only -> robot +X (forward), no lateral, no height.
        let d = nudge_for(&mut m, 0.0, 1.0, false, 50);
        assert!(d[0] > 0.0, "stick forward must move robot +X, got {d:?}");
        assert_eq!(d[1], 0.0);
        assert_eq!(d[2], 0.0, "horizontal nudge must never change height");
    }

    #[test]
    fn nudge_lateral_follows_the_hand_mirror_convention() {
        // mirror=true is the shipped config and means "same side": hand/stick
        // right moves the arm right, i.e. robot -Y.
        let mut m = ik_mapper(true, 0.5);
        let d = nudge_for(&mut m, 1.0, 0.0, false, 50);
        assert!(d[1] < 0.0, "stick right must move robot -Y with mirror, got {d:?}");

        let mut m2 = ik_mapper(false, 0.5);
        let d2 = nudge_for(&mut m2, 1.0, 0.0, false, 50);
        assert!(d2[1] > 0.0, "mirror=false flips lateral, got {d2:?}");
    }

    #[test]
    fn nudge_click_switches_stick_to_height_only() {
        let mut m = ik_mapper(true, 0.5);
        let d = nudge_for(&mut m, 1.0, 1.0, true, 50);
        assert_eq!(d[0], 0.0, "vertical mode must not move forward");
        assert_eq!(d[1], 0.0, "vertical mode must not move laterally");
        assert!(d[2] > 0.0, "vertical mode maps stick Y to height, got {d:?}");
    }

    #[test]
    fn nudge_rate_is_about_30mm_per_second() {
        let mut m = ik_mapper(true, 0.5);
        let d = nudge_for(&mut m, 0.0, 1.0, false, 100);
        // 30mm/s for ~0.1s, with generous slack for scheduler jitter.
        assert!(
            d[0] > 0.001 && d[0] < 0.006,
            "expected ~3mm in 100ms at 30mm/s, got {}m",
            d[0]
        );
    }

    #[test]
    fn new_baseline_zeroes_the_nudge_so_it_is_not_applied_twice() {
        // The baseline is captured at the arm's CURRENT pose, which already
        // includes every nudge so far. Carrying the offset across a re-squeeze
        // would double-count it and make the arm jump on every re-grip.
        let mut m = ik_mapper(true, 0.5);
        nudge_for(&mut m, 0.0, 1.0, false, 50);
        assert!(m.nudge_offset()[0] > 0.0, "precondition: offset accumulated");

        m.set_base_end_effector_pose(&pose([0.25, 0.0, 0.14], [0.0, 0.0, 0.0, 1.0]));
        assert_eq!(
            m.nudge_offset(),
            [0.0; 3],
            "capturing a baseline must clear the offset it already contains"
        );
    }

    #[test]
    fn nudge_offset_is_clamped_so_a_stuck_stick_cannot_run_away() {
        let mut m = ik_mapper(true, 0.5);
        m.integrate_nudge(0.0, 1.0, false);
        // Far more travel than the limit allows.
        for _ in 0..400 {
            std::thread::sleep(std::time::Duration::from_millis(1));
            m.integrate_nudge(0.0, 1.0, false);
        }
        assert!(
            m.nudge_offset()[0] <= DEFAULT_NUDGE_LIMIT_M + 1e-9,
            "offset {} exceeded the {}m guard",
            m.nudge_offset()[0],
            DEFAULT_NUDGE_LIMIT_M
        );
    }

    #[test]
    fn nudge_last_target_moves_the_pose_when_the_deadman_is_released() {
        let mut m = ik_mapper(true, 0.5);
        // No baseline/hand input: seed a target the way a prior enabled frame would.
        m.set_base_end_effector_pose(&pose([0.25, 0.0, 0.14], [0.0, 0.0, 0.0, 1.0]));
        let seeded = m.map_end_effector_target(&pose([0.0, 1.0, 0.0], [0.0, 0.0, 0.0, 1.0]));

        let moved = m
            .nudge_last_target([0.01, 0.0, 0.0])
            .expect("a target exists to nudge");
        assert!((moved.position[0] - (seeded.position[0] + 0.01)).abs() < 1e-9);
        // And it is now the tracked target, so successive nudges accumulate.
        let moved2 = m.nudge_last_target([0.01, 0.0, 0.0]).unwrap();
        assert!((moved2.position[0] - (seeded.position[0] + 0.02)).abs() < 1e-9);
    }

    fn quat_xyzw(q: UnitQuaternion<f64>) -> [f64; 4] {
        let q = q.quaternion();
        [q.i, q.j, q.k, q.w]
    }

    const IDENTITY_QUAT: [f64; 4] = [0.0, 0.0, 0.0, 1.0];

    #[test]
    fn x_delta_drives_joint0_with_mirror_sign() {
        let mut m = mapper(true, 1.0);
        m.set_reference(&pose([0.0, 0.0, 0.0], IDENTITY_QUAT));

        let out = m.map(&pose([0.1, 0.0, 0.0], IDENTITY_QUAT));
        assert!(
            (out.angles[0] - (-30.0)).abs() < 1e-9,
            "joint0 = {} (expected -30)",
            out.angles[0]
        );

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
        assert!(out.angles[3].abs() < 1e-9, "wrist roll = {}", out.angles[3]);
        assert!(
            out.angles[4].abs() < 1e-9,
            "wrist pitch = {}",
            out.angles[4]
        );
        assert!(out.angles[5].abs() < 1e-9, "wrist yaw = {}", out.angles[5]);
    }

    #[test]
    fn y_and_z_deltas_drive_shoulder_and_elbow() {
        let mut m = mapper(true, 1.0);
        m.set_reference(&pose([0.0, 0.0, 0.0], IDENTITY_QUAT));
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
        let m = mapper(true, 1.0);
        let out = m.map(&pose([0.5, 0.5, 0.5], IDENTITY_QUAT));
        assert!(out.angles[0].abs() < 1e-9);
        assert!(out.angles[1].abs() < 1e-9);
        assert!(out.angles[2].abs() < 1e-9);
    }

    #[test]
    fn base_angles_are_preserved_at_reference_pose() {
        let mut m = mapper(false, 1.0);
        m.set_base_angles(&[10.0, 20.0, 30.0, 1.0, 2.0, 3.0]);
        m.set_reference(&pose([0.1, 0.2, 0.3], IDENTITY_QUAT));

        let out = m.map(&pose([0.1, 0.2, 0.3], IDENTITY_QUAT));
        assert_eq!(out.angles, vec![10.0, 20.0, 30.0, 1.0, 2.0, 3.0]);
    }

    #[test]
    fn rotation_is_relative_to_reference_pose() {
        let mut m = mapper(false, 1.0);
        let q_ref = UnitQuaternion::from_euler_angles(0.5, 0.0, 0.0);
        let q_current = UnitQuaternion::from_euler_angles(0.75, 0.0, 0.0);

        m.set_reference(&pose([0.0, 0.0, 0.0], quat_xyzw(q_ref)));
        let out = m.map(&pose([0.0, 0.0, 0.0], quat_xyzw(q_current)));

        assert!((out.angles[3] - 0.25_f64.to_degrees()).abs() < 1e-9);
        assert!(out.angles[4].abs() < 1e-9);
        assert!(out.angles[5].abs() < 1e-9);
    }

    #[test]
    fn unknown_mapping_mode_defaults_to_ik() {
        let m = PoseMapper::new(
            &PoseMappingConfig {
                mode: String::new(),
                scale: 1.0,
                mirror: false,
            },
            5,
        );
        assert!(matches!(m.mode, MappingMode::Ik));
    }

    #[test]
    fn ik_map_is_driver_side_stub_holding_base_angles() {
        let mut m = ik_mapper(false, 1.0);
        let base = [0.0, -68.0, 68.0, 0.0, 0.0];
        m.set_base_angles(&base);
        let out = m.map(&pose([0.1, 0.2, 0.3], IDENTITY_QUAT));
        assert_eq!(out.angles, base);
    }

    #[test]
    fn end_effector_target_holds_base_pose_at_reference() {
        let mut m = ik_mapper(false, 1.0);
        let controller_ref = pose([0.1, 0.2, 0.3], IDENTITY_QUAT);
        let base = pose([0.4, -0.2, 0.25], [0.0, 0.0, 0.0, 1.0]);
        m.set_reference(&controller_ref);
        m.set_base_end_effector_pose(&base);

        let target = m.map_end_effector_target(&controller_ref);
        assert_eq!(target.position, base.position);
        assert_eq!(target.rotation, base.rotation);
    }

    #[test]
    fn end_effector_target_maps_controller_delta_to_robot_frame() {
        let mut m = ik_mapper(true, 0.5);
        m.set_reference(&pose([0.0, 0.0, 0.0], IDENTITY_QUAT));
        m.set_base_end_effector_pose(&pose([1.0, 2.0, 3.0], IDENTITY_QUAT));

        let target = m.map_end_effector_target(&pose([0.1, 0.2, -0.3], IDENTITY_QUAT));
        assert!((target.position[0] - 1.15).abs() < 1e-9);
        assert!((target.position[1] - 1.95).abs() < 1e-9);
        assert!((target.position[2] - 3.10).abs() < 1e-9);
    }

    #[test]
    fn end_effector_target_uses_operator_frame_for_position() {
        let mut m = ik_mapper(true, 1.0);
        let operator_yaw_left =
            UnitQuaternion::from_axis_angle(&Vector3::y_axis(), std::f64::consts::FRAC_PI_2);
        m.set_reference(&pose([0.0, 0.0, 0.0], IDENTITY_QUAT));
        m.set_reference_frame(&pose([0.0, 0.0, 0.0], quat_xyzw(operator_yaw_left)));
        m.set_base_end_effector_pose(&pose([1.0, 2.0, 3.0], IDENTITY_QUAT));

        // With the operator facing world -X, world -X motion is "forward" and
        // should therefore become robot +X.
        let target = m.map_end_effector_target(&pose([-0.2, 0.0, 0.0], IDENTITY_QUAT));
        assert!((target.position[0] - 1.2).abs() < 1e-9);
        assert!((target.position[1] - 2.0).abs() < 1e-9);
        assert!((target.position[2] - 3.0).abs() < 1e-9);
    }

    /// The operator->robot axis convention is encoded **twice** in this file,
    /// in two independent forms:
    ///
    /// * positions: a hand-written index shuffle in `controller_delta_robot`
    ///   (`-z_op, ±x_op, y_op`);
    /// * rotations: the `operator_to_robot_rotation()` basis matrix.
    ///
    /// Nothing else forces them to agree, so changing one and not the other
    /// would silently split translation from orientation. This pins them
    /// together through the public API — if you edit one path, this fails.
    ///
    /// `mirror = true` is the case where the two agree exactly; `mirror =
    /// false` deliberately flips the lateral axis relative to the basis (see
    /// `mirror_flips_only_the_lateral_axis` below).
    #[test]
    fn position_axis_map_agrees_with_the_rotation_basis() {
        let basis = operator_to_robot_rotation();

        for axis in [
            [1.0, 0.0, 0.0], // operator right
            [0.0, 1.0, 0.0], // operator up
            [0.0, 0.0, 1.0], // operator backward
        ] {
            let mut m = ik_mapper(true, 1.0);
            // Identity operator frame + zero base, so the mapped target *is*
            // the retargeted delta.
            m.set_reference(&pose([0.0, 0.0, 0.0], IDENTITY_QUAT));
            m.set_reference_frame(&pose([0.0, 0.0, 0.0], IDENTITY_QUAT));
            m.set_base_end_effector_pose(&pose([0.0, 0.0, 0.0], IDENTITY_QUAT));

            let target = m.map_end_effector_target(&pose(axis, IDENTITY_QUAT));
            let expected = basis * Vector3::new(axis[0], axis[1], axis[2]);

            for i in 0..3 {
                assert!(
                    (target.position[i] - expected[i]).abs() < 1e-9,
                    "operator axis {axis:?}: position path gave {:?}, rotation basis gives {:?}",
                    target.position,
                    expected
                );
            }
        }
    }

    /// Guards the one intentional divergence from the basis matrix: `mirror`
    /// negates the lateral (robot Y) axis and must leave forward/up alone.
    #[test]
    fn mirror_flips_only_the_lateral_axis() {
        let mut mirrored = ik_mapper(true, 1.0);
        let mut plain = ik_mapper(false, 1.0);
        for m in [&mut mirrored, &mut plain] {
            m.set_reference(&pose([0.0, 0.0, 0.0], IDENTITY_QUAT));
            m.set_reference_frame(&pose([0.0, 0.0, 0.0], IDENTITY_QUAT));
            m.set_base_end_effector_pose(&pose([0.0, 0.0, 0.0], IDENTITY_QUAT));
        }

        let probe = pose([0.3, 0.5, 0.7], IDENTITY_QUAT);
        let a = mirrored.map_end_effector_target(&probe);
        let b = plain.map_end_effector_target(&probe);

        assert!(
            (a.position[0] - b.position[0]).abs() < 1e-9,
            "forward must not depend on mirror"
        );
        assert!(
            (a.position[1] + b.position[1]).abs() < 1e-9,
            "lateral must invert with mirror"
        );
        assert!(
            (a.position[2] - b.position[2]).abs() < 1e-9,
            "up must not depend on mirror"
        );
    }

    #[test]
    fn end_effector_target_applies_relative_controller_rotation() {
        let mut m = ik_mapper(false, 1.0);
        let q_ref = UnitQuaternion::from_euler_angles(0.0, 0.0, 0.1);
        let q_current = UnitQuaternion::from_euler_angles(0.0, 0.0, 0.4);
        let q_base = UnitQuaternion::from_euler_angles(0.0, 0.0, 1.0);
        let base = pose([0.0, 0.0, 0.0], quat_xyzw(q_base));
        m.set_reference(&pose([0.0, 0.0, 0.0], quat_xyzw(q_ref)));
        m.set_base_end_effector_pose(&base);

        let target = m.map_end_effector_target(&pose([0.0, 0.0, 0.0], quat_xyzw(q_current)));
        let delta_world = q_current * q_ref.inverse();
        let axis_map = operator_to_robot_rotation();
        let expected = (axis_map * delta_world * axis_map.inverse()) * q_base;
        let actual = quat_from_xyzw(target.rotation);
        assert!(expected.angle_to(&actual) < 1e-9);
    }

    #[test]
    fn end_effector_target_uses_operator_frame_for_rotation() {
        let mut m = ik_mapper(true, 1.0);
        let operator_yaw_left =
            UnitQuaternion::from_axis_angle(&Vector3::y_axis(), std::f64::consts::FRAC_PI_2);
        let turn = 0.25;
        let rotate_about_operator_forward_in_world =
            UnitQuaternion::from_axis_angle(&Vector3::x_axis(), -turn);
        let base = pose([0.0, 0.0, 0.0], IDENTITY_QUAT);
        m.set_reference(&pose([0.0, 0.0, 0.0], IDENTITY_QUAT));
        m.set_reference_frame(&pose([0.0, 0.0, 0.0], quat_xyzw(operator_yaw_left)));
        m.set_base_end_effector_pose(&base);

        let target = m.map_end_effector_target(&pose(
            [0.0, 0.0, 0.0],
            quat_xyzw(rotate_about_operator_forward_in_world),
        ));

        let expected = UnitQuaternion::from_axis_angle(&Vector3::x_axis(), turn);
        let actual = quat_from_xyzw(target.rotation);
        assert!(expected.angle_to(&actual) < 1e-9);
    }
}
