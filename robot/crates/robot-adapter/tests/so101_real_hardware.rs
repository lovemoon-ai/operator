//! Optional real-hardware smoke test for SO-101.
//!
//! This is ignored by default because it touches the physical Feetech bus.

use std::path::PathBuf;

use robot_adapter::control::drivers::so101_real::So101RealDriver;
use robot_adapter::control::drivers::ArmDriver;
use robot_adapter::control::JointAngles;

fn repo_robot_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("..")
        .canonicalize()
        .expect("canonicalize robot dir")
}

#[tokio::test]
#[ignore = "requires a connected SO-101 arm"]
async fn so101_real_connect_and_stop() {
    let python = std::env::var("SO101_REAL_PYTHON").unwrap_or_else(|_| "python3".to_string());
    let port = std::env::var("SO101_REAL_PORT").unwrap_or_else(|_| "/dev/ttyACM0".to_string());
    let script = repo_robot_dir()
        .join("scripts")
        .join("so101_real_bridge.py");
    let extra_args = std::env::var("SO101_REAL_EXTRA_ARGS")
        .map(|s| s.split_whitespace().map(str::to_string).collect::<Vec<_>>())
        .unwrap_or_default();

    let mut driver = So101RealDriver::new(
        script.to_str().expect("script path utf8"),
        &python,
        &port,
        &extra_args,
    )
    .expect("spawn SO-101 bridge");
    driver.enable_torque().await.expect("enable torque");
    let joints = driver
        .last_joint_angles()
        .expect("hardware bridge returns joint snapshot");
    assert_eq!(joints.angles.len(), 6);
    driver.emergency_stop().await.expect("emergency stop");
}

#[tokio::test]
#[ignore = "requires a connected SO-101 arm and moves shoulder_pan by about 1 degree"]
async fn so101_real_small_joint_write() {
    let python = std::env::var("SO101_REAL_PYTHON").unwrap_or_else(|_| "python3".to_string());
    let port = std::env::var("SO101_REAL_PORT").unwrap_or_else(|_| "/dev/ttyACM0".to_string());
    let script = repo_robot_dir()
        .join("scripts")
        .join("so101_real_bridge.py");
    let extra_args = std::env::var("SO101_REAL_EXTRA_ARGS")
        .map(|s| s.split_whitespace().map(str::to_string).collect::<Vec<_>>())
        .unwrap_or_default();

    let mut driver = So101RealDriver::new(
        script.to_str().expect("script path utf8"),
        &python,
        &port,
        &extra_args,
    )
    .expect("spawn SO-101 bridge");
    driver.enable_torque().await.expect("enable torque");
    let start = driver
        .last_joint_angles()
        .expect("hardware bridge returns joint snapshot")
        .angles;
    assert_eq!(start.len(), 6);

    let mut target = start[..5].to_vec();
    target[0] = (target[0] + 3.0).clamp(-105.0, 105.0);
    for _ in 0..8 {
        driver
            .set_joints(&JointAngles {
                angles: target.clone(),
            })
            .await
            .expect("small joint write");
        tokio::time::sleep(std::time::Duration::from_millis(120)).await;
    }
    let after = driver
        .last_joint_angles()
        .expect("hardware bridge returns post-write snapshot")
        .angles;
    assert_eq!(after.len(), 6);
    assert!(
        (after[0] - start[0]).abs() > 0.1,
        "shoulder_pan did not move enough: start={} after={}",
        start[0],
        after[0]
    );
    driver.emergency_stop().await.expect("emergency stop");
}
