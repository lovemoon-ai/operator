//! Hermetic lifecycle + framing test for the LeRobot link driver.
//!
//! Replaces the old `so101_real_driver_stub` test. The shape is different
//! because the driver is: the adapter now *listens* and the plugin *dials in*,
//! so the test spawns the stub plugin itself rather than the driver spawning a
//! subprocess.
//!
//! The other structural difference worth knowing: the old driver was
//! request/response, so `last_joint_angles()` was fresh the instant a write
//! returned. This driver is decoupled (targets are latest-wins, writes never
//! block on the plugin), so state lags by one round trip and the assertions
//! below poll instead of reading immediately.

use std::path::PathBuf;
use std::process::{Child, Command as StdCommand};
use std::time::{Duration, Instant};

use robot_adapter::config::{ArmConfig, LerobotConfig, PoseMappingConfig, SafetyConfig};
use robot_adapter::control::drivers::lerobot_link::{LerobotLinkDriver, NUM_ACTUATORS};
use robot_adapter::control::drivers::ArmDriver;
use robot_adapter::control::JointAngles;
use robot_adapter::{Device, RobotArmDevice};
use teleop_protocol::{DeviceCommand, Endpoint, Pose6D, TelemetryValue};

const HELLO_TIMEOUT: Duration = Duration::from_secs(10);
const SETTLE_TIMEOUT: Duration = Duration::from_secs(5);

fn python_available() -> bool {
    StdCommand::new("python3")
        .arg("--version")
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

fn stub_script() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("fixtures")
        .join("stub_vr_plugin.py")
}

/// Unique per-test UDS path so concurrent `cargo test` threads never collide.
fn temp_endpoint(tag: &str) -> Endpoint {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let path = std::env::temp_dir().join(format!(
        "lerobot-link-{tag}-{}-{nanos}.sock",
        std::process::id()
    ));
    format!("uds:{}", path.display()).parse().unwrap()
}

/// Kills the stub plugin on drop so a failing assertion cannot leak a process.
struct StubGuard(Child);

