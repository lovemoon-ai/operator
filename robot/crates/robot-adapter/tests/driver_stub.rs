//! Hermetic driver-framing test.
//!
//! Spawns a tiny Python stub (`tests/fixtures/stub_bridge.py`) that speaks the
//! same JSON-line protocol as the real MuJoCo bridge but with no MuJoCo
//! dependency. Exercises the `MujocoSo101Driver` framing end to end:
//! `enable_torque()` (ready handshake + reset) and `set_joints()` /
//! `set_gripper()` round-trips. If `python3` is unavailable, the test skips
//! gracefully rather than failing.

use std::path::PathBuf;
use std::process::Command as StdCommand;

use robot_adapter::control::drivers::mujoco_so101::{
    MujocoSo101Driver, GRIPPER_RAD_MAX, GRIPPER_RAD_MIN, NUM_ACTUATORS,
};
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
        .join("stub_bridge.py")
}

#[tokio::test]
async fn driver_round_trips_against_stub_bridge() {
    if !python_available() {
        eprintln!("skipping driver_stub: python3 unavailable");
        return;
    }
    let script = stub_script();
    assert!(
        script.exists(),
        "stub script missing at {}",
        script.display()
    );

    let mut driver =
        MujocoSo101Driver::new(script.to_str().unwrap(), "python3", 3, &[]).expect("spawn stub");

    // enable_torque drives the ready handshake + a reset; should succeed.
    driver.enable_torque().await.expect("enable_torque");

    // The stub seeds q from its HOME on reset.
    let after_reset = driver.last_q_rad();
    assert_eq!(after_reset.len(), NUM_ACTUATORS);
    assert!(
        driver.last_end_effector_pose().is_some(),
        "reset should seed end-effector pose snapshot"
    );

    // Command a non-trivial joint vector (degrees). The stub echoes the ctrl
    // it received (in radians) back as the new snapshot, so last_q_rad should
    // reflect the commanded angles converted to radians.
    let cmd = JointAngles {
        angles: vec![45.0, 0.0, 0.0, 0.0, 0.0, 0.0],
    };
    driver.set_joints(&cmd).await.expect("set_joints");
    let q = driver.last_q_rad();
    assert!(
        (q[0] - 45.0_f64.to_radians()).abs() < 1e-6,
        "joint0 snapshot {} should equal 45deg in rad {}",
        q[0],
        45.0_f64.to_radians()
    );

    // Gripper: 1.0 (open) maps to GRIPPER_RAD_MAX on the last actuator.
    driver.set_gripper(1.0).await.expect("set_gripper");
    let q = driver.last_q_rad();
    assert!(
        (q[NUM_ACTUATORS - 1] - GRIPPER_RAD_MAX).abs() < 1e-6,
        "gripper snapshot {} should be GRIPPER_RAD_MAX {}",
        q[NUM_ACTUATORS - 1],
        GRIPPER_RAD_MAX
    );

    // Arm-only joint writes must preserve the gripper actuator. This prevents
    // controller pose/wrist commands from moving the jaw by positional index.
    let arm_only = JointAngles {
        angles: vec![10.0, 20.0, -30.0, 40.0, -50.0],
    };
    driver
        .set_joints(&arm_only)
        .await
        .expect("set_joints arm-only");
    let q = driver.last_q_rad();
    assert!(
        (q[NUM_ACTUATORS - 1] - GRIPPER_RAD_MAX).abs() < 1e-6,
        "arm-only set_joints changed gripper snapshot {} from {}",
        q[NUM_ACTUATORS - 1],
        GRIPPER_RAD_MAX
    );

    // Gripper: 0.0 (closed) maps to GRIPPER_RAD_MIN.
    driver.set_gripper(0.0).await.expect("set_gripper closed");
    let q = driver.last_q_rad();
    assert!(
        (q[NUM_ACTUATORS - 1] - GRIPPER_RAD_MIN).abs() < 1e-6,
        "closed gripper snapshot {} should be GRIPPER_RAD_MIN {}",
        q[NUM_ACTUATORS - 1],
        GRIPPER_RAD_MIN
    );

    let target = Pose6D {
        position: [0.33, -0.02, 0.25],
        rotation: [0.0, 0.0, 0.0, 1.0],
    };
    driver
        .set_end_effector_pose(&target, Some(0.5))
        .await
        .expect("set_end_effector_pose");
    let ee = driver
        .last_end_effector_pose()
        .expect("end-effector pose after command");
    assert_eq!(ee.position, target.position);
    assert_eq!(ee.rotation, target.rotation);
}
