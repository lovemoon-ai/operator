//! Generic device-level input sanitization.
//!
//! This is the bridge's responsibility: sanitize XR input *before* it crosses
//! the boundary to the robot-adapter. It validates incoming `DeviceCommand`
//! values against the limits declared in the device's `DeviceDescriptor`:
//!   * **Clamp**: out-of-range axis values are silently pulled into the
//!     declared range; small values inside `dead_zone` are zeroed.
//!   * **Reject**: NaN/inf, non-unit quaternions, unknown control names, and
//!     button-group violations cause the entire command to be refused.
//!   * **Button semantics**: stateful handling of `toggle`, `confirm`, and
//!     `group` buttons (see [`ButtonStateTracker`]).
//!
//! Ported from `robot/src/device/safety.rs`, re-implemented against the shared
//! `teleop_protocol` types.

use std::collections::{HashMap, HashSet};
use std::time::{Duration, Instant};

use teleop_protocol::{DeviceCommand, DeviceDescriptor};

/// Result of a safety check on a `DeviceCommand`.
#[derive(Debug, Clone)]
pub enum SafetyResult {
    /// All values within limits — command may proceed as-is.
    Ok(DeviceCommand),
    /// Some axis values were outside limits and have been clamped.
    Clamped(DeviceCommand),
    /// Command is rejected entirely.
    Rejected(String),
}

/// Window during which a `confirm: true` button stays "armed" after the
/// first press. Pressing again within this window confirms; pressing after
/// the window re-arms.
pub const CONFIRM_WINDOW: Duration = Duration::from_millis(2000);

/// Maximum allowed deviation of a quaternion's norm from 1.0.
pub const QUATERNION_NORM_TOLERANCE: f64 = 1.0e-3;

/// Build the neutral command for a descriptor: every declared axis set to its
/// `default`, no buttons, no poses. The `teleop_protocol` `DeviceCommand` does
/// not carry this helper, so it lives here in the bridge.
pub fn neutral_command(desc: &DeviceDescriptor) -> DeviceCommand {
    let axes = desc
        .control_schema
        .axes
        .iter()
        .map(|a| (a.name.clone(), a.default))
        .collect();
    DeviceCommand {
        axes,
        buttons: HashMap::new(),
        poses: HashMap::new(),
        timestamp_ns: 0,
    }
}

/// Validates `DeviceCommand`s against a `DeviceDescriptor`.
///
/// Note: this struct is **stateful** — `validate` takes `&mut self` because
/// stateful button semantics (toggle / confirm) need to remember prior frames.
pub struct DeviceSafety {
    /// Snapshot of the descriptor used for validation.
    descriptor: DeviceDescriptor,
    /// Set of declared axis names (for fast unknown-name checks).
    known_axes: HashSet<String>,
    /// Set of declared button names.
    known_buttons: HashSet<String>,
    /// Set of declared pose names.
    known_poses: HashSet<String>,
    /// Stateful button tracker.
    buttons: ButtonStateTracker,
}

impl DeviceSafety {
    /// Create a new safety validator from a device descriptor.
    pub fn new(descriptor: &DeviceDescriptor) -> Self {
        let known_axes = descriptor
            .control_schema
            .axes
            .iter()
            .map(|a| a.name.clone())
            .collect();
        let known_buttons = descriptor
            .control_schema
            .buttons
            .iter()
            .map(|b| b.name.clone())
            .collect();
        let known_poses = descriptor
            .control_schema
            .poses
            .iter()
            .map(|p| p.name.clone())
            .collect();

        Self {
            buttons: ButtonStateTracker::new(descriptor),
            descriptor: descriptor.clone(),
            known_axes,
            known_buttons,
            known_poses,
        }
    }

    /// Validate a command. May reject, clamp, or accept.
    pub fn validate(&mut self, cmd: &DeviceCommand) -> SafetyResult {
        self.validate_at(cmd, Instant::now())
    }

