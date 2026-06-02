//! robot-adapter binary entry point.
//!
//! Loads config (optional YAML + CLI overrides), builds the dummy device and
//! its descriptor, binds the boundary-protocol listener, and runs the server.

use std::str::FromStr;

use anyhow::{Context, Result};
use clap::Parser;
use tracing_subscriber::EnvFilter;

use robot_adapter::config::AdapterConfig;
use robot_adapter::devices::build_device;
use robot_adapter::server::serve;

use teleop_protocol::{listen, Endpoint};

/// robot-adapter — drives a concrete robot form from the xr-bridge boundary
/// protocol.
#[derive(Debug, Parser)]
#[command(name = "robot-adapter", version, about)]
struct Cli {
    /// Path to a YAML config file.
    #[arg(long)]
    config: Option<String>,

    /// Override the listen endpoint, e.g. `uds:/tmp/teleop-adapter.sock` or
    /// `tcp:127.0.0.1:63910`.
    #[arg(long)]
    endpoint: Option<String>,
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")))
        .init();

    let cli = Cli::parse();

    // Base config: file if given, else defaults.
    let mut cfg = match &cli.config {
        Some(path) => AdapterConfig::from_yaml_file(path)
            .with_context(|| format!("loading config {path}"))?,
        None => AdapterConfig::default(),
    };

    // CLI overrides.
    if let Some(ep) = &cli.endpoint {
        cfg.endpoint = Endpoint::from_str(ep)
            .with_context(|| format!("parsing --endpoint {ep:?}"))?;
    }

    let descriptor = cfg.load_descriptor()?;
    tracing::info!(
        device = %descriptor.device.name,
        device_type = %cfg.device_type,
        "building device"
    );

    // Factory dispatch on device_type: dummy / mujoco_so101 (else dummy + warn).
    let device = build_device(&cfg, descriptor)
        .with_context(|| format!("building device_type {:?}", cfg.device_type))?;

    let listener = listen(&cfg.endpoint)
        .await
        .with_context(|| format!("binding endpoint {}", cfg.endpoint))?;
    tracing::info!("robot-adapter listening on {}", listener.endpoint());

    serve(listener, device).await
}
