//! Hermetic framing test for the real SO-101 hardware driver.

use std::path::PathBuf;
use std::process::Command as StdCommand;

use robot_adapter::control::drivers::so101_real::{So101RealDriver, NUM_ACTUATORS};
use robot_adapter::control::drivers::ArmDriver;
use robot_adapter::control::JointAngles;
use teleop_protocol::Pose6D;

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
        .join("stub_so101_bridge.py")
}

#[tokio::test]
async fn real_driver_round_trips_against_stub_bridge() {
    if !python_available() {
        eprintln!("skipping so101_real_driver_stub: python3 unavailable");
        return;
    }
    let script = stub_script();
    assert!(
        script.exists(),
        "stub script missing at {}",
        script.display()
    );

    let mut driver = So101RealDriver::new(script.to_str().unwrap(), "python3", "/dev/null", &[])
        .expect("spawn stub");

    driver.enable_torque().await.expect("enable_torque");
    let q = driver.last_positions_deg();
    assert_eq!(q.len(), NUM_ACTUATORS);
    assert_eq!(q[1], -90.0);
    assert_eq!(q[NUM_ACTUATORS - 1], 85.0);
    assert!(
        driver.last_end_effector_pose().is_some(),
        "ready snapshot should seed an end-effector pose"
    );

    driver
        .set_joints(&JointAngles {
            angles: vec![10.0, -20.0, 30.0, -40.0, 50.0],
        })
        .await
        .expect("set_joints");
    let q = driver.last_positions_deg();
    assert_eq!(&q[..5], &[10.0, -20.0, 30.0, -40.0, 50.0]);
    assert_eq!(q[5], 85.0, "arm-only command should hold gripper");

    driver.set_gripper(0.0).await.expect("close gripper");
    let q = driver.last_positions_deg();
    assert_eq!(q[5], 8.0);

    driver
        .set_joints(&JointAngles { angles: vec![11.0] })
        .await
        .expect("partial set_joints preserves held arm joints");
    let q = driver.last_positions_deg();
    assert_eq!(&q[..5], &[11.0, -20.0, 30.0, -40.0, 50.0]);
    assert_eq!(q[5], 8.0);

    let pose = Pose6D {
        position: [0.31, -0.02, 0.18],
        rotation: [0.0, 0.0, 0.0, 1.0],
    };
    driver
        .set_end_effector_pose(&pose, Some(0.5))
        .await
        .expect("set_end_effector_pose");
    let q = driver.last_positions_deg();
    assert_eq!(q[0], 0.31);
    assert_eq!(q[5], 46.5);
    let ee = driver
        .last_end_effector_pose()
        .expect("end-effector response should update latest pose");
    assert_eq!(ee.position, pose.position);
    assert_eq!(ee.rotation, pose.rotation);

    driver
        .reset_to_initial_pose()
        .await
        .expect("reset_to_initial_pose");
    let q = driver.last_positions_deg();
    assert_eq!(q, [0.0, -90.0, 90.0, 0.0, 0.0, 85.0]);

    driver.emergency_stop().await.expect("emergency_stop");
}
