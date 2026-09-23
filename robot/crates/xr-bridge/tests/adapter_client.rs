//! Integration test for `AdapterClient` against a mock adapter server.
//!
//! The mock server binds a loopback TCP endpoint, speaks the *adapter* side of
//! the boundary protocol (`AdapterCodec`), replies to `Hello` with a
//! `Descriptor`, records every `Command` it receives, and can push telemetry
//! back. We then drive a real `AdapterClient` through connect → handshake →
//! send_command → telemetry read-back, and verify a sanitized (clamped) value
//! survives the round-trip exactly.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

use futures::{SinkExt, StreamExt};
use tokio::sync::{oneshot, Mutex};
use tokio_util::codec::Framed;

use teleop_protocol::{
    listen, AdapterCodec, AdapterToBridge, AxisDef, Blueprint, BlueprintEvent, BlueprintState,
    BridgeToAdapter, CaptureStreamsConfig, ControlSchema, DeviceCommand, DeviceDescriptor,
    DeviceInfo, DeviceSafetyConfig, DeviceTelemetry, Endpoint, StreamsControl, StreamsStatus,
    TelemetryValue, BLUEPRINT_CAPABILITY, BLUEPRINT_SPEC_HASH_CAPABILITY, SPEC_SHA256,
};

use xr_bridge::adapter_client::AdapterClient;
use xr_bridge::safety::{DeviceSafety, SafetyResult};

fn test_descriptor() -> DeviceDescriptor {
    let mut descriptor = DeviceDescriptor {
        device: DeviceInfo {
            device_type: "test_arm".into(),
            name: "Mock Arm".into(),
            icon: String::new(),
            model_url: String::new(),
        },
        control_schema: ControlSchema {
            axes: vec![AxisDef {
                name: "throttle".into(),
                display: String::new(),
                range: (-1.0, 1.0),
                default: 0.0,
                dead_zone: 0.05,
            }],
            buttons: vec![],
            poses: vec![],
        },
        input_mapping: vec![],
        telemetry_schema: Default::default(),
        video_feeds: vec![],
        safety: DeviceSafetyConfig {
            disconnect_action: "stop".into(),
            command_timeout_ms: 500,
            limits: HashMap::new(),
        },
        ..Default::default()
    };
    descriptor.capabilities.insert(
        BLUEPRINT_CAPABILITY.to_string(),
        serde_json::Value::Bool(true),
    );
    descriptor.capabilities.insert(
        BLUEPRINT_SPEC_HASH_CAPABILITY.to_string(),
        serde_json::Value::String(SPEC_SHA256.to_string()),
    );
    descriptor
}

/// Handle to a running mock adapter server.
struct MockAdapter {
    endpoint: Endpoint,
    /// Commands received from the bridge, in order.
    received: Arc<Mutex<Vec<DeviceCommand>>>,
    _task: tokio::task::JoinHandle<()>,
}

/// Spawn a mock adapter on an ephemeral loopback TCP port.
///
/// On accept it: replies to `Hello` with `descriptor`, records every `Command`,
/// and after the first command pushes one telemetry frame back.
async fn spawn_mock_adapter(descriptor: DeviceDescriptor) -> MockAdapter {
    let listener = listen(&Endpoint::Tcp("127.0.0.1:0".parse().unwrap()))
        .await
        .expect("bind mock adapter");
    let endpoint = listener.endpoint();
    let received = Arc::new(Mutex::new(Vec::new()));
    let received_task = received.clone();

    let task = tokio::spawn(async move {
        let conn = listener.accept().await.expect("accept");
        let mut framed = Framed::new(conn, AdapterCodec);

        let mut sent_telemetry = false;
        while let Some(item) = framed.next().await {
            let msg = match item {
                Ok(m) => m,
                Err(_) => break,
            };
            match msg {
                BridgeToAdapter::Hello => {
                    framed
                        .send(AdapterToBridge::Descriptor(Box::new(descriptor.clone())))
                        .await
                        .expect("send descriptor");
                }
                BridgeToAdapter::Command(cmd) => {
                    received_task.lock().await.push(cmd);
                    if !sent_telemetry {
                        sent_telemetry = true;
                        let mut values = HashMap::new();
                        values.insert("battery".to_string(), TelemetryValue::Float(0.87));
                        framed
                            .send(AdapterToBridge::Telemetry(DeviceTelemetry {
                                values,
                                timestamp_ns: 12345,
                            }))
                            .await
                            .expect("send telemetry");
                    }
                }
                BridgeToAdapter::Stop { .. } | BridgeToAdapter::Shutdown => break,
                BridgeToAdapter::BlueprintEvent { .. } | BridgeToAdapter::StreamsStatus { .. } => {}
            }
        }
    });

    MockAdapter {
        endpoint,
        received,
        _task: task,
    }
}

