use std::collections::VecDeque;
use std::net::IpAddr;
use std::sync::{Arc, Condvar, Mutex};
use std::thread::JoinHandle;
use std::time::Duration;

use pyo3::exceptions::{PyRuntimeError, PyValueError};
use pyo3::prelude::*;
use tokio::sync::{mpsc, oneshot, watch};

use teleop_protocol::{Blueprint, BlueprintEvent, BlueprintState, XrStateFrame, SPEC_SHA256};
use xr_bridge::config::BridgeConfig;
use xr_bridge::sdk::{
    run_sdk_mode_with_startup_and_blueprint, state_channel, BlueprintStreams, XrStateStats,
};

const MAX_PENDING_BLUEPRINT_EVENTS: usize = 256;

#[derive(Default)]
struct LatestState {
    frame: Option<Arc<XrStateFrame>>,
    running: bool,
    error: Option<String>,
}

#[derive(Default)]
struct SharedState {
    latest: Mutex<LatestState>,
    changed: Condvar,
    stats: Mutex<Option<Arc<XrStateStats>>>,
    blueprint_events: Mutex<BlueprintEventState>,
    blueprint_event_changed: Condvar,
}

#[derive(Default)]
struct BlueprintEventState {
    events: VecDeque<BlueprintEvent>,
    running: bool,
}

#[pyclass]
struct NativeSession {
    config: BridgeConfig,
    shared: Arc<SharedState>,
    blueprint_tx: watch::Sender<Option<Arc<Blueprint>>>,
    blueprint_state_tx: watch::Sender<Option<Arc<BlueprintState>>>,
    shutdown: Mutex<Option<watch::Sender<bool>>>,
    thread: Mutex<Option<JoinHandle<()>>>,
}

