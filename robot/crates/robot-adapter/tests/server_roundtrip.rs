//! End-to-end test of the adapter server over a real loopback transport.
//!
//! The client side uses the BRIDGE codec (it encodes `BridgeToAdapter`,
//! decodes `AdapterToBridge`) — mirror image of the server's `AdapterCodec`.

use std::time::Duration;

use futures::{SinkExt, StreamExt};
use tokio::time::timeout;
use tokio_util::codec::Framed;

use robot_adapter::devices::DummyDevice;
use robot_adapter::server::serve;

use teleop_protocol::{
    connect, listen, AdapterToBridge, BridgeCodec, BridgeToAdapter, DeviceCommand, Endpoint,
};

const T: Duration = Duration::from_secs(5);

/// Coerce a numeric `TelemetryValue` to `f64`, tolerating the untagged-serde
/// `Int`->`Float` collapse on the wire.
fn telemetry_number(v: Option<&teleop_protocol::TelemetryValue>) -> Option<f64> {
    use teleop_protocol::TelemetryValue;
    match v {
        Some(TelemetryValue::Float(f)) => Some(*f),
        Some(TelemetryValue::Int(i)) => Some(*i as f64),
        _ => None,
    }
}

/// Bind an ephemeral TCP endpoint, spawn the server on it, return the dialable
/// endpoint plus the device's observable handle.
async fn spawn_server() -> (Endpoint, robot_adapter::devices::DummyHandle) {
    let listener = listen(&Endpoint::Tcp("127.0.0.1:0".parse().unwrap()))
        .await
        .expect("listen");
    let endpoint = listener.endpoint();

    let (device, handle) = DummyDevice::with_handle(DummyDevice::default_descriptor());
    tokio::spawn(async move {
        let _ = serve(listener, Box::new(device)).await;
    });

    (endpoint, handle)
}

#[tokio::test]
async fn hello_returns_descriptor() {
    let (endpoint, _handle) = spawn_server().await;

    let conn = timeout(T, connect(&endpoint)).await.unwrap().unwrap();
    let mut framed = Framed::new(conn, BridgeCodec::default());

    framed.send(BridgeToAdapter::Hello).await.unwrap();

    // Skip any telemetry frames that may arrive; assert we get a Descriptor.
    let mut got_descriptor = false;
    for _ in 0..20 {
        let item = timeout(T, framed.next()).await.unwrap().unwrap().unwrap();
        if let AdapterToBridge::Descriptor(desc) = item {
            assert_eq!(desc.device.device_type, "dummy");
            got_descriptor = true;
            break;
        }
    }
    assert!(got_descriptor, "did not receive a Descriptor");
}

#[tokio::test]
async fn command_reflected_in_telemetry() {
    let (endpoint, handle) = spawn_server().await;

    let conn = timeout(T, connect(&endpoint)).await.unwrap().unwrap();
    let mut framed = Framed::new(conn, BridgeCodec::default());

    let mut cmd = DeviceCommand::default();
    cmd.axes.insert("throttle".to_string(), 0.5);
    cmd.axes.insert("gripper".to_string(), 0.9);
    framed
        .send(BridgeToAdapter::Command(cmd))
        .await
        .unwrap();

    // Wait for a telemetry frame that reflects the 2-axis command.
    let mut saw = false;
    for _ in 0..50 {
        let item = timeout(T, framed.next()).await.unwrap().unwrap().unwrap();
        if let AdapterToBridge::Telemetry(tel) = item {
            // NOTE: `TelemetryValue` is `#[serde(untagged)]` with `Float`
            // ahead of `Int`, so integer telemetry round-trips through JSON as
            // `Float`. Compare numerically rather than on the variant.
            let last_axes = telemetry_number(tel.values.get("last_axes"));
            let command_count = telemetry_number(tel.values.get("command_count"));
            if last_axes == Some(2.0) && command_count.map(|n| n >= 1.0) == Some(true) {
                saw = true;
                break;
            }
        }
    }
    assert!(saw, "telemetry never reflected the command");

    // The observable handle also reflects it.
    assert!(handle.command_count() >= 1);
    assert_eq!(handle.last_axes(), 2);
    assert_eq!(handle.last_gripper(), Some(0.9));
}

#[tokio::test]
async fn stop_triggers_emergency_stop() {
    let (endpoint, handle) = spawn_server().await;

    let conn = timeout(T, connect(&endpoint)).await.unwrap().unwrap();
    let mut framed = Framed::new(conn, BridgeCodec::default());

    assert_eq!(handle.estop_count(), 0);

    framed
        .send(BridgeToAdapter::Stop {
            reason: "watchdog".to_string(),
        })
        .await
        .unwrap();

    // Poll the handle until the estop is observed (server processes the frame
    // asynchronously). Bounded by the outer timeout.
    timeout(T, async {
        loop {
            if handle.estop_count() >= 1 {
                break;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .expect("emergency_stop was never triggered");

    assert_eq!(handle.estop_count(), 1);
}

#[tokio::test]
async fn shutdown_closes_connection() {
    let (endpoint, _handle) = spawn_server().await;

    let conn = timeout(T, connect(&endpoint)).await.unwrap().unwrap();
    let mut framed = Framed::new(conn, BridgeCodec::default());

    framed.send(BridgeToAdapter::Shutdown).await.unwrap();

    // After shutdown the server breaks its loop and drops the connection;
    // the client stream should reach EOF (None) eventually.
    let closed = timeout(T, async {
        loop {
            match framed.next().await {
                None => break true,                  // EOF
                Some(Err(_)) => break true,          // reset also fine
                Some(Ok(_)) => continue,             // ignore stray telemetry
            }
        }
    })
    .await
    .expect("connection did not close after Shutdown");
    assert!(closed);
}