async fn spawn_bursting_adapter(descriptor: DeviceDescriptor, frames: u64) -> Endpoint {
    let listener = listen(&Endpoint::Tcp("127.0.0.1:0".parse().unwrap()))
        .await
        .expect("bind mock adapter");
    let endpoint = listener.endpoint();

    tokio::spawn(async move {
        let conn = listener.accept().await.expect("accept");
        let mut framed = Framed::new(conn, AdapterCodec);

        while let Some(item) = framed.next().await {
            let msg = match item {
                Ok(m) => m,
                Err(_) => break,
            };
            match msg {
                BridgeToAdapter::Hello => {
                    framed
                        .send(AdapterToBridge::Descriptor(Box::new(descriptor.clone())))
                        .await
                        .expect("send descriptor");
                    for timestamp_ns in 0..frames {
                        framed
                            .send(AdapterToBridge::Telemetry(DeviceTelemetry {
                                values: HashMap::new(),
                                timestamp_ns,
                            }))
                            .await
                            .expect("send telemetry");
                    }
                }
                BridgeToAdapter::Stop { .. } | BridgeToAdapter::Shutdown => break,
                BridgeToAdapter::Command(_) => {}
                BridgeToAdapter::BlueprintEvent { .. } | BridgeToAdapter::StreamsStatus { .. } => {}
            }
        }
    });

    endpoint
}

#[tokio::test]
async fn connect_handshake_returns_descriptor() {
    let desc = test_descriptor();
    let mock = spawn_mock_adapter(desc.clone()).await;

    let mut client = AdapterClient::connect(&mock.endpoint).await.unwrap();
    let got = client.handshake().await.unwrap();

    assert_eq!(got.device.name, "Mock Arm");
    assert_eq!(got.device.device_type, "test_arm");
    assert_eq!(got.control_schema.axes.len(), 1);
}

#[tokio::test]
async fn send_command_delivers_sanitized_value() {
    let desc = test_descriptor();
    let mock = spawn_mock_adapter(desc.clone()).await;

    let mut client = AdapterClient::connect(&mock.endpoint).await.unwrap();
    let _ = client.handshake().await.unwrap();

    // Build a deliberately out-of-range command and sanitize it through the
    // bridge's safety layer first, exactly as the real bridge would.
    let mut raw = DeviceCommand::default();
    raw.axes.insert("throttle".into(), 5.0); // way over the (-1, 1) range
    let mut safety = DeviceSafety::new(&desc);
    let clamped = match safety.validate(&raw) {
        SafetyResult::Clamped(c) => c,
        other => panic!("expected Clamped, got {other:?}"),
    };
    assert_eq!(*clamped.axes.get("throttle").unwrap(), 1.0);

    client.send_command(&clamped).await.unwrap();

    // The mock must receive the clamped value (1.0), not the raw 5.0.
    let received = wait_for_one_command(&mock.received).await;
    assert_eq!(
        *received.axes.get("throttle").unwrap(),
        1.0,
        "adapter should receive the sanitized/clamped value"
    );
}

#[tokio::test]
async fn telemetry_round_trips_back_to_bridge() {
    let desc = test_descriptor();
    let mock = spawn_mock_adapter(desc.clone()).await;

    let mut client = AdapterClient::connect(&mock.endpoint).await.unwrap();
    let _ = client.handshake().await.unwrap();

    let mut telemetry = client.telemetry();

    // Sending a command triggers the mock to push one telemetry frame.
    let mut cmd = DeviceCommand::default();
    cmd.axes.insert("throttle".into(), 0.5);
    client.send_command(&cmd).await.unwrap();

    // Wait for the telemetry watch to update.
    tokio::time::timeout(Duration::from_secs(2), telemetry.changed())
        .await
        .expect("telemetry did not arrive in time")
        .expect("telemetry channel closed");

    let latest = telemetry.borrow_and_update().clone().expect("telemetry");
    assert_eq!(latest.timestamp_ns, 12345);
    match latest.values.get("battery").expect("battery value") {
        TelemetryValue::Float(v) => assert!((v - 0.87).abs() < 1e-9),
        other => panic!("unexpected telemetry value: {other:?}"),
    }
}

