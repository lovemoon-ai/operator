//! LeRobot link driver — hands retargeted end-effector targets to a LeRobot
//! `vr_operator` teleoperator plugin running in a separate `lerobot-teleoperate`
//! process.
//!
//! This driver replaces the old `so101_real` driver. The split is deliberate:
//!
//! * **Rust keeps the retarget.** [`crate::control::pose_mapping::PoseMapper`]
//!   runs *above* the [`ArmDriver`] boundary, so the operator→robot frame math
//!   stays a single implementation shared by the MuJoCo sim and real hardware.
//!   This driver only ever sees a robot base-frame target.
//! * **Python keeps the hardware.** IK, the Feetech bus, and calibration live in
//!   the LeRobot plugin, using LeRobot's own maintained `RobotKinematics` and
//!   `so101_follower` rather than a hand-rolled control script.
//!
//! # Transport
//!
//! Unlike the subprocess drivers, this driver does **not** spawn Python. The
//! adapter *listens* and the plugin *dials in*, so the two processes can be
//! started in either order and restarted independently.
//!
//! Framing is `[4B len LE][JSON]`, matching the bridge↔adapter boundary.
//!
//! ## adapter → plugin
//!
//! ```text
//! {"type":"Target","ee_pose":{"position":[x,y,z],"rotation":[qx,qy,qz,qw]},
//!  "gripper":0.5,"seq":12,"ts_ns":...}      // IK mode: robot base-frame target
//! {"type":"Target","positions":[5 deg],"gripper":0.5,"seq":13,"ts_ns":...}
//!                                           // direct mode: joint passthrough
//! {"type":"Control","enabled":true,"stopped":false,"reset_epoch":0}
//! ```
//!
//! ## plugin → adapter
//!
//! ```text
//! {"type":"Hello","joint_names":[...],"positions":[6 deg],"ee":{...}}
//! {"type":"State","positions":[6 deg],"ee":{...},"ik_error":0.001,"ts_ns":...}
//! {"type":"Error","msg":"..."}
//! ```
//!
//! # Rate decoupling
//!
//! The XR client pushes at ~72 Hz; the LeRobot loop pulls at its own `--fps`
//! (60 by default). Targets therefore go through a `watch` channel: **latest
//! wins, stale frames are dropped**, and [`ArmDriver::set_end_effector_pose`]
//! never blocks on the plugin. This is the opposite of the old request/response
//! subprocess drivers, which wrote a line and awaited a reply — that pattern
//! would stall the 72 Hz command path behind a 60 Hz consumer.
//!
//! `Control` is a *state* channel rather than an event stream so a reconnecting
//! plugin resynchronises automatically; `reset` is an edge, so it is carried as
//! a monotonic `reset_epoch` the plugin compares against its own last-seen value.

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use anyhow::{anyhow, Context, Result};
use async_trait::async_trait;
use bytes::{Buf, BufMut, BytesMut};
use futures::{SinkExt, StreamExt};
use serde::{Deserialize, Serialize};
use teleop_protocol::{listen, Endpoint, Pose6D};
use tokio::sync::{oneshot, watch};
use tokio::task::JoinHandle;
use tokio_util::codec::{Decoder, Encoder, Framed};

use super::ArmDriver;
use crate::control::JointAngles;

/// SO-101 actuator count (5 arm joints + gripper).
pub const NUM_ACTUATORS: usize = 6;
const NUM_ARM_JOINTS: usize = NUM_ACTUATORS - 1;

/// Maximum allowed frame length (1 MiB). Frames here are tiny; anything larger
/// is protocol corruption.
const MAX_FRAME_LEN: usize = 1024 * 1024;

/// Log at most one "no plugin connected" warning per this many dropped frames.
const DROP_WARN_EVERY: u64 = 240;

// ---------------------------------------------------------------------------
// Wire types
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct LinkPose {
    pub position: [f64; 3],
    pub rotation: [f64; 4],
}

impl From<&Pose6D> for LinkPose {
    fn from(value: &Pose6D) -> Self {
        Self {
            position: value.position,
            rotation: value.rotation,
        }
    }
}

impl From<&LinkPose> for Pose6D {
    fn from(value: &LinkPose) -> Self {
        Self {
            position: value.position,
            rotation: value.rotation,
        }
    }
}

