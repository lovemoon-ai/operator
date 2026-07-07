//! Real SO-101 hardware driver.
//!
//! This driver keeps hardware-specific Feetech/LeRobot code out of Rust by
//! spawning `scripts/so101_real_bridge.py bridge --port <tty>` and speaking a
//! small stdin/stdout JSON-line protocol:
//!
//! * bridge -> host at startup:
//!   `{"event":"ready","joint_names":[...],"positions":[deg...]}`
//! * host -> bridge:
//!   `{"positions":[5 floats]}` writes arm joints in degrees
//!   `{"gripper":0.5}` writes normalized gripper opening
//!   `{"positions":[5 floats],"gripper":0.5}` writes both
//!   `{"reset":true}` returns to configured home
//!   `{"stop":true}` freezes current position and disables torque
//!   `{"enable":true}` enables torque after a stop
//! * bridge -> host per request:
//!   `{"positions":[6 floats],"currents":{...},"loads":{...},"ts_ns":...}`
//!
//! The Python bridge owns conservative servo configuration, bus calibration,
//! current/load reflexes, and gradual stepping. Rust remains responsible for
//! adapter framing, timeouts, and telemetry snapshots.

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

pub const NUM_ACTUATORS: usize = 6;
const NUM_ARM_JOINTS: usize = NUM_ACTUATORS - 1;
const GRIPPER_DEG_CLOSED: f64 = 8.0;
const GRIPPER_DEG_OPEN: f64 = 85.0;

const READY_TIMEOUT: Duration = Duration::from_secs(20);
const RESPONSE_TIMEOUT: Duration = Duration::from_secs(4);

