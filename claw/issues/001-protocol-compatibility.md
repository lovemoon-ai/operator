# Protocol Compatibility Gaps

Status: open
Category: protocol compatibility

## Unfinished Items

- Handle legacy `"Tracking"` command in the Rust command server.
- Wire the existing `headset_pose_to_device_command()` conversion into the live receive path.
- Activate Godot legacy fallback when `DeviceDescriptor` is not received.
- Reconnect Godot fallback mode to the existing `PoseSender` node.
- Decide whether command-channel `"VideoFrame"` should remain supported or be explicitly removed from the compatibility promise.

## Current Evidence

- `robot/src/network/session.rs` defines `headset_pose_to_device_command()`, but the function is not called.
- `robot/src/network/pose_server.rs` currently handles `"DeviceCommand"`, `"Heartbeat"`, and `"ClockPing"`, but not `"Tracking"`.
- `xr/scripts/network/session.gd` emits `legacy_mode_activated`, but `xr/scenes/main.gd` does not connect that signal.
- `xr/scenes/main.tscn` still contains a `PoseSender` node, but `xr/scenes/main.gd` does not start it.
- `xr/scenes/main.gd` still has `"VideoFrame": pass` on the command channel.

## Acceptance Criteria

- A v1 client sending `"Tracking"` JSON can control the robot arm through the v2 device loop.
- A v2-capable Godot client still uses `DeviceDescriptor` and `DeviceCommand` normally.
- If no descriptor arrives within the handshake timeout, Godot starts legacy pose sending and surfaces that state in the HUD.
- Add regression tests for `"Tracking"` conversion and handshake timeout fallback.
