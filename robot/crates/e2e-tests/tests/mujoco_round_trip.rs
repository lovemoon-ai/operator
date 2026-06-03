//! REAL end-to-end milestone proof: the `xr-bridge` AdapterClient driving the
//! `robot-adapter` `RobotArmDevice` — backed by the actual MuJoCo SO-101
//! simulator subprocess — over a real loopback socket.
//!
//! This crosses every layer that matters for the mujoco control chain:
//!   bridge AdapterClient → BridgeCodec frame → loopback socket
//!   → AdapterCodec decode → RobotArmDevice → PoseMapper EE target mapping
//!   → MuJoCo bridge subprocess IK (python sim_so101.py bridge)
//!   → telemetry frame → bridge watch channel.
//!
//! The test holds the teleop `enable` deadman, seeds the PoseMapper reference
//! with a first pose, then sends poses with a position offset that produce a
//! non-trivial bridge-side IK target, and asserts the reported `joint_angles`
//! telemetry CHANGES (the sim actually moved).
//!
//! Requires the MuJoCo venv (created by `examples/mujuco-arm-so101 make env`).
//! If the python binary is missing, the test skips (prints + returns) rather
//! than failing. Paths are absolute, computed from CARGO_MANIFEST_DIR; override
//! with MUJOCO_PYTHON / MUJOCO_SCRIPT.
//!
//! Run with: `cargo test -p e2e-tests --test mujoco_round_trip`

use std::path::PathBuf;
use std::time::Duration;

use robot_adapter::config::{ArmConfig, MujocoConfig, PoseMappingConfig, SafetyConfig};
use robot_adapter::devices::RobotArmDevice;
use robot_adapter::server::serve;
use teleop_protocol::{listen, DeviceCommand, Endpoint, Pose6D, TelemetryValue};
use tokio::time::{sleep, timeout};
use xr_bridge::adapter_client::AdapterClient;

/// Repo root = e2e-tests manifest dir → up three (`crates/e2e-tests` →
/// `crates` → `robot` → repo root).
fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("..")
        .join("..")
        .canonicalize()
        .expect("canonicalize repo root")
}

fn mujoco_python() -> PathBuf {
    if let Ok(p) = std::env::var("MUJOCO_PYTHON") {
        return PathBuf::from(p);
    }
    repo_root().join("examples/mujuco-arm-so101/.venv/bin/python")
}

fn mujoco_script() -> PathBuf {
    if let Ok(p) = std::env::var("MUJOCO_SCRIPT") {
        return PathBuf::from(p);
    }
    repo_root().join("examples/mujuco-arm-so101/sim_so101.py")
}

fn arm_config(python: &str, script: &str) -> ArmConfig {
    ArmConfig {
        driver: "mujoco_so101".to_string(),
        serial_port: String::new(),
        baudrate: 0,
        servo_ids: vec![1, 2, 3, 4, 5, 6],
        safety: SafetyConfig {
            joint_limits_deg: vec![
                [-105.0, 105.0],
                [-95.0, 95.0],
                [-92.0, 92.0],
                [-90.0, 90.0],
                [-150.0, 155.0],
                [-5.0, 95.0],
            ],
            // Generous velocity so the slew-rate clamp doesn't swallow our
            // deliberately large pose deltas across a few frames.
            max_velocity_deg_s: 100_000.0,
            max_acceleration_deg_s2: 1_000_000.0,
        },
        pose_mapping: PoseMappingConfig {
            mode: "ik".to_string(),
            scale: 0.5,
            mirror: true,
        },
        // Generous so the spawn → ready → first-step warm-up never drops frames.
        driver_write_timeout_ms: 2000,
        mujoco: Some(MujocoConfig {
            python: python.to_string(),
            script: script.to_string(),
            steps_per_write: 3,
            extra_args: vec![],
        }),
    }
}

const IDENTITY_QUAT: [f64; 4] = [0.0, 0.0, 0.0, 1.0];

fn pose_cmd(position: [f64; 3]) -> DeviceCommand {
    let mut cmd = DeviceCommand::default();
    cmd.buttons.insert("enable".to_string(), true);
    cmd.poses.insert(
        "end_effector".to_string(),
        Pose6D {
            position,
            rotation: IDENTITY_QUAT,
        },
    );
    cmd
}

/// Pull the `joint_angles` array out of the latest telemetry on the watch.
fn joint_angles(t: &Option<teleop_protocol::DeviceTelemetry>) -> Option<Vec<f64>> {
    let tel = t.as_ref()?;
    match tel.values.get("joint_angles")? {
        TelemetryValue::Array(a) => Some(a.clone()),
        _ => None,
    }
}