#[tokio::test]
async fn events_receiver_sees_full_messages() {
    let desc = test_descriptor();
    let mock = spawn_mock_adapter(desc.clone()).await;

    let mut client = AdapterClient::connect(&mock.endpoint).await.unwrap();
    let _ = client.handshake().await.unwrap();
    let mut events = client
        .take_events()
        .expect("events receiver available once");

    let mut cmd = DeviceCommand::default();
    cmd.axes.insert("throttle".into(), 0.5);
    client.send_command(&cmd).await.unwrap();

    let msg = tokio::time::timeout(Duration::from_secs(2), events.recv())
        .await
        .expect("event did not arrive")
        .expect("events channel closed");
    match msg {
        AdapterToBridge::Telemetry(t) => assert_eq!(t.timestamp_ns, 12345),
        other => panic!("expected Telemetry, got {other:?}"),
    }
}

#[tokio::test]
async fn telemetry_watch_does_not_depend_on_unread_events_receiver() {
    let desc = test_descriptor();
    let endpoint = spawn_bursting_adapter(desc, 400).await;

    let mut client = AdapterClient::connect(&endpoint).await.unwrap();
    let mut telemetry = client.telemetry();
    let _ = client.handshake().await.unwrap();

    tokio::time::timeout(Duration::from_secs(2), async {
        loop {
            telemetry.changed().await.expect("telemetry channel closed");
            let latest = telemetry.borrow_and_update().clone().expect("telemetry");
            if latest.timestamp_ns >= 399 {
                break;
            }
        }
    })
    .await
    .expect("telemetry reader stalled behind unread events receiver");
}

#[tokio::test]
async fn blueprint_streams_round_trip_across_adapter_client() {
    let listener = listen(&Endpoint::Tcp("127.0.0.1:0".parse().unwrap()))
        .await
        .expect("bind mock adapter");
    let endpoint = listener.endpoint();
    let blueprint: Blueprint = serde_json::from_str(
        r#"{"schema":"operator.blueprint.v1","blueprint_id":"hosted","revision":1,"components":[{"id":"menu","type":"palm_menu","properties":{"title":"Test","action":"toggle"},"bindings":{"value":"ready"}}]}"#,
    )
    .unwrap();
    let state: BlueprintState = serde_json::from_str(
        r#"{"schema":"operator.blueprint_state.v1","blueprint_id":"hosted","blueprint_revision":1,"sequence":1,"timestamp_ns":2,"values":{"ready":true}}"#,
    )
    .unwrap();
    let event: BlueprintEvent = serde_json::from_str(
        r#"{"schema":"operator.blueprint_event.v1","blueprint_id":"hosted","blueprint_revision":1,"sequence":1,"timestamp_ns":3,"component_id":"menu","action":"toggle","value":true}"#,
    )
    .unwrap();
    let sent_blueprint = blueprint.clone();
    let sent_state = state.clone();
    let (event_tx, event_rx) = oneshot::channel();

    tokio::spawn(async move {
        let conn = listener.accept().await.expect("accept");
        let mut framed = Framed::new(conn, AdapterCodec);
        while let Some(message) = framed.next().await {
            match message.expect("decode") {
                BridgeToAdapter::Hello => {
                    framed
                        .send(AdapterToBridge::Descriptor(Box::new(test_descriptor())))
                        .await
                        .unwrap();
                    framed
                        .send(AdapterToBridge::Blueprint {
                            blueprint: Some(Box::new(sent_blueprint.clone())),
                        })
                        .await
                        .unwrap();
                    framed
                        .send(AdapterToBridge::BlueprintState {
                            state: Box::new(sent_state.clone()),
                        })
                        .await
                        .unwrap();
                }
                BridgeToAdapter::BlueprintEvent { event } => {
                    let _ = event_tx.send(*event);
                    break;
                }
                BridgeToAdapter::Command(_)
                | BridgeToAdapter::Stop { .. }
                | BridgeToAdapter::StreamsStatus { .. }
                | BridgeToAdapter::Shutdown => {}
            }
        }
    });

    let mut client = AdapterClient::connect(&endpoint).await.unwrap();
    let mut blueprint_rx = client.blueprint();
    let mut state_rx = client.blueprint_state();
    client.handshake().await.unwrap();
    assert_eq!(wait_for_some(&mut blueprint_rx).await.as_ref(), &blueprint);
    assert_eq!(wait_for_some(&mut state_rx).await.as_ref(), &state);

    client.send_blueprint_event(event.clone()).await.unwrap();
    assert_eq!(
        tokio::time::timeout(Duration::from_secs(2), event_rx)
            .await
            .expect("event did not reach adapter")
            .unwrap(),
        event
    );
}

