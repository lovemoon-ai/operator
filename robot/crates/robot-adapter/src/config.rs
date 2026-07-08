//! Adapter configuration.
//!
//! Loadable from a legacy adapter-only YAML or a shared YAML with
//! `adapter_link` + `adapter` sections, and overridable from the CLI. The
//! endpoint can be expressed as a `"uds:<path>"` / `"tcp:<addr>"` string in
//! YAML thanks to [`Endpoint`]'s `FromStr`.

use std::path::Path;
use std::str::FromStr;

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};

use teleop_protocol::{DeviceDescriptor, Endpoint};

use crate::devices::{DualSo101Device, DummyDevice};

/// Runtime configuration for the adapter.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AdapterConfig {
    /// Where the adapter listens for the bridge.
    #[serde(default, with = "endpoint_serde")]
    pub endpoint: Endpoint,
    /// Which concrete device form to drive.
    #[serde(default = "default_device_type")]
    pub device_type: String,
    /// Optional path to a `DeviceDescriptor` (YAML/JSON). When unset, a
    /// minimal built-in descriptor is used (dummy descriptor for `dummy`,
    /// the built-in arm descriptor for `mujoco_so101` / `so101_real`).
    #[serde(default)]
    pub descriptor_file: Option<String>,
    /// Arm-specific config. Required when `device_type` is an SO-101 arm,
    /// ignored otherwise.
    #[serde(default)]
    pub arm: Option<ArmConfig>,
    /// Dual-arm SO-101 config. Required when `device_type` is
    /// `so101_dual_real`, ignored otherwise.
    #[serde(default)]
    pub dual_arm: Option<DualArmConfig>,
}

/// Robotic arm configuration. Ported from `robot/src/config.rs`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ArmConfig {
    /// Driver type. `"mujoco_so101"` drives the simulator; `"so101_real"`
    /// drives a real SO-101 through the Python/LeRobot Feetech bridge.
    pub driver: String,
    /// Serial port path (e.g. `/dev/ttyUSB0`). Unused by the MuJoCo driver.
    #[serde(default)]
    pub serial_port: String,
    /// Serial baud rate. Unused by the MuJoCo driver.
    #[serde(default)]
    pub baudrate: u32,
    /// List of servo IDs on the bus. Sizes the PoseMapper output vector.
    pub servo_ids: Vec<u8>,
    /// Joint-space safety limits.
    pub safety: SafetyConfig,
    /// Pose-to-joint mapping parameters.
    pub pose_mapping: PoseMappingConfig,
    /// Maximum time a single driver write is allowed to block before the
    /// arm gives up on this frame and waits for the next. Default 20 ms.
    #[serde(default = "default_driver_write_timeout_ms")]
    pub driver_write_timeout_ms: u64,
    /// MuJoCo SO-101 bridge settings. Required when
    /// `driver == "mujoco_so101"`, ignored otherwise.
    #[serde(default)]
    pub mujoco: Option<MujocoConfig>,
    /// Real SO-101 bridge settings. Required when `driver == "so101_real"`,
    /// ignored otherwise.
    #[serde(default)]
    pub so101: Option<So101Config>,
}

/// Two independent SO-101 arms controlled from one XR session.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DualArmConfig {
    /// Arm driven from the XR left controller.
    pub left: ArmConfig,
    /// Arm driven from the XR right controller.
    pub right: ArmConfig,
}

fn default_driver_write_timeout_ms() -> u64 {
    20
}

/// Settings for the MuJoCo SO-101 simulator driver (`driver = "mujoco_so101"`).
/// The driver spawns `<python> <script> bridge [extra_args ...]` as a
/// subprocess and speaks the JSON-line protocol defined in
/// `examples/mujuco-arm-so101/sim_so101.py`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MujocoConfig {
    /// Python interpreter to invoke. Default `"python3"`. Set to the venv's
    /// `python` (e.g. `examples/mujuco-arm-so101/.venv/bin/python`) to avoid
    /// relying on PATH. Relative paths resolve against the adapter CWD.
    #[serde(default = "default_mujoco_python")]
    pub python: String,
    /// Path to `sim_so101.py`. Relative paths resolve against the adapter CWD.
    pub script: String,
    /// `mj_step` calls per outbound ctrl write. The driver clamps to `[1, 50]`.
    #[serde(default = "default_mujoco_steps")]
    pub steps_per_write: u32,
    /// Extra args passed after `bridge`.
    #[serde(default)]
    pub extra_args: Vec<String>,
}

