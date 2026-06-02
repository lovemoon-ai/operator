//! Arm control subsystem for the robot-adapter: pose→joint mapping, joint-space
//! safety, and concrete arm drivers.
//!
//! This is the robot-side half of the control chain that used to live in
//! `robot/src/control/`. It is deliberately joint-space and device-specific —
//! the bridge already sanitizes XR *input* against the device descriptor, so
//! anything here is about turning a sanitized end-effector pose into safe joint
//! commands for a concrete arm (this phase: the MuJoCo SO-101 sim).
//!
//! Naming note: the `safety` here is **joint-space** Safety (per-joint position
//! clamp + slew rate), distinct from the bridge-side input-sanitization
//! `DeviceSafety`. They never coexist in the same process.

pub mod drivers;
pub mod pose_mapping;
pub mod safety;

/// Joint angles for the arm, in **degrees** (one per joint).
///
/// Degrees is the pipeline convention (PoseMapper and joint `Safety` both speak
/// degrees); drivers convert to their own units at the boundary (the MuJoCo
/// driver converts to radians).
#[derive(Debug, Clone)]
pub struct JointAngles {
    /// One angle per joint, in degrees.
    pub angles: Vec<f64>,
}
