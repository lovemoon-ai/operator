//! Real-ffmpeg ingest end-to-end tests.
//!
//! Two tests:
//!
//! * [`ffmpeg_ingest_relays_real_h264`] — RUNNABLE. Drives the *live* ffmpeg
//!   ingest path (`run_ffmpeg_source` → `NalParser` → broadcast → TCP fan-out
//!   → headset-side TCP client) against a self-contained `lavfi testsrc` H.264
//!   source. This exercises the exact subprocess spawn / NAL relay / join
//!   priming code that the RTSP path uses; only the ffmpeg *input* differs
//!   (`-f lavfi` instead of `-i rtsp://…`). Skips (does not fail) if ffmpeg is
//!   not on PATH.
//!
//! * [`rtsp_server_ingest_e2e`] — `#[ignore]`. The "real RTSP server" variant.
//!   ffmpeg 8.x on this machine cannot act as a standalone RTSP server (its
//!   RTSP muxer/demuxer `listen` mode does not open a listening socket — it
//!   expects an external RTSP server such as MediaMTX / live555), so we cannot
//!   stand up an RTSP server with ffmpeg alone. Run it manually against a real
//!   RTSP server (e.g. Isaac Sim or MediaMTX) by exporting the URL:
//!
//!   ```sh
//!   XR_BRIDGE_RTSP_URL=rtsp://127.0.0.1:8554/wrist_left \
//!     cargo test -p xr-bridge --test rtsp_ingest -- --ignored --nocapture
//!   ```

use std::process::Stdio;
use std::time::Duration;

use futures::StreamExt;
use tokio::net::{TcpListener, TcpStream};
use tokio_util::codec::Framed;

use xr_bridge::protocol::{TimedVideoFrame, TimedVideoFrameCodec};
use xr_bridge::video::fanout::serve_video_clients_on;
use xr_bridge::video::nal::{
    is_idr, is_keyframe, nal_type, nal_type_of, Codec, ParamSetCache, HEVC_NAL_SPS, HEVC_NAL_VPS,
};
use xr_bridge::video::source::{run_ffmpeg_source, run_rtsp_source, RtspSource, SourceCtx};

fn ffmpeg_available() -> bool {
    std::process::Command::new("ffmpeg")
        .arg("-version")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

/// True if ffmpeg lists `encoder` (e.g. "libx265") in `-encoders`.
fn ffmpeg_has_encoder(encoder: &str) -> bool {
    std::process::Command::new("ffmpeg")
        .args(["-hide_banner", "-encoders"])
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).contains(encoder))
        .unwrap_or(false)
}

/// ffmpeg args producing a self-contained Annex-B H.264 stream on stdout
/// (no external server needed). Short GOP so an IDR shows up quickly.
fn lavfi_h264_args() -> Vec<String> {
    [
        "-nostdin",
        "-re",
        "-f",
        "lavfi",
        "-i",
        "testsrc=size=320x240:rate=15",
        "-c:v",
        "libx264",
        "-tune",
        "zerolatency",
        "-g",
        "15",
        "-pix_fmt",
        "yuv420p",
        "-bsf:v",
        "h264_mp4toannexb",
        "-f",
        "h264",
        "pipe:1",
    ]
    .iter()
    .map(|s| s.to_string())
    .collect()
}

/// ffmpeg args producing a self-contained Annex-B HEVC stream on stdout.
/// `repeat-headers=1` re-emits VPS/SPS/PPS at every IDR so a late TCP client is
/// reliably primed; `keyint=15` keeps a keyframe arriving quickly.
fn lavfi_hevc_args() -> Vec<String> {
    [
        "-nostdin",
        "-re",
        "-f",
        "lavfi",
        "-i",
        "testsrc=size=320x240:rate=15",
        "-c:v",
        "libx265",
        "-preset",
        "ultrafast",
        "-tune",
        "zerolatency",
        "-x265-params",
        "keyint=15:min-keyint=15:repeat-headers=1:bframes=0",
        "-pix_fmt",
        "yuv420p",
        "-bsf:v",
        "hevc_mp4toannexb",
        "-f",
        "hevc",
        "pipe:1",
    ]
    .iter()
    .map(|s| s.to_string())
    .collect()
}