fn default_mujoco_python() -> String {
    "python3".to_string()
}

fn default_mujoco_steps() -> u32 {
    3
}

/// Settings for the real SO-101 hardware driver (`driver = "so101_real"`).
/// The adapter spawns `<python> <script> control [extra_args ...]` and the
/// Python control process owns LeRobot/Feetech serial bus I/O plus hardware
/// reflexes.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct So101Config {
    /// Python interpreter to invoke. Default `"python3"`. Use a venv that has
    /// `lerobot` and Feetech motor support installed.
    #[serde(default = "default_so101_python")]
    pub python: String,
    /// Path to `scripts/so101_real_control.py`.
    pub script: String,
    /// Serial port path for the Feetech bus, e.g. `/dev/ttyACM0`.
    pub port: String,
    /// Extra args passed after `control --port <port>`.
    #[serde(default)]
    pub extra_args: Vec<String>,
}

fn default_so101_python() -> String {
    "python3".to_string()
}

/// Joint safety limits (degrees).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SafetyConfig {
    /// Per-joint angle limits in degrees: `[[min, max], ...]`.
    pub joint_limits_deg: Vec<[f64; 2]>,
    /// Maximum angular velocity (deg/s).
    pub max_velocity_deg_s: f64,
    /// Maximum angular acceleration (deg/s^2).
    pub max_acceleration_deg_s2: f64,
}

/// Pose mapping configuration.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PoseMappingConfig {
    /// Mapping mode: "direct", "ik", or "retarget".
    pub mode: String,
    /// Position scale factor.
    pub scale: f64,
    /// Whether to mirror left/right.
    pub mirror: bool,
}

fn default_device_type() -> String {
    "dummy".to_string()
}

impl Default for AdapterConfig {
    fn default() -> Self {
        Self {
            endpoint: Endpoint::default(),
            device_type: default_device_type(),
            descriptor_file: None,
            arm: None,
            dual_arm: None,
        }
    }
}

impl AdapterConfig {
    /// Load configuration from a YAML file.
    pub fn from_yaml_file(path: impl AsRef<Path>) -> Result<Self> {
        let path = path.as_ref();
        let text = std::fs::read_to_string(path)
            .with_context(|| format!("reading adapter config {}", path.display()))?;
        Self::from_yaml_str(&text)
            .with_context(|| format!("parsing adapter config {}", path.display()))
    }

    /// Parse configuration from a YAML string.
    pub fn from_yaml_str(text: &str) -> Result<Self> {
        let shared: SharedConfigFile = serde_yaml::from_str(text).context("invalid YAML")?;
        if shared.adapter.is_some() || shared.adapter_link.is_some() || shared.bridge.is_some() {
            let mut cfg = shared.adapter.unwrap_or_default();
            if let Some(link) = shared.adapter_link {
                apply_adapter_link_config(&mut cfg, link)?;
            }
            return Ok(cfg);
        }

        let cfg: AdapterConfig = serde_yaml::from_str(text).context("invalid YAML")?;
        Ok(cfg)
    }

    /// Resolve the [`DeviceDescriptor`] for this config: load from
    /// `descriptor_file` if set, else build the built-in descriptor for the
    /// configured `device_type` (dummy -> dummy descriptor, SO-101 arm types ->
    /// the built-in arm descriptor).
    pub fn load_descriptor(&self) -> Result<DeviceDescriptor> {
        match &self.descriptor_file {
            Some(file) => load_descriptor_file(file),
            None => Ok(self.builtin_descriptor()),
        }
    }

    /// The built-in descriptor for this config's `device_type`.
    pub fn builtin_descriptor(&self) -> DeviceDescriptor {
        match self.device_type.as_str() {
            "mujoco_so101" | "so101_real" => crate::devices::RobotArmDevice::default_descriptor(),
            "so101_dual_real" | "dual_so101_real" => DualSo101Device::default_descriptor(),
            _ => DummyDevice::default_descriptor(),
        }
    }
}

