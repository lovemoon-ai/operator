//! MuJoCo SO-101 simulator driver.
//!
//! Speaks the stdin/stdout JSON-line protocol exported by
//! `examples/mujuco-arm-so101/sim_so101.py bridge`. Lets the same control
//! pipeline that drives a real SO-101 arm drive the MuJoCo simulator instead —
//! useful for headless testing, demos without hardware, and reproducing
//! operator sessions deterministically.
//!
//! Wire protocol (source of truth: `sim_so101.py`):
//!
//! * sim → host, one-shot at startup
//!     ```text
//!     {"event":"ready","nq":13,"nu":6,"joint_names":[...]}
//!     ```
//! * host → sim
//!     ```text
//!     {"ctrl":[6 floats], "steps": N}      # apply ctrl, mj_step N times
//!     {"ee_pose":{...}, "gripper":0.5, "steps": N} # bridge-side IK
//!     {"reset": true}                      # reset to keyframe "home"
//!     ```
//! * sim → host (one line per request)
//!     ```text
//!     {"q":[6 floats], "ctrl":[6 floats], "ee":{...}, "cube":[7 floats], "ts_ns": <i64>}
//!     ```
//! * sim → host on error: `{"error":"<msg>"}`
//!
//! Unit convention: the rest of the control pipeline (Safety, PoseMapper)
//! speaks **degrees**. MuJoCo's `<position>` actuators are in **radians**. We do
//! the conversion here at the driver boundary so the existing pipeline doesn't
//! need to know which backend is wired in.
//!
//! Actuator order (must match the Python bridge's `ARM_ACTUATORS`):
//! `shoulder_pan, shoulder_lift, elbow_flex, wrist_flex, wrist_roll, gripper`.
//!
//! Lifecycle:
//! * `new()` spawns the Python subprocess but does *not* read the ready
//!   handshake — `new()` is sync because [`super::create_driver`] is sync, and
//!   the read needs `.await`.
//! * `enable_torque()` (called from the device's `connect`) awaits the `ready`
//!   event, then issues a `{"reset":true}` to seed `last_q_rad` / `last_ctrl`
//!   from the home keyframe. From that point on `set_joints` / `set_gripper`
//!   write + read in lock-step.
//! * Drop kills the child (`kill_on_drop(true)`).

use std::process::Stdio;
use std::time::Duration;

use anyhow::{anyhow, Context, Result};
use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use teleop_protocol::Pose6D;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin, ChildStdout, Command};
use tokio::time::timeout;

use super::ArmDriver;
use crate::control::JointAngles;

/// SO-101 has 5 arm joints + 1 gripper.
pub const NUM_ACTUATORS: usize = 6;
const NUM_ARM_JOINTS: usize = NUM_ACTUATORS - 1;

/// Gripper actuator range in radians, from `assets/so101/so101.xml`
/// (`+` = open).
pub const GRIPPER_RAD_MIN: f64 = -0.17;
pub const GRIPPER_RAD_MAX: f64 = 1.75;

/// Default number of `mj_step` calls per outbound ctrl write. The sim
/// `timestep = 0.005 s`, so 3 steps per write keeps the sim wall-clock roughly
/// in line with a 72 Hz teleop cadence (≈13.9 ms/frame).
pub const DEFAULT_STEPS_PER_WRITE: u32 = 3;

/// Upper bound the host enforces on `steps_per_write`. The Python bridge also
/// caps internally at 1000; we cap lower so a misconfigured value can't stall
/// the device loop.
const MAX_STEPS_PER_WRITE: u32 = 50;

/// How long to wait for the bridge's one-shot `ready` event after spawning the
/// Python process. Cold start (MuJoCo + STL mesh load) usually finishes in
/// 1–3 s on a laptop; 15 s gives plenty of slack without hanging forever.
const READY_TIMEOUT: Duration = Duration::from_secs(15);

/// How long to wait for a single step/reset response line. Each `mj_step` is
/// microseconds for this model; the dominant cost is the Python round-trip. 2 s
/// is generous; anything slower is a real fault.
const RESPONSE_TIMEOUT: Duration = Duration::from_secs(2);

