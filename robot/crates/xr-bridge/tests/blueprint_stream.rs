use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

use futures::{SinkExt, StreamExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{mpsc, watch};
use tokio::time::timeout;
use tokio_util::codec::Framed;

use teleop_protocol::{
    Blueprint, BlueprintComponent, BlueprintEvent, BlueprintState, ControlSchema, DeviceDescriptor,
    DeviceInfo, DeviceTelemetry, BLUEPRINT_EVENT_SCHEMA, BLUEPRINT_SCHEMA,
    BLUEPRINT_SPEC_CAPABILITY, BLUEPRINT_STATE_SCHEMA,
};
use xr_bridge::latency::LatencyRecorder;
use xr_bridge::pose_server;
use xr_bridge::protocol::{CommandCodec, CommandFrame};
use xr_bridge::sdk::{state_channel, BlueprintStreams};
use xr_bridge::wire_runtime::TimedCommand;

fn descriptor() -> DeviceDescriptor {
    let mut descriptor = DeviceDescriptor {
        device: DeviceInfo {
            device_type: "pyoperator".into(),
            name: "Blueprint test".into(),
            icon: String::new(),
            model_url: String::new(),
        },
        control_schema: ControlSchema::default(),
        input_mapping: vec![],
        telemetry_schema: Default::default(),
        video_feeds: vec![],
        safety: Default::default(),
        ..Default::default()
    };
    descriptor
        .capabilities
        .insert("blueprint_v1".to_string(), serde_json::Value::Bool(true));
    descriptor.capabilities.insert(
        "blueprint_spec_sha256".to_string(),
        serde_json::Value::String(teleop_protocol::SPEC_SHA256.to_string()),
    );
    descriptor
}

fn blueprint() -> Blueprint {
    Blueprint {
        schema: BLUEPRINT_SCHEMA.to_string(),
        blueprint_id: "test.blueprint".to_string(),
        revision: 1,
        components: vec![BlueprintComponent {
            id: "hand_control".to_string(),
            component_type: "palm_menu".to_string(),
            anchor: "left_palm".to_string(),
            transform: Default::default(),
            properties: HashMap::from([
                (
                    "title".to_string(),
                    serde_json::Value::String("Hand control".to_string()),
                ),
                (
                    "action".to_string(),
                    serde_json::Value::String("toggle_unlock".to_string()),
                ),
            ]),
            bindings: HashMap::from([
                ("value".to_string(), "hand.unlocked".to_string()),
                ("available".to_string(), "hand.available".to_string()),
            ]),
            user_overridable: true,
        }],
    }
}

fn state(sequence: u64, unlocked: bool) -> BlueprintState {
    BlueprintState {
        schema: BLUEPRINT_STATE_SCHEMA.to_string(),
        blueprint_id: "test.blueprint".to_string(),
        blueprint_revision: 1,
        sequence,
        timestamp_ns: sequence * 1_000,
        values: HashMap::from([
            ("hand.available".to_string(), serde_json::Value::Bool(true)),
            (
                "hand.unlocked".to_string(),
                serde_json::Value::Bool(unlocked),
            ),
        ]),
    }
}

fn blueprint_with_revision(revision: u64) -> Blueprint {
    Blueprint {
        revision,
        ..blueprint()
    }
}

fn state_with_revision(revision: u64, sequence: u64, unlocked: bool) -> BlueprintState {
    BlueprintState {
        blueprint_revision: revision,
        ..state(sequence, unlocked)
    }
}

async fn next_named(framed: &mut Framed<TcpStream, CommandCodec>, expected: &str) -> CommandFrame {
    timeout(Duration::from_secs(2), async {
        loop {
            let frame = framed
                .next()
                .await
                .expect("connection closed")
                .expect("decode frame");
            if frame.command == expected {
                return frame;
            }
        }
    })
    .await
    .unwrap_or_else(|_| panic!("timed out waiting for {expected}"))
}

#[tokio::test]
async fn blueprint_state_and_event_round_trip() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let (cmd_tx, _cmd_rx) = watch::channel::<Option<TimedCommand>>(None);
    let (_telemetry_tx, telemetry_rx) = watch::channel(DeviceTelemetry::default());
    let (xr_sink, _xr_state_rx) = state_channel();
    let (blueprint_tx, blueprint_rx) = watch::channel(Some(Arc::new(blueprint())));
    let (state_tx, state_rx) = watch::channel(Some(Arc::new(state(1, false))));
    let (event_tx, mut event_rx) = mpsc::channel(4);

    let server = tokio::spawn(pose_server::run_on_with_xr_state_and_blueprint(
        listener,
        Arc::new(descriptor()),
        cmd_tx,
        telemetry_rx,
        LatencyRecorder::new(),
        xr_sink,
        Some(BlueprintStreams {
            blueprint_rx,
            state_rx,
            event_tx,
        }),
    ));

    let socket = TcpStream::connect(address).await.unwrap();
    let mut framed = Framed::new(socket, CommandCodec);
    framed
        .send(CommandFrame {
            command: "Hello".into(),
            data: serde_json::to_vec(&serde_json::json!({
                "version": "2.0",
                "capabilities": ["xr_state_v1", "blueprint_v1", BLUEPRINT_SPEC_CAPABILITY],
            }))
            .unwrap(),
        })
        .await
        .unwrap();

    assert_eq!(
        next_named(&mut framed, "DeviceDescriptor").await.command,
        "DeviceDescriptor"
    );
    let blueprint_frame = next_named(&mut framed, "Blueprint").await;
    let received_blueprint: Blueprint = serde_json::from_slice(&blueprint_frame.data).unwrap();
    assert_eq!(received_blueprint.blueprint_id, "test.blueprint");
    assert_eq!(received_blueprint.components[0].component_type, "palm_menu");

    let initial_state = next_named(&mut framed, "BlueprintState").await;
    let initial_state: BlueprintState = serde_json::from_slice(&initial_state.data).unwrap();
    assert_eq!(initial_state.sequence, 1);

    state_tx.send_replace(Some(Arc::new(state(2, false))));
    state_tx.send_replace(Some(Arc::new(state(3, true))));
    let latest_state = next_named(&mut framed, "BlueprintState").await;
    let latest_state: BlueprintState = serde_json::from_slice(&latest_state.data).unwrap();
    assert_eq!(latest_state.sequence, 3);
    assert_eq!(latest_state.values["hand.unlocked"], true);

    state_tx.send_replace(Some(Arc::new(BlueprintState {
        values: HashMap::from([(
            "hand.unlocked".to_string(),
            serde_json::Value::String("wrong".to_string()),
        )]),
        ..state(4, false)
    })));
    assert!(timeout(
        Duration::from_millis(100),
        next_named(&mut framed, "BlueprintState")
    )
    .await
    .is_err());

    let event = BlueprintEvent {
        schema: BLUEPRINT_EVENT_SCHEMA.to_string(),
        blueprint_id: "test.blueprint".to_string(),
        blueprint_revision: 1,
        sequence: 1,
        timestamp_ns: 4_000,
        component_id: "hand_control".to_string(),
        action: "toggle_unlock".to_string(),
        value: serde_json::Value::Bool(false),
    };
    framed
        .send(CommandFrame {
            command: "BlueprintEvent".into(),
            data: serde_json::to_vec(&event).unwrap(),
        })
        .await
        .unwrap();
    let received_event = timeout(Duration::from_secs(2), event_rx.recv())
        .await
        .expect("blueprint event did not reach Python-facing channel")
        .expect("blueprint event channel closed");
    assert_eq!(received_event, event);

    let mut invalid_event = event.clone();
    invalid_event.sequence += 1;
    invalid_event.value = serde_json::Value::String("wrong".to_string());
    framed
        .send(CommandFrame {
            command: "BlueprintEvent".into(),
            data: serde_json::to_vec(&invalid_event).unwrap(),
        })
        .await
        .unwrap();
    assert!(timeout(Duration::from_millis(100), event_rx.recv())
        .await
        .is_err());

    blueprint_tx.send_replace(None);
    let clear_frame = next_named(&mut framed, "Blueprint").await;
    assert_eq!(clear_frame.data, b"null");

    framed
        .send(CommandFrame {
            command: "BlueprintEvent".into(),
            data: serde_json::to_vec(&event).unwrap(),
        })
        .await
        .unwrap();
    assert!(timeout(Duration::from_millis(100), event_rx.recv())
        .await
        .is_err());

    server.abort();
}

