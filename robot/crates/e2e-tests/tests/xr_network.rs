//! Headline end-to-end test for the XR-facing network layer.
//!
//! Proves the full vertical slice:
//!
//! ```text
//!   simulated headset → xr-bridge pose_server (CommandCodec)
//!                      → command watch → forward loop (DeviceSafety)
//!                      → AdapterClient (BridgeCodec) → socket
//!                      → real robot-adapter server → DummyDevice
//!                      → Telemetry → AdapterClient watch → telemetry fan-in
//!                      → pose_server → headset
//! ```
//!
//! A REAL `robot-adapter` `DummyDevice` is served over a loopback
//! `Endpoint::Tcp`. The xr-bridge stack (`AdapterClient` + `forward` +
//! telemetry fan-in + `pose_server` bound on `127.0.0.1:0` via `spawn_stack`)
//! points at it. A hand-rolled headset (raw `TcpStream` + `CommandCodec`)
//! handshakes, sends a command, and reads telemetry back.
//!
//! Run with: `cargo test -p e2e-tests --test xr_network`

use std::sync::Arc;
use std::time::Duration;

use futures::{SinkExt, StreamExt};
use tokio::net::TcpStream;
use tokio::time::{sleep, timeout};
use tokio_util::codec::Framed;

use robot_adapter::devices::DummyDevice;
use robot_adapter::server::serve;
use robot_adapter::DummyHandle;
use teleop_protocol::{listen, DeviceCommand, DeviceDescriptor, Endpoint};
use xr_bridge::adapter_client::AdapterClient;
use xr_bridge::protocol::{CommandCodec, CommandFrame};
use xr_bridge::runtime::{self, StackHandle};

/// A dummy descriptor with one declared axis ("gripper", range 0..1) so the
/// bridge's `DeviceSafety` has something to accept (it rejects unknown axis
/// names, so an empty schema would reject our command).
fn descriptor_with_gripper() -> DeviceDescriptor {
    serde_json::from_value(serde_json::json!({
        "device": { "type": "dummy", "name": "XR Net Dummy" },
        "control_schema": {
            "axes": [
                { "name": "gripper", "range": [0.0, 1.0], "dead_zone": 0.0 }
            ]
        },
        "safety": { "command_timeout_ms": 500 }
    }))
    .expect("descriptor JSON should deserialize")
}

/// Spin up a real adapter server on an ephemeral loopback TCP port.
async fn spawn_adapter(descriptor: DeviceDescriptor) -> (Endpoint, DummyHandle) {
    let (device, handle) = DummyDevice::with_handle(descriptor);
    let listener = listen(&Endpoint::Tcp("127.0.0.1:0".parse().unwrap()))
        .await
        .expect("listen on ephemeral port");
    let endpoint = listener.endpoint();
    tokio::spawn(async move {
        let _ = serve(listener, Box::new(device)).await;
    });
    (endpoint, handle)
}

/// Bring up the full xr-bridge stack pointed at `endpoint` and return the bound
/// pose-server address (where the simulated headset connects) plus the handle.
/// The descriptor is the one the bridge negotiates with the adapter, not a
/// caller-supplied one.
async fn spawn_bridge_stack(endpoint: &Endpoint) -> StackHandle {
    let mut client = AdapterClient::connect(endpoint).await.expect("connect");
    let negotiated = timeout(Duration::from_secs(2), client.handshake())
        .await
        .expect("handshake did not time out")
        .expect("handshake ok");
    runtime::spawn_stack(Arc::new(negotiated), client)
        .await
        .expect("spawn xr-bridge stack")
}

/// Read frames until one named `command` arrives, or the deadline elapses.
async fn read_frame_named(
    framed: &mut Framed<TcpStream, CommandCodec>,
    command: &str,
    deadline: Duration,
) -> Option<CommandFrame> {
    timeout(deadline, async {
        loop {
            match framed.next().await {
                Some(Ok(frame)) if frame.command == command => return Some(frame),
                Some(Ok(_)) => continue, // some other frame; keep reading.
                Some(Err(_)) | None => return None,
            }
        }
    })
    .await
    .ok()
    .flatten()
}

