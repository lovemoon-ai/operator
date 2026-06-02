//! Video relay: pull N RTSP streams and re-publish them over the existing XR
//! video wire protocol, one independent feed at a time.
//!
//! The monolithic agent captured + encoded a single camera. The bridge instead
//! ingests H.264 that Isaac Sim already encoded (3 RTSP URLs:
//! `wrist_left`/`wrist_right`/`head`) and relays each to the headset unchanged.
//!
//! Per-feed pipeline:
//! ```text
//! RTSP URL ──ffmpeg copy──> NalParser ──> broadcast::Sender<TimedVideoFrame>
//!                                              │             │
//!                                ParamSetCache │             ├─> TCP fan-out (serve_video_clients)
//!                                  (SPS/PPS)   ┘             └─> UDP fan-out (serve_udp_broadcast, optional)
//! ```
//! Each feed runs as an independent set of tasks; one feed dying (RTSP gap,
//! ffmpeg crash) never affects the others.

pub mod fanout;
pub mod nal;
pub mod source;

use anyhow::Result;
use tokio::sync::broadcast;

use crate::protocol::TimedVideoFrame;
use crate::video::fanout::{serve_udp_broadcast, serve_video_clients};
use crate::video::nal::ParamSetCache;
use crate::video::source::{RtspSource, SourceCtx, VideoSource};

pub use crate::video::nal::Codec;

/// One relayed video feed: an RTSP source and the XR-facing ports it serves on.
#[derive(Debug, Clone)]
pub struct VideoFeed {
    /// Feed identifier (e.g. "wrist_left"); used in logs + the descriptor.
    pub name: String,
    /// RTSP URL to pull from (e.g. `rtsp://127.0.0.1:8554/wrist_left`).
    pub rtsp_url: String,
    /// TCP port the headset connects to for this feed.
    pub tcp_port: u16,
    /// Optional UDP fan-out port (Wi-Fi friendly). `None` = TCP only.
    pub udp_port: Option<u16>,
    /// Codec the upstream RTSP stream carries. The bridge never transcodes;
    /// this selects the ffmpeg bitstream filter / muxer for the copy and how
    /// NALs are classified for join-priming. Defaults to H.264.
    pub codec: Codec,
}

/// Broadcast channel depth per feed. Generous so a brief consumer stall (e.g.
/// a slow headset) doesn't immediately lag the source.
const BROADCAST_DEPTH: usize = 256;

/// Run the video relay for every feed concurrently.
///
/// For each feed this spawns: the RTSP supervisor (reconnecting ffmpeg) and the
/// TCP fan-out, plus the UDP fan-out if a `udp_port` is set. Per-feed isolation
/// is achieved by independent tasks — a panic/exit in one feed's tasks doesn't
/// tear down the others. Returns only if `feeds` is empty (immediately) or all
/// tasks somehow complete (they normally loop forever).
pub async fn run(feeds: Vec<VideoFeed>) -> Result<()> {
    if feeds.is_empty() {
        tracing::info!("Video relay: no feeds configured, skipping");
        return Ok(());
    }

    tracing::info!("Video relay: starting {} feed(s)", feeds.len());
    let mut handles = Vec::new();

    for feed in feeds {
        let (nal_tx, _) = broadcast::channel::<TimedVideoFrame>(BROADCAST_DEPTH);
        // The cache carries the feed's codec — every downstream stage (ffmpeg
        // args, NAL classification, join-priming) reads it from here.
        let params = ParamSetCache::with_codec(feed.codec);

        // RTSP source supervisor (reconnects internally).
        {
            let ctx = SourceCtx {
                nal_tx: nal_tx.clone(),
                params: params.clone(),
                name: feed.name.clone(),
            };
            let source = Box::new(RtspSource::new(feed.rtsp_url.clone()));
            let name = feed.name.clone();
            handles.push(tokio::spawn(async move {
                if let Err(e) = source.run(ctx).await {
                    tracing::error!("[{name}] RTSP source exited: {e}");
                }
            }));
        }

        // TCP fan-out.
        {
            let nal_tx = nal_tx.clone();
            let params = params.clone();
            let port = feed.tcp_port;
            let name = feed.name.clone();
            handles.push(tokio::spawn(async move {
                if let Err(e) = serve_video_clients(port, nal_tx, params).await {
                    tracing::error!("[{name}] TCP video server (port {port}) exited: {e}");
                }
            }));
        }

        // Optional UDP fan-out.
        if let Some(udp_port) = feed.udp_port {
            let nal_rx = nal_tx.subscribe();
            let params = params.clone();
            let name = feed.name.clone();
            handles.push(tokio::spawn(async move {
                if let Err(e) = serve_udp_broadcast(udp_port, nal_rx, params).await {
                    tracing::error!("[{name}] UDP video server (port {udp_port}) exited: {e}");
                }
            }));
        }

        tracing::info!(
            "Video feed '{}' [{}]: RTSP {} -> TCP {}{}",
            feed.name,
            feed.codec.as_str(),
            feed.rtsp_url,
            feed.tcp_port,
            feed.udp_port
                .map(|p| format!(" + UDP {p}"))
                .unwrap_or_default(),
        );
    }

    // Hold the feeds open. The tasks loop forever; we only fall through if one
    // of them returns (logged above) — keep waiting on the rest so a single
    // feed's exit doesn't bring the whole relay down.
    for handle in handles {
        let _ = handle.await;
    }
    Ok(())
}
