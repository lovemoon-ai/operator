# Upstream provenance

This example is based on Hugging Face LeRobot's
[`examples/isaac_teleop_to_so101`](https://github.com/huggingface/lerobot/tree/92f96f33b3a842ead3a115cc4f701ba2ad8aa3b5/examples/isaac_teleop_to_so101)
at commit `92f96f33b3a842ead3a115cc4f701ba2ad8aa3b5` (LeRobot `0.6.1`,
2026-07-16). `pyproject.toml` pins that same revision.

The following Apache-2.0 upstream implementations were adapted and keep their
original copyright headers:

- `clutch.py`, `rotation.py`: engage-relative position/orientation clutch;
- `xr_controller_processor.py`: controller EE pose to SO-101 IK inputs;
- `common.py`: SO-101 URDF, Placo IK pipeline, safe hold and startup slew;
- `teleoperate.py`, `record.py`, `save_reset_pose.py`: real follower and
  LeRobotDataset lifecycle.

Operator replaces only the original input/runtime layer. The upstream
`CloudXRLauncher`, LIVE `TeleopSession`, `ControllersSource`, and `XRController`
are intentionally not copied: Operator already owns OpenXR and display, and
the upstream SO-101 path used IsaacTeleop only to expose a raw controller pose.
`operator_isaacteleop.UnixDatagramReceiver` supplies that pose without a second
XR runtime.

The recorder also fixes one important behavioral mismatch in the referenced
example: it saves the action returned by `SOFollower.send_action()`, so a target
clipped by `max_relative_target` is recorded as the action actually executed.
