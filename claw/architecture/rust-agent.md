# Rust robot agent — code-anchored architecture

Companion to `overview.md`. The overview gives the big picture; this
doc tells you *where* to make a change and *why* each part looks the
way it does. Every claim is anchored at `path:line`.

Scope: everything under `robot/`. Cargo manifest `robot/Cargo.toml`,
build/deploy `robot/Makefile`, YAML schemas in `robot/config/`.

---

## 1. Process model — eight subsystems under `try_join!`

Orchestration is in `main.rs` and nowhere else. Read it once.

- Runtime: `#[tokio::main(flavor = "multi_thread", worker_threads = 2)]`
  at `robot/src/main.rs:32`. Two workers is intentional — the
  heavy capture/encode loop is `spawn_blocking`'d
  (`robot/src/video/pipeline.rs:77`), so the async pool only services
  network + control. Bumping workers without removing the blocking
  loop just adds context switches.
- Eight subsystems launched as one `tokio::try_join!(…)` at
  `robot/src/main.rs:121-158`:
  1. `network::discovery::run` (`robot/src/network/discovery.rs:18`)
  2. `network::pose_server::run` (`robot/src/network/pose_server.rs:24`)
  3. `network::pose_udp_server::run` (`robot/src/network/pose_udp_server.rs:61`)
  4. `network::telemetry_server::run` (`robot/src/network/telemetry_server.rs:32`)
  5. `video::pipeline::run` (`robot/src/video/pipeline.rs:61`)
  6. `run_device_loop` (local helper at `robot/src/main.rs:165`)
  7. `telemetry::latency::run_aggregator` (`robot/src/telemetry/latency.rs:196`)
  8. `telemetry::metrics::run` (`robot/src/telemetry/metrics.rs:13`)

**Failure model.** `try_join!` aborts on first `Err`. No
partial-degraded mode — better to crash visibly and let systemd
restart than to run half-blind. The one exception is the control
loop: when the command channel closes it sleeps 1 s and keeps
spinning (`control_loop.rs:148`) so a fresh TCP reconnect can attach.
`panic = "abort"` (`robot/Cargo.toml:66`) makes this airtight against
unwound panics inside one of the seven sibling futures.

**Pre-startup.** Descriptor UDP transport is back-filled from
`VideoConfig.udp_port` at `robot/src/main.rs:66-82`: if YAML declared
TCP-only and the runtime opens UDP, `transport` is rewritten
`"tcp" → "auto"` so the headset auto-selects UDP. Hard-coded `"tcp"`
in YAML is respected.

---

## 2. Device abstraction — why safety can't be bypassed

Production code cannot send a command to hardware without going
through safety validation. The enforcement is structural, not
discipline.

### `Device` trait
`robot/src/device/traits.rs:308-330`. Async, `Send + Sync`. Concrete
impls in `devices/{dummy,rc_car,robot_arm}.rs`.

### `SafeDevice` — the unforgeable wrapper
`robot/src/device/safe_device.rs:27-30`:

```rust
pub struct SafeDevice {
    inner: Box<dyn Device>,
    safety: DeviceSafety,
}
```

`inner` is private and there is no accessor returning `&mut dyn
Device`. The only ways to drive the inner device:

- `SafeDevice::send_command` (`safe_device.rs:66`) — validates first;
  on `Rejected` calls `inner.emergency_stop()` (`safe_device.rs:79`)
  before returning to the caller.
- `SafeDevice::force_send` (`safe_device.rs:92`) — `pub(crate)`, so
  only the `device` module can call it. Used solely by
  `control_loop::apply_disconnect_action` for the synthesised neutral
  command. Still applies `safety.clamp_only`.
- `SafeDevice::emergency_stop` (`safe_device.rs:60`) — always allowed.

Bypassing this would require breaking module privacy. `DeviceRegistry::create_device`
(`robot/src/device/registry.rs:42`) is the only constructor and
always returns a `SafeDevice` — there is no escape hatch.