/// Messages the adapter sends to the LeRobot plugin.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum AdapterToLerobot {
    /// A setpoint. Exactly one of `ee_pose` (IK mode) or `positions` (direct
    /// mode) is populated.
    Target {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        ee_pose: Option<LinkPose>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        positions: Option<Vec<f64>>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        gripper: Option<f32>,
        seq: u64,
        ts_ns: u64,
    },
    /// Latched control state. Re-sent on every change and on plugin reconnect.
    Control {
        enabled: bool,
        stopped: bool,
        reset_epoch: u64,
    },
}

/// Messages the LeRobot plugin sends back to the adapter.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum LerobotToAdapter {
    /// Sent once on connect. `positions` + `ee` seed the adapter's snapshot;
    /// without them `RobotArmDevice` cannot enter driver-side IK mode.
    Hello {
        #[serde(default)]
        joint_names: Vec<String>,
        #[serde(default)]
        positions: Vec<f64>,
        #[serde(default)]
        ee: Option<LinkPose>,
    },
    /// Periodic state report.
    State {
        #[serde(default)]
        positions: Vec<f64>,
        #[serde(default)]
        ee: Option<LinkPose>,
        #[serde(default)]
        ik_error: Option<f64>,
        #[serde(default)]
        ts_ns: u64,
    },
    /// Plugin-side failure. Surfaced as a driver error on the next write.
    Error { msg: String },
}

// ---------------------------------------------------------------------------
// Codec: [4B len LE][JSON]
// ---------------------------------------------------------------------------

/// Codec used by the **adapter** side: encodes [`AdapterToLerobot`], decodes
/// [`LerobotToAdapter`].
#[derive(Debug, Clone, Copy, Default)]
pub struct LinkCodec;

impl Encoder<AdapterToLerobot> for LinkCodec {
    type Error = std::io::Error;

    fn encode(&mut self, item: AdapterToLerobot, dst: &mut BytesMut) -> Result<(), Self::Error> {
        let json = serde_json::to_vec(&item)
            .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
        if json.len() > MAX_FRAME_LEN {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                format!("frame too large: {} bytes", json.len()),
            ));
        }
        dst.reserve(4 + json.len());
        dst.put_u32_le(json.len() as u32);
        dst.put_slice(&json);
        Ok(())
    }
}

impl Decoder for LinkCodec {
    type Item = LerobotToAdapter;
    type Error = std::io::Error;

    fn decode(&mut self, src: &mut BytesMut) -> Result<Option<Self::Item>, Self::Error> {
        if src.len() < 4 {
            return Ok(None);
        }
        let len = u32::from_le_bytes([src[0], src[1], src[2], src[3]]) as usize;
        if len > MAX_FRAME_LEN {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                format!("frame length {len} exceeds maximum {MAX_FRAME_LEN}"),
            ));
        }
        if src.len() < 4 + len {
            src.reserve(4 + len - src.len());
            return Ok(None);
        }
        src.advance(4);
        let json = src.split_to(len);
        let msg = serde_json::from_slice(&json)
            .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
        Ok(Some(msg))
    }
}

// ---------------------------------------------------------------------------
// Shared state
// ---------------------------------------------------------------------------

/// Control state pushed to the plugin.
///
/// The two gates have STRICTLY separate owners; they used to contend over
/// `enabled` and silently cancel each other out:
///
/// * `stopped` -- the e-stop latch. Owned by `emergency_stop` / the watchdog and
///   cleared by `publish` (fresh targets = the fault is stale) or a reset. The
///   plugin checks it FIRST, so it overrides everything.
/// * `enabled` -- "the operator intends motion". Owned solely by
///   `set_motion_allowed`, driven by the deadman OR an active thumbstick nudge.
///   Nothing else may write it: when `emergency_stop` also cleared it and
///   `publish` re-set it, a released-deadman nudge became nondeterministic.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
struct ControlState {
    enabled: bool,
    stopped: bool,
    reset_epoch: u64,
}

#[derive(Debug, Default)]
struct LinkShared {
    positions_deg: Vec<f64>,
    ee: Option<Pose6D>,
    joint_names: Vec<String>,
    /// Set once the plugin has sent `Hello`.
    seeded: bool,
    /// Latest plugin-reported error, drained by the next driver write.
    plugin_error: Option<String>,
}

