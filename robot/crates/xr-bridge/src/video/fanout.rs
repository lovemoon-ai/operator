//! TCP + UDP fan-out of relayed `TimedVideoFrame`s to connected headsets.
//!
//! Copied from `robot/src/video/pipeline.rs` (`serve_video_clients`,
//! `serve_udp_broadcast`, `build_udp_fragments`) and adapted for the RTSP
//! relay in two ways:
//!
//! 1. Each server takes the per-feed [`ParamSetCache`] so it can **prime a
//!    late-joining client**: when a new client connects (TCP accept, or UDP
//!    "Hello"), first send the cached SPS+PPS, then drop P-frames until the
//!    next IDR arrives, then stream normally. Without this a headset that
//!    joins mid-GOP would feed MediaCodec a bare P-frame and show nothing /
//!    error until the next keyframe.
//! 2. The bind helpers expose a `run_on(TcpListener, …)` seam so tests can use
//!    an ephemeral `127.0.0.1:0` port.
//!
//! The wire format is unchanged: `TimedVideoFrameCodec` over TCP, fragmented
//! `build_udp_fragments` over UDP — byte-identical to the legacy pipeline so
//! the Godot/MediaCodec decode path stays untouched.

use anyhow::Result;
use bytes::BytesMut;
use futures::SinkExt;
use tokio::net::{TcpListener, UdpSocket};
use tokio::sync::broadcast;
use tokio_util::codec::{Encoder, Framed};

use crate::protocol::{TimedVideoFrame, TimedVideoFrameCodec, TIMED_VIDEO_HEADER_BYTES};
use crate::video::nal::{is_keyframe, is_param_set, Codec, ParamSetCache};

/// [opt 9] UDP fan-out maximum payload (NAL + header). See legacy pipeline.
const UDP_MAX_PAYLOAD: usize = 60 * 1024;
/// Per-fragment NAL payload byte budget (keeps the datagram under MTU).
const UDP_NAL_FRAGMENT_PAYLOAD: usize = 1200;
/// Magic bytes prefix on every UDP fragment ("NLFR" = "NAL fragment").
const UDP_FRAGMENT_MAGIC: [u8; 4] = *b"NLFR";
/// Wire-format version of the fragment header.
const UDP_FRAGMENT_VERSION: u8 = 1;
/// Size of the fragment sub-header that precedes the timed video header.
const UDP_FRAGMENT_HEADER_BYTES: usize = 4 + 1 + 1 + 2 + 2 + 8;

// ---------------------------------------------------------------------------
// Join-in-progress priming
// ---------------------------------------------------------------------------

/// What the fan-out should do with one incoming frame for a freshly-joined
/// subscriber that is still waiting for a clean GOP boundary.
#[derive(Debug, PartialEq, Eq)]
pub enum PrimeAction {
    /// Forward this frame to the client.
    Send,
    /// Skip this frame (a P-frame before the first post-join IDR).
    Skip,
}

/// Per-client state machine that decides which frames are safe to forward
/// after a join, so MediaCodec always starts on SPS/PPS + IDR rather than a
/// bare P-frame.
///
/// Lifecycle: construct → emit cached params via [`Self::priming_nals`] (sent
/// once, up front), then call [`Self::on_frame`] for every broadcast frame.
/// Until the first IDR (or fresh param set) arrives after the join, P-frames
/// are dropped. Once started, every frame is forwarded.
pub struct JoinPrimer {
    started: bool,
    codec: Codec,
}

impl Default for JoinPrimer {
    fn default() -> Self {
        Self::new()
    }
}

impl JoinPrimer {
    /// New primer for an H.264 client (the historical default).
    pub fn new() -> Self {
        Self {
            started: false,
            codec: Codec::H264,
        }
    }

    /// New primer for a client of the given codec.
    pub fn with_codec(codec: Codec) -> Self {
        Self {
            started: false,
            codec,
        }
    }

    /// The parameter-set NALs to push to a new client before streaming, in
    /// decode order: `[SPS, PPS]` for H.264, `[VPS, SPS, PPS]` for HEVC. Empty
    /// if the cache hasn't seen the full set yet (the client then starts on the
    /// next live parameter sets + keyframe).
    pub fn priming_nals(cache: &ParamSetCache) -> Vec<Vec<u8>> {
        cache.ordered_param_nals()
    }

