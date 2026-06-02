//! Joint-space safety validation for arm commands.
//!
//! Ported faithfully from `robot/src/control/safety.rs`. Every joint command
//! passes through these checks before reaching the driver. This is the
//! robot-side, joint-space gate — distinct from the bridge-side input
//! sanitization (`xr_bridge::safety::DeviceSafety`), which works in
//! device-control-space against the descriptor.

use crate::config::SafetyConfig;
use crate::control::JointAngles;

/// Result of a safety validation check.
#[derive(Debug, Clone)]
pub enum SafetyResult {
    /// All joints within limits — command can proceed as-is.
    Ok(JointAngles),
    /// Some joints were outside limits and have been clamped.
    Clamped(JointAngles),
    /// Command is rejected entirely (e.g. velocity too high).
    Rejected(String),
}

/// Joint-space safety limits validator.
#[derive(Debug, Clone)]
pub struct Safety {
    /// Per-joint `[min_deg, max_deg]` limits.
    joint_limits: Vec<[f64; 2]>,
    /// Maximum allowed angular velocity (deg/s).
    max_velocity: f64,
    /// Maximum allowed angular acceleration (deg/s^2).
    #[allow(dead_code)]
    max_acceleration: f64,
    /// Previous joint angles for velocity checking.
    prev_angles: Option<Vec<f64>>,
    /// Timestamp of previous command (for velocity calculation).
    prev_time: Option<std::time::Instant>,
}

impl Safety {
    /// Create a `Safety` validator from configuration.
    pub fn from_config(config: &SafetyConfig) -> Self {
        Self {
            joint_limits: config.joint_limits_deg.clone(),
            max_velocity: config.max_velocity_deg_s,
            max_acceleration: config.max_acceleration_deg_s2,
            prev_angles: None,
            prev_time: None,
        }
    }

    /// Validate joint angles against safety limits.
    ///
    /// Three layers, in order:
    ///   1. **Sanity** — reject `NaN` / `inf`.
    ///   2. **Position clamp** — per-joint `[min, max]` from config.
    ///   3. **Slew-rate clamp** — clamp the commanded Δangle so the implied
    ///      velocity is at most `max_velocity_deg_s` (clamps, never rejects —
    ///      a fast hand motion should slow the arm, not crash the session).
    pub fn validate(&mut self, joints: &JointAngles) -> SafetyResult {
        let now = std::time::Instant::now();
        let mut clamped = false;
        let mut result_angles = joints.angles.clone();

        // --- 1. Sanity: NaN/inf are programmer / network errors. Reject. ---
        for (i, angle) in result_angles.iter().enumerate() {
            if !angle.is_finite() {
                return SafetyResult::Rejected(format!(
                    "joint {i} angle is not finite ({angle})"
                ));
            }
        }

        // --- 2. Position limits ---
        for (i, angle) in result_angles.iter_mut().enumerate() {
            if let Some(limits) = self.joint_limits.get(i) {
                if *angle < limits[0] {
                    *angle = limits[0];
                    clamped = true;
                    tracing::warn!("Joint {i} clamped to min {}", limits[0]);
                } else if *angle > limits[1] {
                    *angle = limits[1];
                    clamped = true;
                    tracing::warn!("Joint {i} clamped to max {}", limits[1]);
                }
            }
        }

        // --- 3. Slew-rate clamp ---
        if let (Some(prev), Some(prev_t)) = (&self.prev_angles, &self.prev_time) {
            let dt = now.duration_since(*prev_t).as_secs_f64();
            if dt > 0.0 && self.max_velocity > 0.0 {
                let max_step = self.max_velocity * dt;
                for (i, (curr, prev_val)) in
                    result_angles.iter_mut().zip(prev.iter()).enumerate()
                {
                    let delta = *curr - *prev_val;
                    if delta.abs() > max_step {
                        let clamped_delta = max_step.copysign(delta);
                        let new_val = prev_val + clamped_delta;
                        tracing::warn!(
                            "Joint {i} slew-rate limited: requested Δ={:.2}° (v={:.1}°/s), \
                             clamped to Δ={:.2}° (v≤{:.1}°/s)",
                            delta,
                            delta.abs() / dt,
                            clamped_delta,
                            self.max_velocity,
                        );
                        *curr = new_val;
                        clamped = true;
                    }
                }
            }
        }

        // Update history for next check — store the post-clamp values so
        // the next velocity calc compares against what the arm actually
        // got commanded, not what the headset asked for.
        self.prev_angles = Some(result_angles.clone());
        self.prev_time = Some(now);

        let result = JointAngles {
            angles: result_angles,
        };

        if clamped {
            SafetyResult::Clamped(result)
        } else {
            SafetyResult::Ok(result)
        }
    }

    /// Reset internal state (e.g. after an e-stop).
    pub fn reset(&mut self) {
        self.prev_angles = None;
        self.prev_time = None;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::SafetyConfig;

    fn safety(max_vel_deg_s: f64) -> Safety {
        Safety::from_config(&SafetyConfig {
            joint_limits_deg: vec![[-180.0, 180.0]; 6],
            max_velocity_deg_s: max_vel_deg_s,
            max_acceleration_deg_s2: 1000.0,
        })
    }

    #[test]
    fn rejects_non_finite_angles() {
        let mut s = safety(60.0);
        let joints = JointAngles {
            angles: vec![0.0, f64::NAN, 0.0, 0.0, 0.0, 0.0],
        };
        match s.validate(&joints) {
            SafetyResult::Rejected(reason) => assert!(reason.contains("not finite")),
            other => panic!("expected reject, got {other:?}"),
        }
    }

    #[test]
    fn position_clamp_engages_at_limit() {
        let mut s = safety(60.0);
        let joints = JointAngles {
            angles: vec![999.0, 0.0, 0.0, 0.0, 0.0, 0.0],
        };
        match s.validate(&joints) {
            SafetyResult::Clamped(c) => assert_eq!(c.angles[0], 180.0),
            other => panic!("expected clamp, got {other:?}"),
        }
    }

    #[test]
    fn slew_rate_clamps_instead_of_rejecting() {
        // First call seeds prev_angles/prev_time; ~no clamp.
        let mut s = safety(60.0); // 60 deg/s
        let first = JointAngles {
            angles: vec![0.0; 6],
        };
        let _ = s.validate(&first);

        // Immediately ask for +100° on joint 0. Δt is sub-ms so any
        // non-zero delta exceeds the slew budget — output must be
        // clamped, never rejected.
        let second = JointAngles {
            angles: vec![100.0, 0.0, 0.0, 0.0, 0.0, 0.0],
        };
        match s.validate(&second) {
            SafetyResult::Clamped(c) => {
                assert!(c.angles[0] > 0.0 && c.angles[0] < 100.0);
            }
            other => panic!("slew should clamp, not {other:?}"),
        }
    }

    #[test]
    fn slew_within_budget_passes_as_ok() {
        // Effectively unbounded velocity: even a sub-nanosecond dt between the
        // two validate() calls leaves the slew budget (max_velocity * dt) far
        // above the 1.0° delta below, so the result must be Ok (no clamp). The
        // huge factor avoids the flakiness a smaller one would have under heavy
        // parallel test load, where dt can round to ~10 ns.
        let mut s = safety(1e18); // effectively unbounded
        let _ = s.validate(&JointAngles { angles: vec![0.0; 6] });
        let cmd = JointAngles {
            angles: vec![1.0, 0.0, 0.0, 0.0, 0.0, 0.0],
        };
        match s.validate(&cmd) {
            SafetyResult::Ok(_) => {}
            other => panic!("expected Ok, got {other:?}"),
        }
    }
}