`DeviceSafety::validate` itself is at `robot/src/device/safety.rs:89-125`:
four reject-class checks (unknown names, non-finite, non-unit
quaternion, button-group conflict), then stateful button transforms
(toggle/confirm/group at `safety.rs:299-402`), then axis clamp +
dead-zone. The arm-specific `control::safety::Safety`
(`robot/src/control/safety.rs:37`) layers on top inside `RobotArm`
for joint limits and velocity.

### `control_loop::run` — watchdog + `disconnect_action`
`robot/src/device/control_loop.rs:47`. Three-way `tokio::select!` at
`control_loop.rs:76-179`:

- **Incoming command** (`control_loop.rs:81`). Reads latest
  `TimedCommand`, applies the **50 ms stale-pose drop** at
  `control_loop.rs:100-114` (only if `clock_offset_ns != 0`, i.e.
  ClockPing has succeeded — pre-handshake frames pass through to
  avoid burning the first second). Brackets the driver write with
  `t_drv_start` / `t_drv_done` for the latency recorder.
- **Watchdog tick** (`control_loop.rs:159`). Period =
  `timeout/4` clamped to `[50 ms, 250 ms]` (`control_loop.rs:58-63`).
  If `last_cmd_at.elapsed() > timeout`, runs `apply_disconnect_action`
  exactly once until a fresh command arrives.
- **Telemetry poll** at 100 ms (`control_loop.rs:172`).

`apply_disconnect_action` (`control_loop.rs:188`) reads
`descriptor.safety.parsed_disconnect_action()`
(`traits.rs:275-287`, default `Stop`). `Stop` pushes neutral via
`force_send` + e-stop. `Hold` is a no-op. `ReturnHome` currently
falls back to `Stop` with a warning — full implementation needs a
per-device home-pose method.

### `DeviceRegistry`
`robot/src/device/registry.rs:42-63`. String → impl: `"robot_arm"` →
`RobotArm` (requires `[arm]` config), `"rc_car"` → `RcCar`, anything
else → `DummyDevice` with a warning. The arm-driver factory at
`robot/src/control/drivers/mod.rs:53-112` **propagates** serial-open
errors instead of falling back to a dummy — silently degrading hid
real wiring problems in the past (see comment at
`drivers/mod.rs:36-50`).

### Concrete devices
- `devices/dummy.rs:27` — accepts all commands, no hardware.
- `devices/rc_car.rs:49` — PWM serial frames; e-stop sends neutral.
- `devices/robot_arm.rs:147` — wraps the older `control::*` pipeline.
  Non-obvious:
  - `reference_set` atomic (`robot_arm.rs:36, 185-198`). First valid
    `end_effector` pose after (re)connect is captured as the pose
    mapper reference via `compare_exchange`; without this
    `PoseMapper::map_direct` computes `current − current = 0` and the
    first three joints never move.
  - `with_write_timeout` (`robot_arm.rs:80-98`). Each driver write
    is `tokio::time::timeout`'d at `driver_write_timeout_ms`
    (default 20 ms, `config.rs:138-147`). On timeout we **return
    Ok**, log warn, bump a counter — bubbling would trip safety
    rejection → unnecessary e-stop. The driver naturally holds its
    last setpoint.

---

## 3. Networking layer

Six live modules under `robot/src/network/`. `video_server.rs`
(`network/video_server.rs:1-4`) is a deliberately empty stub — video
lives in `video::pipeline`.

### `discovery.rs`
mDNS via `mdns-sd` at `discovery.rs:20-53` (service type
`_xrobo._tcp.local.`) plus UDP broadcast every 3 s to
`255.255.255.255:<discovery_port>` at `discovery.rs:78-90`. Both run
forever; broadcast errors are logged-and-continued.

### `pose_server.rs` — TCP command channel (63901)
- Wire: `CommandCodec`, LE-length frames (`protocol.rs:36-46`).
- Handshake Hello → DeviceDescriptor, 5 s timeout
  (`pose_server.rs:81-119`); non-Hello first frame is tolerated.
- Per connection: `framed.split()`, then a writer task draining a
  bounded `mpsc::channel::<CommandFrame>(64)` (`pose_server.rs:127-136`),
  a telemetry task pushing legacy `Telemetry` at 10 Hz
  (`pose_server.rs:141-158`), and a reader handling `DeviceCommand`
  (`pose_server.rs:164`), `Heartbeat` (`pose_server.rs:182`), and
  `ClockPing` (`pose_server.rs:185-224`). The ClockPing handler
  stamps `t_robot_recv` *before* any await and `t_robot_send`
  immediately after JSON-build for honest round-trip math.
