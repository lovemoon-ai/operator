# Advanced Platform Feature Gaps

Status: open
Category: advanced platform features

## Unfinished Items

- Multi-device simultaneous control.
- Command recording and replay.
- Latency compensation and predictive display.
- Web dashboard for telemetry monitoring.
- Device config sharing or marketplace.
- Broader device model support for robot dog, drone, humanoid, or full-body control scenarios.

## Current Evidence

- Runtime currently loads one configured device descriptor and creates one device instance.
- Command, telemetry, and video flows are organized around one active robot/device.
- No recording, replay, web dashboard, marketplace, or multi-device coordination modules are present.

## Acceptance Criteria

- Define scope and priority for each advanced feature before implementation.
- Multi-device mode has an explicit session model, UI model, and command routing model.
- Recording/replay persists enough command, telemetry, and timing data to reproduce a session.
- Dashboard and sharing features have an agreed API surface and auth/security model.