// ---------------------------------------------------------------------------
// Driver
// ---------------------------------------------------------------------------

/// Driver that publishes targets to a LeRobot `vr_operator` plugin.
pub struct LerobotLinkDriver {
    target_tx: watch::Sender<Option<AdapterToLerobot>>,
    control_tx: watch::Sender<ControlState>,
    shared: Arc<Mutex<LinkShared>>,
    client_connected: Arc<AtomicBool>,
    hello_rx: Option<oneshot::Receiver<()>>,
    bind_rx: Option<oneshot::Receiver<std::io::Result<Endpoint>>>,
    seq: AtomicU64,
    dropped: AtomicU64,
    hello_timeout: Duration,
    endpoint: Endpoint,
    _task: JoinHandle<()>,
}

impl LerobotLinkDriver {
    /// Bind (asynchronously) and start serving the plugin link.
    ///
    /// Binding happens on the spawned task, so a bind failure surfaces from
    /// [`ArmDriver::enable_torque`] rather than here — that is the point at
    /// which `RobotArmDevice` connects and can report a hard error.
    pub fn new(endpoint: &Endpoint, hello_timeout: Duration) -> Result<Self> {
        let (target_tx, target_rx) = watch::channel(None);
        let (control_tx, control_rx) = watch::channel(ControlState::default());
        let (bind_tx, bind_rx) = oneshot::channel();
        let (hello_tx, hello_rx) = oneshot::channel();

        let shared = Arc::new(Mutex::new(LinkShared::default()));
        let client_connected = Arc::new(AtomicBool::new(false));

        let task = tokio::spawn(serve(
            endpoint.clone(),
            target_rx,
            control_rx,
            Arc::clone(&shared),
            Arc::clone(&client_connected),
            bind_tx,
            hello_tx,
        ));

        tracing::info!("LeRobot link driver starting; listening on {endpoint}");

        Ok(Self {
            target_tx,
            control_tx,
            shared,
            client_connected,
            hello_rx: Some(hello_rx),
            bind_rx: Some(bind_rx),
            seq: AtomicU64::new(0),
            dropped: AtomicU64::new(0),
            hello_timeout,
            endpoint: endpoint.clone(),
            _task: task,
        })
    }

