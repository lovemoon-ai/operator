# Architecture overview

Teleoperate-Anything is a two-sided system: a Rust agent on the robot
side and a Godot 4.5 client running in-headset. They speak a custom
TCP+UDP protocol on a shared Layer-2 subnet.

## High-level dataflow

```
       Headset (xr/)                              Robot (robot/)
   ┌───────────────────────┐                ┌─────────────────────────┐
   │ OpenXR / controllers  │                │  Device trait impl      │
   │   → TrackingProvider  │                │   (arm / car / sim)     │
   │   → CommandSender     │                │     ▲                   │
   │       │               │  DeviceCommand │     │ SafeDevice + Safety│
   │       ▼               │ ─────────────► │  control_loop (watchdog)│
   │  TcpHandler ──────── pose_server (63901, TCP)                    │
   │  pose UDP ────────── pose_udp_server (63902, UDP, drop-old) ──┐  │
   │                      │                │                       │  │
   │  Session             │   Telemetry    │  telemetry_server     │  │
   │   ←──────────────────────────────────  (63903, TCP)           │  │
   │                                       │                       │  │
   │  Discovery ◄──────── discovery (63900, UDP broadcast 3s)      │  │
   │                                       │                       ▼  │
   │  Video TCP ────────  video_server (12345, TCP) ←┐  video::pipeline │
   │  Video UDP ────────  (12345, UDP fragments) ◄───┤  (capture+encode)│
   │       │                                          │                │
   │       ▼                                                           │
   │ KotlinVideoDecoderPlugin (MediaCodec)                             │
   │       │                                                           │
   │       ├─ libahb_decoder.so → AhbVideoTexture (zero-copy, gated)   │
   │       └─ YUV plane copy   → 3× L8 ImageTexture (shipping default) │
   │       ▼                                                           │
   │  RobotView (stereo_display.gdshader, passthrough scene)           │
   └───────────────────────┘                └─────────────────────────┘
```

Video transport is **descriptor-driven** (see `005-decisions.md` D-1
and `robot/src/main.rs::main` / `xr/scenes/main.gd::_select_video_transport`):
the robot's `VideoFeedInfo.transport` field advertises
`tcp`/`udp`/`auto` and the XR client picks UDP iff
`transport ∈ {"udp", "auto"}` and `udp_port > 0`. Default is TCP
because `adb reverse` (the USB smoke-test loop) is TCP-only.

## Rust agent (`robot/src/`)

- **`main.rs`** — tokio multi-thread runtime (2 workers). Loads
  `Config` + `DeviceDescriptor`, then `try_join!`'s eight independent
  subsystems. Anything failing brings the whole agent down (no
  partial-degraded mode).
- **`config.rs`** — YAML schema.
- **`device/`** — the abstraction core. `Device` trait, `SafeDevice`
  wrapper, `DeviceSafety` (`device/safety.rs`), `control_loop` (owns
  the watchdog + `disconnect_action`). Two safety layers, both
  non-bypassable: `SafeDevice` / `DeviceSafety`
  (`robot/src/device/safe_device.rs`, `robot/src/device/safety.rs`)
  is the device-agnostic gate — sanity, axis clamp + dead-zone,
  button state, pose validation — applied to *every* command via
  `send_command`; the arm-specific `control::safety::Safety`
  (`robot/src/control/safety.rs:37`) sits underneath inside
  `RobotArm` and enforces joint limits + max velocity in joint space.
- **`devices/`** — concrete `Device` impls: `dummy`, `rc_car`,
  `robot_arm`, plus a MuJoCo subprocess driver behind `robot_arm`.
- **`control/`** — pose remapping, arm controller, driver bindings
  (`feetech`, `dynamixel`, `mujoco_so101`, …).
- **`network/`** — protocol codecs (`protocol.rs` — see header
  comment for the two wire formats), `discovery` (mDNS + UDP
  broadcast), `pose_server` (TCP command in, legacy telemetry out),
  `pose_udp_server` (high-frequency pose data plane, drop-old by seq,
  session-token aware), `telemetry_server` (dedicated TCP).
  `network/video_server.rs` is a 4-line stub kept for backward
  compat — the actual video fan-out lives in `video/pipeline.rs`.
- **`video/`** — `pipeline` orchestrates `camera` (V4L2 or
  ffmpeg/AVFoundation on macOS), `encoder` (auto / `v4l2m2m` /
  software H.264), and the muxer. Also owns the TCP fan-out
  (`serve_video_clients`, `video/pipeline.rs:367`), UDP fan-out
  (`serve_udp_broadcast`, `video/pipeline.rs:112`), and app-layer
  NAL fragmentation capped at 1200 B/datagram (`build_udp_fragments`,
  `video/pipeline.rs:557` — see `005-decisions.md` D-2). On macOS a
  config of `device: /dev/video0` is auto-rewritten to AVFoundation
  index "0" inside `ffmpeg.rs`. `v4l2_m2m.rs` is Linux-only
  (`#[cfg(target_os = "linux")]`).
