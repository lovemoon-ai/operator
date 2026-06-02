# RFC-001 Native visionOS XR Client Reusing the Robot Stack

## Status

Proposed

## Owner

TBD

## Date

2026-06-02

## Summary

Build a native Apple Vision Pro client for teleoperation, implemented in
visionOS rather than Godot, while reusing the existing robot-side
`robot-adapter`, `xr-bridge`, `teleop-protocol`, safety, telemetry, and
video relay stack. The AVP client should behave as another XR headset
implementation of the existing wire protocol: connect to the bridge,
perform `Hello -> DeviceDescriptor`, stream `DeviceCommand` JSON frames,
receive telemetry, and display the existing H.264/HEVC timed video
stream.

The short-term MVP should avoid robot-side changes. Optional follow-up
work can improve AVP discovery, UDP video, dedicated telemetry, and
visionOS-specific input profiles once the core command/video loop is
proven on hardware.

## Context

The current `xr/` client is a Godot 4.5 Android/OpenXR application. It
uses Android export presets, Godot XR Tools, OpenXR vendor plugins, a
Kotlin `MediaCodec` decoder, and an Android `AHardwareBuffer` GDExtension
for the zero-copy video path. That stack is not a practical short-term
base for Apple Vision Pro.

The robot-facing architecture, however, is already mostly headset
agnostic:

- `robot/crates/xr-bridge/src/main.rs` starts the XR-facing network
  stack: discovery, command TCP, pose UDP, telemetry TCP, video relay,
  and forwarding to the adapter.
- `robot/crates/xr-bridge/src/pose_server.rs` defines the headset control
  flow: `Hello`, `DeviceDescriptor`, `DeviceCommand`, `Telemetry`, and
  `ClockPing`/`ClockPong`.
- `robot/crates/xr-bridge/src/protocol.rs` defines the command and timed
  video frame codecs.
- `robot/crates/teleop-protocol/src/wire.rs` defines the platform-neutral
  `DeviceCommand` shape: `axes`, `buttons`, `poses`, and
  `timestamp_ns`.
- `robot/crates/xr-bridge/src/video/fanout.rs` already handles TCP/UDP
  video fan-out and primes late joiners with cached parameter sets before
  waiting for the next IDR.
- `robot/crates/xr-bridge/src/forward.rs` validates and clamps commands
  through descriptor-derived safety rules before forwarding to the
  adapter, and sends `Stop` when command flow goes quiet.

This means an AVP client can reuse the robot side by implementing the
same XR protocol in Swift/visionOS.

## Goals

- Deliver a native visionOS teleoperation MVP without changing the robot
  control stack.
- Reuse the existing `xr-bridge` command channel on TCP 63901.
- Reuse the existing TCP timed video channel advertised in
  `DeviceDescriptor.video_feeds`.
- Decode H.264/HEVC on AVP using native Apple media APIs and render the
  result in a visionOS scene.
- Map AVP head/hand/pinch input into the existing generic
  `DeviceCommand` JSON shape.
- Preserve existing robot-side safety behavior, including descriptor
  limits and watchdog stop-on-silence.
- Keep the existing Godot/Pico/Quest client working unchanged.

## Non-Goals

- Reusing Godot plugins or GDScript code inside the AVP client.
- Porting `KotlinVideoDecoderPlugin`, `QuestCapturePlugin`, or
  `ahb_decoder` to visionOS.
- Implementing AVP capture / SpatialMP4 recording in the MVP.
- Matching every Quest/Pico controller input source in the first AVP
  release.
- Implementing UDP video, pose UDP, or Bonjour discovery before the TCP
  command/video path is validated on hardware.
- Changing robot-side safety semantics for AVP-specific control.

## Current Robot Surfaces to Reuse

### Command channel

Port: TCP 63901.

Frame layout:

```text
[4B cmd_len LE][cmd UTF-8][4B data_len LE][data]
```

Initial flow:

1. AVP connects to TCP 63901.
2. AVP sends command frame `Hello` with a small JSON payload.
3. `xr-bridge` responds with `DeviceDescriptor`.
4. AVP sends `DeviceCommand` frames as JSON.
5. `xr-bridge` sends `Telemetry` frames at 10 Hz on the same channel.

The MVP should implement this channel first. It is sufficient for basic
teleoperation and works on existing bridge deployments.

### DeviceCommand

`DeviceCommand` is already platform-neutral:

```json
{
  "axes": {},
  "buttons": {},
  "poses": {},
  "timestamp_ns": 0
}
```

The AVP client should not try to emulate OpenXR controller names
internally. It should create the target command fields declared by the
descriptor's `control_schema` and command mapping policy. For the MVP,
the client may ignore `input_mapping` and use a small device-specific
mapping table when the descriptor does not declare a visionOS profile.

### Video channel

The robot advertises video feeds through `DeviceDescriptor.video_feeds`.
Each feed carries:

- `port`
- `width`
- `height`
- `fps`
- `stereo`
- `transport`
- `udp_port`
- `codec`