impl Drop for StubGuard {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

fn spawn_stub(endpoint: &Endpoint, extra: &[&str]) -> StubGuard {
    let child = StdCommand::new("python3")
        .arg(stub_script())
        .arg("--endpoint")
        .arg(endpoint.to_string())
        .args(extra)
        .spawn()
        .expect("spawn stub plugin");
    StubGuard(child)
}

/// Poll `f` until it returns `Some`, or panic after `SETTLE_TIMEOUT`.
async fn wait_for<T>(label: &str, mut f: impl FnMut() -> Option<T>) -> T {
    let deadline = Instant::now() + SETTLE_TIMEOUT;
    loop {
        if let Some(v) = f() {
            return v;
        }
        if Instant::now() > deadline {
            panic!("timed out waiting for {label}");
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
}

#[tokio::test]
async fn link_driver_round_trips_against_stub_plugin() {
    if !python_available() {
        eprintln!("skipping lerobot_link_driver_stub: python3 unavailable");
        return;
    }

    let endpoint = temp_endpoint("roundtrip");
    let mut driver = LerobotLinkDriver::new(&endpoint, HELLO_TIMEOUT).expect("start link driver");
    let _stub = spawn_stub(&endpoint, &[]);

    // enable_torque blocks until the plugin's Hello arrives, because the
    // end-effector snapshot it carries is what driver-side IK mode requires.
    driver.enable_torque().await.expect("enable_torque");

    let joints = driver
        .last_joint_angles()
        .expect("Hello should seed joint angles");
    assert_eq!(joints.angles.len(), NUM_ACTUATORS);
    assert_eq!(joints.angles[1], -90.0);
    let ee = driver
        .last_end_effector_pose()
        .expect("Hello should seed an end-effector pose");
    assert_eq!(ee.position, [0.25, 0.0, 0.2]);

    // End-effector target: the stub echoes position[0] into joint 0 and maps
    // the normalized gripper into 0..100.
    let pose = Pose6D {
        position: [0.31, -0.02, 0.18],
        rotation: [0.0, 0.0, 0.0, 1.0],
    };
    driver
        .set_end_effector_pose(&pose, Some(0.5))
        .await
        .expect("set_end_effector_pose");

    let joints = wait_for("end-effector state to land", || {
        driver
            .last_joint_angles()
            .filter(|j| (j.angles[0] - 0.31).abs() < 1e-9)
    })
    .await;
    assert!(
        (joints.angles[5] - 50.0).abs() < 1e-9,
        "gripper 0.5 must map to 50.0 (RANGE_0_100), got {}",
        joints.angles[5]
    );
    let ee = driver.last_end_effector_pose().expect("ee reported");
    assert_eq!(ee.position, pose.position);

    // Direct joint passthrough (pose_mapping.mode = "direct").
    driver
        .set_joints(&JointAngles {
            angles: vec![10.0, -20.0, 30.0, -40.0, 50.0],
        })
        .await
        .expect("set_joints");
    let joints = wait_for("joint state to land", || {
        driver
            .last_joint_angles()
            .filter(|j| (j.angles[0] - 10.0).abs() < 1e-9)
    })
    .await;
    assert_eq!(&joints.angles[..5], &[10.0, -20.0, 30.0, -40.0, 50.0]);

    driver.set_gripper(0.0).await.expect("close gripper");
    wait_for("gripper close to land", || {
        driver.last_joint_angles().filter(|j| j.angles[5] == 0.0)
    })
    .await;

    // Reset is an edge carried as a monotonic epoch.
    driver
        .reset_to_initial_pose()
        .await
        .expect("reset_to_initial_pose");
    let joints = wait_for("reset to land", || {
        driver
            .last_joint_angles()
            .filter(|j| j.angles == vec![0.0, -90.0, 90.0, 0.0, 0.0, 85.0])
    })
    .await;
    assert_eq!(joints.angles[1], -90.0);

    driver.emergency_stop().await.expect("emergency_stop");
}

#[tokio::test]
async fn enable_torque_times_out_without_a_plugin() {
    let endpoint = temp_endpoint("nohello");
    // No stub spawned: the driver must fail loudly rather than silently
    // accepting targets nobody will ever execute.
    let mut driver =
        LerobotLinkDriver::new(&endpoint, Duration::from_millis(300)).expect("start link driver");

    let err = driver
        .enable_torque()
        .await
        .expect_err("enable_torque must fail when no plugin connects");
    let msg = format!("{err:#}");
    assert!(
        msg.contains("vr_operator"),
        "error should tell the operator what to start, got: {msg}"
    );
}

#[tokio::test]
async fn targets_are_dropped_while_no_plugin_is_connected() {
    let endpoint = temp_endpoint("nodrop");
    let mut driver = LerobotLinkDriver::new(&endpoint, HELLO_TIMEOUT).expect("start link driver");

    // Writes before any plugin connects must not error and must not block —
    // the XR command path runs at 72 Hz and cannot stall on a missing consumer.
    let pose = Pose6D {
        position: [0.3, 0.0, 0.2],
        rotation: [0.0, 0.0, 0.0, 1.0],
    };
    for _ in 0..10 {
        driver
            .set_end_effector_pose(&pose, Some(0.5))
            .await
            .expect("writes with no plugin must be dropped, not errors");
    }
    assert!(
        driver.last_joint_angles().is_none(),
        "no plugin means no seeded state"
    );
}

fn arm_config(endpoint: &Endpoint) -> ArmConfig {
    ArmConfig {
        driver: "lerobot_link".to_string(),
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
                [0.0, 100.0],
            ],
            max_velocity_deg_s: 1.0e9,
            max_acceleration_deg_s2: 1.0e9,
        },
        pose_mapping: PoseMappingConfig {
            mode: "ik".to_string(),
            scale: 0.5,
            mirror: true,
        },
        driver_write_timeout_ms: 1000,
        mujoco: None,
        lerobot: Some(LerobotConfig {
            endpoint: endpoint.clone(),
            hello_timeout_ms: 10_000,
        }),
    }
}

/// Device-level integration for the single-arm path.
///
/// `RobotArmDevice` is a separate implementation from `DualSo101Device`'s
/// `ArmRuntime`, so the dual tests do not cover it. This pins the two things the
/// link driver changes here: connect must block for the plugin's Hello and seed
/// the end-effector snapshot that IK mode requires, and telemetry must reflect
/// the plugin's asynchronous report rather than the write-time snapshot.
#[tokio::test]
async fn robot_arm_device_drives_the_plugin_end_to_end() {
    if !python_available() {
        eprintln!("skipping lerobot_link_driver_stub: python3 unavailable");
        return;
    }

    let endpoint = temp_endpoint("device");
    let mut device =
        RobotArmDevice::new(RobotArmDevice::default_descriptor(), &arm_config(&endpoint))
            .expect("create arm device");
    let _stub = spawn_stub(&endpoint, &[]);

    // Would bail with "driver-side IK mode requires an initial end-effector
    // pose snapshot" if Hello had not seeded it.
    device.connect().await.expect("connect arm device");

    let mut cmd = DeviceCommand::default();
    cmd.buttons.insert("enable".to_string(), true);
    // The gripper axis defaults to 1.0 and a first command *at* the default is
    // seeded without a driver write, so use a non-default value.
    cmd.axes.insert("gripper".to_string(), 0.75);
    cmd.poses.insert(
        "end_effector".to_string(),
        Pose6D {
            position: [0.0, 0.0, 0.0],
            rotation: [0.0, 0.0, 0.0, 1.0],
        },
    );
    cmd.poses.insert(
        "operator_frame".to_string(),
        Pose6D {
            position: [0.0, 0.0, 0.0],
            rotation: [0.0, 0.0, 0.0, 1.0],
        },
    );

    device.send_command(&cmd).await.expect("send command");

    let deadline = Instant::now() + SETTLE_TIMEOUT;
    loop {
        let t = device.get_telemetry().await.expect("telemetry");
        let Some(TelemetryValue::Array(angles)) = t.values.get("joint_angles") else {
            panic!("joint_angles missing from telemetry: {:?}", t.values);
        };
        // 0.75 -> 75.0 on the RANGE_0_100 gripper. Landing at all proves
        // get_telemetry samples the driver: the snapshot cached during
        // send_command still held the pre-write value.
        if angles[5] == 75.0 {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "gripper never landed; last joint_angles: {angles:?}"
        );
        tokio::time::sleep(Duration::from_millis(10)).await;
    }

    device.disconnect().await.expect("disconnect");
}

#[tokio::test]
async fn plugin_error_surfaces_on_the_next_write() {
    if !python_available() {
        eprintln!("skipping lerobot_link_driver_stub: python3 unavailable");
        return;
    }

    let endpoint = temp_endpoint("failee");
    let mut driver = LerobotLinkDriver::new(&endpoint, HELLO_TIMEOUT).expect("start link driver");
    let _stub = spawn_stub(&endpoint, &["--fail-ee"]);

    driver.enable_torque().await.expect("enable_torque");

    let pose = Pose6D {
        position: [0.31, 0.0, 0.2],
        rotation: [0.0, 0.0, 0.0, 1.0],
    };
    // The first write publishes; the plugin's Error comes back asynchronously
    // and must fail a subsequent write rather than being swallowed.
    driver
        .set_end_effector_pose(&pose, None)
        .await
        .expect("first write is fire-and-forget");

    let deadline = Instant::now() + SETTLE_TIMEOUT;
    let mut surfaced = None;
    while Instant::now() < deadline {
        if let Err(e) = driver.set_end_effector_pose(&pose, None).await {
            surfaced = Some(e);
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    let err = surfaced.expect("plugin error should surface on a later write");
    assert!(
        format!("{err:#}").contains("forced ee failure"),
        "got: {err:#}"
    );
}