- Every decoded `DeviceCommand` is pushed with `send_replace` at
  `pose_server.rs:178` (drop-old: any prior unread value is
  discarded).
- `latency.new_session()` on each TCP accept (`pose_server.rs:46`)
  invalidates stale in-flight frames from a previous connection.

### `pose_udp_server.rs` — UDP data plane (63902)
- 32 B header + variable payload, full layout at `protocol.rs:285-304`.
  Codec: hand-rolled `PoseUdpPacket::decode` at `protocol.rs:409-476`.
- CRC-16/CCITT-FALSE, 10-line impl at `protocol.rs:343-356`.
- **Three drop policies, in order** (block comment at
  `pose_udp_server.rs:6-19`):
  1. CRC mismatch (`pose_udp_server.rs:88-91`, counter).
  2. Session token (`pose_udp_server.rs:99-109`). Token `0` =
     anonymous. When TCP mints a new token, `last_applied_seq` is
     reset to 0 — otherwise a fresh client's `seq=1` would be
     permanently rejected.
  3. Drop-old by `seq` (`pose_udp_server.rs:111-115`). The core
     HOL-blocking eliminator.
- Accepted packets feed the **same** `watch` channel TCP feeds
  (`pose_udp_server.rs:132`). The control loop is source-agnostic.
- This path **does not** call `latency.record_rx`
  (`pose_udp_server.rs:118-126`) — that would mint a new seq and
  break gap detection. The packet's own seq is preserved end-to-end.

### `telemetry_server.rs` — dedicated TCP (63903)
One `Framed<TcpStream, CommandCodec>` per subscriber, pushing latest
`DeviceTelemetry` every 100 ms (`telemetry_server.rs:32-75`). Exists
to keep 10 Hz telemetry off the control TCP socket — under load the
two flows competed for outbound bytes and amplified jitter on the
72 Hz command stream (block comment `telemetry_server.rs:9-13`). Wire
format identical to legacy `Telemetry` frames so XR decoders are
unchanged.

### `protocol.rs` — three codecs share this file
- `CommandCodec`: LE-length, hard caps `MAX_CMD_LEN = 64 KiB` and
  `MAX_DATA_LEN = 16 MiB` (`protocol.rs:45-47`).
- `VideoFrameCodec`: BE-length raw NAL (`protocol.rs:128-164`). Kept
  for `ffplay`.
- `TimedVideoFrameCodec`: BE 80 B timing header + NAL
  (`protocol.rs:209-283`). Header constant at `protocol.rs:207`.

### `session.rs`
Tiny helper file: `build_descriptor_frame` (`session.rs:16`) for
Hello replies, `headset_pose_to_device_command` (`session.rs:27`) for
legacy v1 "Tracking" JSON.

---

## 4. Video pipeline

Entry `video::pipeline::run` (`robot/src/video/pipeline.rs:61`).

### Mode selection
`should_use_v4l2_hw` (`pipeline.rs:183-208`): Linux only, requires
both the camera device path *and* an M2M device found by
`v4l2_m2m::find_m2m_device` (`v4l2_m2m.rs:528-554`, walks
`/dev/video0` … `/dev/video19`, checks `V4L2_CAP_VIDEO_M2M{,_MPLANE}`
bits). Non-Linux always returns false.

### V4L2 HW path
`v4l2_hw_loop` at `pipeline.rs:212-289`. `Camera::open`
(`camera.rs:32-67`) tries YU12 → NV12 → YUYV (`camera.rs:104-110`)
because YU12 is what the M2M encoder wants; 4-buffer MMAP'd stream
at `camera.rs:153-160`. `V4l2M2mEncoder::open`
(`v4l2_m2m.rs:193-345`) runs the full M2M dance: cap query, set
OUTPUT (raw) + CAPTURE (H.264) formats, bitrate / I-period / baseline
profile / SPS-repeat controls (`v4l2_m2m.rs:275-287`), MMAP buffers,
STREAMON. Single- and multi-plane M2M both supported. Each frame
emits zero or more NALs stamped with `capture_start/end` +
`encode_start/end` and `pipeline_mode = VIDEO_PIPELINE_MODE_V4L2_HW`.