/// Drive a feed (ingest `args` → fan-out) and assert a TCP client sees
/// SPS + IDR + several frames within `budget`.
async fn run_feed_and_assert(args: Vec<String>, budget: Duration) {
    let (tx, _) = tokio::sync::broadcast::channel::<TimedVideoFrame>(256);
    let params = ParamSetCache::new();

    let src_ctx = SourceCtx {
        nal_tx: tx.clone(),
        params: params.clone(),
        name: "test".to_string(),
    };
    let src_handle = tokio::spawn(async move {
        let _ = run_ffmpeg_source(args, src_ctx).await;
    });

    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let fanout_addr = listener.local_addr().unwrap();
    let s_tx = tx.clone();
    let s_params = params.clone();
    let fanout_handle = tokio::spawn(async move {
        let _ = serve_video_clients_on(listener, s_tx, s_params).await;
    });

    let result = tokio::time::timeout(budget, async {
        // Wait until the source has produced params (proves ingest works),
        // then connect so the fan-out primes us with SPS/PPS.
        loop {
            if params.param_nals().is_some() {
                break;
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }

        let client = loop {
            match TcpStream::connect(fanout_addr).await {
                Ok(s) => break s,
                Err(_) => tokio::time::sleep(Duration::from_millis(50)).await,
            }
        };

        let mut framed = Framed::new(client, TimedVideoFrameCodec);
        let mut saw_sps = false;
        let mut saw_pps = false;
        let mut saw_idr = false;
        let mut total = 0usize;

        while let Some(Ok(f)) = framed.next().await {
            total += 1;
            match nal_type(&f.nal) {
                Some(7) => saw_sps = true,
                Some(8) => saw_pps = true,
                _ => {}
            }
            if is_idr(&f.nal) {
                saw_idr = true;
            }
            if saw_sps && saw_idr && total >= 6 {
                break;
            }
        }
        (saw_sps, saw_pps, saw_idr, total)
    })
    .await;

    src_handle.abort();
    fanout_handle.abort();

    match result {
        Ok((saw_sps, saw_pps, saw_idr, total)) => {
            assert!(saw_sps, "expected at least one SPS");
            assert!(saw_idr, "expected at least one IDR");
            assert!(total >= 6, "expected several frames, got {total}");
            eprintln!("ingest OK: sps={saw_sps} pps={saw_pps} idr={saw_idr} total_frames={total}");
        }
        Err(_) => panic!("timed out waiting for SPS+IDR+frames"),
    }
}

#[tokio::test]
async fn ffmpeg_ingest_relays_real_h264() {
    if !ffmpeg_available() {
        eprintln!("SKIP ffmpeg_ingest_relays_real_h264: ffmpeg not on PATH");
        return;
    }
    let start = std::time::Instant::now();
    run_feed_and_assert(lavfi_h264_args(), Duration::from_secs(15)).await;
    eprintln!("ffmpeg_ingest_relays_real_h264 took {:?}", start.elapsed());
}

/// HEVC counterpart of [`ffmpeg_ingest_relays_real_h264`]: drives the live
/// ffmpeg ingest with a real libx265 stream through the HEVC NAL classification
/// + VPS-aware param cache + codec-aware fan-out priming, and asserts a TCP
/// client sees VPS + SPS + a keyframe + several frames. Skips (does not fail)
/// if ffmpeg or the libx265 encoder is unavailable.
#[tokio::test]
async fn ffmpeg_ingest_relays_real_hevc() {
    if !ffmpeg_available() {
        eprintln!("SKIP ffmpeg_ingest_relays_real_hevc: ffmpeg not on PATH");
        return;
    }
    if !ffmpeg_has_encoder("libx265") {
        eprintln!("SKIP ffmpeg_ingest_relays_real_hevc: libx265 encoder not built into ffmpeg");
        return;
    }
    let start = std::time::Instant::now();
    run_hevc_feed_and_assert(lavfi_hevc_args(), Duration::from_secs(20)).await;
    eprintln!("ffmpeg_ingest_relays_real_hevc took {:?}", start.elapsed());
}

/// HEVC variant of [`run_feed_and_assert`]: the cache (and thus the whole
/// relay) is configured for HEVC, and the client-side checks use HEVC NAL
/// classification.
async fn run_hevc_feed_and_assert(args: Vec<String>, budget: Duration) {
    let (tx, _) = tokio::sync::broadcast::channel::<TimedVideoFrame>(256);
    let params = ParamSetCache::with_codec(Codec::Hevc);

    let src_ctx = SourceCtx {
        nal_tx: tx.clone(),
        params: params.clone(),
        name: "test-hevc".to_string(),
    };
    let src_handle = tokio::spawn(async move {
        let _ = run_ffmpeg_source(args, src_ctx).await;
    });

    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let fanout_addr = listener.local_addr().unwrap();
    let s_tx = tx.clone();
    let s_params = params.clone();
    let fanout_handle = tokio::spawn(async move {
        let _ = serve_video_clients_on(listener, s_tx, s_params).await;
    });

    let result = tokio::time::timeout(budget, async {
        // Wait until the source has primed the full VPS+SPS+PPS set.
        loop {
            if !params.ordered_param_nals().is_empty() {
                break;
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }

        let client = loop {
            match TcpStream::connect(fanout_addr).await {
                Ok(s) => break s,
                Err(_) => tokio::time::sleep(Duration::from_millis(50)).await,
            }
        };

        let mut framed = Framed::new(client, TimedVideoFrameCodec);
        let mut saw_vps = false;
        let mut saw_sps = false;
        let mut saw_key = false;
        let mut total = 0usize;

        while let Some(Ok(f)) = framed.next().await {
            total += 1;
            match nal_type_of(&f.nal, Codec::Hevc) {
                Some(HEVC_NAL_VPS) => saw_vps = true,
                Some(HEVC_NAL_SPS) => saw_sps = true,
                _ => {}
            }
            if is_keyframe(&f.nal, Codec::Hevc) {
                saw_key = true;
            }
            if saw_vps && saw_sps && saw_key && total >= 6 {
                break;
            }
        }
        (saw_vps, saw_sps, saw_key, total)
    })
    .await;

    src_handle.abort();
    fanout_handle.abort();

    match result {
        Ok((saw_vps, saw_sps, saw_key, total)) => {
            assert!(saw_vps, "expected at least one VPS (HEVC)");
            assert!(saw_sps, "expected at least one SPS (HEVC)");
            assert!(saw_key, "expected at least one IRAP/keyframe (HEVC)");
            assert!(total >= 6, "expected several frames, got {total}");
            eprintln!("hevc ingest OK: vps={saw_vps} sps={saw_sps} key={saw_key} total={total}");
        }
        Err(_) => panic!("timed out waiting for HEVC VPS+SPS+keyframe+frames"),
    }
}

/// Real RTSP server variant. Ignored by default because ffmpeg alone cannot
/// host an RTSP server on this machine (see module docs). Provide
/// `XR_BRIDGE_RTSP_URL` and run with `--ignored` against a real server.
#[tokio::test]
#[ignore = "needs an external RTSP server; set XR_BRIDGE_RTSP_URL and run with --ignored"]
async fn rtsp_server_ingest_e2e() {
    if !ffmpeg_available() {
        eprintln!("SKIP rtsp_server_ingest_e2e: ffmpeg not on PATH");
        return;
    }
    let url = match std::env::var("XR_BRIDGE_RTSP_URL") {
        Ok(u) if !u.is_empty() => u,
        _ => {
            eprintln!(
                "SKIP rtsp_server_ingest_e2e: set XR_BRIDGE_RTSP_URL to a reachable \
                 RTSP H.264 stream (e.g. rtsp://127.0.0.1:8554/wrist_left)"
            );
            return;
        }
    };

    // Sanity: the URL must parse into the expected low-latency ingest args.
    let args = RtspSource::ffmpeg_args(&url);
    assert!(args.join(" ").contains(&url));

    // Bring up the feed against the real RTSP URL and assert the relay works.
    let (tx, _) = tokio::sync::broadcast::channel::<TimedVideoFrame>(256);
    let params = ParamSetCache::new();
    let src_ctx = SourceCtx {
        nal_tx: tx.clone(),
        params: params.clone(),
        name: "rtsp".to_string(),
    };
    let src_url = url.clone();
    let src_handle = tokio::spawn(async move {
        let _ = run_rtsp_source(&src_url, src_ctx).await;
    });

    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let fanout_addr = listener.local_addr().unwrap();
    let s_tx = tx.clone();
    let s_params = params.clone();
    let fanout_handle = tokio::spawn(async move {
        let _ = serve_video_clients_on(listener, s_tx, s_params).await;
    });

    let result = tokio::time::timeout(Duration::from_secs(20), async {
        loop {
            if params.param_nals().is_some() {
                break;
            }
            tokio::time::sleep(Duration::from_millis(200)).await;
        }
        let client = TcpStream::connect(fanout_addr).await.unwrap();
        let mut framed = Framed::new(client, TimedVideoFrameCodec);
        let (mut sps, mut idr, mut total) = (false, false, 0usize);
        while let Some(Ok(f)) = framed.next().await {
            total += 1;
            if nal_type(&f.nal) == Some(7) {
                sps = true;
            }
            if is_idr(&f.nal) {
                idr = true;
            }
            if sps && idr && total >= 6 {
                break;
            }
        }
        (sps, idr, total)
    })
    .await;

    src_handle.abort();
    fanout_handle.abort();

    let (sps, idr, total) = result.expect("timed out pulling from RTSP server");
    assert!(
        sps && idr && total >= 6,
        "rtsp relay: sps={sps} idr={idr} total={total}"
    );
    eprintln!("rtsp_server_ingest_e2e OK against {url}: total={total}");
}
