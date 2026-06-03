# Test And Engineering Health Gaps

Status: closed
Category: test and engineering health

## Unfinished Items

None.

## Current Evidence

- Full `cargo test` passes from `robot/`.
- The old video examples referenced by earlier versions of this issue are gone; video relay config now uses feed-level optional `udp_port`.
- Disconnect timeout and descriptor safety behavior are covered by Rust tests in the `xr-bridge` forward/safety paths.
- `tests/01_rtsp_test.sh` is the hardware-backed XR video smoke test. It launches local RTSP/bridge components, starts the headset app when requested, and checks logcat for `[LiveVideo] AHB stats: frames=N ...`.
- `tests/ci.sh` intentionally requires attached XR hardware because it runs the video smoke test by default.

## Out Of Scope

- Legacy v1 `"Tracking"` compatibility.
- RC car serial command output until real serial wiring is implemented and brought back into scope.
- Godot-side headless tests for XR protocol/command generation. This project is an OpenXR Android app, so XR-facing verification stays on the Android/headset smoke path unless a separate pure-GDScript test effort is explicitly opened.

## Acceptance Criteria

- Full `cargo test` passes from `robot/`.
- `tests/ci.sh` can be run from either the repository root or the `tests/` directory.
- Manual XR smoke tests are documented with expected logs and pass/fail criteria.