#[pymethods]
impl NativeSession {
    #[new]
    #[pyo3(signature = (
        name = "pyoperator".to_string(),
        pose_port = 63901,
        discovery_port = 63900,
        pose_udp_port = 63902,
        telemetry_port = 63903,
        discovery_unicast_targets = Vec::new()
    ))]
    fn new(
        name: String,
        pose_port: u16,
        discovery_port: u16,
        pose_udp_port: u16,
        telemetry_port: u16,
        discovery_unicast_targets: Vec<String>,
    ) -> PyResult<Self> {
        let targets = discovery_unicast_targets
            .iter()
            .map(|value| {
                value.parse::<IpAddr>().map_err(|error| {
                    PyValueError::new_err(format!("invalid discovery target {value:?}: {error}"))
                })
            })
            .collect::<PyResult<Vec<_>>>()?;
        let config = BridgeConfig {
            name,
            pose_port,
            discovery_port,
            pose_udp_port,
            telemetry_port,
            discovery_unicast_targets: targets,
            ..BridgeConfig::default()
        };
        let (blueprint_tx, _) = watch::channel(None);
        let (blueprint_state_tx, _) = watch::channel(None);
        Ok(Self {
            config,
            shared: Arc::new(SharedState::default()),
            blueprint_tx,
            blueprint_state_tx,
            shutdown: Mutex::new(None),
            thread: Mutex::new(None),
        })
    }

    fn start(&self, py: Python<'_>) -> PyResult<()> {
        let mut thread_slot = self
            .thread
            .lock()
            .map_err(|_| PyRuntimeError::new_err("native session thread lock poisoned"))?;
        if thread_slot
            .as_ref()
            .is_some_and(|thread| !thread.is_finished())
        {
            return Ok(());
        }
        if let Some(finished) = thread_slot.take() {
            let _ = finished.join();
        }

        let config = self.config.clone();
        let shared = self.shared.clone();
        let blueprint_rx = self.blueprint_tx.subscribe();
        let blueprint_state_rx = self.blueprint_state_tx.subscribe();
        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        let mut shutdown_slot = self
            .shutdown
            .lock()
            .map_err(|_| PyRuntimeError::new_err("native session shutdown lock poisoned"))?;
        reset_for_start(&shared)?;
        let (startup_tx, startup_rx) = oneshot::channel();

        let thread = match std::thread::Builder::new()
            .name("pyoperator".into())
            .spawn(move || {
                run_background(
                    config,
                    shared,
                    shutdown_rx,
                    startup_tx,
                    blueprint_rx,
                    blueprint_state_rx,
                )
            }) {
            Ok(thread) => thread,
            Err(error) => {
                let message = format!("starting pyoperator thread: {error}");
                finish_with_error(&self.shared, message.clone());
                return Err(PyRuntimeError::new_err(message));
            }
        };
        *thread_slot = Some(thread);
        *shutdown_slot = Some(shutdown_tx);
        drop(shutdown_slot);

        match py.allow_threads(move || startup_rx.blocking_recv()) {
            Ok(Ok(())) => Ok(()),
            startup => {
                let message = match startup {
                    Ok(Err(error)) => error,
                    Err(_) => {
                        "pyoperator startup thread exited before reporting readiness".to_string()
                    }
                    Ok(Ok(())) => unreachable!(),
                };
                let thread = thread_slot.take();
                drop(thread_slot);
                if let Ok(mut shutdown) = self.shutdown.lock() {
                    if let Some(sender) = shutdown.take() {
                        let _ = sender.send(true);
                    }
                }
                if let Some(thread) = thread {
                    py.allow_threads(move || {
                        let _ = thread.join();
                    });
                }
                finish_with_error(&self.shared, message.clone());
                Err(PyRuntimeError::new_err(format!(
                    "starting pyoperator: {message}"
                )))
            }
        }
    }

    fn close(&self, py: Python<'_>) -> PyResult<()> {
        if let Ok(mut shutdown) = self.shutdown.lock() {
            if let Some(sender) = shutdown.take() {
                let _ = sender.send(true);
            }
        }
        let thread = self
            .thread
            .lock()
            .map_err(|_| PyRuntimeError::new_err("native session thread lock poisoned"))?
            .take();
        if let Some(thread) = thread {
            py.allow_threads(move || {
                let _ = thread.join();
            });
        }
        Ok(())
    }

    fn is_running(&self) -> bool {
        self.shared
            .latest
            .lock()
            .map(|state| state.running)
            .unwrap_or(false)
    }

    fn blueprint_spec_sha256(&self) -> &'static str {
        SPEC_SHA256
    }

    fn latest_json(&self) -> PyResult<Option<String>> {
        let state = self
            .shared
            .latest
            .lock()
            .map_err(|_| PyRuntimeError::new_err("native session state lock poisoned"))?;
        state.frame.as_ref().map(serialize_frame).transpose()
    }

    #[pyo3(signature = (after_frame_id = 0, timeout_seconds = None))]
    fn wait_next_json(
        &self,
        py: Python<'_>,
        after_frame_id: u64,
        timeout_seconds: Option<f64>,
    ) -> PyResult<Option<String>> {
        if timeout_seconds.is_some_and(|value| value < 0.0 || !value.is_finite()) {
            return Err(PyValueError::new_err(
                "timeout_seconds must be finite and non-negative",
            ));
        }
        let shared = self.shared.clone();
        let frame = py.allow_threads(move || {
            wait_for_frame(
                &shared,
                after_frame_id,
                timeout_seconds.map(Duration::from_secs_f64),
            )
        })?;
        frame.as_ref().map(serialize_frame).transpose()
    }

    fn set_blueprint_json(&self, payload: &str) -> PyResult<()> {
        let blueprint: Blueprint = serde_json::from_str(payload)
            .map_err(|error| PyValueError::new_err(format!("invalid Blueprint JSON: {error}")))?;
        blueprint
            .validate()
            .map_err(|error| PyValueError::new_err(format!("invalid Blueprint: {error}")))?;
        clear_pending_blueprint_events(&self.shared)?;
        self.blueprint_state_tx.send_replace(None);
        self.blueprint_tx.send_replace(Some(Arc::new(blueprint)));
        Ok(())
    }

    fn clear_blueprint(&self) -> PyResult<()> {
        clear_pending_blueprint_events(&self.shared)?;
        self.blueprint_tx.send_replace(None);
        self.blueprint_state_tx.send_replace(None);
        Ok(())
    }

    fn publish_blueprint_state_json(&self, payload: &str) -> PyResult<()> {
        let state: BlueprintState = serde_json::from_str(payload).map_err(|error| {
            PyValueError::new_err(format!("invalid BlueprintState JSON: {error}"))
        })?;
        let active_blueprint =
            self.blueprint_tx.borrow().clone().ok_or_else(|| {
                PyValueError::new_err("invalid BlueprintState: no active Blueprint")
            })?;
        active_blueprint
            .validate_state(&state)
            .map_err(|error| PyValueError::new_err(format!("invalid BlueprintState: {error}")))?;
        self.blueprint_state_tx.send_replace(Some(Arc::new(state)));
        Ok(())
    }

    #[pyo3(signature = (timeout_seconds = None))]
    fn poll_blueprint_event_json(
        &self,
        py: Python<'_>,
        timeout_seconds: Option<f64>,
    ) -> PyResult<Option<String>> {
        if timeout_seconds.is_some_and(|value| value < 0.0 || !value.is_finite()) {
            return Err(PyValueError::new_err(
                "timeout_seconds must be finite and non-negative",
            ));
        }
        let shared = self.shared.clone();
        let event = py.allow_threads(move || {
            wait_for_blueprint_event(&shared, timeout_seconds.map(Duration::from_secs_f64))
        })?;
        event
            .as_ref()
            .map(serde_json::to_string)
            .transpose()
            .map_err(|error| {
                PyRuntimeError::new_err(format!("serializing blueprint event: {error}"))
            })
    }

    fn stats_json(&self) -> PyResult<String> {
        let stats = self
            .shared
            .stats
            .lock()
            .map_err(|_| PyRuntimeError::new_err("native stats lock poisoned"))?
            .clone();
        let latest = self
            .shared
            .latest
            .lock()
            .map_err(|_| PyRuntimeError::new_err("native state lock poisoned"))?;
        let value = if let Some(stats) = stats {
            serde_json::json!({
                "running": latest.running,
                "connected": stats.connected(),
                "frames_received": stats.frames_received(),
                "parse_errors": stats.parse_errors(),
                "last_frame_id": stats.last_frame_id(),
                "last_timestamp_ns": stats.last_timestamp_ns(),
                "last_error": latest.error.clone().or_else(|| stats.last_error()),
            })
        } else {
            serde_json::json!({
                "running": latest.running,
                "connected": false,
                "frames_received": 0,
                "parse_errors": 0,
                "last_frame_id": 0,
                "last_timestamp_ns": 0,
                "last_error": latest.error,
            })
        };
        serde_json::to_string(&value)
            .map_err(|error| PyRuntimeError::new_err(format!("serializing stats: {error}")))
    }
}