For the MVP, the AVP client should prefer TCP even if `transport` is
`auto` or `udp`, because TCP is easier to validate and avoids early UDP
loss/reassembly issues. The client receives `TimedVideoFrame` packets:

```text
[80B timed header BE][NAL length BE][Annex-B NAL payload]
```

The AVP decoder adapter is responsible for turning Annex-B H.264/HEVC
access units into the format required by Apple's decoder stack.

### Telemetry and clock sync

The MVP can consume `Telemetry` on TCP 63901. The dedicated telemetry
port 63903 can be added later.

The MVP should implement `ClockPing`/`ClockPong` once basic video works,
because it improves latency accounting but is not required for motion
control.

### Safety

Robot-side safety remains authoritative:

- `forward.rs` validates and clamps incoming `DeviceCommand`s.
- The command watch channel is latest-only.
- The watchdog sends a single `Stop` if the headset goes quiet for the
  descriptor's configured timeout.

The AVP client should still implement local safety affordances:

- A hold-to-control or pinch/deadman gate.
- Neutral command on tracking loss when possible.
- Stop sending commands when the app is suspended or input is invalid.

## Proposed Design

### Client architecture

The AVP app should be split into platform-neutral protocol code and
visionOS-specific presentation/input code:

```text
visionos-client/
  TeleopCore/
    CommandCodec
    DeviceDescriptor model
    DeviceCommand model
    TimedVideoFrame parser
    TCP command session
    TCP video receiver
    Latency/clock sync helpers

  VisionOSApp/
    SwiftUI app shell
    RealityKit immersive scene
    VideoToolbox decoder adapter
    Metal/RealityKit video surface
    Head/hand/pinch input sampler
    Device-specific command mapper
```

`TeleopCore` should not depend on SwiftUI, RealityKit, ARKit, or
VideoToolbox. This keeps the wire protocol testable on macOS without AVP
hardware.

### MVP connection flow

1. User enters robot/bridge host and command port manually.
2. App opens TCP command session to `host:63901`.
3. App sends `Hello`:

```json
{
  "version": "2.0",
  "client": "visionos",
  "capabilities": ["head_pose", "hand_tracking", "pinch", "tcp_video"]
}
```

4. App parses `DeviceDescriptor`.
5. App selects the first usable video feed.
6. App opens TCP video stream to `feed.port`.
7. App configures the decoder from `feed.codec`, `feed.width`, and
   `feed.height`.
8. App starts sending `DeviceCommand` at a fixed rate while the deadman
   input is active.
9. App displays telemetry and connection state.

### Video decoding

The robot video relay sends Annex-B H.264/HEVC NALs and already primes
new clients with the codec parameter sets needed for decoder startup.
The AVP client should:

- Accumulate NALs into access units using `frame_id`, `nal_index`, and
  `nal_count`.
- Preserve timing fields for latency telemetry.
- Convert Annex-B parameter sets / slices into the sample format expected
  by the native decoder.
- Decode with a native Apple video path.
- Present decoded frames as a low-latency texture in RealityKit or Metal.

The MVP does not require zero-copy from the first build. Correctness,
low steady-state latency, and stable recovery after reconnect are more
important than the final texture upload path.

### Input mapping

The AVP client should expose a small canonical input state:

```text
head_pose
primary_hand_pose
secondary_hand_pose
primary_pinch
primary_pinch_strength
gaze_ray
deadman_active
```

For MVP robot-arm control, a reasonable first mapping is:

- `poses.end_effector` from primary hand pose while deadman is active.
- `axes.gripper` from pinch strength or pinch open/closed state.
- Optional `poses.head` from head pose for view-dependent devices.
- Optional stop/neutral when `deadman_active == false`.

This should be implemented as a client-side mapper first. A later RFC or
follow-up issue can extend `DeviceDescriptor.input_mapping` to carry
multiple platform profiles, for example:

```json
{
  "input_profiles": {
    "openxr_controller": [],
    "visionos_hand": []
  }
}
```

The existing robot stack does not need this for the MVP because it only
requires final `DeviceCommand` JSON.

### Discovery

MVP uses manual IP entry.

Follow-up discovery options:

- Browse `_xrobo._tcp.local.` via Bonjour / Network.framework.
- Use the existing UDP 63900 beacon if visionOS local-network policy and
  deployment network allow it.
- Support configured unicast discovery targets from `xr-bridge` config
  for networks where broadcast is blocked.

Manual IP keeps the first implementation independent of local-network
permission edge cases.

## Options Considered

### Option A: Port the Godot XR project to visionOS

Pros:

- Potentially reuses the current Godot scene and GDScript UI.
- Keeps one client codebase long term if Godot immersive visionOS support
  becomes mature.

Cons:

- Current Godot visionOS support is not the same as the existing Android
  OpenXR app model.
- Current video path is Android `MediaCodec` / `AHardwareBuffer`.
- Current capture path is Android/Quest/Meta-specific.
- Large risk before the first robot round trip works.

### Option B: Native visionOS client over the existing robot protocol

Pros:

- Reuses the robot stack directly.
- Avoids Android/Godot plugin portability blockers.
- Uses Apple's intended visionOS app, rendering, media, and input APIs.
- Lets AVP input semantics be designed directly instead of emulating
  OpenXR controller hardware.