#[derive(Debug, Serialize)]
#[serde(untagged)]
enum BridgeRequest<'a> {
    Command {
        #[serde(skip_serializing_if = "Option::is_none")]
        positions: Option<&'a [f64]>,
        #[serde(skip_serializing_if = "Option::is_none")]
        gripper: Option<f32>,
    },
    EndEffector {
        ee_pose: BridgePose,
        #[serde(skip_serializing_if = "Option::is_none")]
        gripper: Option<f32>,
    },
    Reset {
        reset: bool,
    },
    Stop {
        stop: bool,
    },
    Enable {
        enable: bool,
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

#[derive(Debug, Default, Deserialize)]
struct BridgeResponse {
    #[serde(default)]
    event: Option<String>,
    #[serde(default)]
    joint_names: Vec<String>,
    #[serde(default)]
    positions: Vec<f64>,
    #[serde(default)]
    error: Option<String>,
    #[serde(default)]
    reflex: Option<String>,
    #[serde(default)]
    ee: Option<BridgePose>,
    #[serde(default)]
    #[allow(dead_code)]
    ik_error: Option<f64>,
    #[serde(default)]
    #[allow(dead_code)]
    currents: std::collections::HashMap<String, i64>,
    #[serde(default)]
    #[allow(dead_code)]
    loads: std::collections::HashMap<String, i64>,
    #[serde(default)]
    #[allow(dead_code)]
    ts_ns: i64,
}

pub struct So101RealDriver {
    _child: Child,
    stdin: ChildStdin,
    stdout: BufReader<ChildStdout>,
    last_positions_deg: [f64; NUM_ACTUATORS],
    last_ee_pose: Option<Pose6D>,
    ready: bool,
}

impl So101RealDriver {
    pub fn new(
        script_path: &str,
        python_bin: &str,
        port: &str,
        extra_args: &[String],
    ) -> Result<Self> {
        let mut cmd = Command::new(python_bin);
        cmd.arg(script_path)
            .arg("bridge")
            .arg("--port")
            .arg(port)
            .args(extra_args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .kill_on_drop(true);

        let mut child = cmd.spawn().with_context(|| {
            format!(
                "failed to spawn SO-101 bridge: '{python_bin} {script_path} bridge --port {port}'"
            )
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

        tracing::info!(
            "SO-101 hardware bridge spawned: python={} script={} port={}",
            python_bin,
            script_path,
            port
        );

        Ok(Self {
            _child: child,
            stdin,
            stdout,
            last_positions_deg: [0.0; NUM_ACTUATORS],
            last_ee_pose: None,
            ready: false,
        })
    }

    pub fn last_positions_deg(&self) -> [f64; NUM_ACTUATORS] {
        self.last_positions_deg
    }

    fn gripper_value_to_deg(value: f32) -> f64 {
        let v = value.clamp(0.0, 1.0) as f64;
        GRIPPER_DEG_CLOSED + v * (GRIPPER_DEG_OPEN - GRIPPER_DEG_CLOSED)
    }

    fn apply_snapshot(&mut self, resp: &BridgeResponse) {
        if resp.positions.len() == NUM_ACTUATORS {
            for (index, value) in resp.positions.iter().enumerate() {
                self.last_positions_deg[index] = *value;
            }
        } else if !resp.positions.is_empty() {
            tracing::warn!(
                "SO-101 bridge returned positions length {} (expected {NUM_ACTUATORS})",
                resp.positions.len()
            );
        }
        if let Some(ee) = &resp.ee {
            self.last_ee_pose = Some(Pose6D::from(ee));
        }
    }

    async fn read_line(&mut self, wait: Duration) -> Result<BridgeResponse> {
        let mut line = String::new();
        let n = timeout(wait, self.stdout.read_line(&mut line))
            .await
            .map_err(|_| anyhow!("SO-101 bridge response timeout after {:?}", wait))??;
        if n == 0 {
            anyhow::bail!("SO-101 bridge stdout EOF - Python process exited");
        }
        let trimmed = line.trim();
        if trimmed.is_empty() {
            anyhow::bail!("SO-101 bridge sent empty line");
        }
        let resp: BridgeResponse = serde_json::from_str(trimmed)
            .with_context(|| format!("bad JSON from SO-101 bridge: {trimmed:?}"))?;
        if let Some(err) = &resp.error {
            anyhow::bail!("SO-101 bridge error: {err}");
        }
        if let Some(reflex) = &resp.reflex {
            anyhow::bail!("SO-101 hardware reflex: {reflex}");
        }
        Ok(resp)
    }

    async fn await_ready(&mut self) -> Result<()> {
        let deadline = tokio::time::Instant::now() + READY_TIMEOUT;
        for _ in 0..8 {
            let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
            if remaining.is_zero() {
                anyhow::bail!(
                    "SO-101 bridge did not become ready within {:?}",
                    READY_TIMEOUT
                );
            }
            let resp = self.read_line(remaining).await?;
            if resp.event.as_deref() == Some("ready") {
                self.apply_snapshot(&resp);
                tracing::info!(
                    "SO-101 bridge ready: joints={:?} positions={:?}",
                    resp.joint_names,
                    self.last_positions_deg
                );
                return Ok(());
            }
            tracing::debug!("discarding non-ready SO-101 bridge line: {resp:?}");
        }
        anyhow::bail!("did not receive SO-101 `ready` event in the first 8 lines")
    }

    async fn write_request(&mut self, req: &BridgeRequest<'_>) -> Result<()> {
        let mut line = serde_json::to_vec(req)?;
        line.push(b'\n');
        self.stdin.write_all(&line).await?;
        self.stdin.flush().await?;
        Ok(())
    }

    async fn command(&mut self, positions: Option<&[f64]>, gripper: Option<f32>) -> Result<()> {
        let req = BridgeRequest::Command { positions, gripper };
        self.write_request(&req).await?;
        let resp = self.read_line(RESPONSE_TIMEOUT).await?;
        self.apply_snapshot(&resp);
        Ok(())
    }

    async fn end_effector_command(&mut self, target: &Pose6D, gripper: Option<f32>) -> Result<()> {
        let req = BridgeRequest::EndEffector {
            ee_pose: BridgePose::from(target),
            gripper,
        };
        self.write_request(&req).await?;
        let resp = self.read_line(RESPONSE_TIMEOUT).await?;
        self.apply_snapshot(&resp);
        Ok(())
    }

    async fn simple_request(&mut self, req: BridgeRequest<'_>) -> Result<()> {
        self.write_request(&req).await?;
        let resp = self.read_line(RESPONSE_TIMEOUT).await?;
        self.apply_snapshot(&resp);
        Ok(())
    }
}

#[async_trait]
impl ArmDriver for So101RealDriver {
    async fn set_joints(&mut self, joints: &JointAngles) -> Result<()> {
        if !self.ready {
            anyhow::bail!("So101RealDriver::set_joints before enable_torque");
        }
        if joints.angles.len() != NUM_ARM_JOINTS {
            tracing::debug!(
                "So101RealDriver: got {} joint angles, expected {NUM_ARM_JOINTS}; writing arm joints only",
                joints.angles.len()
            );
        }
        let n = joints.angles.len().min(NUM_ARM_JOINTS);
        let mut positions = self.last_positions_deg[..NUM_ARM_JOINTS].to_vec();
        for (index, value) in joints.angles.iter().copied().take(n).enumerate() {
            positions[index] = value;
        }
        self.command(Some(&positions), None).await
    }

    async fn set_gripper(&mut self, value: f32) -> Result<()> {
        if !self.ready {
            anyhow::bail!("So101RealDriver::set_gripper before enable_torque");
        }
        tracing::trace!(
            "SO-101 gripper command {:.2} -> {:.1} deg",
            value,
            Self::gripper_value_to_deg(value)
        );
        self.command(None, Some(value)).await
    }

    fn supports_end_effector_pose(&self) -> bool {
        true
    }

    async fn set_end_effector_pose(&mut self, target: &Pose6D, gripper: Option<f32>) -> Result<()> {
        if !self.ready {
            anyhow::bail!("So101RealDriver::set_end_effector_pose before enable_torque");
        }
        self.end_effector_command(target, gripper).await
    }

    fn last_joint_angles(&self) -> Option<JointAngles> {
        Some(JointAngles {
            angles: self.last_positions_deg.to_vec(),
        })
    }

    fn last_end_effector_pose(&self) -> Option<Pose6D> {
        self.last_ee_pose.clone()
    }

    async fn reset_to_initial_pose(&mut self) -> Result<()> {
        if !self.ready {
            anyhow::bail!("So101RealDriver::reset_to_initial_pose before enable_torque");
        }
        self.simple_request(BridgeRequest::Reset { reset: true })
            .await?;
        tracing::info!("SO-101: reset to configured home pose");
        Ok(())
    }

    async fn emergency_stop(&mut self) -> Result<()> {
        if self.ready {
            if let Err(e) = self
                .simple_request(BridgeRequest::Stop { stop: true })
                .await
            {
                tracing::warn!("SO-101 e-stop bridge request failed (non-fatal): {e}");
            }
        }
        tracing::warn!("SO-101: emergency stop requested");
        Ok(())
    }

    async fn enable_torque(&mut self) -> Result<()> {
        if !self.ready {
            self.await_ready().await?;
            self.ready = true;
        }
        self.simple_request(BridgeRequest::Enable { enable: true })
            .await?;
        tracing::info!("SO-101: torque enabled");
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn gripper_value_to_deg_endpoints() {
        assert!((So101RealDriver::gripper_value_to_deg(0.0) - GRIPPER_DEG_CLOSED).abs() < 1e-9);
        assert!((So101RealDriver::gripper_value_to_deg(1.0) - GRIPPER_DEG_OPEN).abs() < 1e-9);
    }

    #[test]
    fn command_request_serialises_to_expected_shape() {
        let positions = [1.0_f64, 2.0, 3.0, 4.0, 5.0];
        let req = BridgeRequest::Command {
            positions: Some(&positions),
            gripper: Some(0.25),
        };
        let s = serde_json::to_string(&req).unwrap();
        assert!(s.contains("\"positions\":[1.0,2.0,3.0,4.0,5.0]"), "got {s}");
        assert!(s.contains("\"gripper\":0.25"), "got {s}");
    }

    #[test]
    fn end_effector_request_serialises_to_expected_shape() {
        let pose = Pose6D {
            position: [0.1, 0.2, 0.3],
            rotation: [0.0, 0.0, 0.0, 1.0],
        };
        let req = BridgeRequest::EndEffector {
            ee_pose: BridgePose::from(&pose),
            gripper: Some(0.5),
        };
        let s = serde_json::to_string(&req).unwrap();
        assert!(
            s.contains("\"ee_pose\":{\"position\":[0.1,0.2,0.3],\"rotation\":[0.0,0.0,0.0,1.0]}"),
            "got {s}"
        );
        assert!(s.contains("\"gripper\":0.5"), "got {s}");
    }

    #[test]
    fn ready_response_deserialises() {
        let raw = r#"{"event":"ready","joint_names":["shoulder_pan","shoulder_lift","elbow_flex","wrist_flex","wrist_roll","gripper"],"positions":[0.0,-90.0,90.0,0.0,0.0,85.0],"ee":{"position":[0.25,0.0,0.2],"rotation":[0.0,0.0,0.0,1.0]}}"#;
        let resp: BridgeResponse = serde_json::from_str(raw).unwrap();
        assert_eq!(resp.event.as_deref(), Some("ready"));
        assert_eq!(resp.joint_names.len(), NUM_ACTUATORS);
        assert_eq!(resp.positions.len(), NUM_ACTUATORS);
        assert_eq!(
            resp.ee.as_ref().map(|ee| ee.position),
            Some([0.25, 0.0, 0.2])
        );
        assert!(resp.error.is_none());
    }

    #[test]
    fn reflex_response_deserialises() {
        let raw = r#"{"reflex":"gripper current 300 > 260"}"#;
        let resp: BridgeResponse = serde_json::from_str(raw).unwrap();
        assert_eq!(resp.reflex.as_deref(), Some("gripper current 300 > 260"));
    }
}
