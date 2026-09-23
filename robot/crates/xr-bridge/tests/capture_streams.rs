//! Capture-stream routing through the SDK command server: descriptor
//! `capture_streams`, headset `StreamsStatus`, host `StreamsControl`, and the
//! session-owned `media` relay (OLCP media_up / media_down).

use std::sync::Arc;
use std::time::Duration;

use futures::{SinkExt, StreamExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::watch;
use tokio::time::timeout;
use tokio_util::codec::Framed;

use teleop_protocol::{
    CaptureStreamsConfig, DeviceDescriptor, DeviceTelemetry, MediaTransport, StreamsControl,
    StreamsStatus, CAPTURE_STREAMS_CAPABILITY, MEDIA_PROTOCOL, STREAMS_CONTROL_COMMAND,
    STREAMS_STATUS_COMMAND,
};
use xr_bridge::latency::LatencyRecorder;
use xr_bridge::media::{
    MediaChannels, MediaDownError, MediaFrame, MediaListeners, OlcpCodec, RESULT_HELLO_SCHEMA,
    RESULT_WELCOME_SCHEMA, TYPE_HEAD_POSE, TYPE_RESULT_HELLO, TYPE_RESULT_WELCOME, TYPE_RGB_PACKET,
    TYPE_SESSION_START,
};
use xr_bridge::pose_server;
use xr_bridge::protocol::{CommandCodec, CommandFrame};
use xr_bridge::sdk::{state_channel, StreamsChannels, StreamsControlError};
use xr_bridge::wire_runtime::TimedCommand;

type Headset = Framed<TcpStream, CommandCodec>;
type Olcp = Framed<TcpStream, OlcpCodec>;

fn capture_streams() -> CaptureStreamsConfig {
    serde_json::from_value(serde_json::json!({
        "schema_version": 1,
        "streams": [
            {"name": "rgb.hevc", "required": true, "max_hz": 4, "max_bitrate_bps": 2000000, "eye": "left"},
            {"name": "depth.u16", "max_hz": 5}
        ]
    }))
    .unwrap()
}

fn rgb_control(hz: f64) -> StreamsControl {
    serde_json::from_value(serde_json::json!({
        "schema": "operator.streams_control.v1",
        "streams": {"rgb.hevc": {"hz": hz, "paused": false}}
    }))
    .unwrap()
}

async fn start_server(
    capture: Option<CaptureStreamsConfig>,
) -> (
    std::net::SocketAddr,
    StreamsChannels,
    tokio::task::JoinHandle<anyhow::Result<()>>,
) {
    start_server_with(capture, StreamsChannels::new()).await
}

/// SDK command server plus a media relay on ephemeral loopback ports.
async fn start_media_server(
    capture: Option<CaptureStreamsConfig>,
) -> (
    std::net::SocketAddr,
    MediaChannels,
    tokio::task::JoinHandle<anyhow::Result<()>>,
    tokio::task::JoinHandle<anyhow::Result<()>>,
) {
    let media = MediaChannels::new();
    let relay = media
        .serve(MediaListeners::new(
            TcpListener::bind("127.0.0.1:0").await.unwrap(),
            TcpListener::bind("127.0.0.1:0").await.unwrap(),
        ))
        .unwrap();
    let relay = tokio::spawn(relay);
    let (address, _streams, server) =
        start_server_with(capture, StreamsChannels::with_media(media.clone())).await;
    (address, media, server, relay)
}

async fn start_server_with(
    capture: Option<CaptureStreamsConfig>,
    streams: StreamsChannels,
) -> (
    std::net::SocketAddr,
    StreamsChannels,
    tokio::task::JoinHandle<anyhow::Result<()>>,
) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let (cmd_tx, _cmd_rx) = watch::channel::<Option<TimedCommand>>(None);
    let (_telemetry_tx, telemetry_rx) = watch::channel(DeviceTelemetry::default());
    let (sink, _state_rx) = state_channel();
    let descriptor = DeviceDescriptor {
        capture_streams: capture,
        ..Default::default()
    };
    let server = tokio::spawn(pose_server::run_on_with_xr_state_blueprint_and_streams(
        listener,
        Arc::new(descriptor),
        cmd_tx,
        telemetry_rx,
        LatencyRecorder::new(),
        sink,
        None,
        Some(streams.clone()),
    ));
    (address, streams, server)
}