#[tokio::test]
async fn mujoco_round_trip_moves_joints() {
    let python = mujoco_python();
    let script = mujoco_script();

    if !python.exists() {
        eprintln!(
            "skipping: no mujoco venv at {} (run `cd examples/mujuco-arm-so101 && make env`)",
            python.display()
        );
        return;
    }
    assert!(
        script.exists(),
        "mujoco venv present but script missing at {}",
        script.display()
    );

    let arm = arm_config(python.to_str().unwrap(), script.to_str().unwrap());

    // Build the real arm device on absolute paths and serve it on loopback.
    let device = RobotArmDevice::new(RobotArmDevice::default_descriptor(), &arm)
        .expect("build RobotArmDevice");

    let listener = listen(&Endpoint::Tcp("127.0.0.1:0".parse().unwrap()))
        .await
        .expect("listen on ephemeral port");
    let endpoint = listener.endpoint();

    // serve() connects the device once up front — that spawns the MuJoCo
    // subprocess and awaits its ready handshake (cold start 1–3 s).
    tokio::spawn(async move {
        let _ = serve(listener, Box::new(device)).await;
    });

    // Overall budget for the whole test (cold start + frames + telemetry).
    let outcome = timeout(Duration::from_secs(30), async {
        let mut client = AdapterClient::connect(&endpoint).await.expect("connect");

        // Handshake — assert the arm descriptor crossed the boundary.
        let desc = client.handshake().await.expect("handshake");
        assert_eq!(desc.device.device_type, "robot_arm");
        assert!(desc.control_schema.poses.len() >= 2);
        assert_eq!(desc.control_schema.poses[0].name, "end_effector");
        assert!(desc
            .control_schema
            .poses
            .iter()
            .any(|pose| pose.name == "operator_frame"));

        let mut telemetry = client.telemetry();

        // Wait for the first telemetry sample (device connected, sim ready).
        // The sim cold start can take a few seconds; give it up to 15 s.
        let seed_angles = wait_for_joint_angles(&mut telemetry, Duration::from_secs(15))
            .await
            .expect("first joint_angles telemetry (sim ready)");

        // Frame 1: seed the PoseMapper reference at the origin.
        client
            .send_command(&pose_cmd([0.0, 0.0, 0.0]))
            .await
            .expect("seed pose");

        // Frames 2..N: move the controller forward/up. The adapter maps this
        // to a robot-frame end-effector target; the Python bridge solves IK.
        // Send a handful so the sim integrates.
        for _ in 0..8 {
            client
                .send_command(&pose_cmd([0.0, 0.05, -0.10]))
                .await
                .expect("offset pose");
            sleep(Duration::from_millis(30)).await;
        }

        // The reported joint angles must have changed from the seed snapshot.
        let moved = wait_until_changed(&mut telemetry, &seed_angles, Duration::from_secs(10)).await;
        assert!(
            moved.is_some(),
            "joint_angles never changed after moving the controller (seed={seed_angles:?})"
        );
        let after = moved.unwrap();

        // Sanity: at least one arm joint moved meaningfully, proving the
        // position-delta -> EE target -> bridge-side IK path is live.
        let max_arm_delta = after
            .iter()
            .take(5)
            .zip(seed_angles.iter().take(5))
            .map(|(after, seed)| (after - seed).abs())
            .fold(0.0_f64, f64::max);
        assert!(
            max_arm_delta > 0.5,
            "arm joints barely moved (max_delta={max_arm_delta:.3} deg); seed={seed_angles:?} after={after:?}"
        );
    })
    .await;

    outcome.expect("mujoco round trip timed out (30s) — sim may have failed to start");
}

/// Wait until a telemetry sample with a `joint_angles` array lands.
async fn wait_for_joint_angles(
    rx: &mut tokio::sync::watch::Receiver<Option<teleop_protocol::DeviceTelemetry>>,
    budget: Duration,
) -> Option<Vec<f64>> {
    timeout(budget, async {
        loop {
            if let Some(a) = joint_angles(&rx.borrow_and_update()) {
                if !a.is_empty() {
                    return a;
                }
            }
            if rx.changed().await.is_err() {
                // Sender dropped; nothing more will arrive.
                return Vec::new();
            }
        }
    })
    .await
    .ok()
    .filter(|a| !a.is_empty())
}

/// Wait until the telemetry `joint_angles` differs from `baseline`.
async fn wait_until_changed(
    rx: &mut tokio::sync::watch::Receiver<Option<teleop_protocol::DeviceTelemetry>>,
    baseline: &[f64],
    budget: Duration,
) -> Option<Vec<f64>> {
    timeout(budget, async {
        loop {
            if let Some(a) = joint_angles(&rx.borrow_and_update()) {
                if a.len() == baseline.len()
                    && a.iter().zip(baseline).any(|(x, y)| (x - y).abs() > 1e-6)
                {
                    return a;
                }
            }
            if rx.changed().await.is_err() {
                return Vec::new();
            }
        }
    })
    .await
    .ok()
    .filter(|a| !a.is_empty())
}
