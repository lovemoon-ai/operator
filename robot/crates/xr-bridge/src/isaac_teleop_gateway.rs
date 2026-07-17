//! IsaacTeleop external-input UDP gateway.
//!
//! The bridge validates the shared 32-byte little-endian UDP envelope, applies
//! session-token and per-channel drop-old policies, then forwards the complete
//! original datagram to the Unix datagram socket owned by the Isaac Sim-side
//! plugin. The canonical payload remains opaque to the bridge so a future
//! direct IsaacTeleop FlatBuffers payload can use the same transport.

use std::path::PathBuf;
use std::sync::atomic::{AtomicU32, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;

use anyhow::{ensure, Context, Result};
use tokio::net::{UdpSocket, UnixDatagram};

use crate::config::IsaacTeleopGatewayConfig;
use crate::protocol::{crc16_ccitt, POSE_UDP_HEADER_SIZE};

/// Maximum UDP payload accepted by IPv4 without relying on implementation-
/// specific truncation behaviour. Production defaults to a much smaller MTU-
/// friendly ceiling of 1200 bytes.
const MAX_UDP_DATAGRAM_BYTES: usize = 65_507;
/// In anonymous mode there is no TCP token change to mark a restarted app.
/// After this quiet period, allow the same UDP peer to start a fresh sequence
/// domain. Authenticated sessions never use this heuristic.
const ANONYMOUS_SESSION_IDLE_RESET: Duration = Duration::from_secs(1);

/// Supported external-input channels. Sequence numbers are independent for
/// every entry in this array.
pub const ISAAC_TELEOP_KINDS: [[u8; 4]; 8] = [
    *b"HEAD", *b"LCTL", *b"RCTL", *b"LHND", *b"RHND", *b"BODY", *b"CTRL", *b"ANCH",
];

/// Parsed transport header. The payload is deliberately not decoded in the
/// bridge.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct IsaacTeleopHeader {
    /// Raw headset/device sample timestamp in nanoseconds.
    pub sample_time_raw_device_ns: u64,
    /// Monotonic sequence number within this channel and XR session.
    pub seq: u64,
    /// Session minted by the TCP control plane; zero means anonymous mode.
    pub session_token: u32,
    /// Schema/descriptor version supplied by the sender.
    pub descriptor_version: u16,
    /// Opaque transport flags.
    pub flags: u8,
    /// Reserved transport byte. Senders currently write zero; receivers keep
    /// it for forward compatibility and do not enforce a value.
    pub reserved: u8,
    /// FourCC identifying the external-input channel.
    pub kind: [u8; 4],
    /// Zero-based index into [`ISAAC_TELEOP_KINDS`].
    pub kind_index: usize,
}

/// Datagram validation failures. Only CRC failures have a dedicated runtime
/// counter; other structural failures increment `invalid_drop_count`.
#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum IsaacTeleopDecodeError {
    #[error("datagram is {got} bytes, exceeding configured maximum {max}")]
    Oversized { got: usize, max: usize },
    #[error("packet too short: {got} bytes < {need}")]
    TooShort { got: usize, need: usize },
    #[error("datagram length {got} does not match header length {expected}")]
    LengthMismatch { got: usize, expected: usize },
    #[error("unknown IsaacTeleop channel kind {kind:?}")]
    UnknownKind { kind: [u8; 4] },
    #[error("crc mismatch: header=0x{header:04x}, computed=0x{computed:04x}")]
    CrcMismatch { header: u16, computed: u16 },
}