fn clear_pending_blueprint_events(shared: &SharedState) -> PyResult<()> {
    shared
        .blueprint_events
        .lock()
        .map_err(|_| PyRuntimeError::new_err("native blueprint event lock poisoned"))?
        .events
        .clear();
    Ok(())
}

impl Drop for NativeSession {
    fn drop(&mut self) {
        if let Ok(mut shutdown) = self.shutdown.lock() {
            if let Some(sender) = shutdown.take() {
                let _ = sender.send(true);
            }
        }
        if let Ok(mut slot) = self.thread.lock() {
            if let Some(thread) = slot.take() {
                let _ = thread.join();
            }
        }
    }
}

fn run_background(
    config: BridgeConfig,
    shared: Arc<SharedState>,
    shutdown_rx: watch::Receiver<bool>,
    startup_tx: oneshot::Sender<std::result::Result<(), String>>,
    blueprint_rx: watch::Receiver<Option<Arc<Blueprint>>>,
    blueprint_state_rx: watch::Receiver<Option<Arc<BlueprintState>>>,
) {
    let runtime = match tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .worker_threads(2)
        .thread_name("pyoperator-io")
        .build()
    {
        Ok(runtime) => runtime,
        Err(error) => {
            let message = format!("creating Tokio runtime: {error}");
            let _ = startup_tx.send(Err(message.clone()));
            finish_with_error(&shared, message);
            return;
        }
    };

    let (sink, mut frame_rx) = state_channel();
    if let Ok(mut stats) = shared.stats.lock() {
        *stats = Some(sink.stats.clone());
    }

    let result = runtime.block_on(async {
        let (blueprint_event_tx, mut blueprint_event_rx) =
            mpsc::channel(MAX_PENDING_BLUEPRINT_EVENTS);
        let service = run_sdk_mode_with_startup_and_blueprint(
            config,
            sink,
            shutdown_rx,
            startup_tx,
            BlueprintStreams {
                blueprint_rx,
                state_rx: blueprint_state_rx,
                event_tx: blueprint_event_tx,
            },
        );
        tokio::pin!(service);
        loop {
            tokio::select! {
                result = &mut service => break result,
                event = blueprint_event_rx.recv() => {
                    let Some(event) = event else {
                        continue;
                    };
                    if let Ok(mut state) = shared.blueprint_events.lock() {
                        if state.events.len() >= MAX_PENDING_BLUEPRINT_EVENTS {
                            state.events.pop_front();
                        }
                        state.events.push_back(event);
                        shared.blueprint_event_changed.notify_all();
                    }
                }
                changed = frame_rx.changed() => {
                    if changed.is_err() {
                        break Ok(());
                    }
                    let frame = frame_rx.borrow_and_update().clone();
                    if let Some(frame) = frame {
                        if let Ok(mut state) = shared.latest.lock() {
                            state.frame = Some(frame);
                            shared.changed.notify_all();
                        }
                    }
                }
            }
        }
    });

    match result {
        Ok(()) => finish_with_error(&shared, String::new()),
        Err(error) => finish_with_error(&shared, error.to_string()),
    }
}

