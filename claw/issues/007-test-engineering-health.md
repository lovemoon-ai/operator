# Test And Engineering Health Gaps

Status: open
Category: test and engineering health

## Unfinished Items

- Fix full `cargo test` by updating video examples for the new `VideoConfig.udp_port` field.
- Add tests for legacy `"Tracking"` compatibility.
- Add tests for disconnect timeout and descriptor safety behavior.
- Add tests for RC car serial command output once real serial wiring is implemented.
- Add Godot-side tests for protocol encoding/decoding and descriptor-driven command generation.
- Add Android/XR smoke verification for video decode paths, especially GPU YUV and AHardwareBuffer.

## Current Evidence

- `cargo test --lib --tests` passes.
- Full `cargo test` fails because `robot/examples/test_video_pipeline.rs` and `robot/examples/test_video_pipeline_ffplay.rs` construct `VideoConfig` without `udp_port`.
- XR-side automated tests from the design document are not present.
- Several core code paths are currently only smoke-tested manually through headset/logcat workflows.

## Acceptance Criteria

- Full `cargo test` passes from `robot/`.
- CI or local scripts run Rust tests without requiring camera hardware by default.
- Godot protocol and command-generation tests can run headless where possible.
- Manual XR smoke tests are documented with expected logs and pass/fail criteria.