- **`telemetry/`** — `latency::LatencyRecorder` is shared between
  pose_server and the control loop; `run_aggregator` emits a 1 Hz
  summary. `metrics` does periodic info logging.

The device command channel is `tokio::sync::watch<Option<TimedCommand>>`
("latest-only") — slow drivers can never head-of-line-block pose
updates, at the cost of sometimes missing button edges that fall
entirely inside one inter-tick gap. Documented in `main.rs` above the
channel.

## XR client (`xr/`)

Godot 4.5 project, mobile renderer
(`renderer/rendering_method=mobile`), OpenXR with passthrough
(`environment_blend_mode=2` = alpha blend).

- **`scenes/main.gd`** — root controller. Sets up XR, instantiates
  v2-protocol helpers (`Session`, `CommandSender`, `RobotClockSync`),
  wires both `TcpHandler` (command channel) and the two video
  handlers (`VideoTcpHandler` + `UdpVideoHandler`, same
  `video_frame_received` signal API). Auto-connects to loopback /
  `XROBO_HOST` / `getprop debug.xrobo.host` after 3 s if nothing was
  discovered (smoke-test convenience).
- **`scripts/network/`** — GDScript counterparts to the Rust
  protocol. `tcp_handler.gd` is the workhorse — see its
  `_process_connected` inline drain loop; `MAX_DRAIN_PER_TICK = 32`
  and `MAX_RECV_BUFFER = 10 MiB` (overridable via
  `set_max_recv_buffer`, the video handler bumps it to 32 MiB).
  Worker-thread reads were tried and reverted — `StreamPeerTCP` is
  not reliably thread-safe on Pico. See `005-decisions.md` D-4.
- **`scripts/xr/tracking_provider.gd`** — controller pose sampling.
- **`scripts/input/command_sender.gd`** — formats and dispatches
  `DeviceCommand` JSON frames at the configured rate.
- **`scenes/robot_view/`** — the in-headset video display. Shader is
  `stereo_display.gdshader`. Receives packets via
  `set_packet_source`, hands H.264 to the Kotlin plugin.
- **`xr/android/build/src/com/godot/game/video/KotlinVideoDecoderPlugin.kt`**
  — Android `MediaCodec` driver. Probes `libahb_decoder.so` at
  classload time. If present and `debug.xrobo.force_yuv_plane` is
  not set, drives MediaCodec → ImageReader Surface → AHB →
  `nativeImportAhb`. Otherwise falls back to ByteBuffer mode +
  `extractYuvPlanesTight` + three `L8` `ImageTexture` uploads, which
  is the **currently shipping default** (AHB display is gated on
  issue 008 — Godot's default sampler lacks the
  `VkSamplerYcbcrConversion` needed to sample
  `VK_FORMAT_UNDEFINED + externalFormat`, so AHB renders black).
- **`xr/native/ahb_decoder/`** — C++ GDExtension. Imports
  `AHardwareBuffer` into a `VkImage`, creates a YCbCr
  sampler-conversion, hands the RID to Godot via
  `RenderingDevice::texture_create_from_extension`. See
  `xr/native/ahb_decoder/README.md` and `claw/issues/008-…md` for
  the open YCbCr sampler-plumbing gap.

## Wire protocol

- **Command frames** (port 63901, TCP):
  `[4B cmd_len LE][cmd UTF-8][4B data_len LE][data]` — matches
  `NetworkDataProtocolSerializer.cs` from the original XRoboToolkit.
- **Pose UDP** (port 63902, UDP): high-frequency pose updates with
  monotonic sequence numbers; old-seq packets dropped by the server.
  Session-token gated.
- **Discovery** (port 63900, UDP broadcast, 3 s cadence): JSON
  announcement.
- **Video frames** (port 12345, TCP and/or UDP):
  - Timed NAL: `[8B frame_id][4B nal_index][4B nal_count][4B pipeline_mode]
    [8B capture_start][8B capture_end][8B encode_start][8B encode_end]
    [8B read_wait][8B parse][8B send][4B len][NAL]` — all BE.
    The *only* format on the wire; drives the latency HUD.
  - UDP: app-layer fragmentation, `NLFR` magic + fragment header,
    1200 B payload per datagram. See `005-decisions.md` D-2.
  - A legacy raw-NAL `VideoFrameCodec` (`[4B len BE][H.264 NAL]`)
    exists in `protocol.rs` but has no producer wired into the
    pipeline — treat it as dead code until someone wires it.

To add a new video source (Python streamer, IP camera, RTSP relay),
follow `claw/sop/add-new-video-source.md`. The XR client only cares
about the wire format; the reference Python implementation is in
`tools/mac_mock_streamer.py`.