#[tokio::test]
async fn blueprint_replacement_clears_previous_state() {
    let listener = listen(&Endpoint::Tcp("127.0.0.1:0".parse().unwrap()))
        .await
        .expect("bind mock adapter");
    let endpoint = listener.endpoint();
    let initial_blueprint: Blueprint = serde_json::from_str(
        r#"{"schema":"operator.blueprint.v1","blueprint_id":"hosted","revision":1,"components":[{"id":"menu","type":"palm_menu","properties":{"title":"Test","action":"toggle"},"bindings":{"value":"ready"}}]}"#,
    )
    .unwrap();
    let replacement_blueprint = Blueprint {
        revision: 2,
        ..initial_blueprint.clone()
    };
    let initial_state: BlueprintState = serde_json::from_str(
        r#"{"schema":"operator.blueprint_state.v1","blueprint_id":"hosted","blueprint_revision":1,"sequence":1,"timestamp_ns":2,"values":{"ready":true}}"#,
    )
    .unwrap();
    let (replace_tx, replace_rx) = oneshot::channel();

    tokio::spawn(async move {
        let conn = listener.accept().await.expect("accept");
        let mut framed = Framed::new(conn, AdapterCodec);
        while let Some(message) = framed.next().await {
            if matches!(message.expect("decode"), BridgeToAdapter::Hello) {
                framed
                    .send(AdapterToBridge::Descriptor(Box::new(test_descriptor())))
                    .await
                    .unwrap();
                framed
                    .send(AdapterToBridge::Blueprint {
                        blueprint: Some(Box::new(initial_blueprint)),
                    })
                    .await
                    .unwrap();
                framed
                    .send(AdapterToBridge::BlueprintState {
                        state: Box::new(initial_state),
                    })
                    .await
                    .unwrap();
                replace_rx.await.expect("replacement trigger");
                framed
                    .send(AdapterToBridge::Blueprint {
                        blueprint: Some(Box::new(replacement_blueprint)),
                    })
                    .await
                    .unwrap();
                break;
            }
        }
    });

    let mut client = AdapterClient::connect(&endpoint).await.unwrap();
    let mut blueprint_rx = client.blueprint();
    let mut state_rx = client.blueprint_state();
    client.handshake().await.unwrap();
    assert_eq!(wait_for_some(&mut blueprint_rx).await.revision, 1);
    assert_eq!(wait_for_some(&mut state_rx).await.blueprint_revision, 1);

    replace_tx.send(()).unwrap();
    state_rx.changed().await.unwrap();
    assert!(state_rx.borrow_and_update().is_none());
    blueprint_rx.changed().await.unwrap();
    assert_eq!(
        blueprint_rx.borrow_and_update().as_ref().unwrap().revision,
        2
    );
}

#[tokio::test]
async fn incompatible_adapter_blueprint_spec_is_rejected() {
    let listener = listen(&Endpoint::Tcp("127.0.0.1:0".parse().unwrap()))
        .await
        .expect("bind mock adapter");
    let endpoint = listener.endpoint();
    tokio::spawn(async move {
        let conn = listener.accept().await.expect("accept");
        let mut framed = Framed::new(conn, AdapterCodec);
        if matches!(
            framed.next().await.unwrap().unwrap(),
            BridgeToAdapter::Hello
        ) {
            let mut descriptor = test_descriptor();
            descriptor.capabilities.insert(
                BLUEPRINT_SPEC_HASH_CAPABILITY.to_string(),
                serde_json::Value::String("different-spec".to_string()),
            );
            framed
                .send(AdapterToBridge::Descriptor(Box::new(descriptor)))
                .await
                .unwrap();
            framed
                .send(AdapterToBridge::Blueprint {
                    blueprint: Some(Box::new(
                        serde_json::from_str(
                            r#"{"schema":"operator.blueprint.v1","blueprint_id":"stale","revision":1,"components":[]}"#,
                        )
                        .unwrap(),
                    )),
                })
                .await
                .unwrap();
            tokio::time::sleep(Duration::from_millis(200)).await;
        }
    });

    let mut client = AdapterClient::connect(&endpoint).await.unwrap();
    let mut blueprint_rx = client.blueprint();
    client.handshake().await.unwrap();
    assert!(!client.blueprint_compatible());
    assert!(
        tokio::time::timeout(Duration::from_millis(100), blueprint_rx.changed())
            .await
            .is_err()
    );
    assert!(blueprint_rx.borrow().is_none());
}