async fn connect_headset(
    address: std::net::SocketAddr,
    capabilities: &[&str],
) -> (Headset, serde_json::Value) {
    let socket = TcpStream::connect(address).await.unwrap();
    let mut headset = Framed::new(socket, CommandCodec);
    let mut all = vec!["xr_state_v1", "dedicated_telemetry_v1"];
    all.extend_from_slice(capabilities);
    headset
        .send(CommandFrame {
            command: "Hello".into(),
            data: serde_json::to_vec(&serde_json::json!({"version": "2.0", "capabilities": all}))
                .unwrap(),
        })
        .await
        .unwrap();
    let response = headset.next().await.unwrap().unwrap();
    assert_eq!(response.command, "DeviceDescriptor");
    let descriptor = serde_json::from_slice(&response.data).unwrap();
    (headset, descriptor)
}

async fn send_json(headset: &mut Headset, command: &str, value: serde_json::Value) {
    headset
        .send(CommandFrame {
            command: command.into(),
            data: serde_json::to_vec(&value).unwrap(),
        })
        .await
        .unwrap();
}

async fn wait_until(mut predicate: impl FnMut() -> bool) {
    timeout(Duration::from_secs(2), async {
        while !predicate() {
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
    .await
    .expect("condition not reached");
}

#[tokio::test]
async fn capable_headset_reports_status_and_receives_control() {
    let (address, streams, server) = start_server(Some(capture_streams())).await;
    let mut status_rx = streams.status();
    let (mut headset, descriptor) =
        connect_headset(address, &[CAPTURE_STREAMS_CAPABILITY, "stream.rgb.hevc"]).await;
    assert_eq!(
        descriptor["capture_streams"],
        serde_json::to_value(capture_streams()).unwrap()
    );
    // No media relay on this server: no session media block.
    assert!(descriptor.get("media").is_none());
    assert!(streams.headset_supported());
    assert!(streams.latest_status().is_none());

    // Invalid reports are dropped; the valid one becomes the latest status.
    send_json(
        &mut headset,
        STREAMS_STATUS_COMMAND,
        serde_json::json!({"schema": "operator.streams_status.v1", "streams": {"rgb.hevc": {"state": "on"}}}),
    )
    .await;
    let status_json = serde_json::json!({
        "schema": "operator.streams_status.v1",
        "streams": {
            "rgb.hevc": {"state": "active", "hz": 4.0, "bitrate_bps": 2000000, "eye": "left"},
            "depth.u16": {"state": "denied", "reason": "permission_denied"}
        }
    });
    send_json(&mut headset, STREAMS_STATUS_COMMAND, status_json.clone()).await;
    let expected: StreamsStatus = serde_json::from_value(status_json).unwrap();
    timeout(Duration::from_secs(2), async {
        loop {
            status_rx.changed().await.unwrap();
            if status_rx.borrow_and_update().as_deref() == Some(&expected) {
                break;
            }
        }
    })
    .await
    .expect("StreamsStatus was not published");

    for hz in [2.0, 1.0] {
        streams.send_control(rgb_control(hz)).unwrap();
    }
    for hz in [2.0, 1.0] {
        let frame = timeout(Duration::from_secs(1), headset.next())
            .await
            .expect("StreamsControl was not forwarded")
            .unwrap()
            .unwrap();
        assert_eq!(frame.command, STREAMS_CONTROL_COMMAND);
        let control: StreamsControl = serde_json::from_slice(&frame.data).unwrap();
        assert_eq!(control, rgb_control(hz));
    }

    drop(headset);
    wait_until(|| streams.latest_status().is_none() && !streams.headset_supported()).await;
    assert_eq!(
        streams.send_control(rgb_control(2.0)),
        Err(StreamsControlError::NotConnected)
    );
    server.abort();
}

#[tokio::test]
async fn headset_without_capability_never_receives_streams_control() {
    let (address, streams, server) = start_server(None).await;
    let (mut headset, descriptor) = connect_headset(address, &[]).await;
    assert!(descriptor.get("capture_streams").is_none());
    assert!(descriptor.get("media").is_none());
    assert!(!streams.headset_supported());
    assert_eq!(
        streams.send_control(rgb_control(2.0)),
        Err(StreamsControlError::Unsupported)
    );
    assert!(
        timeout(Duration::from_millis(200), headset.next())
            .await
            .is_err(),
        "an old headset must not receive StreamsControl"
    );
    server.abort();
}

fn media_block(descriptor: &serde_json::Value) -> MediaTransport {
    serde_json::from_value(descriptor["media"].clone()).expect("descriptor carries media")
}

async fn connect_olcp(port: u16) -> Olcp {
    Framed::new(
        TcpStream::connect(("127.0.0.1", port)).await.unwrap(),
        OlcpCodec::default(),
    )
}

fn json_frame(frame_type: u8, pts_ns: u64, value: serde_json::Value) -> MediaFrame {
    MediaFrame::new(
        frame_type,
        0,
        pts_ns,
        0,
        serde_json::to_vec(&value).unwrap(),
    )
}

fn session_start(token: &str) -> MediaFrame {
    json_frame(
        TYPE_SESSION_START,
        0,
        serde_json::json!({"protocol": "operator.live_feed.v1", "auth_token": token}),
    )
}

fn result_hello(token: &str) -> MediaFrame {
    json_frame(
        TYPE_RESULT_HELLO,
        0,
        serde_json::json!({"schema": RESULT_HELLO_SCHEMA, "auth_token": token}),
    )
}

/// The relay closed the connection (EOF or reset) without sending anything.
async fn assert_closed(peer: &mut Olcp) {
    match timeout(Duration::from_secs(2), peer.next())
        .await
        .expect("connection was not closed")
    {
        None | Some(Err(_)) => {}
        Some(Ok(frame)) => panic!("unexpected frame {frame:?}"),
    }
}

async fn recv_up(media: &MediaChannels) -> Option<MediaFrame> {
    let media = media.clone();
    tokio::task::spawn_blocking(move || media.recv_up(Some(Duration::from_secs(2))))
        .await
        .unwrap()
}

async fn send_down(media: &MediaChannels, frame: MediaFrame) -> Result<(), MediaDownError> {
    let media = media.clone();
    tokio::task::spawn_blocking(move || media.send_down(frame))
        .await
        .unwrap()
}

#[tokio::test]
async fn capable_headset_gets_session_media_and_both_directions_relay() {
    let (address, media, server, relay) = start_media_server(Some(capture_streams())).await;
    let (headset, descriptor) =
        connect_headset(address, &[CAPTURE_STREAMS_CAPABILITY, "stream.rgb.hevc"]).await;
    let transport = media_block(&descriptor);
    assert_eq!(transport.protocol, MEDIA_PROTOCOL);
    assert!(
        transport.auth_token.len() >= 32,
        "token carries >= 128 bits"
    );
    assert!(transport
        .auth_token
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_'));
    assert!(descriptor["capture_streams"].get("sink").is_none());

    // media_up: a wrong token or a non-session_start first frame is closed.
    let mut rejected = connect_olcp(transport.push_port).await;
    rejected.send(session_start("wrong")).await.unwrap();
    assert_closed(&mut rejected).await;
    let mut rejected = connect_olcp(transport.push_port).await;
    rejected
        .send(json_frame(
            TYPE_HEAD_POSE,
            1,
            serde_json::json!({"auth_token": transport.auth_token}),
        ))
        .await
        .unwrap();
    assert_closed(&mut rejected).await;
    assert!(!media.stats().up_connected);

    let mut up = connect_olcp(transport.push_port).await;
    up.send(session_start(&transport.auth_token)).await.unwrap();
    let rgb = MediaFrame::new(
        TYPE_RGB_PACKET,
        1,
        123_456_789_000,
        33_000_000,
        vec![0, 0, 0, 1, 0x26],
    );
    up.send(rgb.clone()).await.unwrap();
    let first = recv_up(&media).await.expect("session_start relayed");
    assert_eq!(first, session_start(&transport.auth_token));
    // pts / duration / flags / payload pass through untouched.
    assert_eq!(recv_up(&media).await, Some(rgb));
    assert!(media.stats().up_connected);
    assert_eq!(media.stats().up_frames, 2);

    // media_down: hello with the wrong token is rejected; the right one is
    // welcomed and then receives host frames in order.
    assert_eq!(
        send_down(&media, json_frame(110, 0, serde_json::json!({}))).await,
        Err(MediaDownError::NotConnected)
    );
    let mut rejected = connect_olcp(transport.result_port).await;
    rejected.send(result_hello("wrong")).await.unwrap();
    assert_closed(&mut rejected).await;
    let mut down = connect_olcp(transport.result_port).await;
    down.send(result_hello(&transport.auth_token))
        .await
        .unwrap();
    let welcome = timeout(Duration::from_secs(2), down.next())
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    assert_eq!(welcome.frame_type, TYPE_RESULT_WELCOME);
    let welcome: serde_json::Value = serde_json::from_slice(&welcome.payload).unwrap();
    assert_eq!(welcome["schema"], RESULT_WELCOME_SCHEMA);
    assert!(!welcome["server_instance_id"].as_str().unwrap().is_empty());
    wait_until(|| media.stats().down_connected).await;
    for pts in [1, 2] {
        let status = json_frame(110, pts, serde_json::json!({"state": "running"}));
        send_down(&media, status).await.unwrap();
    }
    for pts in [1, 2] {
        let frame = timeout(Duration::from_secs(2), down.next())
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        assert_eq!((frame.frame_type, frame.pts_ns), (110, pts));
    }

    // Ending the ctrl connection revokes the token and closes media.
    drop(headset);
    assert_closed(&mut up).await;
    assert_closed(&mut down).await;
    wait_until(|| {
        let stats = media.stats();
        !stats.up_connected && !stats.down_connected
    })
    .await;
    let mut stale = connect_olcp(transport.push_port).await;
    stale
        .send(session_start(&transport.auth_token))
        .await
        .unwrap();
    assert_closed(&mut stale).await;
    server.abort();
    relay.abort();
}

#[tokio::test]
async fn newer_headset_gets_a_fresh_token_and_replaces_media() {
    let (address, media, server, relay) = start_media_server(Some(capture_streams())).await;
    let (_first_headset, descriptor) =
        connect_headset(address, &[CAPTURE_STREAMS_CAPABILITY]).await;
    let first = media_block(&descriptor);
    let mut first_up = connect_olcp(first.push_port).await;
    first_up
        .send(session_start(&first.auth_token))
        .await
        .unwrap();
    assert!(recv_up(&media).await.is_some());

    let (_second_headset, descriptor) =
        connect_headset(address, &[CAPTURE_STREAMS_CAPABILITY]).await;
    let second = media_block(&descriptor);
    assert_ne!(second.auth_token, first.auth_token);
    assert_closed(&mut first_up).await;

    // A second authenticated media_up replaces the first.
    let mut up_a = connect_olcp(second.push_port).await;
    up_a.send(session_start(&second.auth_token)).await.unwrap();
    assert!(recv_up(&media).await.is_some());
    let mut up_b = connect_olcp(second.push_port).await;
    up_b.send(session_start(&second.auth_token)).await.unwrap();
    assert!(recv_up(&media).await.is_some());
    assert_closed(&mut up_a).await;
    assert!(media.stats().up_connected);
    server.abort();
    relay.abort();
}

#[tokio::test]
async fn media_block_requires_capability_declaration_and_a_serving_relay() {
    // Capable headset, but the host declares no capture streams.
    let (address, _media, server, relay) = start_media_server(None).await;
    let (_headset, descriptor) = connect_headset(address, &[CAPTURE_STREAMS_CAPABILITY]).await;
    assert!(descriptor.get("media").is_none());
    server.abort();
    relay.abort();

    // Declaring host, but an older headset without capture_streams_v1.
    let (address, _media, server, relay) = start_media_server(Some(capture_streams())).await;
    let (_headset, descriptor) = connect_headset(address, &[]).await;
    assert!(descriptor.get("capture_streams").is_some());
    assert!(descriptor.get("media").is_none());
    server.abort();
    relay.abort();

    // Media channels exist but no relay is serving (media ports disabled).
    let (address, _streams, server) = start_server_with(
        Some(capture_streams()),
        StreamsChannels::with_media(MediaChannels::new()),
    )
    .await;
    let (_headset, descriptor) = connect_headset(address, &[CAPTURE_STREAMS_CAPABILITY]).await;
    assert!(descriptor.get("media").is_none());
    server.abort();
}
