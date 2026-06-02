//! Service discovery via mDNS and UDP broadcast.
//!
//! Announces the bridge's presence on the network so headsets can find it
//! without manual IP configuration. Copied from `robot/src/network/discovery.rs`
//! and re-pointed at [`BridgeConfig`]; the device type/name now come from the
//! descriptor the bridge negotiated with the adapter (passed explicitly rather
//! than mutated into the config).
//!
//! Two mechanisms run in parallel:
//! 1. **mDNS** (`_xrobo._tcp.local.`) — standard Bonjour/Avahi discovery.
//! 2. **UDP broadcast** on the discovery port — simple JSON beacon every 3
//!    seconds for clients that cannot do mDNS.

use std::collections::HashMap;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};

use anyhow::Result;
use get_if_addrs::IfAddr;
use mdns_sd::{ServiceDaemon, ServiceInfo};

use crate::config::BridgeConfig;

/// Run the discovery subsystem. Never returns under normal operation.
///
/// `device_type` / `device_name` come from the descriptor the bridge
/// negotiated with the adapter at handshake time.
pub async fn run(config: &BridgeConfig, device_type: &str, device_name: &str) -> Result<()> {
    // --- mDNS registration ---
    let mdns = ServiceDaemon::new().map_err(|e| anyhow::anyhow!("mDNS daemon error: {e}"))?;

    let service_type = "_xrobo._tcp.local.";
    let host_name = hostname::get()
        .unwrap_or_else(|_| "xr-bridge".into())
        .to_string_lossy()
        .into_owned();
    let full_host = format!("{host_name}.local.");

    let mut properties = HashMap::new();
    properties.insert("pose_port".to_string(), config.pose_port.to_string());
    properties.insert("video_port".to_string(), config.video_port.to_string());
    properties.insert(
        "telemetry_port".to_string(),
        config.telemetry_port.to_string(),
    );
    properties.insert(
        "pose_udp_port".to_string(),
        config.pose_udp_port.to_string(),
    );
    properties.insert("version".to_string(), env!("CARGO_PKG_VERSION").to_string());

    let service = ServiceInfo::new(
        service_type,
        &config.name,
        &full_host,
        "",
        config.pose_port,
        properties,
    )
    .map_err(|e| anyhow::anyhow!("mDNS service info error: {e}"))?;

    mdns.register(service)
        .map_err(|e| anyhow::anyhow!("mDNS register error: {e}"))?;

    tracing::info!(
        "mDNS: advertising '{}' as {} on {full_host}",
        config.name,
        service_type
    );

    // --- UDP broadcast ---
    let udp_socket = tokio::net::UdpSocket::bind("0.0.0.0:0").await?;
    udp_socket.set_broadcast(true)?;

    let broadcast_msg = serde_json::json!({
        "service": "xrobo-agent",
        "name": config.name,
        "tcp_port": config.pose_port,
        "video_port": config.video_port,
        "telemetry_port": config.telemetry_port,
        "pose_udp_port": config.pose_udp_port,
        "version": env!("CARGO_PKG_VERSION"),
        "device_type": device_type,
        "device_name": device_name,
    })
    .to_string();

    let discovery_addrs = udp_discovery_targets(config);
    let discovery_label = discovery_addrs
        .iter()
        .map(ToString::to_string)
        .collect::<Vec<_>>()
        .join(", ");

    tracing::info!("UDP discovery: sending to {} every 3s", discovery_label);

    loop {
        for discovery_addr in &discovery_addrs {
            if let Err(e) = udp_socket
                .send_to(broadcast_msg.as_bytes(), discovery_addr)
                .await
            {
                tracing::warn!("UDP discovery send error to {discovery_addr}: {e}");
            }
        }
        tokio::time::sleep(std::time::Duration::from_secs(3)).await;
    }
}

fn udp_discovery_targets(config: &BridgeConfig) -> Vec<SocketAddr> {
    let mut targets = udp_broadcast_targets(config.discovery_port);
    targets.extend(
        config
            .discovery_unicast_targets
            .iter()
            .copied()
            .map(|ip| SocketAddr::new(ip, config.discovery_port)),
    );
    targets.sort_unstable();
    targets.dedup();
    targets
}

fn udp_broadcast_targets(port: u16) -> Vec<SocketAddr> {
    let mut targets = Vec::new();

    match get_if_addrs::get_if_addrs() {
        Ok(interfaces) => {
            for interface in interfaces {
                if interface.is_loopback() {
                    continue;
                }
                let IfAddr::V4(addr) = interface.addr else {
                    continue;
                };
                let broadcast = addr
                    .broadcast
                    .unwrap_or_else(|| ipv4_broadcast(addr.ip, addr.netmask));
                if broadcast.is_unspecified() || broadcast == Ipv4Addr::LOCALHOST {
                    continue;
                }
                targets.push(SocketAddr::new(IpAddr::V4(broadcast), port));
            }
        }
        Err(e) => {
            tracing::warn!("UDP discovery: failed to enumerate interfaces: {e}");
        }
    }

    if targets.is_empty() {
        targets.push(SocketAddr::new(
            IpAddr::V4(Ipv4Addr::new(255, 255, 255, 255)),
            port,
        ));
    }

    targets.sort_unstable();
    targets.dedup();
    targets
}

fn ipv4_broadcast(ip: Ipv4Addr, netmask: Ipv4Addr) -> Ipv4Addr {
    Ipv4Addr::from(u32::from(ip) | !u32::from(netmask))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn computes_ipv4_subnet_broadcast() {
        assert_eq!(
            ipv4_broadcast(
                Ipv4Addr::new(10, 79, 145, 75),
                Ipv4Addr::new(255, 255, 240, 0)
            ),
            Ipv4Addr::new(10, 79, 159, 255)
        );
    }

    #[test]
    fn includes_configured_unicast_discovery_targets() {
        let mut config = BridgeConfig::default();
        config.discovery_port = 63900;
        config.discovery_unicast_targets = vec![IpAddr::V4(Ipv4Addr::new(10, 79, 151, 145))];

        let targets = udp_discovery_targets(&config);

        assert!(targets.contains(&"10.79.151.145:63900".parse().unwrap()));
    }
}
