//! UDP data plane for high-frequency pose commands (XR-facing).
//!
//! Copied from `robot/src/network/pose_udp_server.rs` during the bridge/adapter
//! split, re-pointed at `teleop_protocol` types and the bridge-local
//! [`TimedCommand`]. Accepted packets feed the SAME
//! `watch::Sender<Option<TimedCommand>>` the TCP `pose_server` feeds, so the
//! [`forward`](crate::forward) loop is source-agnostic.
//!
//! Listens on `pose_udp_port` (default 63902). Each datagram is parsed as a
//! [`PoseUdpPacket`] (32 B header + variable payload). Drop policies before
//! forwarding:
//!
//! 1. **CRC** — `crc16(payload)` must match the header. Mismatches dropped +
//!    counted.
//! 2. **Drop-old** — `seq <= last_applied_seq` discarded (eliminates Wi-Fi
//!    head-of-line blocking).
//! 3. **Session token** *(optional)* — enforced only when both the current TCP
//!    session and the packet carry a non-zero token.
//!
//! Testability: [`run`] binds the port then delegates to [`run_on`], which
//! takes a pre-bound [`UdpSocket`] so a test can bind `127.0.0.1:0` and read
//! the OS-assigned address.

use std::sync::atomic::{AtomicU32, AtomicU64, Ordering};
use std::sync::Arc;

use anyhow::Result;
use tokio::net::UdpSocket;
use tokio::sync::watch;

use teleop_protocol::{DeviceCommand, Pose6D};

use crate::latency::{self, LatencyRecorder};
use crate::protocol::{PoseUdpDecodeError, PoseUdpPacket, PoseUdpPayload};
use crate::wire_runtime::TimedCommand;

/// Lock-free counters surfaced for the 1Hz aggregator.
#[derive(Default)]
pub struct UdpDropStats {
    pub crc_drop_count: AtomicU64,
    pub stale_drop_count: AtomicU64,
    pub token_drop_count: AtomicU64,
    pub accepted_count: AtomicU64,
}

impl UdpDropStats {
    pub fn new() -> Arc<Self> {
        Arc::new(Self::default())
    }
}

/// Run the UDP pose server, binding `port` on all interfaces. Never returns
/// under normal operation.
pub async fn run(
    port: u16,
    device_cmd_tx: watch::Sender<Option<TimedCommand>>,
    latency: Arc<LatencyRecorder>,
    current_session_token: Arc<AtomicU32>,
    stats: Arc<UdpDropStats>,
) -> Result<()> {
    let socket = UdpSocket::bind(("0.0.0.0", port)).await?;
    run_on(socket, device_cmd_tx, latency, current_session_token, stats).await
}

/// Run the UDP pose server on a pre-bound [`UdpSocket`]. Used by tests that
/// bind an ephemeral port and need to read `local_addr()` first.
///
/// `current_session_token` is read on every packet; a value of 0 means
/// "anonymous mode" (no token enforcement). The TCP `pose_server` is
/// responsible for storing the per-session token here at handshake time.
pub async fn run_on(
    socket: UdpSocket,
    device_cmd_tx: watch::Sender<Option<TimedCommand>>,
    latency: Arc<LatencyRecorder>,
    current_session_token: Arc<AtomicU32>,
    stats: Arc<UdpDropStats>,
) -> Result<()> {
    tracing::info!("Pose UDP server listening on {}", socket.local_addr()?);

    // Drop-old state. Reset on session change so a fresh XR client starting
    // from seq=1 isn't rejected as "old".
    let mut last_applied_seq: u64 = 0;
    let mut last_seen_token: u32 = current_session_token.load(Ordering::Relaxed);

    let mut buf = [0u8; 2048];
    loop {
        let (n, _peer) = match socket.recv_from(&mut buf).await {
            Ok(v) => v,
            Err(e) => {
                tracing::warn!("UDP recv error: {e}");
                continue;
            }
        };

        let pkt = match PoseUdpPacket::decode(&buf[..n]) {
            Ok(p) => p,
            Err(PoseUdpDecodeError::CrcMismatch { .. }) => {
                stats.crc_drop_count.fetch_add(1, Ordering::Relaxed);
                continue;
            }
            Err(e) => {
                tracing::warn!("UDP decode error: {e}");
                continue;
            }
        };

        // Session token check (only enforced when both sides set one).
        let expected = current_session_token.load(Ordering::Relaxed);
        if expected != last_seen_token {
            // TCP handshake just minted a new token → reset drop-old state.
            last_seen_token = expected;
            last_applied_seq = 0;
        }
        if expected != 0 && pkt.session_token != 0 && pkt.session_token != expected {
            stats.token_drop_count.fetch_add(1, Ordering::Relaxed);
            continue;
        }

        // Drop-old.
        if pkt.seq <= last_applied_seq {
            stats.stale_drop_count.fetch_add(1, Ordering::Relaxed);
            continue;
        }
        last_applied_seq = pkt.seq;

        // Translate the payload into a DeviceCommand and feed the same watch
        // channel the TCP path feeds. Preserve the packet's `seq`.
        let cmd = pose_packet_to_device_command(&pkt);
        let t_rx_ns = latency::wall_clock_ns();
        let timed = TimedCommand {
            cmd,
            seq: pkt.seq,
            t_rx_ns,
        };
        let _ = device_cmd_tx.send_replace(Some(timed));
        stats.accepted_count.fetch_add(1, Ordering::Relaxed);

        if pkt.seq % 1000 == 0 {
            tracing::debug!("UDP pose: seq={} delivered", pkt.seq);
        }
        let _ = (&latency,);
    }
}

/// Translate a decoded UDP pose packet into the generic `DeviceCommand` shape.
/// Right now only POSE is supported.
fn pose_packet_to_device_command(pkt: &PoseUdpPacket) -> DeviceCommand {
    let mut cmd = DeviceCommand {
        timestamp_ns: pkt.t_xr_send_ns,
        ..DeviceCommand::default()
    };
    match &pkt.payload {
        PoseUdpPayload::Pose {
            position,
            rotation,
            gripper,
        } => {
            cmd.poses.insert(
                "end_effector".to_string(),
                Pose6D {
                    position: *position,
                    rotation: *rotation,
                },
            );
            cmd.axes.insert("gripper".to_string(), *gripper);
        }
    }
    cmd
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::POSE_UDP_KIND_POSE;

    #[test]
    fn pose_packet_maps_to_end_effector_and_gripper() {
        let pkt = PoseUdpPacket {
            t_xr_send_ns: 999,
            seq: 7,
            session_token: 0,
            descriptor_version: 0,
            flags: 0,
            kind: POSE_UDP_KIND_POSE,
            payload: PoseUdpPayload::Pose {
                position: [1.0, 2.0, 3.0],
                rotation: [0.0, 0.0, 0.0, 1.0],
                gripper: 0.42,
            },
        };
        let cmd = pose_packet_to_device_command(&pkt);
        assert_eq!(cmd.timestamp_ns, 999);
        assert_eq!(*cmd.axes.get("gripper").unwrap(), 0.42);
        let ee = cmd.poses.get("end_effector").unwrap();
        assert_eq!(ee.position, [1.0, 2.0, 3.0]);
        assert_eq!(ee.rotation, [0.0, 0.0, 0.0, 1.0]);
    }
}