#[tokio::test]
async fn blueprint_requires_matching_headset_spec_capability() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let (cmd_tx, _cmd_rx) = watch::channel::<Option<TimedCommand>>(None);
    let (_telemetry_tx, telemetry_rx) = watch::channel(DeviceTelemetry::default());
    let (xr_sink, _xr_state_rx) = state_channel();
    let (_blueprint_tx, blueprint_rx) = watch::channel(Some(Arc::new(blueprint())));
    let (_state_tx, state_rx) = watch::channel(Some(Arc::new(state(1, false))));
    let (event_tx, _event_rx) = mpsc::channel(4);
    let server = tokio::spawn(pose_server::run_on_with_xr_state_and_blueprint(
        listener,
        Arc::new(descriptor()),
        cmd_tx,
        telemetry_rx,
        LatencyRecorder::new(),
        xr_sink,
        Some(BlueprintStreams {
            blueprint_rx,
            state_rx,
            event_tx,
        }),
    ));

    let socket = TcpStream::connect(address).await.unwrap();
    let mut framed = Framed::new(socket, CommandCodec);
    framed
        .send(CommandFrame {
            command: "Hello".into(),
            data: br#"{"version":"2.0","capabilities":["xr_state_v1","blueprint_v1"]}"#.to_vec(),
        })
        .await
        .unwrap();
    assert_eq!(
        next_named(&mut framed, "DeviceDescriptor").await.command,
        "DeviceDescriptor"
    );
    assert!(timeout(
        Duration::from_millis(100),
        next_named(&mut framed, "Blueprint")
    )
    .await
    .is_err());
    server.abort();
}

