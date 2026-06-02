//! Control-path end-to-end latency instrumentation.
//!
//! Copied from `robot/src/telemetry/latency.rs` during the bridge/adapter
//! split. Self-contained: only atomics + an inline std-only `Mutex` shim, no
//! device-type dependencies. The XR network layer in this crate uses
//! [`LatencyRecorder::record_rx`], [`clock_offset_ns`](LatencyRecorder::clock_offset_ns),
//! [`set_clock_offset`](LatencyRecorder::set_clock_offset),
//! [`new_session`](LatencyRecorder::new_session), and [`wall_clock_ns`].
//!
//! Every stage of the XR → Bridge → adapter pipeline stamps a wall-clock
//! nanosecond timestamp into a [`LatencyFrame`]. Frames are pushed into a
//! ring buffer; a 1Hz aggregator drains it and logs p50/p95/p99/max for each
//! segment plus the end-to-end number.

use std::sync::atomic::{AtomicI64, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use parking_lot_compat::Mutex;

/// Per-command latency frame. All timestamps are wall-clock nanoseconds
/// (UNIX epoch) on the robot side, except [`Self::t_xr_send_ns`] which is
/// the XR-side wall clock as embedded in the `DeviceCommand`.
#[derive(Debug, Clone, Copy, Default)]
pub struct LatencyFrame {
    /// Monotonic sequence number assigned at receive time. Used to detect
    /// gaps and out-of-order arrival.
    pub seq: u64,
    /// XR-side wall clock at send (from `DeviceCommand.timestamp_ns`).
    pub t_xr_send_ns: u64,
    /// Robot wall clock just after `CommandCodec::decode` produced the
    /// `DeviceCommand` from the socket.
    pub t_rx_ns: u64,
    /// Robot wall clock just after the command crossed the mpsc/watch boundary.
    pub t_dispatch_ns: u64,
    /// Robot wall clock just before the driver write call.
    pub t_drv_start_ns: u64,
    /// Robot wall clock just after the driver write call returned.
    pub t_drv_done_ns: u64,
}

impl LatencyFrame {
    /// New frame with only the receive-side fields populated.
    pub fn new_at_rx(seq: u64, t_xr_send_ns: u64, t_rx_ns: u64) -> Self {
        Self {
            seq,
            t_xr_send_ns,
            t_rx_ns,
            t_dispatch_ns: 0,
            t_drv_start_ns: 0,
            t_drv_done_ns: 0,
        }
    }
}

/// Wall-clock nanoseconds since UNIX epoch. Matches the convention used by
/// the video pipeline so cross-pipeline subtraction is well defined.
#[inline]
pub fn wall_clock_ns() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos() as u64)
        .unwrap_or(0)
}

/// Ring buffer of completed [`LatencyFrame`]s. Drained once per
/// aggregation tick.
const RING_CAPACITY: usize = 8192;

/// Globally accessible latency recorder. Wrapped in an `Arc` so probe
/// sites can hold a clone without lifetime fuss.
#[derive(Default)]
pub struct LatencyRecorder {
    /// Next sequence to assign on `record_rx`.
    next_seq: AtomicU64,
    /// Active session ID (zero means "none").
    session_id: AtomicU64,
    /// Most recent XR↔Robot clock offset in ns, signed. Positive means
    /// the XR clock leads the robot clock. Updated by ClockPong replies.
    clock_offset_ns: AtomicI64,
    /// Ring buffer of completed frames.
    completed: Mutex<RingBuffer>,
}

struct RingBuffer {
    buf: Box<[LatencyFrame; RING_CAPACITY]>,
    write: usize,
    dropped: u64,
}

impl Default for RingBuffer {
    fn default() -> Self {
        Self {
            buf: Box::new([LatencyFrame::default(); RING_CAPACITY]),
            write: 0,
            dropped: 0,
        }
    }
}

impl RingBuffer {
    fn push(&mut self, frame: LatencyFrame) {
        let slot = &mut self.buf[self.write];
        if slot.seq != 0 && slot.t_drv_done_ns != 0 {
            self.dropped += 1;
        }
        *slot = frame;
        self.write = (self.write + 1) % RING_CAPACITY;
    }

    fn drain(&mut self) -> (Vec<LatencyFrame>, u64) {
        let mut out = Vec::with_capacity(RING_CAPACITY);
        for slot in self.buf.iter_mut() {
            if slot.seq != 0 && slot.t_drv_done_ns != 0 {
                out.push(*slot);
                *slot = LatencyFrame::default();
            }
        }
        let dropped = self.dropped;
        self.dropped = 0;
        self.write = 0;
        (out, dropped)
    }
}

impl LatencyRecorder {
    pub fn new() -> Arc<Self> {
        Arc::new(Self::default())
    }

    /// Assign the next sequence number and stamp the receive time. Returns
    /// the seq so callers can carry it forward to later stages.
    pub fn record_rx(&self, t_xr_send_ns: u64, t_rx_ns: u64) -> u64 {
        // seq 0 is reserved as a sentinel for "empty slot" so start at 1.
        let seq = self.next_seq.fetch_add(1, Ordering::Relaxed) + 1;
        let _ = (t_xr_send_ns, t_rx_ns);
        seq
    }

