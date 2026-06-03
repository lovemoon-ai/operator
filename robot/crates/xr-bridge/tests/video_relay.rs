//! Synthetic-NAL relay tests for the video fan-out.
//!
//! These drive the TCP fan-out with hand-built `TimedVideoFrame`s (no ffmpeg /
//! no RTSP) and assert:
//!   1. A connected client decodes the relayed frames byte-identically via the
//!      same `TimedVideoFrameCodec` the headset uses, with SPS/PPS/IDR first.
//!   2. Three independent feeds (channels + ports) don't cross-talk.

use std::time::Duration;

use bytes::BytesMut;
use futures::StreamExt;
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::broadcast;
use tokio_util::codec::Framed;

use xr_bridge::protocol::{TimedVideoFrame, TimedVideoFrameCodec, VIDEO_PIPELINE_MODE_FFMPEG};
use xr_bridge::video::fanout::serve_video_clients_on;
use xr_bridge::video::nal::ParamSetCache;

fn frame(frame_id: u64, nal: Vec<u8>) -> TimedVideoFrame {
    TimedVideoFrame {
        frame_id,
        nal_index: 0,
        nal_count: 1,
        pipeline_mode: VIDEO_PIPELINE_MODE_FFMPEG,
        capture_start_ns: 1,
        capture_end_ns: 2,
        encode_start_ns: 3,
        encode_end_ns: 4,
        read_wait_ns: 0,
        parse_ns: 0,
        send_ns: 0,
        nal,
    }
}

fn sps() -> Vec<u8> {
    vec![0x00, 0x00, 0x00, 0x01, 0x67, 0x42, 0xC0, 0x1E]
}
fn pps() -> Vec<u8> {
    vec![0x00, 0x00, 0x00, 0x01, 0x68, 0xCE, 0x38, 0x80]
}
fn idr() -> Vec<u8> {
    vec![0x00, 0x00, 0x00, 0x01, 0x65, 0x88, 0x80, 0x11]
}
fn pframe(n: u8) -> Vec<u8> {
    vec![0x00, 0x00, 0x00, 0x01, 0x41, 0x9A, n]
}

/// Read exactly `count` decoded frames (or fail on timeout).
async fn recv_n(stream: TcpStream, count: usize) -> Vec<TimedVideoFrame> {
    let mut framed = Framed::new(stream, TimedVideoFrameCodec);
    let mut out = Vec::with_capacity(count);
    for _ in 0..count {
        let next = tokio::time::timeout(Duration::from_secs(5), framed.next()).await;
        match next {
            Ok(Some(Ok(f))) => out.push(f),
            other => panic!("expected a frame, got {other:?}"),
        }
    }
    out
}

#[tokio::test]
async fn relay_delivers_sps_pps_idr_then_frames_byte_identically() {
    let (tx, _) = broadcast::channel::<TimedVideoFrame>(64);
    let params = ParamSetCache::new();

    // Pre-seed the param cache (as the RTSP source would when SPS/PPS go by),
    // so the joining client is primed even though it connects mid-stream.
    params.observe(&sps());
    params.observe(&pps());

    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();

    let server_tx = tx.clone();
    let server_params = params.clone();
    tokio::spawn(async move {
        let _ = serve_video_clients_on(listener, server_tx, server_params).await;
    });

    let client = TcpStream::connect(addr).await.unwrap();

    // Give the server task a moment to subscribe + send priming frames.
    tokio::time::sleep(Duration::from_millis(50)).await;

    // Push a live stream: two leading P-frames (must be skipped post-join),
    // then IDR, then more frames.
    let _ = tx.send(frame(10, pframe(1)));
    let _ = tx.send(frame(11, pframe(2)));
    let _ = tx.send(frame(12, idr()));
    let _ = tx.send(frame(13, pframe(3)));
    let _ = tx.send(frame(14, pframe(4)));

    // Expected delivery: primed SPS, primed PPS, then (leading Ps skipped)
    // IDR, P3, P4 = 5 frames.
    let frames = recv_n(client, 5).await;

    // First two are the cached params, byte-identical.
    assert_eq!(frames[0].nal, sps(), "first frame must be SPS");
    assert_eq!(frames[1].nal, pps(), "second frame must be PPS");
    // Then the IDR (the leading P-frames were dropped).
    assert_eq!(frames[2].nal, idr(), "third frame must be the IDR");
    assert_eq!(frames[2].frame_id, 12, "IDR frame_id preserved");
    // Subsequent P-frames flow byte-identically.
    assert_eq!(frames[3].nal, pframe(3));
    assert_eq!(frames[4].nal, pframe(4));

    // Sanity: a P-frame never appears before the IDR.
    let idr_pos = frames.iter().position(|f| f.nal == idr()).unwrap();
    for f in &frames[..idr_pos] {
        assert!(
            f.nal == sps() || f.nal == pps(),
            "only SPS/PPS may precede the IDR, saw {:?}",
            f.nal
        );
    }
}