### FFmpeg path (macOS + Linux fallback)
`ffmpeg_loop` at `pipeline.rs:297-364`. `FfmpegPipeline::start`
(`ffmpeg.rs:34-177`) — most of the macOS reality is in comments:
- `platform_input` (`ffmpeg.rs:320-345`): `/dev/video*` auto-rewrites
  to AVFoundation index `"0"`.
- `pick_capture_size` (`ffmpeg.rs:288-317`): FaceTime HD exposes only
  fixed modes — non-native sizes capture at 1280×720 and libavfilter
  downscales.
- macOS scale filter (`ffmpeg.rs:68-72`):
  `format=nv12,hwupload,scale_vt=…`. `format=nv12` is required
  because `scale_vt` rejects UYVY422 input. ffmpeg 8 also needs
  explicit `-init_hw_device videotoolbox=vt -filter_hw_device vt`
  (`ffmpeg.rs:83-91`); without it hwupload errors with "A hardware
  device reference is required".
- `select_encoder` (`ffmpeg.rs:220-277`): macOS uses
  `h264_videotoolbox` with `-realtime true -profile baseline
  -allow_sw false`; Linux prefers `h264_v4l2m2m` (when `/dev/video11`
  exists) else `libx264 -preset ultrafast -tune zerolatency`.
- GOP = `fps / 2` (`ffmpeg.rs:42-44`) — 0.5 s between IDRs. Trades
  ~10–15 % bandwidth for faster recovery from loss, matters because
  the XR-side stale-NAL drop opportunistically skips P-frames.
- stderr drain thread (`ffmpeg.rs:154-169`). Without it ffmpeg blocks
  once the 64 KiB pipe buffer fills, looking exactly like a stall.
- Annex B NAL parser at `ffmpeg.rs:369-445`; reset-on-overflow guard
  at `ffmpeg.rs:409-416`.

### Fan-out and `send_ns` stamping
- Encoder publishes onto `broadcast::channel::<TimedVideoFrame>(128)`
  at `pipeline.rs:72`.
- **TCP** (`serve_video_clients`, `pipeline.rs:367-399`): `send_ns`
  is stamped at `pipeline.rs:383` — the instant a packet hits the
  socket. That's the value the XR latency HUD subtracts from.
- **UDP** (`serve_udp_broadcast`, `pipeline.rs:112-163`): optional,
  enabled when `VideoConfig.udp_port` is `Some(_)`. Client discovery
  is barely-a-protocol — a single `"Hello"` datagram registers the
  source in a `HashSet<SocketAddr>` (`pipeline.rs:121-135`). UDP
  fragmentation at `pipeline.rs:557-616`: 1200 B payload per
  fragment; every fragment carries `[NLFR magic][version][flags][idx]
  [count][frame_id]` (16 B, `pipeline.rs:51-58`) *plus* the full 80 B
  timed header so any fragment is metadata-self-contained.
  Fragment-count capped at `u16::MAX`; oversize NALs are dropped
  with a warning.

See `claw/issues/005-decisions.md` D-1 (transport selection) and D-2
(1200 B framing budget) for the full design rationale.

---

## 5. Telemetry & latency

`LatencyRecorder` (`robot/src/telemetry/latency.rs`) lives as a
single `Arc` constructed at `main.rs:104` and shared between
pose_server, pose_udp_server, the control loop, and the aggregator.

Stamps and who writes them:

