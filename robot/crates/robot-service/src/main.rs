//! robot-service binary entry point.
//!
//! This is the robot-side service counterpart to the operator/XR client. It
//! reads one shared YAML file, starts `robot-adapter`, then starts the XR-facing
//! bridge against that in-process adapter endpoint. Hardware-specific SO-101
//! control still lives in the Python control subprocess.

use std::path::PathBuf;

use anyhow::{Context, Result};
use clap::Parser;
use tracing_subscriber::EnvFilter;

use robot_adapter::config::AdapterConfig;
use robot_adapter::{build_device, serve};
use teleop_protocol::listen;
use xr_bridge::config::BridgeConfig;
use xr_bridge::service::run_adapter_mode;

/// Robot-side service: adapter + bridge from one shared YAML config.
#[derive(Debug, Parser)]
#[command(name = "robot-service", version, about)]
struct Cli {
    /// Path to a shared YAML config containing adapter_link, adapter, and bridge sections.
    #[arg(long)]
    config: Option<PathBuf>,
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")),
        )
        .init();

    let cli = Cli::parse();
    let (adapter_config, mut bridge_config) = load_configs(cli.config.as_deref())?;

    let descriptor = adapter_config.load_descriptor()?;
    tracing::info!(
        device = %descriptor.device.name,
        device_type = %adapter_config.device_type,
        "building robot-service device"
    );
    let device = build_device(&adapter_config, descriptor)
        .with_context(|| format!("building device_type {:?}", adapter_config.device_type))?;

    let listener = listen(&adapter_config.endpoint)
        .await
        .with_context(|| format!("binding adapter endpoint {}", adapter_config.endpoint))?;
    let bound_endpoint = listener.endpoint();
    bridge_config.adapter_endpoint = bound_endpoint.clone();

    tracing::info!(
        "robot-service starting: adapter={} pose={} pose_udp={} telemetry={} discovery={}",
        bound_endpoint,
        bridge_config.pose_port,
        bridge_config.pose_udp_port,
        bridge_config.telemetry_port,
        bridge_config.discovery_port,
    );

    let mut adapter_task = tokio::spawn(async move { serve(listener, device).await });

    tokio::select! {
        bridge_result = run_adapter_mode(bridge_config) => {
            adapter_task.abort();
            bridge_result.context("bridge service exited")
        }
        adapter_result = &mut adapter_task => {
            match adapter_result {
                Ok(Ok(())) => Ok(()),
                Ok(Err(err)) => Err(err).context("adapter service exited"),
                Err(err) if err.is_cancelled() => Ok(()),
                Err(err) => Err(err).context("adapter service task failed"),
            }
        }
    }
}

fn load_configs(path: Option<&std::path::Path>) -> Result<(AdapterConfig, BridgeConfig)> {
    match path {
        Some(path) => {
            let adapter = AdapterConfig::from_yaml_file(path)?;
            let bridge = BridgeConfig::from_yaml_file(path)?;
            Ok((adapter, bridge))
        }
        None => Ok((AdapterConfig::default(), BridgeConfig::default())),
    }
}