    fn now_ns() -> u64 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos() as u64)
            .unwrap_or(0)
    }

    /// Fail if the plugin reported an error since the last write.
    fn take_plugin_error(&self) -> Result<()> {
        let err = {
            let mut shared = self.shared.lock().unwrap();
            shared.plugin_error.take()
        };
        match err {
            Some(msg) => Err(anyhow!("LeRobot plugin error: {msg}")),
            None => Ok(()),
        }
    }

    /// Publish a setpoint, coalescing it onto the pending one. Never blocks.
    ///
    /// The target channel is a latest-wins `watch`, but a setpoint has two
    /// independent parts — a motion command (an end-effector pose *or* joint
    /// positions) and a gripper value — that arrive as separate calls in direct
    /// mode (`set_joints` then `set_gripper`). A plain latest-wins replace would
    /// let the gripper-only frame clobber the joints frame published microseconds
    /// earlier, silently dropping that frame's motion. So we merge onto whatever
    /// is currently in the slot: a `None` field carries the previous value
    /// forward rather than erasing it.
    ///
    /// This is race-free because every caller is an `&mut self` `ArmDriver`
    /// method and the device holds the driver mutex across the whole
    /// `send_command`, so publishes are serialized. Re-sending an unchanged
    /// motion command when only the gripper moved is harmless — the plugin
    /// re-commands the same joints idempotently.
    fn publish(
        &self,
        ee_pose: Option<LinkPose>,
        positions: Option<Vec<f64>>,
        gripper: Option<f32>,
    ) -> Result<()> {
        self.take_plugin_error()?;
        if !self.client_connected.load(Ordering::Relaxed) {
            let n = self.dropped.fetch_add(1, Ordering::Relaxed);
            if n.is_multiple_of(DROP_WARN_EVERY) {
                tracing::warn!(
                    "LeRobot link: no plugin connected on {}, dropping targets \
                     (start `lerobot-teleoperate --teleop.type=vr_operator`); {} dropped so far",
                    self.endpoint,
                    n + 1
                );
            }
            return Ok(());
        }

        // Self-heal the stop latch. `emergency_stop()` latches `stopped=true`,
        // and it is reached by the bridge's liveness watchdog (headset quiet for
        // command_timeout_ms) as well as by real safety rejections. Nothing on
        // the normal command path used to clear it, so a single 300ms wifi/
        // hand-tracking hiccup left the plugin holding FOREVER -- the arm went
        // dead until the operator happened to press reset (B) or restarted.
        // Reaching here means a fresh, safety-validated target is being written,
        // i.e. the operator is actively driving again, so the stop is stale.
        if self.control_tx.borrow().stopped {
            // Clear ONLY the e-stop latch. `enabled` belongs to
            // `set_motion_allowed`; forcing it true here used to override a
            // deliberate deadman-release and made released-grip nudging work
            // only when the link happened to be stopped.
            self.set_control(|c| c.stopped = false)?;
            tracing::info!("LeRobot link: command flow resumed; clearing stop latch");
        }

        // Merge onto the pending (possibly already-consumed) setpoint.
        let msg = {
            let prev = self.target_tx.borrow();
            merge_target(prev.as_ref(), ee_pose, positions, gripper, self.next_seq(), Self::now_ns())
        };
        // A send error means the serve task is gone, which is fatal.
        self.target_tx
            .send(Some(msg))
            .map_err(|_| anyhow!("LeRobot link serve task terminated"))?;
        Ok(())
    }

    fn next_seq(&self) -> u64 {
        self.seq.fetch_add(1, Ordering::Relaxed)
    }

    fn set_control(&self, f: impl FnOnce(&mut ControlState)) -> Result<()> {
        let mut next = *self.control_tx.borrow();
        f(&mut next);
        self.control_tx
            .send(next)
            .map_err(|_| anyhow!("LeRobot link serve task terminated"))?;
        Ok(())
    }
}

/// Coalesce a new partial setpoint onto the pending one.
///
/// A setpoint has two independent parts: a motion command (an end-effector pose
/// *or* joint positions) and a gripper value. In direct mode these arrive as two
/// calls (`set_joints` then `set_gripper`); on a latest-wins channel the second
/// would clobber the first. Merging preserves both: a `None` field carries the
/// previous value forward. A new motion command replaces the old one wholesale —
/// end-effector and joint modes are mutually exclusive, so a value for either
/// supersedes both.
fn merge_target(
    prev: Option<&AdapterToLerobot>,
    ee_pose: Option<LinkPose>,
    positions: Option<Vec<f64>>,
    gripper: Option<f32>,
    seq: u64,
    ts_ns: u64,
) -> AdapterToLerobot {
    let (prev_ee, prev_pos, prev_grip) = match prev {
        Some(AdapterToLerobot::Target {
            ee_pose,
            positions,
            gripper,
            ..
        }) => (*ee_pose, positions.clone(), *gripper),
        _ => (None, None, None),
    };
    let has_new_motion = ee_pose.is_some() || positions.is_some();
    let (ee_pose, positions) = if has_new_motion {
        (ee_pose, positions)
    } else {
        (prev_ee, prev_pos)
    };
    AdapterToLerobot::Target {
        ee_pose,
        positions,
        gripper: gripper.or(prev_grip),
        seq,
        ts_ns,
    }
}

#[async_trait]
impl ArmDriver for LerobotLinkDriver {
    async fn set_joints(&mut self, joints: &JointAngles) -> Result<()> {
        let n = joints.angles.len().min(NUM_ARM_JOINTS);
        let positions = joints.angles[..n].to_vec();
        self.publish(None, Some(positions), None)
    }

    async fn set_gripper(&mut self, value: f32) -> Result<()> {
        self.publish(None, None, Some(value.clamp(0.0, 1.0)))
    }

    fn supports_end_effector_pose(&self) -> bool {
        true
    }

    async fn set_end_effector_pose(&mut self, target: &Pose6D, gripper: Option<f32>) -> Result<()> {
        self.publish(
            Some(LinkPose::from(target)),
            None,
            gripper.map(|g| g.clamp(0.0, 1.0)),
        )
    }

