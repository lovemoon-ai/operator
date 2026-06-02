# XR Input And UI Gaps

Status: open
Category: XR input and UI

## Unfinished Items

- Complete descriptor-driven button handling for `toggle`, `group`, and `confirm`.
- Implement `ui/device_selector.gd` or an equivalent device selector UI.
- Implement a VR mapping editor for remapping inputs in-headset.
- Decide whether to keep or remove planned but absent files from the early design: `tracking_panel`, separate `hand_tracking.gd`, `video_receiver.gd`, and `video_display.gd`.
- Add XR-side tests for protocol framing, tracking data formatting, and descriptor-driven command generation.

## Current Evidence

- `xr/scripts/input/control_mode.gd` maps axes, poses, and booleans from descriptor `input_mapping`, but does not implement toggle/group/confirm semantics.
- `xr/scripts/input/command_sender.gd` sends descriptor-driven `DeviceCommand` frames.
- `xr/scripts/ui/dynamic_hud.gd` builds telemetry labels from the descriptor.
- There is no `device_selector.gd` or `mapping_editor.gd` in the current XR scripts.
- No XR test directory or test scripts were found for the planned Godot-side tests.

## Acceptance Criteria

- Descriptor button metadata is reflected in command behavior and UI affordances.
- Users can select discovered devices and understand the current device type.
- Input mappings can be inspected and edited in VR, then used by `CommandSender`.
- Godot-side automated tests cover command generation from sample descriptors.