/// Validate and parse an IsaacTeleop transport datagram.
///
/// CRC-16/CCITT-FALSE covers the payload only, matching the existing pose UDP
/// packet in [`crate::protocol`]. Exact length is required so trailing bytes
/// cannot bypass the configured datagram ceiling.
pub fn decode_datagram(
    data: &[u8],
    max_datagram_bytes: usize,
) -> Result<IsaacTeleopHeader, IsaacTeleopDecodeError> {
    if data.len() > max_datagram_bytes {
        return Err(IsaacTeleopDecodeError::Oversized {
            got: data.len(),
            max: max_datagram_bytes,
        });
    }
    if data.len() < POSE_UDP_HEADER_SIZE {
        return Err(IsaacTeleopDecodeError::TooShort {
            got: data.len(),
            need: POSE_UDP_HEADER_SIZE,
        });
    }

    let payload_len = u16::from_le_bytes(data[22..24].try_into().unwrap()) as usize;
    let expected_len = POSE_UDP_HEADER_SIZE + payload_len;
    if data.len() != expected_len {
        return Err(IsaacTeleopDecodeError::LengthMismatch {
            got: data.len(),
            expected: expected_len,
        });
    }

    let kind: [u8; 4] = data[28..32].try_into().unwrap();
    let Some(kind_index) = ISAAC_TELEOP_KINDS
        .iter()
        .position(|candidate| *candidate == kind)
    else {
        return Err(IsaacTeleopDecodeError::UnknownKind { kind });
    };

    let crc_header = u16::from_le_bytes(data[24..26].try_into().unwrap());
    let crc_computed = crc16_ccitt(&data[POSE_UDP_HEADER_SIZE..]);
    if crc_computed != crc_header {
        return Err(IsaacTeleopDecodeError::CrcMismatch {
            header: crc_header,
            computed: crc_computed,
        });
    }

    Ok(IsaacTeleopHeader {
        sample_time_raw_device_ns: u64::from_le_bytes(data[0..8].try_into().unwrap()),
        seq: u64::from_le_bytes(data[8..16].try_into().unwrap()),
        session_token: u32::from_le_bytes(data[16..20].try_into().unwrap()),
        descriptor_version: u16::from_le_bytes(data[20..22].try_into().unwrap()),
        flags: data[26],
        reserved: data[27],
        kind,
        kind_index,
    })
}

/// Lock-free gateway counters. They are safe to sample from telemetry or a
/// diagnostic task without taking locks in the input path.
#[derive(Default)]
pub struct IsaacTeleopGatewayStats {
    pub accepted_count: AtomicU64,
    pub crc_drop_count: AtomicU64,
    pub stale_drop_count: AtomicU64,
    pub token_drop_count: AtomicU64,
    pub io_drop_count: AtomicU64,
    pub invalid_drop_count: AtomicU64,
}

impl IsaacTeleopGatewayStats {
    pub fn new() -> Arc<Self> {
        Arc::new(Self::default())
    }

    /// Read all counters with relaxed ordering for diagnostics.
    pub fn snapshot(&self) -> IsaacTeleopGatewayStatsSnapshot {
        IsaacTeleopGatewayStatsSnapshot {
            accepted: self.accepted_count.load(Ordering::Relaxed),
            crc_drops: self.crc_drop_count.load(Ordering::Relaxed),
            stale_drops: self.stale_drop_count.load(Ordering::Relaxed),
            token_drops: self.token_drop_count.load(Ordering::Relaxed),
            io_drops: self.io_drop_count.load(Ordering::Relaxed),
            invalid_drops: self.invalid_drop_count.load(Ordering::Relaxed),
        }
    }
}

/// Point-in-time diagnostic view of [`IsaacTeleopGatewayStats`].
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct IsaacTeleopGatewayStatsSnapshot {
    pub accepted: u64,
    pub crc_drops: u64,
    pub stale_drops: u64,
    pub token_drops: u64,
    pub io_drops: u64,
    pub invalid_drops: u64,
}

/// Bind the configured UDP port and forward accepted packets to the configured
/// Unix datagram destination. Never returns during normal operation.
pub async fn run(
    config: IsaacTeleopGatewayConfig,
    current_session_token: Arc<AtomicU32>,
    stats: Arc<IsaacTeleopGatewayStats>,
) -> Result<()> {
    validate_config(&config)?;
    let socket = UdpSocket::bind(("0.0.0.0", config.udp_port))
        .await
        .with_context(|| format!("binding IsaacTeleop UDP port {}", config.udp_port))?;
    let output = UnixDatagram::unbound().context("creating IsaacTeleop Unix datagram sender")?;
    run_on(
        socket,
        output,
        config.unix_socket,
        config.max_datagram_bytes,
        current_session_token,
        stats,
    )
    .await
}