Cons:

- Creates a second client implementation.
- Requires Swift implementation of the wire codec and video parser.
- Requires new testing discipline to keep protocol behavior aligned with
  Rust and Godot.

### Option C: Web client / WebRTC bridge

Pros:

- Potentially fast to prototype across devices.
- Avoids App Store / native build loops for some demos.

Cons:

- Does not speak the current raw TCP/UDP protocol directly.
- Requires a robot-side WebSocket/WebRTC/WebTransport bridge.
- Adds media relay complexity before validating AVP control ergonomics.

## Decision

Proceed with Option B: a native visionOS client that implements the
existing XR wire protocol and reuses the robot-side stack unchanged for
the MVP.

## Rollout Plan

### Phase 0: Protocol fixtures

- Add golden command-frame and timed-video-frame fixtures derived from
  the Rust codecs.
- Add Swift unit tests that decode/encode the same bytes.
- Keep fixtures small and deterministic so they can run on macOS CI.

### Phase 1: TCP command MVP

- Implement command TCP connect.
- Send `Hello` and parse `DeviceDescriptor`.
- Send hand-authored `DeviceCommand` JSON to a dummy adapter.
- Receive and display legacy `Telemetry` on TCP 63901.
- Verify robot-side safety and watchdog behavior are unchanged.

### Phase 2: TCP video MVP

- Connect to the selected feed's TCP port.
- Parse `TimedVideoFrame`.
- Prime and configure the H.264/HEVC decoder.
- Display decoded video in a visionOS scene.
- Log basic latency: robot `send_ns`, AVP receive time, decode time, and
  present time.

### Phase 3: AVP input control

- Sample head pose, hand pose, and pinch/deadman state.
- Map AVP input into descriptor-compatible `DeviceCommand`.
- Add local input-loss handling.
- Test against dummy and one real/simulated robot-arm descriptor.

### Phase 4: Transport and UX hardening

- Bonjour discovery.
- Dedicated telemetry port 63903.
- UDP video (`NLFR` fragment reassembly).
- Optional pose UDP or a new generic UDP `DeviceCommand` data plane.
- Multi-feed selection and stereo video layout.

## Robot-Side Changes

No robot-side changes are required for the MVP.

Optional future changes:

- Add `visionos_hand` input profile hints to `DeviceDescriptor`.
- Add a descriptor field that tells clients whether dedicated telemetry
  and pose UDP are preferred.
- Add a generic UDP command data plane if AVP hand pose benefits from
  drop-old semantics beyond the current `end_effector + gripper` pose
  UDP packet.
- Add protocol conformance fixtures generated from `teleop-protocol`.

Any future robot changes must remain backward compatible with the Godot
client.

## Risks

- Video decoder startup may require stricter access-unit assembly than
  the current Android path.
- AVP hand/pinch input may not map cleanly onto descriptors designed for
  controller axes and buttons.
- Manual IP entry is acceptable for MVP but poor for repeated operator
  use.
- TCP video may be too latent on Wi-Fi for final operation, requiring
  UDP video earlier than planned.
- App lifecycle events on visionOS can interrupt command flow; the robot
  watchdog should safe the device, but the client still needs explicit
  local stop behavior.
- Maintaining multiple clients increases protocol drift risk unless
  fixtures and end-to-end tests become part of the workflow.

## Test Plan

- Unit-test Swift command codec against Rust-generated fixtures.
- Unit-test Swift timed-video parser against Rust-generated fixtures.
- Use `robot/crates/e2e-tests` style dummy adapter tests to validate
  `Hello -> DeviceDescriptor -> DeviceCommand`.
- Run the bridge in `--video-only` mode with a known H.264 test source
  and validate decode/display on AVP.
- Run a robot-arm or MuJoCo SO-101 session and verify:
  - deadman inactive means no motion,
  - command timeout triggers robot-side stop,
  - invalid/out-of-range axes are clamped/rejected by robot safety,
  - video reconnect recovers on the next parameter set / IDR.

## Acceptance Criteria

- A native visionOS app can connect to an existing `xr-bridge` without
  robot-side code changes.
- The app receives and parses `DeviceDescriptor`.
- The app sends valid `DeviceCommand` frames that reach the adapter and
  pass existing safety validation.
- The app receives and displays at least one TCP video feed.
- The app handles disconnect, tracking loss, and app suspend without
  leaving the robot in motion.
- Existing Godot Android XR clients continue to work unchanged.

## Open Questions

- Should the AVP MVP live in this monorepo or as a separate app repo
  that imports generated protocol fixtures from here?
- Should `teleop-protocol` generate Swift models/fixtures, or should the
  Swift client maintain hand-written models with conformance tests?
- Should AVP first map commands per device type, or should we extend
  `DeviceDescriptor` with platform-specific input profiles before the
  first hardware demo?
- How quickly should UDP video move from Phase 4 into Phase 2 if TCP
  video latency is visibly too high?
- Should the dedicated telemetry port become part of the baseline AVP
  implementation, or remain a compatibility improvement after MVP?