    fn last_joint_angles(&self) -> Option<JointAngles> {
        let shared = self.shared.lock().unwrap();
        if !shared.seeded {
            return None;
        }
        Some(JointAngles {
            angles: shared.positions_deg.clone(),
        })
    }

    fn last_end_effector_pose(&self) -> Option<Pose6D> {
        let shared = self.shared.lock().unwrap();
        shared.ee.clone()
    }

    async fn reset_to_initial_pose(&mut self) -> Result<()> {
        self.take_plugin_error()?;
        self.set_control(|c| {
            c.reset_epoch += 1;
            c.stopped = false;
        })?;
        tracing::info!("LeRobot link: reset requested");
        Ok(())
    }

    async fn emergency_stop(&mut self) -> Result<()> {
        // Only the stop latch: the plugin checks `stopped` before `enabled`, so
        // this already blocks all motion without stomping on motion intent.
        self.set_control(|c| c.stopped = true)?;
        tracing::warn!("LeRobot link: emergency stop requested");
        Ok(())
    }

    /// Forward MOTION INTENT to the plugin as `Control.enabled`.
    ///
    /// Intent is `deadman held OR stick nudging`, not the deadman alone: the
    /// plugin refuses to act on targets while this is false, so gating it purely
    /// on the deadman made released-grip nudging a no-op.
    ///
    /// Without the edge at all, the plugin only learns the operator let go when
    /// the last target ages past `command_timeout_ms` (500ms), and until then it
    /// keeps re-solving that stale target while its rate limiter slews toward it
    /// — the arm carries on moving for up to half a second after release.
    async fn set_motion_allowed(&mut self, driving: bool) -> Result<()> {
        // Edge-only: this is called per command frame, and a watch send per
        // frame would wake the serve task ~90x/s for no reason.
        if self.control_tx.borrow().enabled == driving {
            return Ok(());
        }
        self.set_control(|c| c.enabled = driving)?;
        tracing::debug!("LeRobot link: motion allowed = {driving}");
        Ok(())
    }