async fn wait_until<F: Fn() -> bool>(cond: F, deadline: Duration) -> bool {
    timeout(deadline, async {
        loop {
            if cond() {
                return;
            }
            sleep(Duration::from_millis(5)).await;
        }
    })
    .await
    .is_ok()
}

#[tokio::test]
async fn headset_to_adapter_round_trip() {
    // 1. Real adapter + dummy device.
    let (endpoint, handle) = spawn_adapter(descriptor_with_gripper()).await;

    // 2. xr-bridge stack pointed at the adapter; learn the pose addr.
    let stack = spawn_bridge_stack(&endpoint).await;
    let pose_addr = stack.pose_addr;

    // 3. Simulated headset: raw TCP + CommandCodec.
    let socket = TcpStream::connect(pose_addr).await.expect("connect to pose port");
    socket.set_nodelay(true).unwrap();
    let mut framed = Framed::new(socket, CommandCodec);

    // Hello → DeviceDescriptor.
    framed
        .send(CommandFrame {
            command: "Hello".to_string(),
            data: Vec::new(),
        })
        .await
        .expect("send Hello");

    let desc_frame = read_frame_named(&mut framed, "DeviceDescriptor", Duration::from_secs(2))
        .await
        .expect("expected a DeviceDescriptor frame in response to Hello");
    let got: DeviceDescriptor =
        serde_json::from_slice(&desc_frame.data).expect("descriptor JSON parses");
    assert_eq!(got.device.name, "XR Net Dummy");
    assert_eq!(got.device.device_type, "dummy");
    assert_eq!(got.control_schema.axes.len(), 1);

    // Send a DeviceCommand with the declared "gripper" axis.
    let mut cmd = DeviceCommand::default();
    cmd.axes.insert("gripper".to_string(), 0.5);
    let cmd_json = serde_json::to_vec(&cmd).unwrap();
    framed
        .send(CommandFrame {
            command: "DeviceCommand".to_string(),
            data: cmd_json,
        })
        .await
        .expect("send DeviceCommand");

    // The command must reach the dummy adapter device.
    let arrived = wait_until(|| handle.command_count() >= 1, Duration::from_secs(2)).await;
    assert!(
        arrived,
        "dummy adapter never received the command (count={})",
        handle.command_count()
    );
    // The sanitized gripper value (in-range, passes through unchanged).
    assert_eq!(handle.last_gripper(), Some(0.5));

    // At least one Telemetry frame must come back to the headset.
    let telem = read_frame_named(&mut framed, "Telemetry", Duration::from_secs(2)).await;
    assert!(
        telem.is_some(),
        "headset never received a Telemetry frame from the bridge"
    );

    stack.abort();
}

#[tokio::test]
async fn out_of_range_command_is_clamped_before_reaching_adapter() {
    let (endpoint, handle) = spawn_adapter(descriptor_with_gripper()).await;
    let stack = spawn_bridge_stack(&endpoint).await;

    let socket = TcpStream::connect(stack.pose_addr)
        .await
        .expect("connect to pose port");
    socket.set_nodelay(true).unwrap();
    let mut framed = Framed::new(socket, CommandCodec);

    framed
        .send(CommandFrame {
            command: "Hello".to_string(),
            data: Vec::new(),
        })
        .await
        .expect("send Hello");
    read_frame_named(&mut framed, "DeviceDescriptor", Duration::from_secs(2))
        .await
        .expect("descriptor");

    // Out-of-range gripper (5.0): the bridge must clamp to the declared max
    // (1.0) before the command crosses the boundary to the adapter.
    let mut cmd = DeviceCommand::default();
    cmd.axes.insert("gripper".to_string(), 5.0);
    framed
        .send(CommandFrame {
            command: "DeviceCommand".to_string(),
            data: serde_json::to_vec(&cmd).unwrap(),
        })
        .await
        .expect("send DeviceCommand");

    let clamped = wait_until(
        || handle.command_count() >= 1 && handle.last_gripper() == Some(1.0),
        Duration::from_secs(2),
    )
    .await;
    assert!(
        clamped,
        "device should observe the clamped value 1.0 (count={}, gripper={:?})",
        handle.command_count(),
        handle.last_gripper()
    );

    stack.abort();
}