    /// Validate with an explicit "now" — used by tests for deterministic
    /// confirm-window timing.
    pub fn validate_at(&mut self, cmd: &DeviceCommand, now: Instant) -> SafetyResult {
        // ─── 1. Hard rejections (run before any mutation) ────────────────
        if let Err(reason) = self.check_unknown_names(cmd) {
            tracing::warn!("Safety reject: {reason}");
            return SafetyResult::Rejected(reason);
        }
        if let Err(reason) = self.check_finite(cmd) {
            tracing::warn!("Safety reject: {reason}");
            return SafetyResult::Rejected(reason);
        }
        if let Err(reason) = self.check_quaternions(cmd) {
            tracing::warn!("Safety reject: {reason}");
            return SafetyResult::Rejected(reason);
        }
        if let Err(reason) = self.check_button_groups(cmd) {
            tracing::warn!("Safety reject: {reason}");
            return SafetyResult::Rejected(reason);
        }

        // ─── 2. Stateful button transformation (may reject confirm) ──────
        let mut result = cmd.clone();
        match self.buttons.transform(&mut result, now) {
            Ok(()) => {}
            Err(reason) => {
                tracing::warn!("Safety reject: {reason}");
                return SafetyResult::Rejected(reason);
            }
        }

        // ─── 3. Axis clamp + dead-zone ───────────────────────────────────
        let clamped = self.clamp_axes(&mut result);

        if clamped {
            SafetyResult::Clamped(result)
        } else {
            SafetyResult::Ok(result)
        }
    }

    /// Apply only axis clamp + dead-zone (no rejection, no button state).
    /// Used for synthetic watchdog / disconnect commands.
    pub fn clamp_only(&self, cmd: &DeviceCommand) -> DeviceCommand {
        let mut result = cmd.clone();
        let _ = self.clamp_axes(&mut result);
        result
    }

    // ────────────────────────────── helpers ──────────────────────────────

    fn check_unknown_names(&self, cmd: &DeviceCommand) -> Result<(), String> {
        for name in cmd.axes.keys() {
            if !self.known_axes.contains(name) {
                return Err(format!("unknown axis '{name}'"));
            }
        }
        for name in cmd.buttons.keys() {
            if !self.known_buttons.contains(name) {
                return Err(format!("unknown button '{name}'"));
            }
        }
        for name in cmd.poses.keys() {
            if !self.known_poses.contains(name) {
                return Err(format!("unknown pose '{name}'"));
            }
        }
        Ok(())
    }

    fn check_finite(&self, cmd: &DeviceCommand) -> Result<(), String> {
        for (name, v) in &cmd.axes {
            if !v.is_finite() {
                return Err(format!("axis '{name}' has non-finite value ({v})"));
            }
        }
        for (name, pose) in &cmd.poses {
            if pose.position.iter().any(|x| !x.is_finite()) {
                return Err(format!("pose '{name}' position contains non-finite"));
            }
            if pose.rotation.iter().any(|x| !x.is_finite()) {
                return Err(format!("pose '{name}' rotation contains non-finite"));
            }
        }
        Ok(())
    }

    fn check_quaternions(&self, cmd: &DeviceCommand) -> Result<(), String> {
        for (name, pose) in &cmd.poses {
            let [x, y, z, w] = pose.rotation;
            let norm_sq = x * x + y * y + z * z + w * w;
            let norm = norm_sq.sqrt();
            if (norm - 1.0).abs() > QUATERNION_NORM_TOLERANCE {
                return Err(format!(
                    "pose '{name}' quaternion not unit-length (||q||={norm:.4})"
                ));
            }
        }
        Ok(())
    }

    fn check_button_groups(&self, cmd: &DeviceCommand) -> Result<(), String> {
        // For each group, count how many of its members are pressed in this frame.
        let mut group_counts: HashMap<&str, u32> = HashMap::new();
        for btn_def in &self.descriptor.control_schema.buttons {
            let Some(group) = btn_def.group.as_deref() else {
                continue;
            };
            if cmd.buttons.get(&btn_def.name).copied().unwrap_or(false) {
                *group_counts.entry(group).or_insert(0) += 1;
            }
        }
        for (group, count) in group_counts {
            if count > 1 {
                return Err(format!(
                    "multiple buttons active in group '{group}' ({count})"
                ));
            }
        }
        Ok(())
    }