#[tokio::test]
async fn initial_state_waits_for_a_racing_blueprint_replacement() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let (cmd_tx, _cmd_rx) = watch::channel::<Option<TimedCommand>>(None);
    let (_telemetry_tx, telemetry_rx) = watch::channel(DeviceTelemetry::default());
    let (xr_sink, _xr_state_rx) = state_channel();
    let (blueprint_tx, blueprint_rx) = watch::channel(Some(Arc::new(blueprint())));
    let (_state_tx, state_rx) = watch::channel(Some(Arc::new(state_with_revision(2, 1, true))));
    let (event_tx, _event_rx) = mpsc::channel(4);
    let server = tokio::spawn(pose_server::run_on_with_xr_state_and_blueprint(
        listener,
        Arc::new(descriptor()),
        cmd_tx,
        telemetry_rx,
        LatencyRecorder::new(),
        xr_sink,
        Some(BlueprintStreams {
            blueprint_rx,
            state_rx,
            event_tx,
        }),
    ));

    let socket = TcpStream::connect(address).await.unwrap();
    let mut framed = Framed::new(socket, CommandCodec);
    framed
        .send(CommandFrame {
            command: "Hello".into(),
            data: serde_json::to_vec(&serde_json::json!({
                "version": "2.0",
                "capabilities": ["xr_state_v1", "blueprint_v1", BLUEPRINT_SPEC_CAPABILITY],
            }))
            .unwrap(),
        })
        .await
        .unwrap();

    assert_eq!(
        next_named(&mut framed, "DeviceDescriptor").await.command,
        "DeviceDescriptor"
    );
    let initial_blueprint = next_named(&mut framed, "Blueprint").await;
    let initial_blueprint: Blueprint = serde_json::from_slice(&initial_blueprint.data).unwrap();
    assert_eq!(initial_blueprint.revision, 1);
    assert!(timeout(
        Duration::from_millis(100),
        next_named(&mut framed, "BlueprintState")
    )
    .await
    .is_err());

    blueprint_tx.send_replace(Some(Arc::new(blueprint_with_revision(2))));
    let replacement = next_named(&mut framed, "Blueprint").await;
    let replacement: Blueprint = serde_json::from_slice(&replacement.data).unwrap();
    assert_eq!(replacement.revision, 2);
    let deferred_state = next_named(&mut framed, "BlueprintState").await;
    let deferred_state: BlueprintState = serde_json::from_slice(&deferred_state.data).unwrap();
    assert_eq!(deferred_state.blueprint_revision, 2);
    assert_eq!(deferred_state.sequence, 1);
    assert_eq!(deferred_state.values["hand.unlocked"], true);

    server.abort();
}