#[tokio::test]
async fn relay_roundtrips_a_large_idr_byte_for_byte() {
    // Ensure the timed codec carries an arbitrary-length NAL unchanged.
    let (tx, _) = broadcast::channel::<TimedVideoFrame>(8);
    let params = ParamSetCache::new();

    // Build a big IDR: start code + type-5 header byte + recognisable pattern.
    let mut big = vec![0x00, 0x00, 0x00, 0x01, 0x65];
    big.extend((0..40_000).map(|i| (i & 0xFF) as u8));
    params.observe(&sps());
    params.observe(&pps());

    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let s_tx = tx.clone();
    let s_params = params.clone();
    tokio::spawn(async move {
        let _ = serve_video_clients_on(listener, s_tx, s_params).await;
    });

    let client = TcpStream::connect(addr).await.unwrap();
    tokio::time::sleep(Duration::from_millis(50)).await;
    let _ = tx.send(frame(1, big.clone()));

    // SPS, PPS, then the big IDR.
    let frames = recv_n(client, 3).await;
    assert_eq!(
        frames[2].nal, big,
        "large IDR must survive the relay verbatim"
    );
}

#[tokio::test]
async fn three_feeds_are_independent() {
    // Three feeds = three channels + three ports. Frames pushed to feed B
    // must NOT appear on feed A's port.
    let mut ports = Vec::new();
    let mut txs = Vec::new();

    for _ in 0..3 {
        let (tx, _) = broadcast::channel::<TimedVideoFrame>(32);
        let params = ParamSetCache::new();
        params.observe(&sps());
        params.observe(&pps());
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        ports.push(listener.local_addr().unwrap());
        let s_tx = tx.clone();
        tokio::spawn(async move {
            let _ = serve_video_clients_on(listener, s_tx, params).await;
        });
        txs.push(tx);
    }

    // Connect a client to feed A (index 0) only.
    let client_a = TcpStream::connect(ports[0]).await.unwrap();
    tokio::time::sleep(Duration::from_millis(50)).await;

    // Push a UNIQUE marker IDR to feed B (index 1) — its bytes encode "B".
    let mut idr_b = idr();
    idr_b.push(0xBB);
    let _ = txs[1].send(frame(100, idr_b.clone()));

    // Push feed A's own distinct IDR.
    let mut idr_a = idr();
    idr_a.push(0xAA);
    let _ = txs[0].send(frame(200, idr_a.clone()));

    // Client A should receive SPS, PPS, then ONLY feed A's IDR — never B's.
    let frames = recv_n(client_a, 3).await;
    assert_eq!(frames[0].nal, sps());
    assert_eq!(frames[1].nal, pps());
    assert_eq!(frames[2].nal, idr_a, "feed A client must see feed A's IDR");
    assert!(
        frames.iter().all(|f| f.nal != idr_b),
        "feed B's frame must never appear on feed A's port"
    );
}

#[tokio::test]
async fn timed_codec_roundtrip_matches_wire_bytes() {
    // Defensive: confirm the exact wire bytes a relayed frame produces decode
    // back identically (this is the format the headset consumes unchanged).
    let mut codec = TimedVideoFrameCodec;
    let f = frame(7, idr());
    let mut buf = BytesMut::new();
    use tokio_util::codec::{Decoder, Encoder};
    codec.encode(f.clone(), &mut buf).unwrap();
    let decoded = codec.decode(&mut buf).unwrap().unwrap();
    assert_eq!(decoded.frame_id, 7);
    assert_eq!(decoded.nal, idr());
}
