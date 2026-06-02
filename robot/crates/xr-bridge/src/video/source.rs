//! Video sources that feed relayed H.264 NALs into a feed's broadcast channel.
//!
//! The relay swaps the legacy "camera capture + encode" producer for "pull an
//! RTSP stream Isaac already encoded". [`RtspSource`] does that via an ffmpeg
//! subprocess (stream-copy, no transcode). A thin [`VideoSource`] trait leaves
//! a seam for a future pure-Rust impl (e.g. `retina`) without touching the
//! fan-out or supervisor.

use std::time::Duration;

use anyhow::Result;
use async_trait::async_trait;
use tokio::io::AsyncReadExt;
use tokio::process::Command;
use tokio::sync::broadcast;

use crate::protocol::{TimedVideoFrame, VIDEO_PIPELINE_MODE_FFMPEG};
use crate::video::nal::{nal_type, NalParser, ParamSetCache};

/// Shared inputs every source needs to publish into a feed.
#[derive(Clone)]
pub struct SourceCtx {
    /// Where to publish relayed frames (one per NAL).
    pub nal_tx: broadcast::Sender<TimedVideoFrame>,
    /// Per-feed parameter-set cache (updated as SPS/PPS go by).
    pub params: ParamSetCache,
    /// Feed name, for logging.
    pub name: String,
}

/// A producer of H.264 NALs for one feed.
///
/// `run` should loop forever, reconnecting on failure; it only returns on an
/// unrecoverable error (callers treat that as "this feed is dead" but keep the
/// other feeds alive).
#[async_trait]
pub trait VideoSource: Send + 'static {
    async fn run(self: Box<Self>, ctx: SourceCtx) -> Result<()>;
}

/// Pulls one RTSP stream via ffmpeg and relays its NALs, with reconnect.
pub struct RtspSource {
    pub url: String,
}

impl RtspSource {
    pub fn new(url: impl Into<String>) -> Self {
        Self { url: url.into() }
    }