    /// Decide whether to forward `nal` to this client.
    ///
    /// - Before the GOP has started: forward parameter sets and keyframe slices
    ///   (the keyframe flips us into the "started" state); skip everything else
    ///   (inter frames).
    /// - After start: forward everything.
    pub fn on_frame(&mut self, nal: &[u8]) -> PrimeAction {
        if self.started {
            return PrimeAction::Send;
        }
        if is_keyframe(nal, self.codec) {
            // First keyframe after join: open the stream from here on.
            self.started = true;
            return PrimeAction::Send;
        }
        if is_param_set(nal, self.codec) {
            // Fresh parameter sets arriving live: forward them (harmless, keeps
            // the decoder's params current) but don't start on them alone.
            return PrimeAction::Send;
        }
        // An inter frame (or any non-key slice) before the first keyframe: drop.
        PrimeAction::Skip
    }

    /// Whether the GOP has started (the first post-join IDR has been seen).
    pub fn started(&self) -> bool {
        self.started
    }
}

// ---------------------------------------------------------------------------
// TCP fan-out
// ---------------------------------------------------------------------------

/// TCP server: accept headset connections, stream timed H.264 packets.
///
/// Binds `0.0.0.0:port` then defers to [`serve_video_clients_on`].
pub async fn serve_video_clients(
    port: u16,
    nal_tx: broadcast::Sender<TimedVideoFrame>,
    params: ParamSetCache,
) -> Result<()> {
    let listener = TcpListener::bind(("0.0.0.0", port)).await?;
    tracing::info!("Video server listening on port {port}");
    serve_video_clients_on(listener, nal_tx, params).await
}

/// Same as [`serve_video_clients`] but takes an already-bound listener so
/// tests can use an ephemeral `127.0.0.1:0` port.
pub async fn serve_video_clients_on(
    listener: TcpListener,
    nal_tx: broadcast::Sender<TimedVideoFrame>,
    params: ParamSetCache,
) -> Result<()> {
    loop {
        let (socket, addr) = listener.accept().await?;
        socket.set_nodelay(true)?;
        tracing::info!("Video client connected from {addr}");

        // Subscribe BEFORE sending priming frames so we don't miss the IDR
        // that arrives between priming and the first recv().
        let mut nal_rx = nal_tx.subscribe();
        let params = params.clone();

        tokio::spawn(async move {
            let mut framed = Framed::new(socket, TimedVideoFrameCodec);
            let mut primer = JoinPrimer::with_codec(params.codec());

            // 1. Prime with cached SPS+PPS as one access unit so MediaCodec
            // sees both parameter sets before it configures.
            for frame in priming_frames(JoinPrimer::priming_nals(&params), now_ns()) {
                if framed.send(frame).await.is_err() {
                    tracing::info!("Video client disconnected from {addr}");
                    return;
                }
            }

            // 2. Stream from the broadcast, dropping P-frames until the first IDR.
            loop {
                match nal_rx.recv().await {
                    Ok(packet) => {
                        if primer.on_frame(&packet.nal) == PrimeAction::Skip {
                            continue;
                        }
                        let packet = packet.with_send_ns(now_ns());
                        if framed.send(packet).await.is_err() {
                            break;
                        }
                    }
                    Err(broadcast::error::RecvError::Lagged(n)) => {
                        tracing::warn!("Video client {addr} lagged {n} frames, skipping");
                    }
                    Err(broadcast::error::RecvError::Closed) => break,
                }
            }
            tracing::info!("Video client disconnected from {addr}");
        });
    }
}

// ---------------------------------------------------------------------------
// UDP fan-out
// ---------------------------------------------------------------------------

