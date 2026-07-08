use std::collections::BTreeMap;
use std::process::Stdio;
use std::time::Duration;

use anyhow::{anyhow, Context, Result};
use serde::{Deserialize, Serialize};
use teleop_protocol::Pose6D;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin, ChildStdout, Command};
use tokio::time::timeout;

use crate::config::GalbotG1Config;

pub const LEFT_ARM: &str = "left_arm";
pub const RIGHT_ARM: &str = "right_arm";
pub const LEFT_GRIPPER: &str = "left_gripper";
pub const RIGHT_GRIPPER: &str = "right_gripper";

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct BridgePose {
    pub position: [f64; 3],
    pub rotation: [f64; 4],
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

#[derive(Debug, Serialize)]
#[serde(untagged)]
enum BridgeRequest<'a> {
    Command {
        #[serde(skip_serializing_if = "BTreeMap::is_empty")]
        ee: BTreeMap<&'a str, BridgePose>,
        #[serde(skip_serializing_if = "BTreeMap::is_empty")]
        gripper: BTreeMap<&'a str, f32>,
    },
    Reset {
        reset: bool,
    },
    Stop {
        stop: bool,
    },
}

#[derive(Debug, Default, Deserialize)]
struct BridgeResponse {
    #[serde(default)]
    event: Option<String>,
    #[serde(default)]
    error: Option<String>,
    #[serde(default)]
    ee: BTreeMap<String, BridgePose>,
    #[serde(default)]
    gripper: BTreeMap<String, f32>,
    #[serde(default)]
    joints: Vec<f64>,
    #[serde(default)]
    connected: Option<bool>,
}

/// JSON-line bridge to the Galbot SDK Python process.
pub struct GalbotG1Driver {
    _child: Child,
    stdin: ChildStdin,
    stdout: BufReader<ChildStdout>,
    ready_timeout: Duration,
    response_timeout: Duration,
    ready: bool,
    last_ee_poses: BTreeMap<String, Pose6D>,
    last_grippers: BTreeMap<String, f32>,
    last_joints: Vec<f64>,
    connected: bool,
}

impl GalbotG1Driver {
    pub fn new(cfg: &GalbotG1Config) -> Result<Self> {
        let bridge_config =
            serde_json::to_string(cfg).context("serializing Galbot bridge config")?;
        let mut cmd = Command::new(&cfg.python);
        cmd.arg(&cfg.script)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .env("GALBOT_G1_BRIDGE_CONFIG", bridge_config)
            .kill_on_drop(true);

        let mut child = cmd.spawn().with_context(|| {
            format!(
                "failed to spawn Galbot G1 bridge: '{} {}'",
                cfg.python, cfg.script
            )
        })?;

        let stdin = child
            .stdin
            .take()
            .ok_or_else(|| anyhow!("Galbot bridge stdin not piped"))?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| anyhow!("Galbot bridge stdout not piped"))?;

        tracing::info!(
            "Galbot G1 bridge spawned: python={} script={}",
            cfg.python,
            cfg.script
        );

