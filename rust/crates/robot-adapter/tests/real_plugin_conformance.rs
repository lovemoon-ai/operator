//! Cross-language conformance: the REAL LeRobot `vr_operator` plugin against
//! the REAL `lerobot_link` driver.
//!
//! `lerobot_link_driver_stub` proves the Rust side against a stub that *models*
//! the contract; the plugin's own pytest suite proves the Python side against a
//! fake adapter. Neither catches the two halves drifting apart. This does.
//!
//! Ignored by default: needs a venv with lerobot>=0.6.0, placo, and the plugin
//! installed, plus an SO-101 URDF. No hardware or headset required.
//!
//!   VR_OPERATOR_PYTHON=/tmp/vrop-verify/bin/python \
//!   VR_OPERATOR_URDF=/tmp/so101_kin_only.urdf \
//!   cargo test -p robot-adapter --test real_plugin_conformance -- --ignored --nocapture

use std::process::{Child, Command as StdCommand, Stdio};
use std::time::{Duration, Instant};

use robot_adapter::control::drivers::lerobot_link::{LerobotLinkDriver, NUM_ACTUATORS};
use robot_adapter::control::drivers::ArmDriver;
use teleop_protocol::Endpoint;

struct Guard(Child);
impl Drop for Guard {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

#[tokio::test]
#[ignore = "requires a venv with lerobot>=0.6.0 + placo + the vr_operator plugin"]
async fn real_plugin_speaks_the_link_protocol() {
    let python = std::env::var("VR_OPERATOR_PYTHON").expect("set VR_OPERATOR_PYTHON");
    let urdf = std::env::var("VR_OPERATOR_URDF").expect("set VR_OPERATOR_URDF");
    let client = std::env::var("VR_OPERATOR_CLIENT").unwrap_or_else(|_| {
        concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/tests/fixtures/real_plugin_client.py"
        )
        .to_string()
    });

    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let endpoint: Endpoint = format!("uds:/tmp/vrop-conformance-{nanos}.sock")
        .parse()
        .unwrap();

    let mut driver =
        LerobotLinkDriver::new(&endpoint, Duration::from_secs(30)).expect("start driver");

    let _plugin = Guard(
        StdCommand::new(&python)
            .arg(&client)
            .arg("--endpoint")
            .arg(endpoint.to_string())
            .arg("--urdf")
            .arg(&urdf)
            .stdout(Stdio::inherit())
            .stderr(Stdio::inherit())
            .spawn()
            .expect("spawn real plugin"),
    );

    // Blocks until the plugin's Hello lands. If the plugin's FK snapshot or
    // framing disagreed with Rust, this is where it would hang or error.
    driver
        .enable_torque()
        .await
        .expect("enable_torque via real plugin");

    let seeded = driver
        .last_joint_angles()
        .expect("real plugin Hello must seed joint angles");
    assert_eq!(seeded.angles.len(), NUM_ACTUATORS);
    let ee = driver
        .last_end_effector_pose()
        .expect("real plugin Hello must seed an end-effector pose (FK of home)");
    println!("Hello: joints={:?} ee={:?}", seeded.angles, ee.position);

    // Nudge the target 3cm along robot +X from the plugin's own reported EE and
    // assert real placo IK moves the joints toward it.
    let mut target = ee.clone();
    target.position[0] += 0.03;
    let deadline = Instant::now() + Duration::from_secs(15);
    loop {
        driver
            .set_end_effector_pose(&target, Some(0.25))
            .await
            .expect("set_end_effector_pose");
        let j = driver.last_joint_angles().expect("joints");
        // 0.25 normalized -> 25.0 on the RANGE_0_100 gripper. Agreeing on this
        // is exactly the units contract that is easy to get wrong.
        if (j.angles[5] - 25.0).abs() < 1e-6 && j.angles[..5] != seeded.angles[..5] {
            println!("IK responded: joints={:?}", j.angles);
            break;
        }
        assert!(
            Instant::now() < deadline,
            "real plugin never tracked the target; last joints: {:?}",
            j.angles
        );
        tokio::time::sleep(Duration::from_millis(50)).await;
    }

    driver.emergency_stop().await.expect("emergency_stop");
}