/// UDP fan-out. Same `TimedVideoFrame` framing as the TCP path (fragmented).
/// Clients register by sending a "Hello" datagram; each new client is primed
/// with SPS/PPS and then waits for the next IDR before P-frames flow.
pub async fn serve_udp_broadcast(
    port: u16,
    nal_rx: broadcast::Receiver<TimedVideoFrame>,
    params: ParamSetCache,
) -> Result<()> {
    let socket = UdpSocket::bind(("0.0.0.0", port)).await?;
    socket.set_broadcast(true)?;
    tracing::info!("UDP video server listening on port {port}");
    serve_udp_broadcast_on(socket, nal_rx, params).await
}

/// Same as [`serve_udp_broadcast`] but takes an already-bound socket so tests
/// can use an ephemeral `127.0.0.1:0` port.
pub async fn serve_udp_broadcast_on(
    socket: UdpSocket,
    mut nal_rx: broadcast::Receiver<TimedVideoFrame>,
    params: ParamSetCache,
) -> Result<()> {
    use std::collections::HashMap;
    use std::net::SocketAddr;

    let mut codec = TimedVideoFrameCodec;
    // Per-client primer: drop P-frames until the client has seen an IDR.
    let mut clients: HashMap<SocketAddr, JoinPrimer> = HashMap::new();
    let mut hello_buf = vec![0u8; 1024];

    loop {
        tokio::select! {
            recv = socket.recv_from(&mut hello_buf) => {
                if let Ok((n, addr)) = recv {
                    let payload = &hello_buf[..n];
                    if payload.starts_with(b"Hello") && !clients.contains_key(&addr) {
                        tracing::info!("UDP video client registered: {addr}");
                        clients.insert(addr, JoinPrimer::with_codec(params.codec()));
                        // Prime the new client with cached SPS+PPS as one
                        // access unit.
                        for frame in priming_frames(JoinPrimer::priming_nals(&params), now_ns()) {
                            if let Some(datagrams) = build_udp_fragments(&mut codec, frame) {
                                for d in &datagrams {
                                    let _ = socket.send_to(d, addr).await;
                                }
                            }
                        }
                    }
                }
            }
            packet = nal_rx.recv() => {
                let packet = match packet {
                    Ok(p) => p,
                    Err(broadcast::error::RecvError::Lagged(n)) => {
                        tracing::warn!("UDP video lagged {n} frames");
                        continue;
                    }
                    Err(broadcast::error::RecvError::Closed) => return Ok(()),
                };
                if clients.is_empty() {
                    continue;
                }
                let stamped = packet.with_send_ns(now_ns());
                let datagrams = match build_udp_fragments(&mut codec, stamped.clone()) {
                    Some(d) => d,
                    None => continue,
                };
                for (addr, primer) in clients.iter_mut() {
                    if primer.on_frame(&stamped.nal) == PrimeAction::Skip {
                        continue;
                    }
                    for datagram in &datagrams {
                        let _ = socket.send_to(datagram, addr).await;
                    }
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Wrap cached SPS/PPS NALs into one priming access unit.
///
/// `frame_id` is left 0 and the timing fields are zeroed except `send_ns`; the
/// headset only needs the NAL bytes from priming frames. Keeping `nal_count`
/// greater than one matters: the Godot side concatenates the NALs before
/// calling MediaCodec, which lets the decoder configure with both SPS and PPS.
fn priming_frames(nals: Vec<Vec<u8>>, send_ns: u64) -> Vec<TimedVideoFrame> {
    let nal_count = nals.len() as u32;
    nals.into_iter()
        .enumerate()
        .map(|(idx, nal)| TimedVideoFrame {
            frame_id: 0,
            nal_index: idx as u32,
            nal_count,
            pipeline_mode: crate::protocol::VIDEO_PIPELINE_MODE_FFMPEG,
            capture_start_ns: 0,
            capture_end_ns: 0,
            encode_start_ns: 0,
            encode_end_ns: 0,
            read_wait_ns: 0,
            parse_ns: 0,
            send_ns,
            nal,
        })
        .collect()
}

/// Encode a `TimedVideoFrame` for UDP transport, splitting the NAL into
/// MTU-sized fragments. Copied verbatim from the legacy pipeline.
pub fn build_udp_fragments(
    codec: &mut TimedVideoFrameCodec,
    packet: TimedVideoFrame,
) -> Option<Vec<Vec<u8>>> {
    let frame_id = packet.frame_id;

    let mut timed_buf = BytesMut::with_capacity(128 + packet.nal.len());
    if codec.encode(packet, &mut timed_buf).is_err() {
        return None;
    }
    let timed_header = &timed_buf[..TIMED_VIDEO_HEADER_BYTES];
    let nal_bytes = &timed_buf[TIMED_VIDEO_HEADER_BYTES..];

    let nal_len = nal_bytes.len();
    let fragment_count = if nal_len == 0 {
        1
    } else {
        nal_len.div_ceil(UDP_NAL_FRAGMENT_PAYLOAD)
    };
    if fragment_count > u16::MAX as usize {
        tracing::warn!(
            "NAL too large to fragment ({} bytes -> {} fragments), dropping",
            nal_len,
            fragment_count,
        );
        return None;
    }

    let mut out: Vec<Vec<u8>> = Vec::with_capacity(fragment_count);
    for frag_idx in 0..fragment_count {
        let start = frag_idx * UDP_NAL_FRAGMENT_PAYLOAD;
        let end = ((frag_idx + 1) * UDP_NAL_FRAGMENT_PAYLOAD).min(nal_len);
        let payload_slice = &nal_bytes[start..end];

        let mut datagram = Vec::with_capacity(
            UDP_FRAGMENT_HEADER_BYTES + TIMED_VIDEO_HEADER_BYTES + payload_slice.len(),
        );
        datagram.extend_from_slice(&UDP_FRAGMENT_MAGIC);
        datagram.push(UDP_FRAGMENT_VERSION);
        let mut flags: u8 = 0;
        if frag_idx == 0 {
            flags |= 0b0000_0010;
        }
        if frag_idx + 1 == fragment_count {
            flags |= 0b0000_0001;
        }
        datagram.push(flags);
        datagram.extend_from_slice(&(frag_idx as u16).to_be_bytes());
        datagram.extend_from_slice(&(fragment_count as u16).to_be_bytes());
        datagram.extend_from_slice(&frame_id.to_be_bytes());
        datagram.extend_from_slice(timed_header);
        datagram.extend_from_slice(payload_slice);

        debug_assert!(datagram.len() <= UDP_MAX_PAYLOAD);
        out.push(datagram);
    }
    Some(out)
}

fn now_ns() -> u64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos() as u64)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    // These H.264 assertion helpers are no longer imported at file scope (the
    // fan-out now uses the codec-aware variants), so bring them in here.
    use crate::video::nal::{is_idr, is_param};

    fn sps() -> Vec<u8> {
        vec![0x00, 0x00, 0x00, 0x01, 0x67, 0xAA]
    }
    fn pps() -> Vec<u8> {
        vec![0x00, 0x00, 0x00, 0x01, 0x68, 0xBB]
    }
    fn idr() -> Vec<u8> {
        vec![0x00, 0x00, 0x00, 0x01, 0x65, 0x01]
    }
    fn p(n: u8) -> Vec<u8> {
        vec![0x00, 0x00, 0x00, 0x01, 0x41, n]
    }

    #[test]
    fn primer_skips_pframes_until_first_idr() {
        let mut primer = JoinPrimer::new();
        // Mid-stream join: a run of P-frames must be skipped.
        assert_eq!(primer.on_frame(&p(1)), PrimeAction::Skip);
        assert_eq!(primer.on_frame(&p(2)), PrimeAction::Skip);
        assert!(!primer.started());
        // Live SPS/PPS may arrive before the IDR — forward them, still not started.
        assert_eq!(primer.on_frame(&sps()), PrimeAction::Send);
        assert_eq!(primer.on_frame(&pps()), PrimeAction::Send);
        assert!(!primer.started());
        // A P-frame between params and IDR is still dropped.
        assert_eq!(primer.on_frame(&p(3)), PrimeAction::Skip);
        // The IDR starts the GOP.
        assert_eq!(primer.on_frame(&idr()), PrimeAction::Send);
        assert!(primer.started());
        // Everything after the IDR flows, including P-frames.
        assert_eq!(primer.on_frame(&p(4)), PrimeAction::Send);
        assert_eq!(primer.on_frame(&p(5)), PrimeAction::Send);
    }

    #[test]
    fn primer_never_starts_on_bare_pframe() {
        let mut primer = JoinPrimer::new();
        for i in 0..100u8 {
            // Only ever P-frames: never starts, never forwards.
            assert_eq!(primer.on_frame(&p(i)), PrimeAction::Skip);
            assert!(!primer.started());
        }
    }

    #[test]
    fn priming_nals_from_cache() {
        let cache = ParamSetCache::new();
        // No params yet → nothing to prime with.
        assert!(JoinPrimer::priming_nals(&cache).is_empty());
        cache.observe(&sps());
        cache.observe(&pps());
        let primed = JoinPrimer::priming_nals(&cache);
        assert_eq!(primed, vec![sps(), pps()], "SPS then PPS");
    }

    #[test]
    fn full_join_sequence_params_then_wait_then_frames() {
        // Simulate the fan-out's per-client decision for a client that joins
        // mid-GOP: priming gives [SPS, PPS], then the live stream is
        // P,P,IDR,P,P — the client should see SPS,PPS first, skip the leading
        // Ps, then IDR + the trailing Ps.
        let cache = ParamSetCache::new();
        cache.observe(&sps());
        cache.observe(&pps());

        let mut delivered: Vec<Vec<u8>> = JoinPrimer::priming_nals(&cache);

        let live = [p(1), p(2), idr(), p(3), p(4)];
        let mut primer = JoinPrimer::new();
        for nal in &live {
            if primer.on_frame(nal) == PrimeAction::Send {
                delivered.push(nal.clone());
            }
        }

        assert_eq!(delivered, vec![sps(), pps(), idr(), p(3), p(4)]);
        // First three delivered are the param sets + IDR — never a bare P.
        assert!(is_param(&delivered[0]));
        assert!(is_param(&delivered[1]));
        assert!(is_idr(&delivered[2]));
    }

    // ---- HEVC primer ----

    // HEVC NAL bytes (2-byte header; type in bits 6..1 of byte 0).
    fn h_vps() -> Vec<u8> {
        vec![0x00, 0x00, 0x00, 0x01, 0x40, 0x01]
    }
    fn h_sps() -> Vec<u8> {
        vec![0x00, 0x00, 0x00, 0x01, 0x42, 0x01]
    }
    fn h_pps() -> Vec<u8> {
        vec![0x00, 0x00, 0x00, 0x01, 0x44, 0x01]
    }
    fn h_idr() -> Vec<u8> {
        vec![0x00, 0x00, 0x00, 0x01, 0x26, 0x01] // IDR_W_RADL (type 19)
    }
    fn h_trail(n: u8) -> Vec<u8> {
        vec![0x00, 0x00, 0x00, 0x01, 0x02, n] // TRAIL_R (type 1)
    }

    #[test]
    fn hevc_full_join_sequence_primes_with_vps_sps_pps() {
        let cache = ParamSetCache::with_codec(Codec::Hevc);
        // Priming needs the full VPS+SPS+PPS set; partial → nothing yet.
        cache.observe(&h_vps());
        cache.observe(&h_sps());
        assert!(JoinPrimer::priming_nals(&cache).is_empty());
        cache.observe(&h_pps());

        let mut delivered: Vec<Vec<u8>> = JoinPrimer::priming_nals(&cache);
        assert_eq!(delivered, vec![h_vps(), h_sps(), h_pps()], "VPS,SPS,PPS order");

        // Live HEVC stream: trail, trail, IDR, trail — skip the leading inter
        // frames, start on the IDR, then forward everything.
        let live = [h_trail(1), h_trail(2), h_idr(), h_trail(3)];
        let mut primer = JoinPrimer::with_codec(Codec::Hevc);
        for nal in &live {
            if primer.on_frame(nal) == PrimeAction::Send {
                delivered.push(nal.clone());
            }
        }
        assert_eq!(
            delivered,
            vec![h_vps(), h_sps(), h_pps(), h_idr(), h_trail(3)]
        );
        assert!(primer.started());
    }
}