/// Outbound request envelope (host → bridge).
///
/// `#[serde(untagged)]` lets each variant serialize to just its inner fields,
/// matching the bridge's free-form JSON shape.
#[derive(Debug, Serialize)]
#[serde(untagged)]
enum BridgeRequest<'a> {
    Step {
        ctrl: &'a [f64],
        steps: u32,
    },
    EndEffector {
        ee_pose: BridgePose,
        #[serde(skip_serializing_if = "Option::is_none")]
        gripper: Option<f32>,
        steps: u32,
    },
    Reset {
        reset: bool,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
struct BridgePose {
    position: [f64; 3],
    rotation: [f64; 4],
}

impl From<&Pose6D> for BridgePose {
    fn from(value: &Pose6D) -> Self {
        Self {
            position: value.position,
            rotation: value.rotation,
        }
    }
}

impl From<&BridgePose> for Pose6D {
    fn from(value: &BridgePose) -> Self {
        Self {
            position: value.position,
            rotation: value.rotation,
        }
    }
}

/// Inbound response envelope (bridge → host).
///
/// All fields are optional / defaulted because the bridge emits three different
/// shapes (ready event, snapshot, error) on the same stream and we want a single
/// deserializer.
#[derive(Debug, Default, Deserialize)]
struct BridgeResponse {
    /// Snapshot: joint positions in radians (actuator order).
    #[serde(default)]
    q: Vec<f64>,
    /// Snapshot: current actuator ctrl in radians (actuator order).
    #[serde(default)]
    ctrl: Vec<f64>,
    /// Snapshot: current `gripperframe` site pose in MuJoCo world/base frame.
    #[serde(default)]
    ee: Option<BridgePose>,
    /// Snapshot: red_cube qpos `[x,y,z,qw,qx,qy,qz]`. Unused for control today.
    #[serde(default)]
    #[allow(dead_code)]
    cube: Vec<f64>,
    /// Snapshot: wall-clock ns when the bridge produced this line.
    #[serde(default)]
    #[allow(dead_code)]
    ts_ns: i64,
    /// Error string from the bridge (e.g. "ctrl must be list of 6 floats").
    #[serde(default)]
    error: Option<String>,
    /// Lifecycle event ("ready" is the only one currently defined).
    #[serde(default)]
    event: Option<String>,
    /// Ready event: actuator names declared by the bridge.
    #[serde(default)]
    joint_names: Vec<String>,
    /// Ready event: actuator count.
    #[serde(default)]
    nu: Option<u32>,
    /// Ready event: generalised-coordinate count.
    #[serde(default)]
    nq: Option<u32>,
}

/// Driver for the MuJoCo SO-101 simulator (bridge-mode subprocess).
pub struct MujocoSo101Driver {
    /// Owns the child. Kept alive for the driver's lifetime; killed when this
    /// struct drops because `kill_on_drop` was set on spawn.
    _child: Child,
    stdin: ChildStdin,
    stdout: BufReader<ChildStdout>,
    /// Last commanded ctrl in radians (actuator order). Both `set_joints` and
    /// `set_gripper` mutate this; both then re-send the full vector since the
    /// bridge has no partial-update form.
    last_ctrl: [f64; NUM_ACTUATORS],
    /// Latest joint snapshot returned by the bridge, in radians.
    last_q_rad: [f64; NUM_ACTUATORS],
    /// Latest `gripperframe` site pose returned by the bridge.
    last_ee_pose: Option<Pose6D>,
    /// Cleared on construction, set after the `ready` event is read.
    ready: bool,
    /// `mj_step` calls per outbound write. Clamped to `[1, MAX_STEPS_PER_WRITE]`
    /// at construction.
    steps_per_write: u32,
}

impl MujocoSo101Driver {
    /// Spawn `<python_bin> <script_path> bridge [extra_args ...]`.
    ///
    /// The `ready` handshake is **not** performed here — see the module docs for
    /// why. Call [`Self::enable_torque`] to drive it.
    pub fn new(
        script_path: &str,
        python_bin: &str,
        steps_per_write: u32,
        extra_args: &[String],
    ) -> Result<Self> {
        let mut cmd = Command::new(python_bin);
        cmd.arg(script_path)
            .arg("bridge")
            .args(extra_args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            // Python writes log lines to stderr ("bridge: ready ...");
            // inherit so they land in the adapter's terminal.
            .stderr(Stdio::inherit())
            .kill_on_drop(true);

        let mut child = cmd.spawn().with_context(|| {
            format!("failed to spawn MuJoCo bridge: '{python_bin} {script_path} bridge'")
        })?;

        let stdin = child
            .stdin
            .take()
            .ok_or_else(|| anyhow!("child stdin not piped"))?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| anyhow!("child stdout not piped"))?;
        let stdout = BufReader::new(stdout);

        let steps_per_write = steps_per_write.clamp(1, MAX_STEPS_PER_WRITE);

        tracing::info!(
            "MuJoCo SO-101 bridge spawned: python={} script={} steps_per_write={}",
            python_bin,
            script_path,
            steps_per_write
        );

        Ok(Self {
            _child: child,
            stdin,
            stdout,
            last_ctrl: [0.0; NUM_ACTUATORS],
            last_q_rad: [0.0; NUM_ACTUATORS],
            last_ee_pose: None,
            ready: false,
            steps_per_write,
        })
    }

    /// Latest joint snapshot in radians (actuator order). Updated on every
    /// successful step / reset.
    pub fn last_q_rad(&self) -> [f64; NUM_ACTUATORS] {
        self.last_q_rad
    }

    fn apply_snapshot(&mut self, resp: &BridgeResponse) {
        if resp.q.len() == NUM_ACTUATORS {
            for (i, v) in resp.q.iter().enumerate() {
                self.last_q_rad[i] = *v;
            }
        } else if !resp.q.is_empty() {
            tracing::warn!(
                "bridge returned q of unexpected length {} (expected {NUM_ACTUATORS})",
                resp.q.len()
            );
        }

        if resp.ctrl.len() == NUM_ACTUATORS {
            for (i, v) in resp.ctrl.iter().enumerate() {
                self.last_ctrl[i] = *v;
            }
        } else if !resp.ctrl.is_empty() {
            tracing::warn!(
                "bridge returned ctrl of unexpected length {} (expected {NUM_ACTUATORS})",
                resp.ctrl.len()
            );
        }

        if let Some(ee) = &resp.ee {
            self.last_ee_pose = Some(Pose6D::from(ee));
        }
    }

    /// Map a normalised gripper command in `[0, 1]` (0 = closed, 1 = open) to
    /// the MuJoCo gripper actuator range in radians.
    fn gripper_value_to_rad(value: f32) -> f64 {
        let v = value.clamp(0.0, 1.0) as f64;
        GRIPPER_RAD_MIN + v * (GRIPPER_RAD_MAX - GRIPPER_RAD_MIN)
    }

    /// Read one JSON-line from the bridge with the given timeout. Empty lines
    /// are skipped. EOF / bad JSON / `{"error":...}` all bubble up as anyhow
    /// errors.
    async fn read_line(&mut self, wait: Duration) -> Result<BridgeResponse> {
        let mut line = String::new();
        let n = timeout(wait, self.stdout.read_line(&mut line))
            .await
            .map_err(|_| anyhow!("bridge response timeout after {:?}", wait))??;
        if n == 0 {
            anyhow::bail!("bridge stdout EOF — Python process exited");
        }
        let trimmed = line.trim();
        if trimmed.is_empty() {
            anyhow::bail!("bridge sent empty line");
        }
        let resp: BridgeResponse = serde_json::from_str(trimmed)
            .with_context(|| format!("bad JSON from bridge: {trimmed:?}"))?;
        if let Some(err) = &resp.error {
            anyhow::bail!("bridge error: {err}");
        }
        Ok(resp)
    }

    /// Consume the one-shot `ready` event. Tolerant of a few non-ready lines
    /// slipping in (defensive; the bridge currently emits ready as the very
    /// first stdout line).
    async fn await_ready(&mut self) -> Result<()> {
        let deadline = tokio::time::Instant::now() + READY_TIMEOUT;
        for _ in 0..8 {
            let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
            if remaining.is_zero() {
                anyhow::bail!(
                    "MuJoCo bridge did not become ready within {:?}",
                    READY_TIMEOUT
                );
            }
            let resp = self.read_line(remaining).await?;
            if resp.event.as_deref() == Some("ready") {
                if let Some(nu) = resp.nu {
                    if (nu as usize) != NUM_ACTUATORS {
                        anyhow::bail!(
                            "MuJoCo bridge reports nu={nu}, expected {NUM_ACTUATORS} \
                             — model mismatch with driver"
                        );
                    }
                }
                tracing::info!(
                    "MuJoCo bridge ready: nq={:?} nu={:?} joints={:?}",
                    resp.nq,
                    resp.nu,
                    resp.joint_names
                );
                return Ok(());
            }
            tracing::debug!("discarding non-ready bridge line: {resp:?}");
        }
        anyhow::bail!("did not receive `ready` event in the first 8 lines")
    }

    /// Send the current `last_ctrl` to the bridge and read one snapshot back.
    /// Updates `last_q_rad` on success.
    async fn step(&mut self) -> Result<()> {
        let req = BridgeRequest::Step {
            ctrl: &self.last_ctrl,
            steps: self.steps_per_write,
        };
        let mut line = serde_json::to_vec(&req)?;
        line.push(b'\n');
        self.stdin.write_all(&line).await?;
        self.stdin.flush().await?;

        let resp = self.read_line(RESPONSE_TIMEOUT).await?;
        self.apply_snapshot(&resp);
        Ok(())
    }

    async fn reset_bridge_to_home(&mut self) -> Result<()> {
        let req = BridgeRequest::Reset { reset: true };
        let mut line = serde_json::to_vec(&req)?;
        line.push(b'\n');
        self.stdin.write_all(&line).await?;
        self.stdin.flush().await?;
        let resp = self.read_line(RESPONSE_TIMEOUT).await?;
        self.apply_snapshot(&resp);
        if resp.ctrl.is_empty() && resp.q.len() == NUM_ACTUATORS {
            self.last_ctrl = self.last_q_rad;
        }
        Ok(())
    }
}

#[async_trait]
impl ArmDriver for MujocoSo101Driver {
    async fn set_joints(&mut self, joints: &JointAngles) -> Result<()> {
        if !self.ready {
            anyhow::bail!("MujocoSo101Driver::set_joints before enable_torque");
        }
        if joints.angles.len() != NUM_ARM_JOINTS {
            tracing::debug!(
                "MujocoSo101Driver: got {} joint angles, expected {NUM_ARM_JOINTS}; \
                 writing arm joints only and holding gripper",
                joints.angles.len()
            );
        }
        let n = joints.angles.len().min(NUM_ARM_JOINTS);
        // Degrees → radians at the driver boundary. The rest of the pipeline is
        // degrees by convention (PoseMapper, Safety). The gripper actuator is
        // intentionally excluded here so pose/wrist commands can never move the
        // jaw; it is controlled only by set_gripper().
        for i in 0..n {
            self.last_ctrl[i] = joints.angles[i].to_radians();
        }
        tracing::trace!(
            "MujocoSo101Driver: set_joints wrote {n} arm joints, held gripper_ctrl={:.3}",
            self.last_ctrl[NUM_ACTUATORS - 1]
        );
        self.step().await
    }

    async fn set_gripper(&mut self, value: f32) -> Result<()> {
        if !self.ready {
            anyhow::bail!("MujocoSo101Driver::set_gripper before enable_torque");
        }
        self.last_ctrl[NUM_ACTUATORS - 1] = Self::gripper_value_to_rad(value);
        self.step().await
    }

    fn supports_end_effector_pose(&self) -> bool {
        true
    }

    async fn set_end_effector_pose(&mut self, target: &Pose6D, gripper: Option<f32>) -> Result<()> {
        if !self.ready {
            anyhow::bail!("MujocoSo101Driver::set_end_effector_pose before enable_torque");
        }
        let req = BridgeRequest::EndEffector {
            ee_pose: BridgePose::from(target),
            gripper,
            steps: self.steps_per_write,
        };
        let mut line = serde_json::to_vec(&req)?;
        line.push(b'\n');
        self.stdin.write_all(&line).await?;
        self.stdin.flush().await?;

        let resp = self.read_line(RESPONSE_TIMEOUT).await?;
        self.apply_snapshot(&resp);
        Ok(())
    }

    fn last_joint_angles(&self) -> Option<JointAngles> {
        Some(JointAngles {
            angles: self.last_q_rad.iter().map(|rad| rad.to_degrees()).collect(),
        })
    }

    fn last_end_effector_pose(&self) -> Option<Pose6D> {
        self.last_ee_pose.clone()
    }

    async fn reset_to_initial_pose(&mut self) -> Result<()> {
        if !self.ready {
            anyhow::bail!("MujocoSo101Driver::reset_to_initial_pose before enable_torque");
        }
        self.reset_bridge_to_home().await?;
        tracing::info!(
            "MujocoSo101: reset to home pose q_rad={:?}",
            self.last_q_rad
        );
        Ok(())
    }

    async fn emergency_stop(&mut self) -> Result<()> {
        // The sim has no torque-off concept. Freeze ctrl at the last reported q
        // so the next physics step has zero motion demand. We don't return
        // errors from this path even if the step write fails — the device layer
        // treats e-stop failures as fatal and we don't want a transient pipe
        // glitch to tear down the whole session.
        if self.ready {
            self.last_ctrl = self.last_q_rad;
            if let Err(e) = self.step().await {
                tracing::warn!("MujocoSo101 e-stop step failed (non-fatal): {e}");
            }
        }
        tracing::warn!("MujocoSo101: emergency stop (ctrl frozen at last sim q)");
        Ok(())
    }

    async fn enable_torque(&mut self) -> Result<()> {
        if self.ready {
            return Ok(());
        }
        self.await_ready().await?;
        self.ready = true;

        // Seed last_ctrl from the bridge's home keyframe. Without this the very
        // first set_joints would snap the sim from wherever the home pose put it
        // to whatever the PoseMapper computes — easily a 90° jump on
        // shoulder_lift, which looks like a violent commanded motion. Reset
        // returns a snapshot we mirror into both `last_q_rad` and `last_ctrl`.
        self.reset_bridge_to_home().await?;
        tracing::info!(
            "MujocoSo101: torque enabled, home pose seeded q_rad={:?}",
            self.last_q_rad
        );
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn gripper_value_to_rad_endpoints() {
        let lo = MujocoSo101Driver::gripper_value_to_rad(0.0);
        let hi = MujocoSo101Driver::gripper_value_to_rad(1.0);
        assert!((lo - GRIPPER_RAD_MIN).abs() < 1e-9);
        assert!((hi - GRIPPER_RAD_MAX).abs() < 1e-9);
    }

    #[test]
    fn gripper_value_to_rad_midpoint_and_saturation() {
        let mid = MujocoSo101Driver::gripper_value_to_rad(0.5);
        let expected_mid = (GRIPPER_RAD_MIN + GRIPPER_RAD_MAX) * 0.5;
        assert!((mid - expected_mid).abs() < 1e-9);

        // Out-of-range inputs clamp instead of returning garbage.
        assert!(
            (MujocoSo101Driver::gripper_value_to_rad(-1.0) - GRIPPER_RAD_MIN).abs() < 1e-9,
            "negative gripper input should clamp to GRIPPER_RAD_MIN"
        );
        assert!(
            (MujocoSo101Driver::gripper_value_to_rad(2.0) - GRIPPER_RAD_MAX).abs() < 1e-9,
            "out-of-range gripper input should clamp to GRIPPER_RAD_MAX"
        );
    }

    #[test]
    fn step_request_serialises_to_expected_shape() {
        let ctrl = [0.1_f64, 0.2, 0.3, 0.4, 0.5, 0.6];
        let req = BridgeRequest::Step {
            ctrl: &ctrl,
            steps: 3,
        };
        let s = serde_json::to_string(&req).unwrap();
        // Untagged enum ⇒ fields come out as a top-level object.
        assert!(s.contains("\"ctrl\":[0.1,0.2,0.3,0.4,0.5,0.6]"), "got {s}");
        assert!(s.contains("\"steps\":3"), "got {s}");
        assert!(!s.contains("Step"), "untagged variant leaked tag: {s}");
    }

    #[test]
    fn end_effector_request_serialises_to_expected_shape() {
        let target = Pose6D {
            position: [0.1, -0.2, 0.3],
            rotation: [0.0, 0.0, 0.0, 1.0],
        };
        let req = BridgeRequest::EndEffector {
            ee_pose: BridgePose::from(&target),
            gripper: Some(0.25),
            steps: 3,
        };
        let s = serde_json::to_string(&req).unwrap();
        assert!(
            s.contains("\"ee_pose\":{\"position\":[0.1,-0.2,0.3],\"rotation\":[0.0,0.0,0.0,1.0]}"),
            "got {s}"
        );
        assert!(s.contains("\"gripper\":0.25"), "got {s}");
        assert!(s.contains("\"steps\":3"), "got {s}");
        assert!(
            !s.contains("EndEffector"),
            "untagged variant leaked tag: {s}"
        );
    }

    #[test]
    fn reset_request_serialises_to_expected_shape() {
        let req = BridgeRequest::Reset { reset: true };
        let s = serde_json::to_string(&req).unwrap();
        assert_eq!(s, "{\"reset\":true}");
    }

    #[test]
    fn ready_response_deserialises() {
        let raw = r#"{"event":"ready","nq":13,"nu":6,"joint_names":["shoulder_pan","shoulder_lift","elbow_flex","wrist_flex","wrist_roll","gripper"]}"#;
        let resp: BridgeResponse = serde_json::from_str(raw).unwrap();
        assert_eq!(resp.event.as_deref(), Some("ready"));
        assert_eq!(resp.nu, Some(6));
        assert_eq!(resp.nq, Some(13));
        assert_eq!(resp.joint_names.len(), 6);
        assert!(resp.q.is_empty());
        assert!(resp.ctrl.is_empty());
        assert!(resp.ee.is_none());
        assert!(resp.error.is_none());
    }

    #[test]
    fn snapshot_response_deserialises() {
        let raw = r#"{"q":[0.0,1.5,0.5,0.0,0.0,0.5],"ctrl":[0.0,1.4,0.4,0.0,0.0,0.2],"ee":{"position":[0.2,0.0,0.3],"rotation":[0.0,0.0,0.0,1.0]},"cube":[0.3,0.0,0.02,1.0,0.0,0.0,0.0],"ts_ns":1234567890}"#;
        let resp: BridgeResponse = serde_json::from_str(raw).unwrap();
        assert_eq!(resp.q.len(), 6);
        assert!((resp.q[1] - 1.5).abs() < 1e-9);
        assert_eq!(resp.ctrl.len(), 6);
        assert!((resp.ctrl[1] - 1.4).abs() < 1e-9);
        assert_eq!(
            resp.ee.as_ref().map(|ee| ee.position),
            Some([0.2, 0.0, 0.3])
        );
        assert_eq!(resp.cube.len(), 7);
        assert_eq!(resp.ts_ns, 1234567890);
        assert!(resp.error.is_none());
        assert!(resp.event.is_none());
    }

    #[test]
    fn error_response_surfaces_bridge_error_text() {
        // Direct deserialization works; the `error` field gets populated.
        let raw = r#"{"error":"ctrl must be list of 6 floats"}"#;
        let resp: BridgeResponse = serde_json::from_str(raw).unwrap();
        assert_eq!(resp.error.as_deref(), Some("ctrl must be list of 6 floats"));
    }

    #[test]
    fn deg_to_rad_at_90_is_pi_over_two() {
        // Sanity check on the conversion we do in set_joints — if this ever
        // drifts (e.g. someone accidentally introduces a 0.5x factor) the whole
        // sim will be off by the same factor.
        let deg = 90.0_f64;
        assert!((deg.to_radians() - std::f64::consts::FRAC_PI_2).abs() < 1e-12);
    }
}