fn reset_for_start(shared: &SharedState) -> PyResult<()> {
    *shared
        .stats
        .lock()
        .map_err(|_| PyRuntimeError::new_err("native stats lock poisoned"))? = None;
    let mut latest = shared
        .latest
        .lock()
        .map_err(|_| PyRuntimeError::new_err("native session state lock poisoned"))?;
    latest.frame = None;
    latest.running = true;
    latest.error = None;
    let mut blueprint = shared
        .blueprint_events
        .lock()
        .map_err(|_| PyRuntimeError::new_err("native blueprint event lock poisoned"))?;
    blueprint.events.clear();
    blueprint.running = true;
    drop(blueprint);
    shared.changed.notify_all();
    shared.blueprint_event_changed.notify_all();
    Ok(())
}

fn finish_with_error(shared: &SharedState, error: String) {
    if let Ok(mut state) = shared.latest.lock() {
        state.running = false;
        if !error.is_empty() {
            state.error = Some(error);
        }
        shared.changed.notify_all();
    }
    if let Ok(mut blueprint) = shared.blueprint_events.lock() {
        blueprint.running = false;
        shared.blueprint_event_changed.notify_all();
    }
}

fn wait_for_blueprint_event(
    shared: &SharedState,
    timeout: Option<Duration>,
) -> PyResult<Option<BlueprintEvent>> {
    let state = shared
        .blueprint_events
        .lock()
        .map_err(|_| PyRuntimeError::new_err("native blueprint event lock poisoned"))?;
    let ready = |state: &BlueprintEventState| !state.events.is_empty() || !state.running;
    let mut state = if ready(&state) {
        state
    } else if let Some(timeout) = timeout {
        shared
            .blueprint_event_changed
            .wait_timeout_while(state, timeout, |state| !ready(state))
            .map_err(|_| PyRuntimeError::new_err("native blueprint event lock poisoned"))?
            .0
    } else {
        shared
            .blueprint_event_changed
            .wait_while(state, |state| !ready(state))
            .map_err(|_| PyRuntimeError::new_err("native blueprint event lock poisoned"))?
    };
    Ok(state.events.pop_front())
}

fn wait_for_frame(
    shared: &SharedState,
    after_frame_id: u64,
    timeout: Option<Duration>,
) -> PyResult<Option<Arc<XrStateFrame>>> {
    let state = shared
        .latest
        .lock()
        .map_err(|_| PyRuntimeError::new_err("native state lock poisoned"))?;
    let ready = |state: &LatestState| {
        state
            .frame
            .as_ref()
            // Frame ids belong to the headset process, not this service. A
            // headset reconnect may therefore reset the id to zero. TCP
            // preserves ordering within a connection, so inequality is the
            // correct "new snapshot" test and also handles counter wrap.
            .is_some_and(|frame| frame.frame_id != after_frame_id)
            || !state.running
    };
    let state = if ready(&state) {
        state
    } else if let Some(timeout) = timeout {
        shared
            .changed
            .wait_timeout_while(state, timeout, |state| !ready(state))
            .map_err(|_| PyRuntimeError::new_err("native state lock poisoned"))?
            .0
    } else {
        shared
            .changed
            .wait_while(state, |state| !ready(state))
            .map_err(|_| PyRuntimeError::new_err("native state lock poisoned"))?
    };
    Ok(state
        .frame
        .as_ref()
        .filter(|frame| frame.frame_id != after_frame_id)
        .cloned())
}

fn serialize_frame(frame: &Arc<XrStateFrame>) -> PyResult<String> {
    serde_json::to_string(frame.as_ref())
        .map_err(|error| PyRuntimeError::new_err(format!("serializing XR state: {error}")))
}

#[pymodule]
fn _native(module: &Bound<'_, PyModule>) -> PyResult<()> {
    module.add_class::<NativeSession>()?;
    module.add(
        "XR_STATE_SCHEMA_VERSION",
        teleop_protocol::XR_STATE_SCHEMA_VERSION,
    )?;
    Ok(())
}