fn validate_config(config: &IsaacTeleopGatewayConfig) -> Result<()> {
    ensure!(
        config.max_datagram_bytes >= POSE_UDP_HEADER_SIZE,
        "isaac_teleop.max_datagram_bytes must be at least {POSE_UDP_HEADER_SIZE}"
    );
    ensure!(
        config.max_datagram_bytes <= MAX_UDP_DATAGRAM_BYTES,
        "isaac_teleop.max_datagram_bytes must not exceed {MAX_UDP_DATAGRAM_BYTES}"
    );
    ensure!(
        !config.unix_socket.as_os_str().is_empty(),
        "isaac_teleop.unix_socket must not be empty"
    );
    Ok(())
}

/// Run with pre-created sockets, primarily for deterministic async tests.
pub async fn run_on(
    socket: UdpSocket,
    output: UnixDatagram,
    unix_socket: PathBuf,
    max_datagram_bytes: usize,
    current_session_token: Arc<AtomicU32>,
    stats: Arc<IsaacTeleopGatewayStats>,
) -> Result<()> {
    ensure!(
        (POSE_UDP_HEADER_SIZE..=MAX_UDP_DATAGRAM_BYTES).contains(&max_datagram_bytes),
        "invalid IsaacTeleop maximum datagram size {max_datagram_bytes}"
    );

    tracing::info!(
        udp = %socket.local_addr()?,
        unix_socket = %unix_socket.display(),
        max_datagram_bytes,
        "IsaacTeleop gateway listening"
    );

    // One extra byte makes an oversized datagram distinguishable from an
    // exactly-max-sized packet even though UDP recv truncates to the buffer.
    let mut buf = vec![0u8; max_datagram_bytes + 1];
    let mut last_applied_seq = [0u64; ISAAC_TELEOP_KINDS.len()];
    let mut last_seen_token = current_session_token.load(Ordering::Relaxed);
    let mut anonymous_peer = None;
    let mut last_anonymous_accept = None;
    let mut stats_interval = tokio::time::interval(tokio::time::Duration::from_secs(10));
    stats_interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    stats_interval.tick().await;

    loop {
        tokio::select! {
            receive = socket.recv_from(&mut buf) => {
                let (n, peer) = match receive {
                    Ok(value) => value,
                    Err(error) => {
                        stats.io_drop_count.fetch_add(1, Ordering::Relaxed);
                        tracing::warn!(%error, "IsaacTeleop UDP receive failed");
                        tokio::task::yield_now().await;
                        continue;
                    }
                };

                let header = match decode_datagram(&buf[..n], max_datagram_bytes) {
                    Ok(header) => header,
                    Err(IsaacTeleopDecodeError::CrcMismatch { .. }) => {
                        stats.crc_drop_count.fetch_add(1, Ordering::Relaxed);
                        continue;
                    }
                    Err(error) => {
                        stats.invalid_drop_count.fetch_add(1, Ordering::Relaxed);
                        tracing::debug!(%peer, %error, "invalid IsaacTeleop UDP datagram");
                        continue;
                    }
                };

                // Match pose_udp_server: enforce only when both the current
                // TCP session and packet carry non-zero tokens. A token change
                // starts a fresh sequence domain for every channel.
                let expected_token = current_session_token.load(Ordering::Relaxed);
                if expected_token != last_seen_token {
                    last_seen_token = expected_token;
                    last_applied_seq.fill(0);
                    anonymous_peer = None;
                    last_anonymous_accept = None;
                }
                if expected_token != 0
                    && header.session_token != 0
                    && header.session_token != expected_token
                {
                    stats.token_drop_count.fetch_add(1, Ordering::Relaxed);
                    continue;
                }

                // Token zero is intentionally an unauthenticated development
                // mode. Recover an anonymous app restart from seq=1 when its
                // UDP source address changes, or after the prior source has
                // been quiet for one second (covering port reuse).
                let now = tokio::time::Instant::now();
                if expected_token == 0 {
                    let peer_changed = anonymous_peer.is_some_and(|previous| previous != peer);
                    let idle_restart = last_anonymous_accept
                        .is_some_and(|accepted_at| now.duration_since(accepted_at) >= ANONYMOUS_SESSION_IDLE_RESET);
                    if peer_changed || idle_restart {
                        last_applied_seq.fill(0);
                    }
                    anonymous_peer = Some(peer);
                }

                let channel_seq = &mut last_applied_seq[header.kind_index];
                if header.seq <= *channel_seq {
                    stats.stale_drop_count.fetch_add(1, Ordering::Relaxed);
                    continue;
                }

                match output.send_to(&buf[..n], &unix_socket).await {
                    Ok(sent) if sent == n => {
                        *channel_seq = header.seq;
                        stats.accepted_count.fetch_add(1, Ordering::Relaxed);
                        if expected_token == 0 {
                            last_anonymous_accept = Some(now);
                        }
                    }
                    Ok(sent) => {
                        stats.io_drop_count.fetch_add(1, Ordering::Relaxed);
                        tracing::warn!(sent, expected = n, "short IsaacTeleop Unix datagram send");
                    }
                    Err(error) => {
                        stats.io_drop_count.fetch_add(1, Ordering::Relaxed);
                        tracing::debug!(
                            %error,
                            unix_socket = %unix_socket.display(),
                            "IsaacTeleop Unix datagram send failed"
                        );
                    }
                }
            }
            _ = stats_interval.tick() => {
                let snapshot = stats.snapshot();
                tracing::debug!(
                    accepted = snapshot.accepted,
                    crc_drops = snapshot.crc_drops,
                    stale_drops = snapshot.stale_drops,
                    token_drops = snapshot.token_drops,
                    io_drops = snapshot.io_drops,
                    invalid_drops = snapshot.invalid_drops,
                    "IsaacTeleop gateway stats"
                );
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;
    use std::sync::atomic::AtomicU64 as TestAtomicU64;
    use std::time::Duration;

    static NEXT_SOCKET_ID: TestAtomicU64 = TestAtomicU64::new(0);

    fn packet(kind: [u8; 4], seq: u64, token: u32, payload: &[u8]) -> Vec<u8> {
        let mut bytes = Vec::with_capacity(POSE_UDP_HEADER_SIZE + payload.len());
        bytes.extend_from_slice(&123_456_789u64.to_le_bytes());
        bytes.extend_from_slice(&seq.to_le_bytes());
        bytes.extend_from_slice(&token.to_le_bytes());
        bytes.extend_from_slice(&1u16.to_le_bytes());
        bytes.extend_from_slice(&(payload.len() as u16).to_le_bytes());
        bytes.extend_from_slice(&crc16_ccitt(payload).to_le_bytes());
        bytes.push(0);
        bytes.push(0);
        bytes.extend_from_slice(&kind);
        bytes.extend_from_slice(payload);
        bytes
    }

    fn socket_path(label: &str) -> PathBuf {
        let id = NEXT_SOCKET_ID.fetch_add(1, Ordering::Relaxed);
        std::env::temp_dir().join(format!(
            "operator-isaacteleop-{label}-{}-{id}.sock",
            std::process::id()
        ))
    }

    async fn wait_for_counter(counter: &AtomicU64, expected: u64) {
        tokio::time::timeout(Duration::from_secs(1), async {
            while counter.load(Ordering::Relaxed) < expected {
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("counter did not update");
    }

    #[test]
    fn decodes_every_supported_kind_and_all_header_fields() {
        for kind in ISAAC_TELEOP_KINDS {
            let bytes = packet(kind, 42, 0xAABBCCDD, b"canonical-payload");
            let header = decode_datagram(&bytes, 1200).unwrap();
            assert_eq!(header.sample_time_raw_device_ns, 123_456_789);
            assert_eq!(header.seq, 42);
            assert_eq!(header.session_token, 0xAABBCCDD);
            assert_eq!(header.descriptor_version, 1);
            assert_eq!(header.flags, 0);
            assert_eq!(header.reserved, 0);
            assert_eq!(header.kind, kind);
        }
    }

    #[test]
    fn rejects_crc_length_kind_and_oversize_errors() {
        let mut bad_crc = packet(*b"HEAD", 1, 0, b"payload");
        *bad_crc.last_mut().unwrap() ^= 0x80;
        assert!(matches!(
            decode_datagram(&bad_crc, 1200),
            Err(IsaacTeleopDecodeError::CrcMismatch { .. })
        ));

        let trailing = [packet(*b"HEAD", 1, 0, b"x"), vec![0]].concat();
        assert!(matches!(
            decode_datagram(&trailing, 1200),
            Err(IsaacTeleopDecodeError::LengthMismatch { .. })
        ));

        let unknown = packet(*b"NOPE", 1, 0, b"x");
        assert!(matches!(
            decode_datagram(&unknown, 1200),
            Err(IsaacTeleopDecodeError::UnknownKind { .. })
        ));

        let oversized = packet(*b"HEAD", 1, 0, &[0; 64]);
        assert!(matches!(
            decode_datagram(&oversized, 64),
            Err(IsaacTeleopDecodeError::Oversized { .. })
        ));
    }

    #[tokio::test]
    async fn forwards_exact_original_datagram() {
        let path = socket_path("exact");
        let receiver = UnixDatagram::bind(&path).unwrap();
        let input = UdpSocket::bind(("127.0.0.1", 0)).await.unwrap();
        let input_addr = input.local_addr().unwrap();
        let output = UnixDatagram::unbound().unwrap();
        let stats = IsaacTeleopGatewayStats::new();
        let worker = tokio::spawn(run_on(
            input,
            output,
            path.clone(),
            1200,
            Arc::new(AtomicU32::new(0)),
            stats.clone(),
        ));

        let client = UdpSocket::bind(("127.0.0.1", 0)).await.unwrap();
        let expected = packet(*b"LHND", 7, 0, b"opaque-canonical-bytes");
        client.send_to(&expected, input_addr).await.unwrap();

        let mut received = [0u8; 1200];
        let n = tokio::time::timeout(Duration::from_secs(1), receiver.recv(&mut received))
            .await
            .unwrap()
            .unwrap();
        assert_eq!(&received[..n], expected.as_slice());
        assert_eq!(stats.snapshot().accepted, 1);

        worker.abort();
        drop(receiver);
        let _ = std::fs::remove_file(path);
    }

    #[tokio::test]
    async fn drop_old_is_independent_per_kind() {
        let path = socket_path("drop-old");
        let receiver = UnixDatagram::bind(&path).unwrap();
        let input = UdpSocket::bind(("127.0.0.1", 0)).await.unwrap();
        let input_addr = input.local_addr().unwrap();
        let stats = IsaacTeleopGatewayStats::new();
        let worker = tokio::spawn(run_on(
            input,
            UnixDatagram::unbound().unwrap(),
            path.clone(),
            1200,
            Arc::new(AtomicU32::new(0)),
            stats.clone(),
        ));
        let client = UdpSocket::bind(("127.0.0.1", 0)).await.unwrap();

        client
            .send_to(&packet(*b"HEAD", 2, 0, b"head-2"), input_addr)
            .await
            .unwrap();
        client
            .send_to(&packet(*b"HEAD", 1, 0, b"head-1"), input_addr)
            .await
            .unwrap();
        client
            .send_to(&packet(*b"LCTL", 1, 0, b"left-1"), input_addr)
            .await
            .unwrap();

        let mut buf = [0u8; 1200];
        for _ in 0..2 {
            tokio::time::timeout(Duration::from_secs(1), receiver.recv(&mut buf))
                .await
                .unwrap()
                .unwrap();
        }
        wait_for_counter(&stats.stale_drop_count, 1).await;
        assert_eq!(stats.snapshot().accepted, 2);

        worker.abort();
        drop(receiver);
        let _ = std::fs::remove_file(path);
    }

    #[tokio::test]
    async fn token_change_resets_sequences_and_anonymous_packets_are_allowed() {
        let path = socket_path("token");
        let receiver = UnixDatagram::bind(&path).unwrap();
        let input = UdpSocket::bind(("127.0.0.1", 0)).await.unwrap();
        let input_addr = input.local_addr().unwrap();
        let token = Arc::new(AtomicU32::new(7));
        let stats = IsaacTeleopGatewayStats::new();
        let worker = tokio::spawn(run_on(
            input,
            UnixDatagram::unbound().unwrap(),
            path.clone(),
            1200,
            token.clone(),
            stats.clone(),
        ));
        let client = UdpSocket::bind(("127.0.0.1", 0)).await.unwrap();

        client
            .send_to(&packet(*b"HEAD", 10, 7, b"session-7"), input_addr)
            .await
            .unwrap();
        client
            .send_to(&packet(*b"LCTL", 1, 0, b"anonymous"), input_addr)
            .await
            .unwrap();
        client
            .send_to(&packet(*b"HEAD", 11, 8, b"wrong-token"), input_addr)
            .await
            .unwrap();
        wait_for_counter(&stats.token_drop_count, 1).await;

        token.store(8, Ordering::Relaxed);
        client
            .send_to(&packet(*b"HEAD", 1, 8, b"session-8"), input_addr)
            .await
            .unwrap();

        let mut buf = [0u8; 1200];
        for _ in 0..3 {
            tokio::time::timeout(Duration::from_secs(1), receiver.recv(&mut buf))
                .await
                .unwrap()
                .unwrap();
        }
        assert_eq!(stats.snapshot().accepted, 3);
        assert_eq!(stats.snapshot().token_drops, 1);

        worker.abort();
        drop(receiver);
        let _ = std::fs::remove_file(path);
    }

    #[tokio::test]
    async fn anonymous_peer_change_starts_a_fresh_sequence_domain() {
        let path = socket_path("anonymous-peer");
        let receiver = UnixDatagram::bind(&path).unwrap();
        let input = UdpSocket::bind(("127.0.0.1", 0)).await.unwrap();
        let input_addr = input.local_addr().unwrap();
        let stats = IsaacTeleopGatewayStats::new();
        let worker = tokio::spawn(run_on(
            input,
            UnixDatagram::unbound().unwrap(),
            path.clone(),
            1200,
            Arc::new(AtomicU32::new(0)),
            stats.clone(),
        ));
        let first_client = UdpSocket::bind(("127.0.0.1", 0)).await.unwrap();
        let restarted_client = UdpSocket::bind(("127.0.0.1", 0)).await.unwrap();

        first_client
            .send_to(&packet(*b"HEAD", 100, 0, b"before-restart"), input_addr)
            .await
            .unwrap();
        let mut buf = [0u8; 1200];
        tokio::time::timeout(Duration::from_secs(1), receiver.recv(&mut buf))
            .await
            .unwrap()
            .unwrap();

        restarted_client
            .send_to(&packet(*b"HEAD", 1, 0, b"after-restart"), input_addr)
            .await
            .unwrap();
        tokio::time::timeout(Duration::from_secs(1), receiver.recv(&mut buf))
            .await
            .unwrap()
            .unwrap();

        assert_eq!(stats.snapshot().accepted, 2);
        assert_eq!(stats.snapshot().stale_drops, 0);

        worker.abort();
        drop(receiver);
        let _ = std::fs::remove_file(path);
    }

    #[tokio::test]
    async fn anonymous_idle_timeout_allows_same_peer_to_restart_sequence() {
        let path = socket_path("anonymous-idle");
        let receiver = UnixDatagram::bind(&path).unwrap();
        let input = UdpSocket::bind(("127.0.0.1", 0)).await.unwrap();
        let input_addr = input.local_addr().unwrap();
        let stats = IsaacTeleopGatewayStats::new();
        let worker = tokio::spawn(run_on(
            input,
            UnixDatagram::unbound().unwrap(),
            path.clone(),
            1200,
            Arc::new(AtomicU32::new(0)),
            stats.clone(),
        ));
        let client = UdpSocket::bind(("127.0.0.1", 0)).await.unwrap();

        client
            .send_to(&packet(*b"RCTL", 100, 0, b"before-idle"), input_addr)
            .await
            .unwrap();
        let mut buf = [0u8; 1200];
        tokio::time::timeout(Duration::from_secs(1), receiver.recv(&mut buf))
            .await
            .unwrap()
            .unwrap();

        tokio::time::sleep(ANONYMOUS_SESSION_IDLE_RESET + Duration::from_millis(50)).await;
        client
            .send_to(&packet(*b"RCTL", 1, 0, b"after-idle"), input_addr)
            .await
            .unwrap();
        tokio::time::timeout(Duration::from_secs(1), receiver.recv(&mut buf))
            .await
            .unwrap()
            .unwrap();

        assert_eq!(stats.snapshot().accepted, 2);
        assert_eq!(stats.snapshot().stale_drops, 0);

        worker.abort();
        drop(receiver);
        let _ = std::fs::remove_file(path);
    }

    #[tokio::test]
    async fn authenticated_peer_change_does_not_reset_sequences() {
        let path = socket_path("authenticated-peer");
        let receiver = UnixDatagram::bind(&path).unwrap();
        let input = UdpSocket::bind(("127.0.0.1", 0)).await.unwrap();
        let input_addr = input.local_addr().unwrap();
        let stats = IsaacTeleopGatewayStats::new();
        let worker = tokio::spawn(run_on(
            input,
            UnixDatagram::unbound().unwrap(),
            path.clone(),
            1200,
            Arc::new(AtomicU32::new(7)),
            stats.clone(),
        ));
        let first_client = UdpSocket::bind(("127.0.0.1", 0)).await.unwrap();
        let other_client = UdpSocket::bind(("127.0.0.1", 0)).await.unwrap();

        first_client
            .send_to(&packet(*b"HEAD", 100, 7, b"authenticated"), input_addr)
            .await
            .unwrap();
        let mut buf = [0u8; 1200];
        tokio::time::timeout(Duration::from_secs(1), receiver.recv(&mut buf))
            .await
            .unwrap()
            .unwrap();

        other_client
            .send_to(&packet(*b"HEAD", 1, 7, b"must-be-stale"), input_addr)
            .await
            .unwrap();
        wait_for_counter(&stats.stale_drop_count, 1).await;
        assert_eq!(stats.snapshot().accepted, 1);

        worker.abort();
        drop(receiver);
        let _ = std::fs::remove_file(path);
    }

    #[tokio::test]
    async fn missing_unix_receiver_counts_io_drop() {
        let path = socket_path("missing");
        let input = UdpSocket::bind(("127.0.0.1", 0)).await.unwrap();
        let input_addr = input.local_addr().unwrap();
        let stats = IsaacTeleopGatewayStats::new();
        let worker = tokio::spawn(run_on(
            input,
            UnixDatagram::unbound().unwrap(),
            path.clone(),
            1200,
            Arc::new(AtomicU32::new(0)),
            stats.clone(),
        ));
        let client = UdpSocket::bind(("127.0.0.1", 0)).await.unwrap();
        client
            .send_to(&packet(*b"BODY", 1, 0, b"body"), input_addr)
            .await
            .unwrap();

        wait_for_counter(&stats.io_drop_count, 1).await;
        assert_eq!(stats.snapshot().accepted, 0);

        worker.abort();
    }
}
