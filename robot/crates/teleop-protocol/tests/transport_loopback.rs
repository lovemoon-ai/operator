//! Test 4 — transport loopback over UDS and TCP.

use std::collections::HashMap;

use futures::{SinkExt as _, StreamExt as _};
use teleop_protocol::{
    AdapterCodec, AdapterToBridge, BridgeCodec, BridgeToAdapter, DeviceCommand, Endpoint,
};
use tokio_util::codec::Framed;

fn sample_command() -> DeviceCommand {
    let mut axes = HashMap::new();
    axes.insert("throttle".to_string(), 0.42);
    DeviceCommand {
        axes,
        buttons: HashMap::new(),
        poses: HashMap::new(),
        timestamp_ns: 123,
    }
}

async fn roundtrip_over(endpoint: Endpoint) {
    let listener = teleop_protocol::listen(&endpoint).await.unwrap();
    // The listener may have rewritten the endpoint (e.g. ephemeral TCP port).
    let connect_endpoint = listener.endpoint().clone();

    let original = BridgeToAdapter::Command(sample_command());
    let send_original = original.clone();

    // Adapter side: accept one connection, decode one BridgeToAdapter frame,
    // reply with an AdapterToBridge frame.
    let server = tokio::spawn(async move {
        let conn = listener.accept().await.unwrap();
        let mut framed = Framed::new(conn, AdapterCodec::default());
        let got = framed.next().await.unwrap().unwrap();
        framed
            .send(AdapterToBridge::Event {
                kind: "ack".to_string(),
                msg: "received".to_string(),
            })
            .await
            .unwrap();
        got
    });

    // Bridge side: connect, send the command, read the ack.
    let conn = teleop_protocol::connect(&connect_endpoint).await.unwrap();
    let mut framed = Framed::new(conn, BridgeCodec::default());
    framed.send(send_original).await.unwrap();
    let reply = framed.next().await.unwrap().unwrap();

    let got = server.await.unwrap();
    assert_eq!(
        serde_json::to_value(&got).unwrap(),
        serde_json::to_value(&original).unwrap()
    );
    match reply {
        AdapterToBridge::Event { kind, msg } => {
            assert_eq!(kind, "ack");
            assert_eq!(msg, "received");
        }
        other => panic!("expected Event, got {other:?}"),
    }
}

#[tokio::test]
async fn uds_loopback() {
    let dir = std::env::temp_dir();
    let path = dir.join(format!("teleop-test-{}.sock", std::process::id()));
    let _ = std::fs::remove_file(&path);
    let endpoint = Endpoint::Uds(path.clone());
    roundtrip_over(endpoint).await;
    let _ = std::fs::remove_file(&path);
}

#[tokio::test]
async fn tcp_loopback() {
    // Ephemeral port via :0
    let endpoint: Endpoint = "tcp:127.0.0.1:0".parse().unwrap();
    roundtrip_over(endpoint).await;
}

#[test]
fn endpoint_string_parsing() {
    match "uds:/tmp/teleop-adapter.sock".parse::<Endpoint>().unwrap() {
        Endpoint::Uds(p) => assert_eq!(p.to_str().unwrap(), "/tmp/teleop-adapter.sock"),
        other => panic!("expected Uds, got {other:?}"),
    }
    match "tcp:127.0.0.1:63910".parse::<Endpoint>().unwrap() {
        Endpoint::Tcp(addr) => assert_eq!(addr.to_string(), "127.0.0.1:63910"),
        other => panic!("expected Tcp, got {other:?}"),
    }
    // Default endpoint.
    match Endpoint::default() {
        Endpoint::Uds(p) => assert_eq!(p.to_str().unwrap(), "/tmp/teleop-adapter.sock"),
        other => panic!("expected default Uds, got {other:?}"),
    }
}
