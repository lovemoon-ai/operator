//! Validation spike for the RTSP→XR relay.
//!
//! Drives the PRODUCTION relay code (`video::source::run_rtsp_source` +
//! `ParamSetCache`) against N RTSP URLs, captures each feed's relayed Annex-B
//! NAL bytes to a file, and reports per-feed throughput / broadcast-lag /
//! time-to-first-IDR / SPS profile. Decoding the captured `.h264` afterwards
//! (with ffmpeg) validates that `-c:v copy` relaying preserves a decodable
//! bitstream — including High-profile + B-frame streams like Isaac/NVENC emit.
//!
//! Usage:
//!   cargo run -p xr-bridge --example rtsp_probe -- \
//!       --secs 15 --out /tmp/relayout \
//!       wrist_left=rtsp://127.0.0.1:8554/wrist_left \
//!       wrist_right=rtsp://127.0.0.1:8554/wrist_right \
//!       head=rtsp://127.0.0.1:8554/head

use std::io::Write;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use tokio::sync::broadcast;
use xr_bridge::protocol::TimedVideoFrame;
use xr_bridge::video::nal::{is_idr, nal_type, ParamSetCache};
use xr_bridge::video::source::{run_rtsp_source, SourceCtx};

#[derive(Default)]
struct FeedStats {
    nals: AtomicU64,
    bytes: AtomicU64,
    lag_events: AtomicU64,
    lagged_frames: AtomicU64,
    first_idr_ns: AtomicU64, // wall-clock ns of first IDR, 0 = none yet
    sps_profile_idc: AtomicU64,
    sps_level_idc: AtomicU64,
    got_idr: AtomicBool,
}

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| {
                tracing_subscriber::EnvFilter::new("xr_bridge=warn,rtsp_probe=info")
            }),
        )
        .init();

    // ── Parse args ──
    let mut secs = 15u64;
    let mut out_dir = "/tmp/relayout".to_string();
    let mut feeds: Vec<(String, String)> = Vec::new();
    let mut args = std::env::args().skip(1);
    while let Some(a) = args.next() {
        match a.as_str() {
            "--secs" => secs = args.next().and_then(|s| s.parse().ok()).unwrap_or(15),
            "--out" => out_dir = args.next().unwrap_or(out_dir),
            other => {
                if let Some((name, url)) = other.split_once('=') {
                    feeds.push((name.to_string(), url.to_string()));
                } else {
                    eprintln!("ignoring arg {other:?} (expected name=url)");
                }
            }
        }
    }
    if feeds.is_empty() {
        eprintln!("no feeds given; usage: --secs N --out DIR name=rtsp://...");
        std::process::exit(2);
    }
    std::fs::create_dir_all(&out_dir).expect("create out dir");

    let start = Instant::now();
    let mut stats_all: Vec<(String, Arc<FeedStats>)> = Vec::new();

    for (name, url) in &feeds {
        let (tx, mut rx) = broadcast::channel::<TimedVideoFrame>(256);
        let params = ParamSetCache::new();
        let stats = Arc::new(FeedStats::default());
        stats_all.push((name.clone(), stats.clone()));

        // Production relay supervisor.
        let ctx = SourceCtx {
            nal_tx: tx.clone(),
            params: params.clone(),
            name: name.clone(),
        };
        let src_url = url.clone();
        tokio::spawn(async move {
            let _ = run_rtsp_source(&src_url, ctx).await;
        });
        // Keep one Sender alive so the channel never closes even if the source
        // momentarily has no other receivers.
        std::mem::forget(tx);

        // Capture consumer: write relayed NAL bytes to <out>/<name>.h264.
        let path = format!("{out_dir}/{name}.h264");
        let mut file = std::fs::File::create(&path).expect("create capture file");
        let stats_c = stats.clone();
        let t0 = start;
        tokio::spawn(async move {
            loop {
                match rx.recv().await {
                    Ok(frame) => {
                        let nal = &frame.nal;
                        let _ = file.write_all(nal);
                        stats_c.nals.fetch_add(1, Ordering::Relaxed);
                        stats_c.bytes.fetch_add(nal.len() as u64, Ordering::Relaxed);
                        if let Some(7) = nal_type(nal) {
                            // SPS: profile_idc/level_idc sit right after the
                            // 4-byte start code + 1-byte NAL header.
                            if nal.len() >= 8 {
                                stats_c
                                    .sps_profile_idc
                                    .store(nal[5] as u64, Ordering::Relaxed);
                                stats_c
                                    .sps_level_idc
                                    .store(nal[7] as u64, Ordering::Relaxed);
                            }
                        }
                        if is_idr(nal) && !stats_c.got_idr.swap(true, Ordering::Relaxed) {
                            stats_c
                                .first_idr_ns
                                .store(t0.elapsed().as_nanos() as u64, Ordering::Relaxed);
                        }
                    }
                    Err(broadcast::error::RecvError::Lagged(n)) => {
                        stats_c.lag_events.fetch_add(1, Ordering::Relaxed);
                        stats_c.lagged_frames.fetch_add(n, Ordering::Relaxed);
                    }
                    Err(broadcast::error::RecvError::Closed) => break,
                }
            }
        });
    }

    eprintln!("probing {} feed(s) for {secs}s …", feeds.len());
    tokio::time::sleep(Duration::from_secs(secs)).await;
    let elapsed = start.elapsed().as_secs_f64();

    // ── Report ──
    println!("\n==== RTSP relay probe ({elapsed:.1}s) ====");
    let mut agg_mbps = 0.0;
    for (name, s) in &stats_all {
        let nals = s.nals.load(Ordering::Relaxed);
        let bytes = s.bytes.load(Ordering::Relaxed);
        let mbps = (bytes as f64 * 8.0) / elapsed / 1e6;
        agg_mbps += mbps;
        let lag_ev = s.lag_events.load(Ordering::Relaxed);
        let lag_fr = s.lagged_frames.load(Ordering::Relaxed);
        let ttf = s.first_idr_ns.load(Ordering::Relaxed);
        let ttf_ms = if ttf > 0 { ttf as f64 / 1e6 } else { -1.0 };
        let prof = s.sps_profile_idc.load(Ordering::Relaxed);
        let level = s.sps_level_idc.load(Ordering::Relaxed);
        let prof_name = match prof {
            66 => "Baseline",
            77 => "Main",
            100 => "High",
            0 => "?(no SPS seen)",
            _ => "other",
        };
        println!(
            "feed {name:<12} nals={nals:<7} {mb:>7.2} MB  {mbps:>6.2} Mb/s  \
             lag_events={lag_ev} lagged_frames={lag_fr}  ttf_idr={ttf_ms:.0}ms  \
             SPS profile_idc={prof}({prof_name}) level_idc={level}",
            mb = bytes as f64 / 1e6,
        );
    }
    println!(
        "---- aggregate egress: {agg_mbps:.2} Mb/s across {} feed(s) ----",
        stats_all.len()
    );
    println!("captured streams in {out_dir}/<name>.h264 — decode with: ffmpeg -v error -i <file> -f null -");
}