    fn clamp_axes(&self, cmd: &mut DeviceCommand) -> bool {
        let mut clamped = false;

        // Range + dead-zone from descriptor.control_schema.axes.
        for axis_def in &self.descriptor.control_schema.axes {
            if let Some(val) = cmd.axes.get_mut(&axis_def.name) {
                if val.abs() < axis_def.dead_zone {
                    *val = 0.0;
                }
                let (lo, hi) = axis_def.range;
                if *val < lo {
                    *val = lo;
                    clamped = true;
                } else if *val > hi {
                    *val = hi;
                    clamped = true;
                }
            }
        }

        // Per-axis safety limits override (descriptor.safety.limits).
        for (axis_name, (lo, hi)) in &self.descriptor.safety.limits {
            if let Some(val) = cmd.axes.get_mut(axis_name) {
                if *val < *lo {
                    *val = *lo;
                    clamped = true;
                } else if *val > *hi {
                    *val = *hi;
                    clamped = true;
                }
            }
        }

        clamped
    }
}

/// Stateful tracker for button semantics: `toggle`, `confirm`, and `group`.
///
/// * `toggle`: client sends raw press/release; tracker flips a latched state
///   on each rising edge and rewrites the outgoing command to the latched value.
/// * `confirm`: first press arms the button (does not pass through). Second
///   press within `CONFIRM_WINDOW` confirms (passes through). Out-of-window
///   second press re-arms.
/// * `group`: when one member of a group becomes active, others in the same
///   group are forced to `false` in the outgoing command.
struct ButtonStateTracker {
    /// Toggle buttons → latched state.
    toggle_state: HashMap<String, bool>,
    /// Toggle buttons → previous-frame raw input.
    toggle_prev_raw: HashMap<String, bool>,
    /// Confirm buttons → time the button was last "armed".
    armed_at: HashMap<String, Instant>,
    /// Confirm buttons → previous-frame raw input (rising-edge detect).
    confirm_prev_raw: HashMap<String, bool>,
    /// Snapshot of relevant button definitions.
    defs: Vec<ButtonMeta>,
}

#[derive(Clone)]
struct ButtonMeta {
    name: String,
    toggle: bool,
    confirm: bool,
    group: Option<String>,
}

impl ButtonStateTracker {
    fn new(descriptor: &DeviceDescriptor) -> Self {
        let defs: Vec<ButtonMeta> = descriptor
            .control_schema
            .buttons
            .iter()
            .map(|b| ButtonMeta {
                name: b.name.clone(),
                toggle: b.toggle,
                confirm: b.confirm,
                group: b.group.clone(),
            })
            .collect();
        Self {
            toggle_state: HashMap::new(),
            toggle_prev_raw: HashMap::new(),
            armed_at: HashMap::new(),
            confirm_prev_raw: HashMap::new(),
            defs,
        }
    }