    /// ffmpeg args for low-latency RTSP ingest → Annex-B H.264 on stdout.
    /// No transcode: `-c:v copy` keeps Isaac's bytes; `h264_mp4toannexb`
    /// guarantees Annex-B start codes regardless of the RTSP container.
    pub fn ffmpeg_args(url: &str) -> Vec<String> {
        [
            "-nostdin",
            "-rtsp_transport",
            "tcp",
            "-fflags",
            "nobuffer",
            "-flags",
            "low_delay",
            "-i",
            url,
            "-an",
            "-c:v",
            "copy",
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
}

#[async_trait]
impl VideoSource for RtspSource {
    async fn run(self: Box<Self>, ctx: SourceCtx) -> Result<()> {
        run_rtsp_source(&self.url, ctx).await
    }
}

/// Backoff bounds for the reconnect loop.
const BACKOFF_MIN: Duration = Duration::from_millis(500);
const BACKOFF_MAX: Duration = Duration::from_secs(2);

/// Supervised RTSP ingest loop. Spawns ffmpeg, relays its NALs, and on any
/// failure (ffmpeg exit, stdout EOF, spawn error — e.g. Isaac not up yet)
/// logs a warning, backs off (0.5s→2s, capped), and respawns. Never crashes
/// the process; only returns if the broadcast channel is permanently closed
/// (no receivers will ever exist again — which doesn't happen while the
/// fan-out servers hold the Sender).
pub async fn run_rtsp_source(url: &str, ctx: SourceCtx) -> Result<()> {
    run_ffmpeg_source(RtspSource::ffmpeg_args(url), ctx).await
}

/// Supervised ingest loop for arbitrary ffmpeg args that emit an Annex-B H.264
/// bytestream on `pipe:1`. [`run_rtsp_source`] is the RTSP specialisation;
/// tests use this directly with a self-contained `lavfi` input so the live
/// ffmpeg→relay path is exercised without an external RTSP server.
pub async fn run_ffmpeg_source(args: Vec<String>, ctx: SourceCtx) -> Result<()> {
    let mut backoff = BACKOFF_MIN;
    let mut frame_id: u64 = 0;

    loop {
        match ingest_once(&args, &ctx, &mut frame_id).await {
            Ok(()) => {
                tracing::warn!(
                    "[{}] ffmpeg stream ended (stdout EOF); reconnecting in {:?}",
                    ctx.name,
                    backoff
                );
            }
            Err(e) => {
                tracing::warn!(
                    "[{}] ffmpeg ingest failed: {e}; reconnecting in {:?}",
                    ctx.name,
                    backoff
                );
            }
        }

        tokio::time::sleep(backoff).await;
        backoff = (backoff * 2).min(BACKOFF_MAX);
    }
}

/// One ffmpeg lifetime: spawn, read stdout, relay NALs until EOF/exit.
///
/// Returns `Ok(())` on a clean stdout EOF (stream gap / Isaac restart) and
/// `Err` if ffmpeg couldn't be spawned or stdout couldn't be taken.
async fn ingest_once(args: &[String], ctx: &SourceCtx, frame_id: &mut u64) -> Result<()> {
    tracing::info!("[{}] Starting ffmpeg: ffmpeg {}", ctx.name, args.join(" "));

    let mut child = Command::new("ffmpeg")
        .args(args)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(true)
        .spawn()?;

    // Drain stderr so ffmpeg never blocks on a full pipe and so connection
    // errors are visible in the log.
    if let Some(stderr) = child.stderr.take() {
        let name = ctx.name.clone();
        tokio::spawn(async move {
            use tokio::io::{AsyncBufReadExt, BufReader};
            let mut lines = BufReader::new(stderr).lines();
            while let Ok(Some(line)) = lines.next_line().await {
                if !line.trim().is_empty() {
                    tracing::debug!("[{name}] ffmpeg: {line}");
                }
            }
        });
    }

    let mut stdout = child
        .stdout
        .take()
        .ok_or_else(|| anyhow::anyhow!("ffmpeg stdout not available"))?;

    let mut parser = NalParser::new();
    let mut access_units = AccessUnitAssembler::new();
    let mut buf = [0u8; 65536];
    let mut nal_total: u64 = 0;

    loop {
        let n = match stdout.read(&mut buf).await {
            Ok(0) => break, // EOF: ffmpeg exited / stream closed.
            Ok(n) => n,
            Err(e) => {
                let _ = child.start_kill();
                return Err(e.into());
            }
        };

        for nal in parser.feed(&buf[..n]) {
            // Keep SPS/PPS current for late-joiner priming.
            ctx.params.observe(&nal);

            for access_unit in access_units.push(nal) {
                publish_access_unit(access_unit, ctx, frame_id, &mut nal_total);
            }
        }
    }

    if let Some(access_unit) = access_units.flush() {
        publish_access_unit(access_unit, ctx, frame_id, &mut nal_total);
    }

    let _ = child.wait().await;
    if nal_total > 0 {
        tracing::info!("[{}] relayed {} NALs before EOF", ctx.name, nal_total);
    }
    Ok(())
}

/// Groups Annex-B NAL units back into H.264 access units.
///
/// ffmpeg's `-f h264` output is a raw NAL bytestream. Android MediaCodec is
/// much happier when each input buffer is a complete access unit, especially
/// for the first keyframe where SPS+PPS must arrive before the IDR slice. The
/// XR wire protocol already carries `nal_index`/`nal_count`, so we keep NALs
/// separate on the wire but assign a shared frame id/count for each access
/// unit and let the headset concatenate them before submitting to MediaCodec.
struct AccessUnitAssembler {
    pending: Vec<Vec<u8>>,
    has_vcl: bool,
}

impl AccessUnitAssembler {
    fn new() -> Self {
        Self {
            pending: Vec::new(),
            has_vcl: false,
        }
    }

    fn push(&mut self, nal: Vec<u8>) -> Vec<Vec<Vec<u8>>> {
        let mut complete = Vec::new();
        let typ = nal_type(&nal);
        let is_vcl = matches!(typ, Some(1..=5));
        let is_aud = typ == Some(9);

        if is_aud && !self.pending.is_empty() {
            if let Some(unit) = self.take_pending() {
                complete.push(unit);
            }
        } else if is_vcl && self.has_vcl && starts_new_picture(&nal) {
            if let Some(unit) = self.take_pending() {
                complete.push(unit);
            }
        } else if !is_vcl && self.has_vcl {
            // Parameter sets/SEI after VCL belong to the next picture in the
            // streams we relay. Flush the completed picture before queuing
            // those non-VCL NALs for the next access unit.
            if let Some(unit) = self.take_pending() {
                complete.push(unit);
            }
        }

        self.has_vcl |= is_vcl;
        self.pending.push(nal);
        complete
    }

    fn flush(&mut self) -> Option<Vec<Vec<u8>>> {
        self.take_pending()
    }

    fn take_pending(&mut self) -> Option<Vec<Vec<u8>>> {
        if self.pending.is_empty() {
            return None;
        }
        self.has_vcl = false;
        Some(std::mem::take(&mut self.pending))
    }
}

fn publish_access_unit(
    access_unit: Vec<Vec<u8>>,
    ctx: &SourceCtx,
    frame_id: &mut u64,
    nal_total: &mut u64,
) {
    if access_unit.is_empty() {
        return;
    }
    let now = now_ns();
    let nal_count = access_unit.len() as u32;
    let current_frame_id = *frame_id;
    for (idx, nal) in access_unit.into_iter().enumerate() {
        let frame = TimedVideoFrame {
            frame_id: current_frame_id,
            nal_index: idx as u32,
            nal_count,
            pipeline_mode: VIDEO_PIPELINE_MODE_FFMPEG,
            // No capture/encode stages on the relay path: stamp arrival
            // wall-clock into the read fields so XR-side latency logging
            // still sees a sensible producer timestamp.
            capture_start_ns: now,
            capture_end_ns: now,
            encode_start_ns: now,
            encode_end_ns: now,
            read_wait_ns: 0,
            parse_ns: 0,
            send_ns: now,
            nal,
        };
        // Ignore send errors: with no subscribers the frame is simply dropped
        // (broadcast semantics). We keep relaying regardless.
        let _ = ctx.nal_tx.send(frame);
        *nal_total += 1;
    }
    *frame_id = frame_id.wrapping_add(1);
}

/// Best-effort access-unit boundary check for VCL NALs.
///
/// H.264 starts every picture with a VCL slice whose `first_mb_in_slice` is 0.
/// Multi-slice pictures have subsequent VCL NALs with a non-zero value; those
/// stay in the same access unit. If parsing fails, assume a new picture so the
/// relay favours decoder progress over unbounded buffering.
fn starts_new_picture(nal: &[u8]) -> bool {
    first_mb_in_slice(nal).map_or(true, |v| v == 0)
}

fn first_mb_in_slice(nal: &[u8]) -> Option<u32> {
    let start = start_code_len(nal);
    if nal.len() <= start + 1 {
        return None;
    }
    // Skip the NAL header byte; the slice header begins immediately after it.
    let rbsp = rbsp_unescape(&nal[start + 1..]);
    read_ue(&rbsp)
}

fn start_code_len(nal: &[u8]) -> usize {
    if nal.len() >= 4 && nal[0] == 0 && nal[1] == 0 && nal[2] == 0 && nal[3] == 1 {
        4
    } else if nal.len() >= 3 && nal[0] == 0 && nal[1] == 0 && nal[2] == 1 {
        3
    } else {
        0
    }
}

fn rbsp_unescape(ebsp: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(ebsp.len());
    let mut i = 0;
    while i < ebsp.len() {
        if i + 2 < ebsp.len() && ebsp[i] == 0 && ebsp[i + 1] == 0 && ebsp[i + 2] == 3 {
            out.push(0);
            out.push(0);
            i += 3;
        } else {
            out.push(ebsp[i]);
            i += 1;
        }
    }
    out
}

fn read_ue(data: &[u8]) -> Option<u32> {
    let mut bit_pos = 0usize;
    let mut leading_zero_bits = 0u32;
    while bit_pos < data.len() * 8 {
        if read_bit(data, bit_pos)? {
            break;
        }
        leading_zero_bits += 1;
        bit_pos += 1;
    }
    if bit_pos >= data.len() * 8 || leading_zero_bits >= 32 {
        return None;
    }
    bit_pos += 1; // marker one bit

    let mut suffix = 0u32;
    for _ in 0..leading_zero_bits {
        suffix = (suffix << 1) | u32::from(read_bit(data, bit_pos)?);
        bit_pos += 1;
    }
    Some((1u32 << leading_zero_bits) - 1 + suffix)
}

fn read_bit(data: &[u8], bit_pos: usize) -> Option<bool> {
    let byte = *data.get(bit_pos / 8)?;
    let shift = 7 - (bit_pos % 8);
    Some(((byte >> shift) & 1) != 0)
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

    #[test]
    fn ffmpeg_args_are_low_latency_stream_copy() {
        let args = RtspSource::ffmpeg_args("rtsp://127.0.0.1:8554/wrist_left");
        let joined = args.join(" ");
        // Stream copy (no transcode) + Annex-B bitstream filter + RTSP-over-TCP.
        assert!(joined.contains("-c:v copy"));
        assert!(joined.contains("h264_mp4toannexb"));
        assert!(joined.contains("-rtsp_transport tcp"));
        assert!(joined.contains("-fflags nobuffer"));
        assert!(joined.contains("-flags low_delay"));
        assert!(joined.ends_with("pipe:1"));
        assert!(joined.contains("rtsp://127.0.0.1:8554/wrist_left"));
    }
}