/// Load a [`DeviceDescriptor`] from a YAML or JSON file (decided by extension;
/// defaults to YAML, which is a JSON superset so JSON parses too).
pub fn load_descriptor_file(path: impl AsRef<Path>) -> Result<DeviceDescriptor> {
    let path = path.as_ref();
    let text = std::fs::read_to_string(path)
        .with_context(|| format!("reading descriptor {}", path.display()))?;
    let desc: DeviceDescriptor = serde_yaml::from_str(&text)
        .with_context(|| format!("parsing descriptor {}", path.display()))?;
    Ok(desc)
}

/// Minimal built-in dummy descriptor (re-export of [`DummyDevice::default_descriptor`]).
pub fn builtin_dummy_descriptor() -> DeviceDescriptor {
    DummyDevice::default_descriptor()
}

/// Shared config section for the bridge/adapter boundary connection.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
struct AdapterLinkConfigFile {
    /// Endpoint used by the adapter to listen and by the bridge to dial.
    #[serde(default)]
    endpoint: Option<String>,
}

/// Shared YAML envelope. `robot-adapter` reads only `adapter_link` and
/// `adapter`, ignoring the `bridge` section.
#[derive(Debug, Clone, Deserialize, Default)]
struct SharedConfigFile {
    #[serde(default)]
    adapter_link: Option<AdapterLinkConfigFile>,
    #[serde(default)]
    adapter: Option<AdapterConfig>,
    #[serde(default)]
    bridge: Option<serde_yaml::Value>,
}

fn apply_adapter_link_config(cfg: &mut AdapterConfig, link: AdapterLinkConfigFile) -> Result<()> {
    if let Some(ep) = link.endpoint {
        cfg.endpoint = Endpoint::from_str(&ep)
            .with_context(|| format!("invalid adapter_link.endpoint {ep:?}"))?;
    }
    Ok(())
}

/// Serde adapter for [`Endpoint`] as a `"uds:..."` / `"tcp:..."` string.
mod endpoint_serde {
    use super::Endpoint;
    use serde::{Deserialize, Deserializer, Serializer};
    use std::str::FromStr;