    /// Push a fully populated frame into the ring buffer.
    pub fn record_complete(&self, frame: LatencyFrame) {
        self.completed.lock().push(frame);
    }

    /// Update the XR↔Robot wall-clock offset. Called from the ClockPong
    /// path. `offset_ns` = XR clock − Robot clock at the same instant.
    pub fn set_clock_offset(&self, offset_ns: i64) {
        self.clock_offset_ns.store(offset_ns, Ordering::Relaxed);
    }

    pub fn clock_offset_ns(&self) -> i64 {
        self.clock_offset_ns.load(Ordering::Relaxed)
    }

    /// Bump the active session id on reconnect.
    pub fn new_session(&self) -> u64 {
        self.session_id.fetch_add(1, Ordering::Relaxed) + 1
    }

    pub fn session_id(&self) -> u64 {
        self.session_id.load(Ordering::Relaxed)
    }
}

/// 1Hz aggregator. Drains the ring buffer, computes percentiles, logs a
/// single structured line, and repeats.
pub async fn run_aggregator(recorder: Arc<LatencyRecorder>) -> anyhow::Result<()> {
    let mut interval = tokio::time::interval(std::time::Duration::from_secs(1));
    // First tick fires immediately — skip it so the first log line covers
    // a real 1s window.
    interval.tick().await;

    loop {
        interval.tick().await;
        let (frames, dropped) = {
            let mut buf = recorder.completed.lock();
            buf.drain()
        };

        if frames.is_empty() {
            tracing::trace!("latency: no frames in window");
            continue;
        }

        let stats = Stats::from_frames(&frames, recorder.clock_offset_ns());
        tracing::info!(
            target: "latency",
            "n={n} dropped={dropped} \
             xr_rx(p50/p95/p99/max)={x50:.2}/{x95:.2}/{x99:.2}/{xmax:.2}ms \
             rx_disp(p50/p95)={r50:.2}/{r95:.2}ms \
             disp_drv(p50/p95)={d50:.2}/{d95:.2}ms \
             drv(p50/p95)={v50:.2}/{v95:.2}ms \
             e2e(p50/p95/p99/max)={e50:.2}/{e95:.2}/{e99:.2}/{emax:.2}ms \
             seq_gap_max={gap}",
            n = frames.len(),
            dropped = dropped,
            x50 = stats.xr_rx.p50_ms,
            x95 = stats.xr_rx.p95_ms,
            x99 = stats.xr_rx.p99_ms,
            xmax = stats.xr_rx.max_ms,
            r50 = stats.rx_dispatch.p50_ms,
            r95 = stats.rx_dispatch.p95_ms,
            d50 = stats.dispatch_drv.p50_ms,
            d95 = stats.dispatch_drv.p95_ms,
            v50 = stats.drv.p50_ms,
            v95 = stats.drv.p95_ms,
            e50 = stats.e2e.p50_ms,
            e95 = stats.e2e.p95_ms,
            e99 = stats.e2e.p99_ms,
            emax = stats.e2e.max_ms,
            gap = stats.seq_gap_max,
        );
    }
}

#[derive(Debug, Clone, Copy, Default)]
pub struct Bucket {
    pub p50_ms: f64,
    pub p95_ms: f64,
    pub p99_ms: f64,
    pub max_ms: f64,
}

impl Bucket {
    fn from_sorted_ns(sorted: &[i64]) -> Self {
        if sorted.is_empty() {
            return Self::default();
        }
        let pct = |p: f64| -> f64 {
            let idx = ((sorted.len() as f64 - 1.0) * p).round() as usize;
            ns_to_ms(sorted[idx])
        };
        Self {
            p50_ms: pct(0.50),
            p95_ms: pct(0.95),
            p99_ms: pct(0.99),
            max_ms: ns_to_ms(*sorted.last().unwrap()),
        }
    }
}

#[derive(Debug, Clone, Copy, Default)]
pub struct Stats {
    pub xr_rx: Bucket,
    pub rx_dispatch: Bucket,
    pub dispatch_drv: Bucket,
    pub drv: Bucket,
    pub e2e: Bucket,
    pub seq_gap_max: u64,
}