| Stamp                | Writer                                | Site                                              |
|----------------------|---------------------------------------|---------------------------------------------------|
| `t_xr_send_ns`       | XR client (in `DeviceCommand`)        | (off-robot)                                       |
| `t_rx_ns` (TCP)      | `pose_server` on decode               | `pose_server.rs:97` / `:166`                      |
| `t_rx_ns` (UDP)      | `pose_udp_server` on decode           | `pose_udp_server.rs:122`                          |
| `seq` (TCP)          | `record_rx`                           | `latency.rs:156`                                  |
| `seq` (UDP)          | preserved from packet                 | `pose_udp_server.rs:129`                          |
| `t_dispatch_ns`      | control_loop, post-watch-wake         | `control_loop.rs:97`                              |
| `t_drv_start_ns`     | control_loop, pre-driver-write        | `control_loop.rs:116`                             |
| `t_drv_done_ns`      | control_loop, post-driver-write       | `control_loop.rs:118`                             |
| `clock_offset_ns`    | pose_server on ClockPing              | `pose_server.rs:210`                              |

Completed frames live in a `Mutex<RingBuffer>` of 8192 slots
(`latency.rs:88, 103`) — ~110 s of 72 Hz history, sized so a stalled
aggregator can't backpressure the hot path. The
`parking_lot_compat::Mutex` shim (`latency.rs:343-376`) exists to
avoid the parking_lot crate dependency.

`run_aggregator` (`latency.rs:196-243`) drains 1 Hz, computes
p50/p95/p99/max for five buckets (`xr_rx`, `rx_dispatch`,
`dispatch_drv`, `drv`, `e2e`) plus `seq_gap_max`. Negative deltas are
dropped, not clamped (`latency.rs:316-320`) — they indicate clock
de-sync and skewing percentiles would hide that.

`metrics::run` (`telemetry/metrics.rs:13`) emits uptime at
`log_interval_secs`. When `enabled = false` it parks forever via
`std::future::pending` (`metrics.rs:18`) so `try_join!` doesn't exit.

---

## 6. Channels

| Channel                                 | Type                                       | Cardinality | Why this shape                                                                                       |
|-----------------------------------------|--------------------------------------------|-------------|------------------------------------------------------------------------------------------------------|
| `device_cmd_tx/rx` (`main.rs:95`)       | `watch<Option<TimedCommand>>`              | many→1      | **Latest-only**. Drop-old, no HOL. Rationale block at `main.rs:86-94`.                               |
| `telemetry_tx/rx` (`main.rs:100`)       | `watch<DeviceTelemetry>`                   | 1→many      | Subscribers (pose_server, telemetry_server) clone receivers.                                         |
| outbound (`pose_server.rs:127`)         | `mpsc<CommandFrame>(64)`                   | many→1      | Telemetry pusher + ClockPong replier funnel into single TCP writer task; bounded to cap memory.       |
| `nal_tx` (`pipeline.rs:72`)             | `broadcast<TimedVideoFrame>(128)`          | 1→many      | One encoder, N TCP clients + optional UDP fanout. Lag is observable (`broadcast::error::Lagged`).    |
| `session_token` (`main.rs:110`)         | `Arc<AtomicU32>`                           | producer→consumer | TCP mints, UDP reads. Shared atomic, not a channel.                                              |
| `udp_stats` (`main.rs:111`)             | `Arc<UdpDropStats>` (4 × `AtomicU64`)      | counters    | Definitions at `pose_udp_server.rs:42-47`.                                                           |
| `latency.completed` (`latency.rs:103`)  | `Mutex<RingBuffer<8192>>`                  | many→1      | Cheap push, drained 1 Hz.                                                                            |

### Why latest-only on `device_cmd_tx`

`watch::send_replace` (`pose_server.rs:178`, `pose_udp_server.rs:132`)
silently overwrites any unread value. The control loop only ever
sees the freshest command. The cost, called out at `main.rs:86-94`:
button rising-edges that fall entirely inside one inter-tick gap can
be missed. For continuous pose at 72 Hz (the dominant workload) this
is the right trade. Buttons get edge detection above the channel via
the stateful semantics in `DeviceSafety` (`safety.rs:299-402`,
toggle/confirm/group).

The `Option` wrapper (`main.rs:95`) distinguishes "never sent
anything yet" from "value sent and overwritten" — `cmd_rx.changed()`
only wakes on a fresh send, not on the initial state.

---

## 7. Cross-compile + deploy

- `robot/Cross.toml:1-5` — two cross-compile targets:
  `aarch64-unknown-linux-gnu` and `armv7-unknown-linux-gnueabihf`
  via upstream `cross-rs` images.