    /// Mutate `cmd.buttons` in place, applying button semantics.
    /// Returns `Err` if the command must be rejected.
    fn transform(&mut self, cmd: &mut DeviceCommand, now: Instant) -> Result<(), String> {
        // Snapshot raw inputs for declared buttons (default false if absent).
        let mut raw: HashMap<String, bool> = HashMap::with_capacity(self.defs.len());
        for def in &self.defs {
            let v = cmd.buttons.get(&def.name).copied().unwrap_or(false);
            raw.insert(def.name.clone(), v);
        }

        // Compute output state per declared button.
        let mut out: HashMap<String, bool> = HashMap::with_capacity(self.defs.len());
        for def in &self.defs {
            let raw_v = *raw.get(&def.name).unwrap_or(&false);
            let prev_toggle_raw = *self.toggle_prev_raw.get(&def.name).unwrap_or(&false);
            let prev_confirm_raw = *self.confirm_prev_raw.get(&def.name).unwrap_or(&false);

            let resolved = match (def.toggle, def.confirm) {
                // Pure toggle: flip latched state on rising edge.
                (true, false) => {
                    let mut latched = *self.toggle_state.get(&def.name).unwrap_or(&false);
                    if raw_v && !prev_toggle_raw {
                        latched = !latched;
                        self.toggle_state.insert(def.name.clone(), latched);
                    }
                    latched
                }
                // Pure confirm: rising-edge arms; second rising-edge in
                // window confirms. Output is `true` only on confirmed press.
                (false, true) => {
                    let mut confirmed = false;
                    if raw_v && !prev_confirm_raw {
                        // Rising edge.
                        match self.armed_at.get(&def.name) {
                            Some(t) if now.duration_since(*t) <= CONFIRM_WINDOW => {
                                // Second press within window: confirmed.
                                confirmed = true;
                                self.armed_at.remove(&def.name);
                                tracing::info!("Button '{}': confirmed", def.name);
                            }
                            _ => {
                                // Arm (or re-arm).
                                self.armed_at.insert(def.name.clone(), now);
                                tracing::info!("Button '{}': armed, waiting for confirm", def.name);
                            }
                        }
                    }
                    confirmed
                }
                // Toggle + confirm: confirm gates each rising edge before
                // toggling the latched state.
                (true, true) => {
                    let mut latched = *self.toggle_state.get(&def.name).unwrap_or(&false);
                    if raw_v && !prev_confirm_raw {
                        match self.armed_at.get(&def.name) {
                            Some(t) if now.duration_since(*t) <= CONFIRM_WINDOW => {
                                latched = !latched;
                                self.toggle_state.insert(def.name.clone(), latched);
                                self.armed_at.remove(&def.name);
                            }
                            _ => {
                                self.armed_at.insert(def.name.clone(), now);
                            }
                        }
                    }
                    latched
                }
                // Plain momentary button: pass through.
                (false, false) => raw_v,
            };

            out.insert(def.name.clone(), resolved);

            // Update edge-detection memory.
            self.toggle_prev_raw.insert(def.name.clone(), raw_v);
            self.confirm_prev_raw.insert(def.name.clone(), raw_v);
        }

        // Group resolution: if any member is active, others in same group are
        // forced false in the *output* (we already rejected truly conflicting
        // raw inputs in `check_button_groups`).
        let mut active_in_group: HashMap<String, String> = HashMap::new();
        for def in &self.defs {
            let Some(group) = def.group.as_ref() else {
                continue;
            };
            if *out.get(&def.name).unwrap_or(&false) {
                if let Some(other) = active_in_group.get(group) {
                    if other != &def.name {
                        out.insert(other.clone(), false);
                    }
                }
                active_in_group.insert(group.clone(), def.name.clone());
            }
        }

        // Write back.
        cmd.buttons = out;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use teleop_protocol::{
        AxisDef, ButtonDef, ControlSchema, DeviceInfo, DeviceSafetyConfig, Pose6D, PoseDef,
        TelemetrySchema,
    };

    fn axis(name: &str, range: (f64, f64), dead_zone: f64) -> AxisDef {
        AxisDef {
            name: name.into(),
            display: String::new(),
            range,
            default: 0.0,
            dead_zone,
        }
    }

    fn button(name: &str, toggle: bool, confirm: bool, group: Option<&str>) -> ButtonDef {
        ButtonDef {
            name: name.into(),
            display: String::new(),
            toggle,
            confirm,
            group: group.map(|s| s.into()),
        }
    }

    fn pose(name: &str) -> PoseDef {
        PoseDef {
            name: name.into(),
            display: String::new(),
            dof: 6,
            frame: String::new(),
        }
    }

    fn descriptor_with(
        axes: Vec<AxisDef>,
        buttons: Vec<ButtonDef>,
        poses: Vec<PoseDef>,
    ) -> DeviceDescriptor {
        DeviceDescriptor {
            device: DeviceInfo {
                device_type: "test".into(),
                name: "Test".into(),
                icon: String::new(),
                model_url: String::new(),
            },
            control_schema: ControlSchema {
                axes,
                buttons,
                poses,
            },
            input_mapping: vec![],
            telemetry_schema: TelemetrySchema::default(),
            video_feeds: vec![],
            safety: DeviceSafetyConfig {
                disconnect_action: "stop".into(),
                command_timeout_ms: 500,
                limits: HashMap::new(),
            },
        }
    }

    fn simple_descriptor() -> DeviceDescriptor {
        descriptor_with(vec![axis("throttle", (-1.0, 1.0), 0.05)], vec![], vec![])
    }

    #[test]
    fn dead_zone_zeroes_small_values() {
        let mut safety = DeviceSafety::new(&simple_descriptor());
        let mut cmd = DeviceCommand::default();
        cmd.axes.insert("throttle".into(), 0.02);

        match safety.validate(&cmd) {
            SafetyResult::Ok(c) | SafetyResult::Clamped(c) => {
                assert_eq!(*c.axes.get("throttle").unwrap(), 0.0);
            }
            SafetyResult::Rejected(r) => panic!("unexpected reject: {r}"),
        }
    }

    #[test]
    fn clamps_out_of_range() {
        let mut safety = DeviceSafety::new(&simple_descriptor());
        let mut cmd = DeviceCommand::default();
        cmd.axes.insert("throttle".into(), 5.0);

        match safety.validate(&cmd) {
            SafetyResult::Clamped(c) => {
                assert_eq!(*c.axes.get("throttle").unwrap(), 1.0);
            }
            other => panic!("expected Clamped, got {other:?}"),
        }
    }

    #[test]
    fn rejects_nan_axis() {
        let mut safety = DeviceSafety::new(&simple_descriptor());
        let mut cmd = DeviceCommand::default();
        cmd.axes.insert("throttle".into(), f64::NAN);

        match safety.validate(&cmd) {
            SafetyResult::Rejected(r) => assert!(r.contains("non-finite"), "got: {r}"),
            other => panic!("expected Rejected, got {other:?}"),
        }
    }

    #[test]
    fn rejects_inf_axis() {
        let mut safety = DeviceSafety::new(&simple_descriptor());
        let mut cmd = DeviceCommand::default();
        cmd.axes.insert("throttle".into(), f64::INFINITY);

        match safety.validate(&cmd) {
            SafetyResult::Rejected(_) => {}
            other => panic!("expected Rejected, got {other:?}"),
        }
    }

    #[test]
    fn rejects_unknown_axis_name() {
        let mut safety = DeviceSafety::new(&simple_descriptor());
        let mut cmd = DeviceCommand::default();
        cmd.axes.insert("nonexistent".into(), 0.5);

        match safety.validate(&cmd) {
            SafetyResult::Rejected(r) => assert!(r.contains("unknown axis"), "got: {r}"),
            other => panic!("expected Rejected, got {other:?}"),
        }
    }

    #[test]
    fn rejects_unknown_button_name() {
        let mut safety = DeviceSafety::new(&simple_descriptor());
        let mut cmd = DeviceCommand::default();
        cmd.buttons.insert("phantom".into(), true);

        match safety.validate(&cmd) {
            SafetyResult::Rejected(r) => assert!(r.contains("unknown button"), "got: {r}"),
            other => panic!("expected Rejected, got {other:?}"),
        }
    }

    #[test]
    fn rejects_non_unit_quaternion() {
        let desc = descriptor_with(vec![], vec![], vec![pose("ee")]);
        let mut safety = DeviceSafety::new(&desc);
        let mut cmd = DeviceCommand::default();
        cmd.poses.insert(
            "ee".into(),
            Pose6D {
                position: [0.0, 0.0, 0.0],
                rotation: [1.0, 1.0, 1.0, 1.0], // norm = 2.0
            },
        );

        match safety.validate(&cmd) {
            SafetyResult::Rejected(r) => {
                assert!(r.contains("quaternion"), "got: {r}");
            }
            other => panic!("expected Rejected, got {other:?}"),
        }
    }

    #[test]
    fn accepts_unit_quaternion() {
        let desc = descriptor_with(vec![], vec![], vec![pose("ee")]);
        let mut safety = DeviceSafety::new(&desc);
        let mut cmd = DeviceCommand::default();
        cmd.poses.insert(
            "ee".into(),
            Pose6D {
                position: [0.1, 0.2, 0.3],
                rotation: [0.0, 0.0, 0.0, 1.0], // identity
            },
        );

        match safety.validate(&cmd) {
            SafetyResult::Ok(_) => {}
            other => panic!("expected Ok, got {other:?}"),
        }
    }

    #[test]
    fn rejects_pose_with_nan_position() {
        let desc = descriptor_with(vec![], vec![], vec![pose("ee")]);
        let mut safety = DeviceSafety::new(&desc);
        let mut cmd = DeviceCommand::default();
        cmd.poses.insert(
            "ee".into(),
            Pose6D {
                position: [f64::NAN, 0.0, 0.0],
                rotation: [0.0, 0.0, 0.0, 1.0],
            },
        );

        match safety.validate(&cmd) {
            SafetyResult::Rejected(r) => assert!(r.contains("non-finite"), "got: {r}"),
            other => panic!("expected Rejected, got {other:?}"),
        }
    }

    #[test]
    fn confirm_button_requires_two_presses() {
        let desc = descriptor_with(vec![], vec![button("estop", false, true, None)], vec![]);
        let mut safety = DeviceSafety::new(&desc);
        let t0 = Instant::now();

        // Press 1: arms but does not fire.
        let mut cmd = DeviceCommand::default();
        cmd.buttons.insert("estop".into(), true);
        let r = safety.validate_at(&cmd, t0);
        let out = match r {
            SafetyResult::Ok(c) => c,
            other => panic!("expected Ok, got {other:?}"),
        };
        assert_eq!(
            *out.buttons.get("estop").unwrap(),
            false,
            "first press should arm only"
        );

        // Release between presses (rising-edge detection).
        let mut release = DeviceCommand::default();
        release.buttons.insert("estop".into(), false);
        let _ = safety.validate_at(&release, t0 + Duration::from_millis(100));

        // Press 2 within window: confirms.
        let r = safety.validate_at(&cmd, t0 + Duration::from_millis(500));
        let out = match r {
            SafetyResult::Ok(c) => c,
            other => panic!("expected Ok, got {other:?}"),
        };
        assert_eq!(
            *out.buttons.get("estop").unwrap(),
            true,
            "second press should confirm"
        );
    }

    #[test]
    fn confirm_window_expires() {
        let desc = descriptor_with(vec![], vec![button("estop", false, true, None)], vec![]);
        let mut safety = DeviceSafety::new(&desc);
        let t0 = Instant::now();

        let mut cmd = DeviceCommand::default();
        cmd.buttons.insert("estop".into(), true);

        // Press 1 (arm).
        let _ = safety.validate_at(&cmd, t0);

        // Release.
        let mut release = DeviceCommand::default();
        release.buttons.insert("estop".into(), false);
        let _ = safety.validate_at(&release, t0 + Duration::from_millis(100));

        // Press 2 outside window: re-arms instead of confirming.
        let r = safety.validate_at(&cmd, t0 + Duration::from_secs(10));
        let out = match r {
            SafetyResult::Ok(c) => c,
            other => panic!("expected Ok, got {other:?}"),
        };
        assert_eq!(
            *out.buttons.get("estop").unwrap(),
            false,
            "press after window should re-arm, not confirm"
        );
    }

    #[test]
    fn toggle_button_flips_on_rising_edge() {
        let desc = descriptor_with(vec![], vec![button("light", true, false, None)], vec![]);
        let mut safety = DeviceSafety::new(&desc);

        let press = |val: bool| {
            let mut c = DeviceCommand::default();
            c.buttons.insert("light".into(), val);
            c
        };

        // Initial: false.
        let r = safety.validate(&press(false));
        assert_eq!(extract_button(&r, "light"), false);

        // Rising edge → flip to true.
        let r = safety.validate(&press(true));
        assert_eq!(extract_button(&r, "light"), true);

        // Held: stays true (no second flip).
        let r = safety.validate(&press(true));
        assert_eq!(extract_button(&r, "light"), true);

        // Release: stays true (latched).
        let r = safety.validate(&press(false));
        assert_eq!(extract_button(&r, "light"), true);

        // Next rising edge → flip to false.
        let r = safety.validate(&press(true));
        assert_eq!(extract_button(&r, "light"), false);
    }

    #[test]
    fn group_rejects_two_active_in_same_frame() {
        let desc = descriptor_with(
            vec![],
            vec![
                button("mode_a", false, false, Some("mode")),
                button("mode_b", false, false, Some("mode")),
            ],
            vec![],
        );
        let mut safety = DeviceSafety::new(&desc);
        let mut cmd = DeviceCommand::default();
        cmd.buttons.insert("mode_a".into(), true);
        cmd.buttons.insert("mode_b".into(), true);

        match safety.validate(&cmd) {
            SafetyResult::Rejected(r) => assert!(r.contains("group"), "got: {r}"),
            other => panic!("expected Rejected, got {other:?}"),
        }
    }

    #[test]
    fn neutral_command_passes() {
        let desc = simple_descriptor();
        let mut safety = DeviceSafety::new(&desc);
        let neutral = neutral_command(&desc);
        match safety.validate(&neutral) {
            SafetyResult::Ok(c) => {
                assert_eq!(*c.axes.get("throttle").unwrap(), 0.0);
            }
            other => panic!("expected Ok, got {other:?}"),
        }
    }

    fn extract_button(r: &SafetyResult, name: &str) -> bool {
        match r {
            SafetyResult::Ok(c) | SafetyResult::Clamped(c) => {
                *c.buttons.get(name).unwrap_or(&false)
            }
            SafetyResult::Rejected(reason) => panic!("unexpected reject: {reason}"),
        }
    }
}
