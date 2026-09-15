//! Video relay: ingest N Annex-B streams and re-publish them over the existing
//! XR video wire protocol, one independent feed at a time.
//!
//! RTSP feeds use ffmpeg stream-copy. Robot-specific capture or encoding can
//! run as a trusted local command whose stdout is Annex-B H.264/H.265.
//!
//! Per-feed pipeline:
//! ```text
//! RTSP/command ──Annex-B──> NalParser ──> broadcast::Sender<TimedVideoFrame>
//!                                              │             │
//!                                ParamSetCache │             ├─> TCP fan-out (serve_video_clients)
//!                                  (SPS/PPS)   ┘             └─> UDP fan-out (serve_udp_broadcast, optional)
//! ```
//! Each feed runs as an independent set of tasks; one source dying never
//! affects the others.

pub mod fanout;
pub mod nal;
pub mod source;

use anyhow::Result;
use tokio::sync::broadcast;

use crate::protocol::TimedVideoFrame;
use crate::video::fanout::{serve_udp_broadcast, serve_video_clients};
use crate::video::nal::ParamSetCache;
use crate::video::source::{AnnexBCommandSource, RtspSource, SourceCtx, VideoSource};

pub use crate::video::nal::Codec;

#[derive(Debug, Clone)]
pub enum VideoFeedSource {
    Rtsp(String),
    Command(Vec<String>),
}

/// One relayed video feed and the XR-facing ports it serves on.
#[derive(Debug, Clone)]
pub struct VideoFeed {
    /// Feed identifier (e.g. "wrist_left"); used in logs + the descriptor.
    pub name: String,
    /// Encoded input source.
    pub source: VideoFeedSource,
    /// TCP port the headset connects to for this feed.
    pub tcp_port: u16,
    /// Optional UDP fan-out port (Wi-Fi friendly). `None` = TCP only.
    pub udp_port: Option<u16>,
    /// Codec emitted by the source. For RTSP this also selects the ffmpeg
    /// bitstream filter and muxer used by the stream-copy path.
    pub codec: Codec,
}

/// Broadcast channel depth per feed. Generous so a brief consumer stall (e.g.
/// a slow headset) doesn't immediately lag the source.
const BROADCAST_DEPTH: usize = 256;

/// Run the video relay for every feed concurrently.
///
/// For each feed this spawns the source supervisor and TCP fan-out, plus the
/// UDP fan-out if a `udp_port` is set. Per-feed isolation
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

        let source_description = match &feed.source {
            VideoFeedSource::Rtsp(url) => format!("RTSP {url}"),
            VideoFeedSource::Command(command) => format!("command {}", command.join(" ")),
        };

        {
            let ctx = SourceCtx {
                nal_tx: nal_tx.clone(),
                params: params.clone(),
                name: feed.name.clone(),
            };
            let source: Box<dyn VideoSource> = match feed.source.clone() {
                VideoFeedSource::Rtsp(url) => Box::new(RtspSource::new(url)),
                VideoFeedSource::Command(command) => Box::new(AnnexBCommandSource::new(command)),
            };
            let name = feed.name.clone();
            handles.push(tokio::spawn(async move {
                if let Err(e) = source.run(ctx).await {
                    tracing::error!("[{name}] video source exited: {e}");
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
            "Video feed '{}' [{}]: {} -> TCP {}{}",
            feed.name,
            feed.codec.as_str(),
            source_description,
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