- `make build-rpi` → cross aarch64 (`robot/Makefile:8-9`).
- `make deploy` (`robot/Makefile:12-15`) `scp`'s the binary +
  `config/default.yaml` to `$RPI_HOST:~/`. No systemd unit shipped;
  that's the operator's job.

Release profile (`robot/Cargo.toml:61-66`) is aggressive:
`opt-level=3`, `lto=true`, `strip=true`, `codegen-units=1`,
`panic="abort"`. The abort is load-bearing — `try_join!` semantics
mean any subsystem panic is best surfaced as process death so systemd
restarts cleanly. Linux-only deps (`v4l`, `nix`, `libc`) gated by
`cfg(target_os = "linux")` at `robot/Cargo.toml:52-55` so macOS dev
builds don't pull them.

---

## 8. Non-obvious behaviours / trip-wires

Places where comments shout "we tried X, reverted because Y", or
where the intuitive change is wrong.

- **macOS Camera permission via Terminal.app.** `make
  run-mac-local-camera-bg` re-launches via `open -a Terminal` so the
  TCC prompt attaches to Terminal (a known TCC client) rather than
  the embedded VSCode/Conductor terminal (which is not). Full story
  at `robot/Makefile:62-99`. Symptom of doing it wrong: ffmpeg hangs
  in AVFoundation init forever, no Video: stats line ever appears.

- **`scale_vt` filter shape (macOS).** `robot/src/video/ffmpeg.rs:58-91`
  documents why the filter must be `format=nv12,hwupload,scale_vt=…`
  with explicit `-init_hw_device videotoolbox=vt -filter_hw_device
  vt`. Earlier shapes silently fail on ffmpeg 8.

- **ffmpeg stderr drain thread.** `ffmpeg.rs:147-169`. Without it
  ffmpeg blocks on stderr write once the 64 KiB pipe buffer fills.

- **UDP NAL fragment payload = 1200 B is the whole-datagram budget.**
  `pipeline.rs:33-38`. Bumping without reading
  `claw/issues/005-decisions.md` D-2 risks compounding loss via
  kernel-level IP fragmentation.

- **UDP drop-old must reset on session change.**
  `pose_udp_server.rs:99-109`. Without `last_applied_seq = 0` on a
  fresh token, a new client's `seq=1` is permanently rejected.

- **UDP path skips `record_rx`.** `pose_udp_server.rs:118-126`.
  Calling it would mint a new seq and break the aggregator's gap
  detection.

- **50 ms stale-pose drop only after clock sync.**
  `control_loop.rs:25-28, 100-114`. Pre-ClockPing the offset is zero,
  so age can't be computed; frames pass through. Intentional —
  burning frames during the handshake window would degrade the first
  second of teleop.

- **Driver write timeout returns Ok, not Err.** `robot_arm.rs:80-98`.
  Bubbling would trip `SafetyOutcome::Rejected` → unnecessary e-stop.
  Holding the last setpoint is correct for a slow-bus glitch.

- **RobotArm reference-set one-shot.** `robot_arm.rs:32-36, 185-198`.
  Without `compare_exchange`-gated `mapper.set_reference()` on the
  first valid pose, the position joints never move. The disconnect
  path clears the flag (`robot_arm.rs:159-164`) so reconnect
  re-calibrates.

- **`network::video_server.rs` is a stub.** Two lines of comments
  (`network/video_server.rs:1-4`). Don't put code there — video lives
  in `video/pipeline.rs`. Kept only for backward compat against
  branches that still `mod` it.

- **V4L2 M2M module gating.** `robot/src/video/mod.rs:12-13`
  declares `pub mod v4l2_m2m;` inside `#[cfg(target_os = "linux")]`.
  Cross-module references must be similarly gated or macOS builds
  break.

- **TCP-reader on the XR side is single-threaded** (cross-reference,
  not editable from here). See `claw/issues/005-decisions.md` D-4.

- **`try_join!` cardinality is fixed at eight.** Adding a ninth means
  adding it to the call at `main.rs:121-158` and deciding whether
  its failure should bring the agent down (almost certainly yes).
  Don't `tokio::spawn` it bare — a panicked detached task is
  invisible to `try_join!`.