    pub fn serialize<S: Serializer>(ep: &Endpoint, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&ep.to_string())
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Endpoint, D::Error> {
        let s = String::deserialize(d)?;
        Endpoint::from_str(&s).map_err(serde::de::Error::custom)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_config_uses_default_uds_endpoint() {
        let cfg = AdapterConfig::default();
        assert_eq!(cfg.device_type, "dummy");
        assert!(matches!(cfg.endpoint, Endpoint::Uds(_)));
        assert!(cfg.descriptor_file.is_none());
    }

    #[test]
    fn parses_yaml_with_tcp_endpoint() {
        let yaml = r#"
endpoint: "tcp:127.0.0.1:63910"
device_type: "dummy"
"#;
        let cfg = AdapterConfig::from_yaml_str(yaml).unwrap();
        assert_eq!(
            cfg.endpoint,
            Endpoint::Tcp("127.0.0.1:63910".parse().unwrap())
        );
        assert_eq!(cfg.device_type, "dummy");
    }

    #[test]
    fn empty_yaml_falls_back_to_defaults() {
        let cfg = AdapterConfig::from_yaml_str("{}").unwrap();
        assert!(matches!(cfg.endpoint, Endpoint::Uds(_)));
        assert_eq!(cfg.device_type, "dummy");
    }

    #[test]
    fn load_descriptor_returns_builtin_when_unset() {
        let cfg = AdapterConfig::default();
        let desc = cfg.load_descriptor().unwrap();
        assert_eq!(desc.device.device_type, "dummy");
    }

    #[test]
    fn parses_mujoco_arm_config() {
        let yaml = r#"
endpoint: "tcp:127.0.0.1:63910"
device_type: "mujoco_so101"
arm:
  driver: "mujoco_so101"
  servo_ids: [1, 2, 3, 4, 5, 6]
  safety:
    joint_limits_deg: [[-105.0, 105.0], [-95.0, 95.0]]
    max_velocity_deg_s: 90.0
    max_acceleration_deg_s2: 180.0
  pose_mapping:
    mode: "direct"
    scale: 1.0
    mirror: true
  driver_write_timeout_ms: 60
  mujoco:
    python: "../examples/mujuco-arm-so101/.venv/bin/python"
    script: "../examples/mujuco-arm-so101/sim_so101.py"
    steps_per_write: 3
"#;
        let cfg = AdapterConfig::from_yaml_str(yaml).unwrap();
        assert_eq!(cfg.device_type, "mujoco_so101");
        let arm = cfg.arm.as_ref().expect("arm section present");
        assert_eq!(arm.driver, "mujoco_so101");
        assert_eq!(arm.servo_ids.len(), 6);
        assert_eq!(arm.driver_write_timeout_ms, 60);
        let mj = arm.mujoco.as_ref().expect("mujoco block present");
        assert_eq!(mj.steps_per_write, 3);
        assert!(mj.script.ends_with("sim_so101.py"));
        // mujoco device_type resolves the built-in arm descriptor.
        let desc = cfg.builtin_descriptor();
        assert_eq!(desc.device.device_type, "robot_arm");
    }

    #[test]
    fn parses_so101_real_arm_config() {
        let yaml = r#"
endpoint: "tcp:127.0.0.1:63910"
device_type: "so101_real"
arm:
  driver: "so101_real"
  serial_port: "/dev/ttyACM0"
  servo_ids: [1, 2, 3, 4, 5, 6]
  safety:
    joint_limits_deg: [[-105.0, 105.0], [-95.0, 95.0]]
    max_velocity_deg_s: 90.0
    max_acceleration_deg_s2: 180.0
  pose_mapping:
    mode: "direct"
    scale: 0.35
    mirror: true
  driver_write_timeout_ms: 250
  so101:
    python: "python3"
    script: "scripts/so101_real_control.py"
    port: "/dev/ttyACM0"
"#;
        let cfg = AdapterConfig::from_yaml_str(yaml).unwrap();
        assert_eq!(cfg.device_type, "so101_real");
        let arm = cfg.arm.as_ref().expect("arm section present");
        assert_eq!(arm.driver, "so101_real");
        assert_eq!(arm.servo_ids.len(), 6);
        assert_eq!(arm.driver_write_timeout_ms, 250);
        let so101 = arm.so101.as_ref().expect("so101 block present");
        assert_eq!(so101.port, "/dev/ttyACM0");
        assert!(so101.script.ends_with("so101_real_control.py"));
        let desc = cfg.builtin_descriptor();
        assert_eq!(desc.device.device_type, "robot_arm");
    }

    #[test]
    fn parses_so101_dual_real_arm_config() {
        let yaml = r#"
endpoint: "tcp:127.0.0.1:63910"
device_type: "so101_dual_real"
dual_arm:
  left:
    driver: "so101_real"
    servo_ids: [1, 2, 3, 4, 5, 6]
    safety:
      joint_limits_deg: [[-105.0, 105.0], [-95.0, 95.0], [-92.0, 92.0], [-90.0, 90.0], [-150.0, 155.0], [0.0, 100.0]]
      max_velocity_deg_s: 90.0
      max_acceleration_deg_s2: 180.0
    pose_mapping:
      mode: "ik"
      scale: 0.5
      mirror: false
    driver_write_timeout_ms: 250
    so101:
      python: "python3"
      script: "scripts/so101_real_control.py"
      port: "/dev/ttyLEFT"
  right:
    driver: "so101_real"
    servo_ids: [1, 2, 3, 4, 5, 6]
    safety:
      joint_limits_deg: [[-105.0, 105.0], [-95.0, 95.0], [-92.0, 92.0], [-90.0, 90.0], [-150.0, 155.0], [0.0, 100.0]]
      max_velocity_deg_s: 90.0
      max_acceleration_deg_s2: 180.0
    pose_mapping:
      mode: "ik"
      scale: 0.5
      mirror: true
    driver_write_timeout_ms: 250
    so101:
      python: "python3"
      script: "scripts/so101_real_control.py"
      port: "/dev/ttyRIGHT"
"#;
        let cfg = AdapterConfig::from_yaml_str(yaml).unwrap();
        assert_eq!(cfg.device_type, "so101_dual_real");
        let dual = cfg.dual_arm.as_ref().expect("dual_arm section present");
        assert_eq!(dual.left.driver, "so101_real");
        assert_eq!(dual.left.so101.as_ref().unwrap().port, "/dev/ttyLEFT");
        assert_eq!(dual.right.so101.as_ref().unwrap().port, "/dev/ttyRIGHT");
        assert_eq!(
            cfg.builtin_descriptor().device.device_type,
            "so101_dual_arm"
        );
    }

    #[test]
    fn parses_shared_yaml_adapter_section_and_adapter_link() {
        let yaml = r#"
adapter_link:
  endpoint: "tcp:127.0.0.1:63910"

bridge:
  name: "ignored-by-adapter"
  video:
    feeds:
      - name: head
        rtsp_url: "rtsp://10.79.252.23:8554/head"
        tcp_port: 12345

adapter:
  endpoint: "tcp:127.0.0.1:1"
  device_type: "mujoco_so101"
  arm:
    driver: "mujoco_so101"
    servo_ids: [1, 2, 3, 4, 5, 6]
    safety:
      joint_limits_deg: [[-105.0, 105.0], [-95.0, 95.0]]
      max_velocity_deg_s: 90.0
      max_acceleration_deg_s2: 180.0
    pose_mapping:
      mode: "direct"
      scale: 1.0
      mirror: true
    driver_write_timeout_ms: 60
    mujoco:
      python: "../examples/mujuco-arm-so101/.venv/bin/python"
      script: "../examples/mujuco-arm-so101/sim_so101.py"
      steps_per_write: 3
"#;
        let cfg = AdapterConfig::from_yaml_str(yaml).unwrap();

        assert_eq!(
            cfg.endpoint,
            Endpoint::Tcp("127.0.0.1:63910".parse().unwrap())
        );
        assert_eq!(cfg.device_type, "mujoco_so101");
        let arm = cfg.arm.as_ref().expect("arm section present");
        assert_eq!(arm.driver, "mujoco_so101");
        assert_eq!(arm.servo_ids.len(), 6);
        assert_eq!(arm.driver_write_timeout_ms, 60);
        assert_eq!(
            arm.mujoco
                .as_ref()
                .expect("mujoco block present")
                .steps_per_write,
            3
        );
    }

    #[test]
    fn shipped_mujoco_config_file_parses() {
        // The config file shipped under robot/configs/ must parse and resolve
        // a mujoco arm device.
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../configs/mujoco_so101.yaml"
        );
        let cfg = AdapterConfig::from_yaml_file(path).expect("shipped config parses");
        assert_eq!(cfg.device_type, "mujoco_so101");
        assert!(cfg.arm.is_some());
    }

    #[test]
    fn shipped_so101_real_config_file_parses() {
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../../configs/so101_real.yaml");
        let cfg = AdapterConfig::from_yaml_file(path).expect("shipped config parses");
        assert_eq!(cfg.device_type, "so101_real");
        assert!(cfg
            .arm
            .as_ref()
            .and_then(|arm| arm.so101.as_ref())
            .is_some());
        let desc_path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../configs/so101_real_descriptor.yaml"
        );
        let desc = load_descriptor_file(desc_path).expect("shipped descriptor parses");
        assert_eq!(desc.device.device_type, "robot_arm");
    }

    #[test]
    fn shipped_so101_dual_real_config_file_parses() {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../configs/so101_dual_real.yaml"
        );
        let cfg = AdapterConfig::from_yaml_file(path).expect("shipped config parses");
        assert_eq!(cfg.device_type, "so101_dual_real");
        assert!(cfg.dual_arm.is_some());
        let desc_path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../configs/so101_dual_real_descriptor.yaml"
        );
        let desc = load_descriptor_file(desc_path).expect("shipped descriptor parses");
        assert_eq!(desc.device.device_type, "so101_dual_arm");
    }
}
