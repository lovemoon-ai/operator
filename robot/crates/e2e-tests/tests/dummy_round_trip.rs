//! End-to-end: the real `xr-bridge` AdapterClient driving the real
//! `robot-adapter` server over a real loopback socket, using the
//! `teleop-protocol` boundary transport.
//!
//! This is the architecture-proving vertical slice for the bridge/adapter
//! split. It crosses every layer that matters:
//!   bridge input-sanitization (DeviceSafety) → BridgeCodec frame → socket
//!   → AdapterCodec decode → DummyDevice → Telemetry frame → bridge watch.
//!
//! Run with: `cargo test -p e2e-tests`

use std::time::Duration;

use robot_adapter::devices::DummyDevice;
use robot_adapter::server::serve;
use robot_adapter::DummyHandle;
use teleop_protocol::{listen, DeviceCommand, DeviceDescriptor, Endpoint};
use tokio::time::{sleep, timeout};
use xr_bridge::adapter_client::AdapterClient;
use xr_bridge::safety::{DeviceSafety, SafetyResult};

/// A dummy descriptor with one declared axis ("gripper", range 0..1) so the
/// bridge's `DeviceSafety` has something to clamp against (it rejects unknown
/// axis names, so an empty schema would reject our command).
fn descriptor_with_gripper() -> DeviceDescriptor {
    serde_json::from_value(serde_json::json!({
        "device": { "type": "dummy", "name": "E2E Dummy" },
        "control_schema": {
            "axes": [
                { "name": "gripper", "range": [0.0, 1.0], "dead_zone": 0.0 }
            ]
        },
        "safety": { "command_timeout_ms": 200 }
    }))
    .expect("descriptor JSON should deserialize")
}

/// Spin up a real adapter server on an ephemeral loopback TCP port and return
/// the bound endpoint plus a handle to observe the underlying DummyDevice.
async fn spawn_adapter(descriptor: DeviceDescriptor) -> (Endpoint, DummyHandle) {
    let (device, handle) = DummyDevice::with_handle(descriptor);

    // Bind first so the endpoint (with the OS-assigned port) is known before
    // the client tries to connect — avoids a connect race.
    let listener = listen(&Endpoint::Tcp("127.0.0.1:0".parse().unwrap()))
        .await
        .expect("listen on ephemeral port");
    let endpoint = listener.endpoint();

    tokio::spawn(async move {
        // serve() runs until the connection closes / errors; ignore the
        // result — the test drives the lifecycle.
        let _ = serve(listener, Box::new(device)).await;
    });

    (endpoint, handle)
}

/// Poll a condition until it holds or the deadline elapses. Returns whether it
/// became true. Avoids sleeping for a fixed (flaky) duration.
async fn wait_until<F: Fn() -> bool>(cond: F, deadline: Duration) -> bool {
    let res = timeout(deadline, async {
        loop {
            if cond() {
                return;
            }
            sleep(Duration::from_millis(5)).await;
        }
    })
    .await;
    res.is_ok()
}

#[tokio::test]
async fn handshake_returns_descriptor() {
    let (endpoint, _handle) = spawn_adapter(descriptor_with_gripper()).await;

    let mut client = AdapterClient::connect(&endpoint).await.expect("connect");
    let descriptor = timeout(Duration::from_secs(2), client.handshake())
        .await
        .expect("handshake did not time out")
        .expect("handshake ok");

    assert_eq!(descriptor.device.name, "E2E Dummy");
    assert_eq!(descriptor.device.device_type, "dummy");
    assert_eq!(descriptor.control_schema.axes.len(), 1);
}

#[tokio::test]
async fn sanitized_command_reaches_device_clamped() {
    let descriptor = descriptor_with_gripper();
    let (endpoint, handle) = spawn_adapter(descriptor.clone()).await;

    let mut client = AdapterClient::connect(&endpoint).await.expect("connect");
    let negotiated = client.handshake().await.expect("handshake");

    // Bridge-side input sanitization, using the descriptor the adapter
    // advertised. Send an out-of-range gripper (5.0) — DeviceSafety must
    // clamp it to the declared max (1.0) BEFORE it crosses the boundary.
    let mut safety = DeviceSafety::new(&negotiated);
    let mut raw = DeviceCommand::default();
    raw.axes.insert("gripper".to_string(), 5.0);

    let sanitized = match safety.validate(&raw) {
        SafetyResult::Ok(c) | SafetyResult::Clamped(c) => c,
        SafetyResult::Rejected(reason) => panic!("unexpected rejection: {reason}"),
    };
    assert_eq!(
        *sanitized.axes.get("gripper").unwrap(),
        1.0,
        "bridge should clamp before sending"
    );

    client.send_command(&sanitized).await.expect("send_command");

    // The adapter's DummyDevice should observe exactly the clamped value.
    let arrived = wait_until(
        || handle.command_count() >= 1 && handle.last_gripper() == Some(1.0),
        Duration::from_secs(2),
    )
    .await;
    assert!(
        arrived,
        "device never saw the clamped command (count={}, gripper={:?})",
        handle.command_count(),
        handle.last_gripper()
    );
}

#[tokio::test]
async fn telemetry_flows_back_to_bridge() {
    let (endpoint, _handle) = spawn_adapter(descriptor_with_gripper()).await;

    let mut client = AdapterClient::connect(&endpoint).await.expect("connect");
    client.handshake().await.expect("handshake");

    // The adapter pushes telemetry at ~10 Hz; the client surfaces the latest
    // sample on a watch channel. Wait for at least one to land.
    let mut telemetry = client.telemetry();
    let got = timeout(Duration::from_secs(2), async {
        loop {
            if telemetry.changed().await.is_err() {
                return false;
            }
            if telemetry.borrow_and_update().is_some() {
                return true;
            }
        }
    })
    .await
    .expect("telemetry did not time out");

    assert!(got, "bridge never received telemetry from the adapter");
}

#[tokio::test]
async fn stop_triggers_emergency_stop_on_device() {
    let (endpoint, handle) = spawn_adapter(descriptor_with_gripper()).await;

    let mut client = AdapterClient::connect(&endpoint).await.expect("connect");
    client.handshake().await.expect("handshake");

    assert_eq!(handle.estop_count(), 0);
    client.stop("watchdog: headset quiet".to_string()).await.expect("stop");

    let stopped = wait_until(|| handle.estop_count() >= 1, Duration::from_secs(2)).await;
    assert!(
        stopped,
        "adapter device never emergency-stopped (estop_count={})",
        handle.estop_count()
    );
}