        Ok(Self {
            _child: child,
            stdin,
            stdout: BufReader::new(stdout),
            ready_timeout: Duration::from_millis(cfg.ready_timeout_ms),
            response_timeout: Duration::from_millis(cfg.response_timeout_ms),
            ready: false,
            last_ee_poses: BTreeMap::new(),
            last_grippers: BTreeMap::new(),
            last_joints: Vec::new(),
            connected: false,
        })
    }

    pub fn last_ee_poses(&self) -> BTreeMap<String, Pose6D> {
        self.last_ee_poses.clone()
    }

    pub fn last_grippers(&self) -> BTreeMap<String, f32> {
        self.last_grippers.clone()
    }

    pub fn last_joints(&self) -> Vec<f64> {
        self.last_joints.clone()
    }

    pub fn is_connected(&self) -> bool {
        self.connected
    }

    pub async fn enable(&mut self) -> Result<()> {
        if self.ready {
            return Ok(());
        }
        self.await_ready().await?;
        self.ready = true;
        self.connected = true;
        Ok(())
    }

    pub async fn set_targets(
        &mut self,
        targets: &BTreeMap<String, Pose6D>,
        grippers: &BTreeMap<String, f32>,
    ) -> Result<()> {
        if !self.ready {
            anyhow::bail!("GalbotG1Driver::set_targets before enable");
        }
        let req = BridgeRequest::Command {
            ee: targets
                .iter()
                .map(|(name, pose)| (name.as_str(), BridgePose::from(pose)))
                .collect(),
            gripper: grippers
                .iter()
                .map(|(name, value)| (name.as_str(), *value))
                .collect(),
        };
        self.send_request(&req).await
    }

    pub async fn reset_to_initial_pose(&mut self) -> Result<()> {
        if !self.ready {
            anyhow::bail!("GalbotG1Driver::reset_to_initial_pose before enable");
        }
        self.send_request(&BridgeRequest::Reset { reset: true })
            .await
    }

    pub async fn stop(&mut self) -> Result<()> {
        if self.ready {
            if let Err(e) = self.send_request(&BridgeRequest::Stop { stop: true }).await {
                tracing::warn!("Galbot G1 stop request failed (non-fatal): {e}");
            }
        }
        self.connected = false;
        Ok(())
    }

    async fn send_request(&mut self, req: &BridgeRequest<'_>) -> Result<()> {
        let mut line = serde_json::to_vec(req)?;
        line.push(b'\n');
        self.stdin.write_all(&line).await?;
        self.stdin.flush().await?;

        let resp = self.read_line(self.response_timeout).await?;
        self.apply_response(&resp);
        Ok(())
    }

    async fn await_ready(&mut self) -> Result<()> {
        let deadline = tokio::time::Instant::now() + self.ready_timeout;
        for _ in 0..8 {
            let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
            if remaining.is_zero() {
                anyhow::bail!(
                    "Galbot G1 bridge did not become ready within {:?}",
                    self.ready_timeout
                );
            }
            let resp = self.read_line(remaining).await?;
            if resp.event.as_deref() == Some("ready") {
                self.apply_response(&resp);
                tracing::info!(
                    "Galbot G1 bridge ready: ee={:?} grippers={:?}",
                    self.last_ee_poses.keys().collect::<Vec<_>>(),
                    self.last_grippers
                );
                return Ok(());
            }
            tracing::debug!("discarding non-ready Galbot bridge line: {resp:?}");
        }
        anyhow::bail!("did not receive Galbot bridge `ready` event in the first 8 lines")
    }

    async fn read_line(&mut self, wait: Duration) -> Result<BridgeResponse> {
        let mut line = String::new();
        let n = timeout(wait, self.stdout.read_line(&mut line))
            .await
            .map_err(|_| anyhow!("Galbot bridge response timeout after {:?}", wait))??;
        if n == 0 {
            anyhow::bail!("Galbot bridge stdout EOF; Python process exited");
        }
        let trimmed = line.trim();
        if trimmed.is_empty() {
            anyhow::bail!("Galbot bridge sent empty line");
        }
        let resp: BridgeResponse = serde_json::from_str(trimmed)
            .with_context(|| format!("bad JSON from Galbot bridge: {trimmed:?}"))?;
        if let Some(err) = &resp.error {
            anyhow::bail!("Galbot bridge error: {err}");
        }
        Ok(resp)
    }

    fn apply_response(&mut self, resp: &BridgeResponse) {
        for (name, pose) in &resp.ee {
            self.last_ee_poses.insert(name.clone(), Pose6D::from(pose));
        }
        for (name, value) in &resp.gripper {
            self.last_grippers.insert(name.clone(), *value);
        }
        if !resp.joints.is_empty() {
            self.last_joints = resp.joints.clone();
        }
        if let Some(connected) = resp.connected {
            self.connected = connected;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const IDENTITY_QUAT: [f64; 4] = [0.0, 0.0, 0.0, 1.0];

    #[test]
    fn command_request_serialises_to_expected_shape() {
        let mut targets = BTreeMap::new();
        targets.insert(
            "left_arm",
            Pose6D {
                position: [0.1, 0.2, 0.3],
                rotation: IDENTITY_QUAT,
            },
        );
        let mut grippers = BTreeMap::new();
        grippers.insert("left_gripper", 0.25);
        let req = BridgeRequest::Command {
            ee: targets
                .iter()
                .map(|(name, pose)| (*name, BridgePose::from(pose)))
                .collect(),
            gripper: grippers
                .iter()
                .map(|(name, value)| (*name, *value))
                .collect(),
        };

        let s = serde_json::to_string(&req).unwrap();
        assert!(
            s.contains(
                "\"ee\":{\"left_arm\":{\"position\":[0.1,0.2,0.3],\"rotation\":[0.0,0.0,0.0,1.0]}}"
            ),
            "got {s}"
        );
        assert!(s.contains("\"gripper\":{\"left_gripper\":0.25}"), "got {s}");
        assert!(!s.contains("Command"), "untagged variant leaked tag: {s}");
    }

    #[test]
    fn reset_request_serialises_to_expected_shape() {
        let s = serde_json::to_string(&BridgeRequest::Reset { reset: true }).unwrap();
        assert_eq!(s, "{\"reset\":true}");
    }

    #[test]
    fn ready_response_deserialises() {
        let raw = r#"{"event":"ready","ee":{"left_arm":{"position":[0.1,0.2,0.3],"rotation":[0.0,0.0,0.0,1.0]}},"gripper":{"left_gripper":1.0},"connected":true}"#;
        let resp: BridgeResponse = serde_json::from_str(raw).unwrap();
        assert_eq!(resp.event.as_deref(), Some("ready"));
        assert_eq!(resp.ee["left_arm"].position, [0.1, 0.2, 0.3]);
        assert_eq!(resp.gripper["left_gripper"], 1.0);
        assert_eq!(resp.connected, Some(true));
    }

    #[test]
    fn error_response_deserialises() {
        let raw = r#"{"error":"SDK init failed"}"#;
        let resp: BridgeResponse = serde_json::from_str(raw).unwrap();
        assert_eq!(resp.error.as_deref(), Some("SDK init failed"));
    }
}