#[tokio::test]
async fn capture_streams_ctrl_round_trips_across_adapter_client() {
    let listener = listen(&Endpoint::Tcp("127.0.0.1:0".parse().unwrap()))
        .await
        .expect("bind mock adapter");
    let endpoint = listener.endpoint();
    let capture: CaptureStreamsConfig = serde_json::from_str(
        r#"{"schema_version":1,"streams":[{"name":"rgb.hevc","required":true,"max_hz":4}]}"#,
    )
    .unwrap();
    let valid: StreamsControl = serde_json::from_str(
        r#"{"schema":"operator.streams_control.v1","streams":{"rgb.hevc":{"hz":2.0}}}"#,
    )
    .unwrap();
    let invalid: StreamsControl = serde_json::from_str(
        r#"{"schema":"operator.streams_control.v1","streams":{"rgb.hevc":{"hz":0.0}}}"#,
    )
    .unwrap();
    let status: StreamsStatus = serde_json::from_str(
        r#"{"schema":"operator.streams_status.v1","streams":{"rgb.hevc":{"state":"active","hz":2.0}}}"#,
    )
    .unwrap();
    let mut descriptor = test_descriptor();
    descriptor.capture_streams = Some(capture.clone());
    let sent_valid = valid.clone();
    let (status_tx, status_rx) = oneshot::channel();

    tokio::spawn(async move {
        let conn = listener.accept().await.expect("accept");
        let mut framed = Framed::new(conn, AdapterCodec);
        while let Some(message) = framed.next().await {
            match message.expect("decode") {
                BridgeToAdapter::Hello => {
                    framed
                        .send(AdapterToBridge::Descriptor(Box::new(descriptor.clone())))
                        .await
                        .unwrap();
                    for control in [invalid.clone(), sent_valid.clone()] {
                        framed
                            .send(AdapterToBridge::StreamsControl {
                                control: Box::new(control),
                            })
                            .await
                            .unwrap();
                    }
                }
                BridgeToAdapter::StreamsStatus { status } => {
                    let _ = status_tx.send(status.map(|status| *status));
                    break;
                }
                _ => {}
            }
        }
    });

    let mut client = AdapterClient::connect(&endpoint).await.unwrap();
    let mut controls = client.take_streams_control().expect("control receiver");
    assert!(client.take_streams_control().is_none());
    let got = client.handshake().await.unwrap();
    assert_eq!(got.capture_streams, Some(capture));

    let control = tokio::time::timeout(Duration::from_secs(2), controls.recv())
        .await
        .expect("StreamsControl did not arrive")
        .expect("control channel closed");
    assert_eq!(
        control, valid,
        "invalid control must be dropped, valid kept"
    );

    client
        .send_streams_status(Some(status.clone()))
        .await
        .unwrap();
    let forwarded: Option<StreamsStatus> = tokio::time::timeout(Duration::from_secs(2), status_rx)
        .await
        .expect("status did not reach adapter")
        .unwrap();
    assert_eq!(forwarded, Some(status));
}

/// Poll the mock's received-command buffer until at least one command lands.
async fn wait_for_one_command(received: &Arc<Mutex<Vec<DeviceCommand>>>) -> DeviceCommand {
    for _ in 0..200 {
        if let Some(cmd) = received.lock().await.first().cloned() {
            return cmd;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    panic!("mock adapter never received a command");
}

/// Wait until a watch channel actually holds a value.
///
/// `AdapterClient` clears `blueprint_state` to `None` before publishing a new
/// `Blueprint` (see `adapter_client.rs`), and `watch::Sender::send` marks the
/// channel changed even when the value is unchanged. A single `changed()` can
/// therefore observe that `None` clear rather than the state that follows, so
/// waiting for one notification is racy; wait for the value instead.
async fn wait_for_some<T: Clone + Send + Sync + 'static>(
    rx: &mut tokio::sync::watch::Receiver<Option<T>>,
) -> T {
    tokio::time::timeout(Duration::from_secs(2), async {
        loop {
            if let Some(value) = rx.borrow_and_update().clone() {
                return value;
            }
            rx.changed().await.expect("watch channel closed");
        }
    })
    .await
    .expect("watch channel never produced a value")
}