    async fn enable_torque(&mut self) -> Result<()> {
        // Surface a bind failure exactly once, at connect time.
        if let Some(bind_rx) = self.bind_rx.take() {
            match bind_rx.await {
                Ok(Ok(ep)) => tracing::info!("LeRobot link: listening on {ep}"),
                Ok(Err(e)) => {
                    return Err(anyhow::Error::new(e))
                        .with_context(|| format!("LeRobot link failed to bind {}", self.endpoint))
                }
                Err(_) => anyhow::bail!("LeRobot link serve task terminated before binding"),
            }
        }

        // The device contract requires an end-effector snapshot at connect, and
        // only the plugin can produce one (it owns the URDF and forward
        // kinematics). So block here until the plugin says Hello.
        if let Some(hello_rx) = self.hello_rx.take() {
            tracing::info!(
                "LeRobot link: waiting up to {:?} for the vr_operator plugin to connect on {} \
                 (run `lerobot-teleoperate --teleop.type=vr_operator`)",
                self.hello_timeout,
                self.endpoint
            );
            match tokio::time::timeout(self.hello_timeout, hello_rx).await {
                Ok(Ok(())) => {}
                Ok(Err(_)) => anyhow::bail!("LeRobot link serve task terminated before Hello"),
                Err(_) => anyhow::bail!(
                    "no vr_operator plugin connected to {} within {:?}; \
                     start `lerobot-teleoperate --teleop.type=vr_operator --teleop.endpoint={}`",
                    self.endpoint,
                    self.hello_timeout,
                    self.endpoint
                ),
            }
        }

        self.take_plugin_error()?;
        // Link is live but the operator has not asked for motion yet; `enabled`
        // is raised by the first deadman squeeze or stick nudge.
        self.set_control(|c| {
            c.enabled = false;
            c.stopped = false;
        })?;
        tracing::info!("LeRobot link: ready (awaiting operator motion intent)");
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// Serve task
// ---------------------------------------------------------------------------

#[allow(clippy::too_many_arguments)]
async fn serve(
    endpoint: Endpoint,
    target_rx: watch::Receiver<Option<AdapterToLerobot>>,
    control_rx: watch::Receiver<ControlState>,
    shared: Arc<Mutex<LinkShared>>,
    client_connected: Arc<AtomicBool>,
    bind_tx: oneshot::Sender<std::io::Result<Endpoint>>,
    hello_tx: oneshot::Sender<()>,
) {
    let listener = match listen(&endpoint).await {
        Ok(l) => {
            let _ = bind_tx.send(Ok(l.endpoint()));
            l
        }
        Err(e) => {
            tracing::error!("LeRobot link: failed to bind {endpoint}: {e}");
            let _ = bind_tx.send(Err(e));
            return;
        }
    };

    let mut hello_tx = Some(hello_tx);

    loop {
        let conn = match listener.accept().await {
            Ok(c) => c,
            Err(e) => {
                tracing::error!("LeRobot link: accept failed: {e}");
                tokio::time::sleep(Duration::from_millis(200)).await;
                continue;
            }
        };
        tracing::info!("LeRobot link: plugin connected");
        client_connected.store(true, Ordering::Relaxed);

        let reason = handle_client(
            conn,
            target_rx.clone(),
            control_rx.clone(),
            Arc::clone(&shared),
            &mut hello_tx,
        )
        .await;

        client_connected.store(false, Ordering::Relaxed);
        {
            // A disconnected plugin's snapshot is stale; force a fresh Hello
            // before the adapter trusts it again.
            let mut s = shared.lock().unwrap();
            s.seeded = false;
        }
        tracing::warn!("LeRobot link: plugin disconnected ({reason}); awaiting reconnect");
    }
}

async fn handle_client(
    conn: teleop_protocol::Conn,
    mut target_rx: watch::Receiver<Option<AdapterToLerobot>>,
    mut control_rx: watch::Receiver<ControlState>,
    shared: Arc<Mutex<LinkShared>>,
    hello_tx: &mut Option<oneshot::Sender<()>>,
) -> String {
    let mut framed = Framed::new(conn, LinkCodec);

    // Mark current values as seen so we only push changes from here on, then
    // immediately push the latched control state so a reconnecting plugin
    // resynchronises.
    target_rx.mark_unchanged();
    control_rx.mark_unchanged();
    let current = *control_rx.borrow();
    if let Err(e) = framed
        .send(AdapterToLerobot::Control {
            enabled: current.enabled,
            stopped: current.stopped,
            reset_epoch: current.reset_epoch,
        })
        .await
    {
        return format!("control resync write failed: {e}");
    }

    loop {
        tokio::select! {
            // Newest target wins; intermediate values are coalesced by `watch`.
            changed = target_rx.changed() => {
                if changed.is_err() {
                    return "driver dropped".to_string();
                }
                let msg = target_rx.borrow_and_update().clone();
                if let Some(msg) = msg {
                    if let Err(e) = framed.send(msg).await {
                        return format!("target write failed: {e}");
                    }
                }
            }
            changed = control_rx.changed() => {
                if changed.is_err() {
                    return "driver dropped".to_string();
                }
                let c = *control_rx.borrow_and_update();
                if let Err(e) = framed
                    .send(AdapterToLerobot::Control {
                        enabled: c.enabled,
                        stopped: c.stopped,
                        reset_epoch: c.reset_epoch,
                    })
                    .await
                {
                    return format!("control write failed: {e}");
                }
            }
            incoming = framed.next() => {
                match incoming {
                    Some(Ok(msg)) => apply_incoming(msg, &shared, hello_tx),
                    Some(Err(e)) => return format!("read failed: {e}"),
                    None => return "eof".to_string(),
                }
            }
        }
    }
}

fn apply_incoming(
    msg: LerobotToAdapter,
    shared: &Arc<Mutex<LinkShared>>,
    hello_tx: &mut Option<oneshot::Sender<()>>,
) {
    match msg {
        LerobotToAdapter::Hello {
            joint_names,
            positions,
            ee,
        } => {
            {
                let mut s = shared.lock().unwrap();
                s.joint_names = joint_names;
                s.positions_deg = positions;
                s.ee = ee.as_ref().map(Pose6D::from);
                s.seeded = true;
                s.plugin_error = None;
            }
            {
                let s = shared.lock().unwrap();
                tracing::info!(
                    "LeRobot link: plugin Hello joints={:?} positions={:?} ee={:?}",
                    s.joint_names,
                    s.positions_deg,
                    s.ee.as_ref().map(|p| p.position)
                );
            }
            if let Some(tx) = hello_tx.take() {
                let _ = tx.send(());
            }
        }
        LerobotToAdapter::State {
            positions,
            ee,
            ik_error,
            ..
        } => {
            let mut s = shared.lock().unwrap();
            if !positions.is_empty() {
                s.positions_deg = positions;
            }
            if let Some(ee) = ee.as_ref() {
                s.ee = Some(Pose6D::from(ee));
            }
            if let Some(err) = ik_error {
                tracing::trace!("LeRobot link: ik_error={err:.5}");
            }
        }
        LerobotToAdapter::Error { msg } => {
            tracing::error!("LeRobot link: plugin reported error: {msg}");
            let mut s = shared.lock().unwrap();
            s.plugin_error = Some(msg);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn encode(msg: AdapterToLerobot) -> BytesMut {
        let mut buf = BytesMut::new();
        LinkCodec.encode(msg, &mut buf).unwrap();
        buf
    }

    #[test]
    fn target_ee_serialises_without_positions_key() {
        let msg = AdapterToLerobot::Target {
            ee_pose: Some(LinkPose {
                position: [0.1, 0.2, 0.3],
                rotation: [0.0, 0.0, 0.0, 1.0],
            }),
            positions: None,
            gripper: Some(0.5),
            seq: 7,
            ts_ns: 42,
        };
        let s = serde_json::to_string(&msg).unwrap();
        assert!(s.contains(r#""type":"Target""#), "got {s}");
        assert!(
            s.contains(r#""ee_pose":{"position":[0.1,0.2,0.3],"rotation":[0.0,0.0,0.0,1.0]}"#),
            "got {s}"
        );
        assert!(s.contains(r#""gripper":0.5"#), "got {s}");
        assert!(
            !s.contains("positions"),
            "direct-mode key must be absent: {s}"
        );
    }

    #[test]
    fn target_joints_serialises_without_ee_key() {
        let msg = AdapterToLerobot::Target {
            ee_pose: None,
            positions: Some(vec![1.0, 2.0, 3.0, 4.0, 5.0]),
            gripper: None,
            seq: 1,
            ts_ns: 0,
        };
        let s = serde_json::to_string(&msg).unwrap();
        assert!(
            s.contains(r#""positions":[1.0,2.0,3.0,4.0,5.0]"#),
            "got {s}"
        );
        assert!(!s.contains("ee_pose"), "IK-mode key must be absent: {s}");
        assert!(
            !s.contains("gripper"),
            "absent gripper must be omitted: {s}"
        );
    }

    fn motion(msg: &AdapterToLerobot) -> (Option<Vec<f64>>, Option<f32>) {
        match msg {
            AdapterToLerobot::Target {
                positions, gripper, ..
            } => (positions.clone(), *gripper),
            other => panic!("expected Target, got {other:?}"),
        }
    }

    #[test]
    fn merge_gripper_only_preserves_pending_joints() {
        // The finding-4 regression: set_joints then set_gripper in one frame.
        // A latest-wins replace would drop the joints; the merge must keep them.
        let joints = merge_target(None, None, Some(vec![10.0, 20.0, 30.0, 40.0, 50.0]), None, 0, 0);
        let merged = merge_target(Some(&joints), None, None, Some(0.5), 1, 0);
        let (positions, gripper) = motion(&merged);
        assert_eq!(positions, Some(vec![10.0, 20.0, 30.0, 40.0, 50.0]));
        assert_eq!(gripper, Some(0.5));
    }

    #[test]
    fn merge_new_joints_preserves_pending_gripper() {
        let with_grip = merge_target(None, None, None, Some(0.25), 0, 0);
        let merged = merge_target(Some(&with_grip), None, Some(vec![1.0, 2.0, 3.0, 4.0, 5.0]), None, 1, 0);
        let (positions, gripper) = motion(&merged);
        assert_eq!(positions, Some(vec![1.0, 2.0, 3.0, 4.0, 5.0]));
        assert_eq!(gripper, Some(0.25), "gripper set on the previous frame must survive");
    }

    #[test]
    fn merge_new_ee_supersedes_pending_joints() {
        // Motion modes are mutually exclusive: a new EE pose clears stale joints.
        let joints = merge_target(None, None, Some(vec![1.0, 2.0, 3.0, 4.0, 5.0]), Some(0.5), 0, 0);
        let ee = LinkPose {
            position: [0.3, 0.0, 0.2],
            rotation: [0.0, 0.0, 0.0, 1.0],
        };
        let merged = merge_target(Some(&joints), Some(ee), None, None, 1, 0);
        match &merged {
            AdapterToLerobot::Target {
                ee_pose,
                positions,
                gripper,
                ..
            } => {
                assert!(ee_pose.is_some(), "new EE pose must be present");
                assert!(positions.is_none(), "stale joints must be cleared by a new EE pose");
                assert_eq!(*gripper, Some(0.5), "gripper still carries forward");
            }
            other => panic!("expected Target, got {other:?}"),
        }
    }

    #[test]
    fn codec_round_trips_a_frame() {
        let mut buf = encode(AdapterToLerobot::Control {
            enabled: true,
            stopped: false,
            reset_epoch: 3,
        });
        // Decode it back through the mirror-image path the plugin uses.
        let len = u32::from_le_bytes([buf[0], buf[1], buf[2], buf[3]]) as usize;
        assert_eq!(len, buf.len() - 4);
        buf.advance(4);
        let msg: AdapterToLerobot = serde_json::from_slice(&buf).unwrap();
        assert_eq!(
            msg,
            AdapterToLerobot::Control {
                enabled: true,
                stopped: false,
                reset_epoch: 3
            }
        );
    }

    #[test]
    fn codec_decodes_plugin_messages_incrementally() {
        let hello = LerobotToAdapter::Hello {
            joint_names: vec!["shoulder_pan".into()],
            positions: vec![0.0, -90.0, 90.0, 0.0, 0.0, 85.0],
            ee: Some(LinkPose {
                position: [0.25, 0.0, 0.2],
                rotation: [0.0, 0.0, 0.0, 1.0],
            }),
        };
        let json = serde_json::to_vec(&hello).unwrap();
        let mut buf = BytesMut::new();
        buf.put_u32_le(json.len() as u32);

        let mut codec = LinkCodec;
        // Length prefix only: not enough to decode.
        assert!(codec.decode(&mut buf).unwrap().is_none());
        buf.put_slice(&json[..4]);
        // Partial body: still not enough.
        assert!(codec.decode(&mut buf).unwrap().is_none());
        buf.put_slice(&json[4..]);
        assert_eq!(codec.decode(&mut buf).unwrap(), Some(hello));
        assert!(buf.is_empty(), "codec must consume the whole frame");
    }

    #[test]
    fn codec_rejects_oversized_frame() {
        let mut buf = BytesMut::new();
        buf.put_u32_le((MAX_FRAME_LEN + 1) as u32);
        buf.put_slice(b"junk");
        let err = LinkCodec.decode(&mut buf).unwrap_err();
        assert_eq!(err.kind(), std::io::ErrorKind::InvalidData);
    }

    #[test]
    fn state_message_tolerates_missing_optional_fields() {
        let raw = r#"{"type":"State","positions":[1.0,2.0,3.0,4.0,5.0,6.0]}"#;
        let msg: LerobotToAdapter = serde_json::from_str(raw).unwrap();
        match msg {
            LerobotToAdapter::State {
                positions,
                ee,
                ik_error,
                ts_ns,
            } => {
                assert_eq!(positions.len(), NUM_ACTUATORS);
                assert!(ee.is_none());
                assert!(ik_error.is_none());
                assert_eq!(ts_ns, 0);
            }
            other => panic!("expected State, got {other:?}"),
        }
    }

    #[test]
    fn error_message_deserialises() {
        let raw = r#"{"type":"Error","msg":"IK did not converge"}"#;
        let msg: LerobotToAdapter = serde_json::from_str(raw).unwrap();
        assert_eq!(
            msg,
            LerobotToAdapter::Error {
                msg: "IK did not converge".into()
            }
        );
    }
}
