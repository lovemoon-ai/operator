//! xr-bridge binary entry point.
//!
//! The reusable bridge runtime lives in [`xr_bridge::service`] so the
//! standalone `xr-bridge` binary and the combined `robot-service` binary share
//! the same XR-facing network implementation.

use std::path::PathBuf;
use std::str::FromStr;

use anyhow::{Context, Result};
use clap::Parser;
use tracing_subscriber::EnvFilter;

use teleop_protocol::Endpoint;
use xr_bridge::config::BridgeConfig;
use xr_bridge::service::{run_adapter_mode, run_video_only_mode};

/// XR-facing bridge: adapter-backed control path plus optional standalone video relay.
#[derive(Debug, Parser)]
#[command(name = "xr-bridge", version, about)]
struct Cli {
    /// Path to a YAML config file.
    #[arg(long)]
    config: Option<PathBuf>,

    /// Adapter endpoint, e.g. `uds:/tmp/teleop-adapter.sock` or
    /// `tcp:127.0.0.1:63910`. Overrides the config file value when set.
    #[arg(long)]
    adapter_endpoint: Option<String>,

    /// Run without robot-adapter and advertise only bridge-configured video feeds.
    #[arg(long)]
    video_only: bool,
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")),
        )
        .init();

    let cli = Cli::parse();

    let mut config = match &cli.config {
        Some(path) => BridgeConfig::from_yaml_file(path)?,
        None => BridgeConfig::default(),
    };

    if cli.video_only {
        if cli.adapter_endpoint.is_some() {
            tracing::warn!("Ignoring --adapter-endpoint because --video-only does not connect to robot-adapter");
        }
        run_video_only_mode(config).await
    } else {
        if let Some(ep) = &cli.adapter_endpoint {
            config.adapter_endpoint = Endpoint::from_str(ep)
                .with_context(|| format!("invalid --adapter-endpoint {ep:?}"))?;
        }
        run_adapter_mode(config).await
    }
}