impl Stats {
    pub fn from_frames(frames: &[LatencyFrame], clock_offset_ns: i64) -> Self {
        let n = frames.len();
        let mut xr_rx = Vec::with_capacity(n);
        let mut rx_disp = Vec::with_capacity(n);
        let mut disp_drv = Vec::with_capacity(n);
        let mut drv = Vec::with_capacity(n);
        let mut e2e = Vec::with_capacity(n);

        let mut seqs: Vec<u64> = frames.iter().map(|f| f.seq).collect();
        seqs.sort_unstable();
        let mut gap_max = 0u64;
        for w in seqs.windows(2) {
            let gap = w[1] - w[0];
            if gap > gap_max {
                gap_max = gap;
            }
        }

        for f in frames {
            let rx_to_disp = f.t_dispatch_ns as i64 - f.t_rx_ns as i64;
            let disp_to_drv = f.t_drv_start_ns as i64 - f.t_dispatch_ns as i64;
            let drv_span = f.t_drv_done_ns as i64 - f.t_drv_start_ns as i64;
            let xr_send_robot_ns = f.t_xr_send_ns as i64 - clock_offset_ns;
            let xr_to_rx = f.t_rx_ns as i64 - xr_send_robot_ns;
            let e2e_span = f.t_drv_done_ns as i64 - xr_send_robot_ns;

            if rx_to_disp >= 0 {
                rx_disp.push(rx_to_disp);
            }
            if disp_to_drv >= 0 {
                disp_drv.push(disp_to_drv);
            }
            if drv_span >= 0 {
                drv.push(drv_span);
            }
            if xr_to_rx >= 0 {
                xr_rx.push(xr_to_rx);
            }
            if e2e_span >= 0 {
                e2e.push(e2e_span);
            }
        }

        for v in [&mut xr_rx, &mut rx_disp, &mut disp_drv, &mut drv, &mut e2e] {
            v.sort_unstable();
        }

        Self {
            xr_rx: Bucket::from_sorted_ns(&xr_rx),
            rx_dispatch: Bucket::from_sorted_ns(&rx_disp),
            dispatch_drv: Bucket::from_sorted_ns(&disp_drv),
            drv: Bucket::from_sorted_ns(&drv),
            e2e: Bucket::from_sorted_ns(&e2e),
            seq_gap_max: gap_max,
        }
    }
}

#[inline]
fn ns_to_ms(ns: i64) -> f64 {
    ns as f64 / 1_000_000.0
}

/// Tiny std-only Mutex shim so we don't depend on parking_lot.
mod parking_lot_compat {
    use std::sync::MutexGuard;

    pub struct Mutex<T> {
        inner: std::sync::Mutex<T>,
    }

    impl<T: Default> Default for Mutex<T> {
        fn default() -> Self {
            Self {
                inner: std::sync::Mutex::new(T::default()),
            }
        }
    }

    impl<T> Mutex<T> {
        #[allow(dead_code)]
        pub fn new(t: T) -> Self {
            Self {
                inner: std::sync::Mutex::new(t),
            }
        }

        pub fn lock(&self) -> MutexGuard<'_, T> {
            // Poisoning is fatal here; latency recording must never panic
            // the caller. On poison, just take the guard anyway.
            match self.inner.lock() {
                Ok(g) => g,
                Err(poisoned) => poisoned.into_inner(),
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bucket_percentiles_basic() {
        let mut data: Vec<i64> = (1..=100).map(|x| x * 1_000_000).collect();
        data.sort_unstable();
        let b = Bucket::from_sorted_ns(&data);
        assert!((b.p50_ms - 50.0).abs() <= 2.0, "p50={}", b.p50_ms);
        assert!((b.p95_ms - 95.0).abs() <= 2.0, "p95={}", b.p95_ms);
        assert!((b.p99_ms - 99.0).abs() <= 2.0, "p99={}", b.p99_ms);
        assert!((b.max_ms - 100.0).abs() < 0.001, "max={}", b.max_ms);
    }

    #[test]
    fn ring_buffer_drain_clears_slots() {
        let mut rb = RingBuffer::default();
        for i in 1..=10 {
            rb.push(LatencyFrame {
                seq: i,
                t_drv_done_ns: 1,
                ..LatencyFrame::default()
            });
        }
        let (drained, _dropped) = rb.drain();
        assert_eq!(drained.len(), 10);
        let (drained2, _) = rb.drain();
        assert_eq!(drained2.len(), 0);
    }

    #[test]
    fn stats_seq_gap_detected() {
        let frames = vec![
            LatencyFrame {
                seq: 1,
                t_drv_done_ns: 1,
                ..Default::default()
            },
            LatencyFrame {
                seq: 2,
                t_drv_done_ns: 1,
                ..Default::default()
            },
            // gap of 3 here.
            LatencyFrame {
                seq: 5,
                t_drv_done_ns: 1,
                ..Default::default()
            },
        ];
        let s = Stats::from_frames(&frames, 0);
        assert_eq!(s.seq_gap_max, 3);
    }

    #[test]
    fn record_rx_assigns_monotonic_seq() {
        let rec = LatencyRecorder::new();
        let a = rec.record_rx(0, 0);
        let b = rec.record_rx(0, 0);
        assert_eq!(a, 1);
        assert_eq!(b, 2);
    }

    #[test]
    fn clock_offset_roundtrips() {
        let rec = LatencyRecorder::new();
        assert_eq!(rec.clock_offset_ns(), 0);
        rec.set_clock_offset(-12345);
        assert_eq!(rec.clock_offset_ns(), -12345);
    }

    #[test]
    fn new_session_increments() {
        let rec = LatencyRecorder::new();
        assert_eq!(rec.session_id(), 0);
        assert_eq!(rec.new_session(), 1);
        assert_eq!(rec.new_session(), 2);
        assert_eq!(rec.session_id(), 2);
    }
}
