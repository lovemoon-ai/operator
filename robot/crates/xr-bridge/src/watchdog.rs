//! Liveness watchdog for the bridge↔adapter link.
//!
//! Tracks the time of the last forwarded command. If more than
//! `command_timeout` elapses without a fresh command, the watchdog fires the
//! disconnect action exactly **once** (by invoking a caller-provided async
//! `StopAction`) and stays latched until a new [`Watchdog::note_command`]
//! resets it. The next idle period then re-arms and can fire again.
//!
//! Unlike the robot-side control loop (`robot/src/device/control_loop.rs`)
//! whose disconnect action drives hardware, the bridge-side action is "tell the
//! adapter to Stop" — the concrete effect is injected by the caller.
//!
//! Designed to be unit-testable under `tokio::time` paused clock: construct a
//! [`Watchdog`], drive it from a task that uses [`Watchdog::poll_period`] as a
//! tick interval, and `tokio::time::advance` to make idle periods elapse.

use std::sync::Arc;

use tokio::sync::Mutex;
use tokio::time::{Duration, Instant};

/// An async callback invoked when the watchdog fires. The bridge wires this to
/// "send `BridgeToAdapter::Stop { reason }` to the adapter".
///
/// It is boxed and shared so the watchdog can be cloned across tasks.
pub type StopAction = Arc<dyn Fn(String) -> futures::future::BoxFuture<'static, ()> + Send + Sync>;

/// Liveness tracker. See module docs.
#[derive(Clone)]
pub struct Watchdog {
    inner: Arc<Mutex<WatchdogState>>,
    timeout: Duration,
    action: StopAction,
}

struct WatchdogState {
    /// When the most recent command was noted. `None` until the first command.
    last_cmd_at: Option<Instant>,
    /// Whether we have already fired for the current idle period.
    fired: bool,
}

impl Watchdog {
    /// Build a watchdog with the given idle `timeout` and `StopAction`.
    ///
    /// `timeout` is typically `descriptor.safety.timeout()`.
    pub fn new(timeout: Duration, action: StopAction) -> Self {
        Self {
            inner: Arc::new(Mutex::new(WatchdogState {
                last_cmd_at: None,
                fired: false,
            })),
            timeout,
            action,
        }
    }

    /// The configured idle timeout.
    pub fn timeout(&self) -> Duration {
        self.timeout
    }

    /// Suggested polling period for a driver loop: a quarter of the timeout,
    /// clamped to a sane 50–250 ms band (mirrors the robot control loop).
    pub fn poll_period(&self) -> Duration {
        self.timeout
            .checked_div(4)
            .unwrap_or(Duration::from_millis(100))
            .clamp(Duration::from_millis(50), Duration::from_millis(250))
    }

    /// Record that a fresh command was just forwarded. Resets the idle timer
    /// and clears the latched "fired" flag so a future idle period can fire
    /// again.
    pub async fn note_command(&self) {
        let mut st = self.inner.lock().await;
        st.last_cmd_at = Some(Instant::now());
        st.fired = false;
    }

    /// Check whether the idle timeout has elapsed and, if so and not already
    /// fired for this idle period, invoke the `StopAction` exactly once.
    ///
    /// Returns `true` if the action fired on this call.
    pub async fn tick(&self, reason: impl Into<String>) -> bool {
        let should_fire = {
            let mut st = self.inner.lock().await;
            match st.last_cmd_at {
                Some(t) if !st.fired && t.elapsed() > self.timeout => {
                    st.fired = true;
                    true
                }
                _ => false,
            }
        };
        if should_fire {
            let reason = reason.into();
            tracing::warn!("Watchdog fired: {reason}");
            (self.action)(reason).await;
        }
        should_fire
    }

    /// Spawn a background task that polls [`Watchdog::tick`] on
    /// [`Watchdog::poll_period`] forever. Returns the join handle.
    pub fn spawn(self, reason: impl Into<String>) -> tokio::task::JoinHandle<()> {
        let reason = reason.into();
        let period = self.poll_period();
        tokio::spawn(async move {
            let mut interval = tokio::time::interval(period);
            interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
            loop {
                interval.tick().await;
                let _ = self.tick(reason.clone()).await;
            }
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    /// Build a watchdog and a shared counter the StopAction increments.
    fn watchdog_with_counter(timeout: Duration) -> (Watchdog, Arc<AtomicUsize>) {
        let counter = Arc::new(AtomicUsize::new(0));
        let c = counter.clone();
        let action: StopAction = Arc::new(move |_reason: String| {
            let c = c.clone();
            Box::pin(async move {
                c.fetch_add(1, Ordering::SeqCst);
            })
        });
        (Watchdog::new(timeout, action), counter)
    }

    #[tokio::test(start_paused = true)]
    async fn fires_once_after_timeout_then_not_again() {
        let timeout = Duration::from_millis(500);
        let (wd, fired) = watchdog_with_counter(timeout);

        // A command starts the idle timer.
        wd.note_command().await;

        // Before timeout: no fire.
        tokio::time::advance(Duration::from_millis(300)).await;
        assert!(!wd.tick("idle").await);
        assert_eq!(fired.load(Ordering::SeqCst), 0);

        // Cross the timeout: fires exactly once.
        tokio::time::advance(Duration::from_millis(300)).await;
        assert!(wd.tick("idle").await, "should fire after timeout");
        assert_eq!(fired.load(Ordering::SeqCst), 1);

        // Advancing further without a fresh command: does NOT fire again.
        tokio::time::advance(Duration::from_secs(5)).await;
        assert!(!wd.tick("idle").await, "should not re-fire while still idle");
        assert_eq!(fired.load(Ordering::SeqCst), 1);
    }

    #[tokio::test(start_paused = true)]
    async fn fresh_command_resets_and_allows_refire() {
        let timeout = Duration::from_millis(500);
        let (wd, fired) = watchdog_with_counter(timeout);

        wd.note_command().await;
        tokio::time::advance(Duration::from_millis(600)).await;
        assert!(wd.tick("idle").await);
        assert_eq!(fired.load(Ordering::SeqCst), 1);

        // Fresh command resets the timer and clears the latch.
        wd.note_command().await;
        // Immediately after reset: not idle long enough.
        tokio::time::advance(Duration::from_millis(300)).await;
        assert!(!wd.tick("idle").await);
        assert_eq!(fired.load(Ordering::SeqCst), 1);

        // Next idle period fires again.
        tokio::time::advance(Duration::from_millis(300)).await;
        assert!(wd.tick("idle").await, "should fire on the second idle period");
        assert_eq!(fired.load(Ordering::SeqCst), 2);
    }

    #[tokio::test(start_paused = true)]
    async fn does_not_fire_before_first_command() {
        let timeout = Duration::from_millis(500);
        let (wd, fired) = watchdog_with_counter(timeout);

        // No command ever noted: the timer never started, so no fire.
        tokio::time::advance(Duration::from_secs(10)).await;
        assert!(!wd.tick("idle").await);
        assert_eq!(fired.load(Ordering::SeqCst), 0);
    }
}
