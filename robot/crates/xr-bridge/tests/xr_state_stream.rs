use std::sync::Arc;
use std::time::Duration;

use futures::{SinkExt, StreamExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::watch;
use tokio::time::timeout;
use tokio_util::codec::Framed;

use teleop_protocol::{
    ControlSchema, DeviceDescriptor, DeviceInfo, DeviceTelemetry, TrackedPose, XrStateFrame,
};
use xr_bridge::latency::LatencyRecorder;
use xr_bridge::pose_server;
use xr_bridge::protocol::{CommandCodec, CommandFrame};
use xr_bridge::sdk::state_channel;
use xr_bridge::wire_runtime::TimedCommand;

fn sdk_hello() -> CommandFrame {
    CommandFrame {
        command: "Hello".into(),
        data: br#"{"version":"2.0","capabilities":["xr_state_v1"]}"#.to_vec(),
    }
}

fn descriptor() -> DeviceDescriptor {
    DeviceDescriptor {
        device: DeviceInfo {
            device_type: "pyoperator".into(),
            name: "SDK test".into(),
            icon: String::new(),
            model_url: String::new(),
        },
        control_schema: ControlSchema::default(),
        input_mapping: vec![],
        telemetry_schema: Default::default(),
        video_feeds: vec![],
        safety: Default::default(),
        ..Default::default()
    }
}

#[tokio::test]
async fn sdk_state_frame_is_published_as_one_watch_value() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let (cmd_tx, _cmd_rx) = watch::channel::<Option<TimedCommand>>(None);
    let (_telemetry_tx, telemetry_rx) = watch::channel(DeviceTelemetry::default());
    let (sink, mut state_rx) = state_channel();
    let stats = sink.stats.clone();

    let server = tokio::spawn(pose_server::run_on_with_xr_state(
        listener,
        Arc::new(descriptor()),
        cmd_tx,
        telemetry_rx,
        LatencyRecorder::new(),
        sink,
    ));

    let socket = TcpStream::connect(address).await.unwrap();
    let mut framed = Framed::new(socket, CommandCodec);
    framed.send(sdk_hello()).await.unwrap();
    let response = framed.next().await.unwrap().unwrap();
    assert_eq!(response.command, "DeviceDescriptor");

    let state = XrStateFrame {
        frame_id: 7,
        timestamp_ns: 10_000,
        head: Some(TrackedPose {
            valid: true,
            sample_timestamp_ns: 9_999,
            position: [0.1, 0.2, 0.3],
            ..TrackedPose::default()
        }),
        ..XrStateFrame::default()
    };
    framed
        .send(CommandFrame {
            command: "XrStateFrame".into(),
            data: serde_json::to_vec(&state).unwrap(),
        })
        .await
        .unwrap();

    timeout(Duration::from_secs(1), state_rx.changed())
        .await
        .expect("state was not published")
        .unwrap();
    let received = state_rx.borrow_and_update().clone().unwrap();
    assert_eq!(received.frame_id, 7);
    assert_eq!(received.head.as_ref().unwrap().position, [0.1, 0.2, 0.3]);
    assert_eq!(stats.frames_received(), 1);
    assert_eq!(stats.last_frame_id(), 7);

    server.abort();
}

#[tokio::test]
async fn sdk_rejects_hello_without_xr_state_capability() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let (cmd_tx, _cmd_rx) = watch::channel::<Option<TimedCommand>>(None);
    let (_telemetry_tx, telemetry_rx) = watch::channel(DeviceTelemetry::default());
    let (sink, _state_rx) = state_channel();
    let stats = sink.stats.clone();
    let server = tokio::spawn(pose_server::run_on_with_xr_state(
        listener,
        Arc::new(descriptor()),
        cmd_tx,
        telemetry_rx,
        LatencyRecorder::new(),
        sink,
    ));

    let socket = TcpStream::connect(address).await.unwrap();
    let mut framed = Framed::new(socket, CommandCodec);
    framed
        .send(CommandFrame {
            command: "Hello".into(),
            data: br#"{"version":"2.0","capabilities":[]}"#.to_vec(),
        })
        .await
        .unwrap();

    assert!(timeout(Duration::from_secs(1), framed.next())
        .await
        .expect("incompatible connection should close")
        .is_none());
    assert!(!stats.connected());
    assert!(stats.last_error().unwrap().contains("xr_state_v1"));

    server.abort();
}

#[tokio::test]
async fn sdk_new_headset_replaces_previous_owner() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let (cmd_tx, _cmd_rx) = watch::channel::<Option<TimedCommand>>(None);
    let (_telemetry_tx, telemetry_rx) = watch::channel(DeviceTelemetry::default());
    let (sink, mut state_rx) = state_channel();
    let stats = sink.stats.clone();
    let server = tokio::spawn(pose_server::run_on_with_xr_state(
        listener,
        Arc::new(descriptor()),
        cmd_tx,
        telemetry_rx,
        LatencyRecorder::new(),
        sink,
    ));

    let mut first = Framed::new(TcpStream::connect(address).await.unwrap(), CommandCodec);
    first.send(sdk_hello()).await.unwrap();
    assert_eq!(
        first.next().await.unwrap().unwrap().command,
        "DeviceDescriptor"
    );

    let mut second = Framed::new(TcpStream::connect(address).await.unwrap(), CommandCodec);
    second.send(sdk_hello()).await.unwrap();
    assert_eq!(
        second.next().await.unwrap().unwrap().command,
        "DeviceDescriptor"
    );

    loop {
        match timeout(Duration::from_secs(1), first.next())
            .await
            .expect("previous owner should be disconnected")
        {
            None => break,
            Some(Ok(_)) => continue,
            Some(Err(_)) => break,
        }
    }
    assert!(stats.connected());

    let state = XrStateFrame {
        frame_id: 7,
        timestamp_ns: 10_000,
        ..XrStateFrame::default()
    };
    second
        .send(CommandFrame {
            command: "XrStateFrame".into(),
            data: serde_json::to_vec(&state).unwrap(),
        })
        .await
        .unwrap();
    timeout(Duration::from_secs(1), state_rx.changed())
        .await
        .expect("new owner state was not published")
        .unwrap();
    assert_eq!(state_rx.borrow_and_update().as_ref().unwrap().frame_id, 7);
    assert!(stats.connected());

    server.abort();
}
