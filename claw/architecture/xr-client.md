# XR client architecture (`xr/`)

Godot 4.5 mobile-renderer OpenXR app. Single-scene project, mobile
Vulkan, passthrough alpha-blend. This document is keyed to file paths
and line numbers so a future engineer can locate the right hook before
making any non-trivial change.

Entry points worth knowing up front:

- `xr/project.godot:14` — main scene is `res://scenes/main.tscn`.
- `xr/project.godot:37` — `renderer/rendering_method="mobile"`. The AHB
  GDExtension assumes Vulkan; non-mobile/GLES forces the Plan B fallback
  (`xr/native/ahb_decoder/src/ahb_video_texture.cpp:138`).
- `xr/project.godot:41-53` — OpenXR enabled with alpha-blend
  passthrough; hand-tracking + Meta/Pico vendor extensions.
- Two autoloads from godot-xr-tools (`xr/project.godot:18-20`):
  `XRToolsUserSettings`, `XRToolsRumbleManager`. No other globals.

---

## 1. Scene + runtime layout

### Scene graph (`xr/scenes/main.tscn`)

The static tree authored in the editor:

- `Main` (`Node3D`, `xr/scenes/main.tscn:13-14`) — root, script
  `scenes/main.gd`.
- `StartXR` — instanced `addons/godot-xr-tools/xr/start_xr.tscn` with
  `enable_passthrough=true` (`xr/scenes/main.tscn:16-17`).
- `XROrigin3D` → `XRCamera3D`, `LeftController`, `RightController`,
  `RobotView`, `HUD` (`xr/scenes/main.tscn:19-31`). Controllers use the
  standard `left_hand` / `right_hand` trackers (`xr/scenes/main.tscn:24,27`).
- `ConnectionPanel`, `TrackingProvider`, `TcpHandler`, `PoseSender`,
  `Discovery` as plain `Node` siblings of `XROrigin3D`
  (`xr/scenes/main.tscn:33-45`).

`PoseSender` exists in the scene (`xr/scenes/main.tscn:41-42`) but the
v2 protocol uses `CommandSender` instead — see §3. `PoseSender` is the
legacy/v1 path that fires only after the session falls back to legacy
mode (`xr/scripts/network/session.gd:58-60`).

### `_ready` wiring (`xr/scenes/main.gd:39-93`)

`main.gd::_ready` does, in order:

1. `_configure_passthrough()` — make the viewport transparent so OpenXR
   alpha-blend composites the camera through
   (`xr/scenes/main.gd:201-211`).
2. `_create_v2_nodes()` — creates `Session`, `CommandSender`, the
   second `TcpHandler` (`VideoTcpHandler` with a 32 MiB recv buffer),
   `UdpVideoHandler`, `RobotClockSync`, and the `DynamicHUD` SubViewport
   (`xr/scenes/main.gd:96-145`). The 32 MiB buffer override is at
   `xr/scenes/main.gd:115` (`set_max_recv_buffer(32 * 1024 * 1024)`).
3. Connects `StartXR.xr_started` and, **only if present**,
   `xr_failed`. The `has_signal` guard at `xr/scenes/main.gd:54` is a
   trip-wire fix — newer godot-xr-tools removed `xr_failed` and the
   strict connect raised a script error that aborted `_ready` before
   the TCP signal wiring below was hooked up (comment at
   `xr/scenes/main.gd:48-53`).
4. Wires both video handlers to the **same** `_on_video_*` callbacks so
   transport-switching is transparent (`xr/scenes/main.gd:63-73`).
5. Wires `ConnectionPanel.connect_requested → _on_connect_requested`
   (`xr/scenes/main.gd:75-76`) and `Discovery.robot_found/lost`
   (`xr/scenes/main.gd:78-79`).
6. Wires `Session` signals (`device_connected`, `device_disconnected`,
   `telemetry_received`) (`xr/scenes/main.gd:82-84`).
7. Assigns dependencies into `CommandSender`
   (`xr/scenes/main.gd:87-88`).
8. `_discovery.start_scan()` (`xr/scenes/main.gd:91`).

### XR start + auto-connect (`xr/scenes/main.gd:147-193`)

`_on_xr_started` initializes `RobotView`, sets HUD status, and reads
`XRRuntimeName` defensively — the strict `: String` annotation here
previously aborted before the auto-connect timer could be scheduled on
Pico's OpenXR (comment at `xr/scenes/main.gd:156-162`).

The 3-second auto-connect timer is scheduled at
`xr/scenes/main.gd:168`. Its callback `_auto_connect_loopback`
(`xr/scenes/main.gd:171-193`) checks, in order:

1. Skip if already connected or any robot was discovered
   (`xr/scenes/main.gd:172-175`).
2. `OS.get_environment("XROBO_HOST")` (Linux/macOS-style env)
   (`xr/scenes/main.gd:181`).
3. `getprop debug.xrobo.host` via `OS.execute("getprop", ...)` for
   Pico/Android (`xr/scenes/main.gd:185-187`). The shell command for
   operators is documented inline:
   `adb shell setprop debug.xrobo.host 192.168.31.31`.
4. Fall back to `127.0.0.1:63901` for the `adb reverse` USB workflow
   (`xr/scenes/main.gd:192-193`).

Either override path calls `_on_connect_requested(host, 63901)`. The
discovery list is preferred when populated.

### Connection flow

`ConnectionPanel.connect_requested` → `_on_connect_requested(ip, port)`
(`xr/scenes/main.gd:214-216`) → `TcpHandler.connect_to_robot`. On
success `_on_connected` (`xr/scenes/main.gd:225-232`) calls
`Session.on_connected()` (which sends `Hello` and starts the v2
handshake timer), `_connect_video_stream`, and
`RobotClockSync.start()`.

`_connect_video_stream` (`xr/scenes/main.gd:425-481`) selects TCP vs
UDP from the cached descriptor feed via `_select_video_transport`
(`xr/scenes/main.gd:381-388`). The selection rules are documented at
`xr/scenes/main.gd:364-388`:

- `transport == "udp"` and `udp_port > 0` → UDP.
- `transport == "auto"` and `udp_port > 0` → UDP (Wi-Fi tail-latency
  preference).
- Anything else → TCP. This means old robots without
  `transport`/`udp_port` always fall back to TCP — no flag day.

The first `_connect_video_stream` always runs before the descriptor
arrives so it picks TCP; `_on_device_connected`
(`xr/scenes/main.gd:298-318`) re-runs it after the descriptor lands so
UDP can take over. The comment at `xr/scenes/main.gd:305-309` explains
this.

---

## 2. Networking GDScript layer

### `tcp_handler.gd` (`xr/scripts/network/tcp_handler.gd`)

One file does both the command channel and (in a second instance) the
video TCP channel — `StreamMode` enum at line 41 selects parsers.

**Why inline polling, not worker threads** (`xr/scripts/network/tcp_handler.gd:6-24`):

> *"Inline drain-loop is the final design. Worker threads were
> attempted (see [opt 6 reverted] history below) but Godot 4's
> StreamPeerTCP isn't reliably thread-safe on swan: the very first
> put_data after the worker started polling returned err=1 (FAILED)
> ~half the time, killing the connection before any frames flowed. We
> accept the ~3–5 ms worst-case scheduling latency of inline polling
> — well under the 100 ms motion-to-photons budget — in exchange for
> a connection that actually stays up."*

Trip-wire to revisit (`xr/scripts/network/tcp_handler.gd:14-20`): a
Godot release fixing the threading bug **or** profiling showing
process-tick latency dominates. The API was kept thread-friendly so
re-introducing a worker is mechanical.

Key constants:

- `DEFAULT_MAX_RECV_BUFFER = 10 * 1024 * 1024`
  (`xr/scripts/network/tcp_handler.gd:78`). Sized for 720p30 at 4 Mbps
  with ~6 frames of headroom. Override per-instance with
  `set_max_recv_buffer()` (`xr/scripts/network/tcp_handler.gd:94-98`)
  — `main.gd` bumps the video handler to 32 MiB
  (`xr/scenes/main.gd:115`).
- `READ_CHUNK_SIZE = 65536` (`xr/scripts/network/tcp_handler.gd:80`).
- `MAX_DRAIN_PER_TICK = 32`
  (`xr/scripts/network/tcp_handler.gd:108`). Hard cap on iterations so
  a pathological producer can't livelock the loop.
- `BAD_STATUS_TOLERANCE = 5` (`xr/scripts/network/tcp_handler.gd:68`).
  Some Godot 4 / Pico builds report `STATUS_NONE` for a single tick
  right after the first `put_data`; tearing down on one bad tick was
  killing the command channel. Comment at lines 62-67.

**Drain loop** (`xr/scripts/network/tcp_handler.gd:181-221`). The
opt-7 comment at line 181 explains: a single read per process tick
(~11 ms at 90 fps) added 30+ ms of scheduling latency to NALs larger
than `READ_CHUNK_SIZE`. The while-loop at line 188 drains until
`get_available_bytes() == 0` or 32 iters. Overflow triggers
hard-disconnect rather than head-drop (rationale: `claw/issues/005-decisions.md`
D-5, ref'd at lines 208-210).

**TCP_NODELAY** is set in `_ready` *and* re-applied on successful
connect (`xr/scripts/network/tcp_handler.gd:111-118` and
`141`); some Godot 4 builds don't honour the pre-connect call. Without
this, the 76-byte timed-video header was coalesced with subsequent
data and added up to 40 ms to `tx=`.

Parsing splits by `_mode`:
`_parse_frames` (command, `xr/scripts/network/tcp_handler.gd:224-259`),
`_parse_video_packets` (timed video,
`xr/scripts/network/tcp_handler.gd:262-279`). Legacy non-timed video
emits a packet dict with `"legacy": true` and `nal_data`
(`xr/scripts/network/tcp_handler.gd:253-257`).

### `udp_video_handler.gd` (`xr/scripts/network/udp_video_handler.gd`)

Mirrors `TcpHandler`'s API surface (`connect_to_video_stream`,
`video_frame_received` signal) so `main.gd` doesn't care which is
active (`xr/scripts/network/udp_video_handler.gd:5-10`).

- **Hello-driven fan-out** — sends `"Hello"` payload as a datagram
  every 5 s (`HELLO_REPEAT_SEC`,
  `xr/scripts/network/udp_video_handler.gd:36`); the robot replies to
  whatever address Hello came from
  (`xr/scripts/network/udp_video_handler.gd:303-306`).
- **NLFR fragment magic** — defined in
  `xr/scripts/network/protocol.gd:41-51` as the 4-byte ASCII
  `"NLFR"` + 1-byte version + 1-byte flags + fragment_index +
  fragment_count + frame_id. Parser at
  `xr/scripts/network/protocol.gd:268-317`. Magic check is at
  `xr/scripts/network/protocol.gd:272-274` — silent bail on mismatch
  so legacy non-fragmented datagrams fall through to
  `decode_timed_video_frame` at
  `xr/scripts/network/udp_video_handler.gd:106-111`.
- **Reassembly** — keyed by `"frame_id:nal_index"`
  (`xr/scripts/network/udp_video_handler.gd:117`). Caps at
  `REASSEMBLY_MAX = 16` partials
  (`xr/scripts/network/udp_video_handler.gd:63`) and times out at
  `REASSEMBLY_TTL_NS = 200 ms`
  (`xr/scripts/network/udp_video_handler.gd:68`). Drop counter at
  `xr/scripts/network/udp_video_handler.gd:218-222` is exposed to
  RobotView's HUD via `get_drop_count()`.
- Reassembly fills `fragments[idx]` and emits the packet only when
  `received_count == fragment_count`
  (`xr/scripts/network/udp_video_handler.gd:171-172`).

### `discovery.gd` (`xr/scripts/network/discovery.gd`)

UDP-broadcast listener on port `63900`
(`xr/scripts/network/discovery.gd:17`). Expects JSON with
`service: "xrobo-agent"` and `tcp_port`/`video_port`
(`xr/scripts/network/discovery.gd:6-12`, `49-80`). Times robots out
after 10 s of silence (`ROBOT_TIMEOUT`,
`xr/scripts/network/discovery.gd:19`).

### `session.gd` (`xr/scripts/network/session.gd`)

v2 handshake. On connect sends `"Hello"` with
`{"version":"2.0","client":"godot","capabilities":["hand_tracking","controller"]}`
(`xr/scripts/network/session.gd:21-29`). Waits up to `HANDSHAKE_TIMEOUT
= 3.0` s for a `DeviceDescriptor`
(`xr/scripts/network/session.gd:18`, `54-60`); if it doesn't arrive,
emits `legacy_mode_activated` and the v1 `PoseSender` (`Tracking`
frames) takes over. Telemetry frames are forwarded to `main.gd` via
the `telemetry_received` signal (`xr/scripts/network/session.gd:45-50`).

### `clock_sync.gd` (`xr/scripts/network/clock_sync.gd`)

NTP-style offset via `ClockPing` / `ClockPong` on the command channel.

- Cadence: `PING_INTERVAL_SEC = 1.0`
  (`xr/scripts/network/clock_sync.gd:23`). First ping is intentionally
  delayed by one full interval — back-to-back sends right after
  `STATUS_CONNECTED` were racing `StreamPeerTCP` state on swan and
  dropping the command socket (comment at
  `xr/scripts/network/clock_sync.gd:57-62`).
- Offset is EWMA-smoothed (`EWMA_ALPHA = 0.3`,
  `xr/scripts/network/clock_sync.gd:24`); RTT outliers >3× median over
  a 5-sample window are rejected
  (`xr/scripts/network/clock_sync.gd:94-99`).
- Exposed via `static var offset_ns`
  (`xr/scripts/network/clock_sync.gd:30`).
  `VideoLatencyTracker.format_packet` reads this at
  `xr/scripts/network/video_latency.gd:58-61` and uses it to bring the
  robot-stamped `send_ns` into the XR clock domain:
  `send_ns_xr = send_ns - clock_offset_ns`. Until the first ping
  completes the `tx=` field shows `--`.

### `protocol.gd` (`xr/scripts/network/protocol.gd`)

Wire-format codec. Binary-compatible with the original C#
`NetworkDataProtocolSerializer`. Documented at the top
(`xr/scripts/network/protocol.gd:1-29`):

- **Command frame**: `[4B cmd_len LE][cmd UTF-8][4B data_len LE][data]`,
  encoder/decoder at lines 57-120.
- **Legacy video**: `[4B len BE][NAL]`, helper at lines 124-139.
- **Timed video header** (80 bytes, all big-endian) including
  `frame_id`, `nal_index`, `nal_count`, `pipeline_mode`, eight u64
  stage timestamps (`capture_*`, `encode_*`, `read_wait`, `parse`,
  `send`), and the NAL length. Decoder at lines 182-223.
  `TIMED_VIDEO_HEADER_SIZE` is precomputed at line 53.
- **UDP fragment** (`NLFR` magic): described above. Note the magic
  bytes are stored as individual constants rather than a
  `PackedByteArray` because GDScript `const` evaluation rejects
  non-trivial array initializers (comment at
  `xr/scripts/network/protocol.gd:43-44`).

---

## 3. Input pipeline

`tracking_provider.gd` (`xr/scripts/xr/tracking_provider.gd`) is a
node that resolves the XR scene tree lazily (deferred to
`_find_xr_nodes` at line 24) and exposes vendor-agnostic OpenXR
accessors:

- `get_head_pose()` (line 78) — XRCamera3D transform.
- `get_controller_pose(hand)` (line 91) — XRController3D transform +
  `is_active` flag.
- `get_controller_input(hand)` (line 110) — returns trigger/grip
  floats, `primary` Vector2, A/B/X/Y button floats, menu button.
- `get_hand_joints(hand)` (line 132) — 26-joint OpenXR hand tracker
  output. Untracked joints return `{"tracked": false}`.

`command_sender.gd` (`xr/scripts/input/command_sender.gd`) runs in
`_physics_process` at up to 72 Hz (`_min_send_interval = 1.0 / 72.0`,
line 11). Each tick:

1. Build descriptor-driven command via `ControlMode.collect_command`
   (line 29).
2. JSON-encode and send as `"DeviceCommand"` frame on the command TCP
   channel (line 31).

`configure_for_device(descriptor)`
(`xr/scripts/input/command_sender.gd:15-18`) instantiates a fresh
`ControlMode` and hands the descriptor to it.

### `control_mode.gd` (`xr/scripts/input/control_mode.gd`)

The mapping layer between VR inputs and the robot's input schema. Reads
two descriptor sections:

- `input_mapping` (`xr/scripts/input/control_mode.gd:15`) — array of
  `{source, target, scale, invert, offset}` mappings.
- `control_schema.axes[*].dead_zone` for per-axis deadbands
  (`xr/scripts/input/control_mode.gd:17-19`).

`_read_vr_source` (line 53) is the source-name dispatch table.
Recognised sources: `left/right_joystick_x/y`, `left/right_trigger`,
`left/right_grip`, `button_a/b/x/y`,
`right/left_controller_pose`, `head_pose`,
`right/left_hand_joints`.

`collect_command` produces:

```
{
  "axes":    { target: scaled_value, ... },
  "buttons": { target: bool, ... },
  "poses":   { target: { "position": [x,y,z], "rotation": [x,y,z,w] }, ... },
  "timestamp_ns": int
}
```

Floats below `dead_zone` are zeroed
(`xr/scripts/input/control_mode.gd:41`); booleans use the >0.5
threshold (`xr/scripts/input/control_mode.gd:94`).

`PoseSender` (`xr/scripts/network/pose_sender.gd:50`) is the legacy
fallback — it sends `"Tracking"` frames and only fires after the v2
handshake times out.

---

## 4. Video decode pipeline

Three decode paths exist. Selection happens entirely inside
`KotlinVideoDecoderPlugin`'s static `ahbNativeAvailable` initializer
(`xr/android/build/src/com/godot/game/video/KotlinVideoDecoderPlugin.kt:62-78`)
and the `surfaceMode` switch in `configureCodec`
(`xr/android/build/src/com/godot/game/video/KotlinVideoDecoderPlugin.kt:424-449`).

### 4.1 AHB Surface mode (zero-copy, gated)

Selected when `libahb_decoder.so` loads successfully **and**
`debug.xrobo.force_yuv_plane != 1`
(`xr/android/build/src/com/godot/game/video/KotlinVideoDecoderPlugin.kt:62-78`).
Path:

1. `configureCodec` allocates an `ImageReader` with
   `ImageFormat.PRIVATE` + `HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE`
   (`xr/android/build/src/com/godot/game/video/KotlinVideoDecoderPlugin.kt:427-441`)
   and configures MediaCodec into Surface output mode
   (`xr/android/build/src/com/godot/game/video/KotlinVideoDecoderPlugin.kt:451`).
2. `drainOutput` calls `releaseOutputBuffer(idx, true)` to render to
   the surface; the heavy lifting moves to
   `onAhbImageAvailable`
   (`xr/android/build/src/com/godot/game/video/KotlinVideoDecoderPlugin.kt:531-541`).
3. `onAhbImageAvailable` uses `acquireLatestImage()` (drop-stale
   policy, `xr/android/build/src/com/godot/game/video/KotlinVideoDecoderPlugin.kt:472-477`),
   pulls `image.hardwareBuffer`, and calls the JNI bridge
   `nativeImportAhb`
   (`xr/android/build/src/com/godot/game/video/KotlinVideoDecoderPlugin.kt:494`).
4. The C++ side hands the `AHardwareBuffer` to the singleton
   `AhbVideoTexture` (see §5).
5. `RobotView._process` polls `_ahb_texture.is_ready()` and swaps it
   into the shader (`xr/scenes/robot_view/robot_view.gd:115-123`),
   setting `use_yuv = false`.

**This path is currently broken visually on Pico** — see §5 and
`claw/issues/008-ahb-ycbcr-sampler-gap.md`. The operator override to
fall back is `setprop debug.xrobo.force_yuv_plane 1`.

### 4.2 YUV plane copy (shipping default)

Selected when AHB isn't available *or* the operator forced YUV.
ByteBuffer-mode output path:

- `drainOutputByteBufferMode`
  (`xr/android/build/src/com/godot/game/video/KotlinVideoDecoderPlugin.kt:566-612`)
  calls `extractYuvPlanesTight` (line 754) to copy each YUV_420_888
  plane out of `Image.getOutputImage(idx)` into tightly-packed byte
  arrays.
- Emits `yuv_frame_ready(width, height, decoded_ns, y, u, v)` signal
  (`xr/android/build/src/com/godot/game/video/KotlinVideoDecoderPlugin.kt:587-594`).
- GDScript handler is
  `RobotView._on_video_yuv_frame_ready`
  (`xr/scenes/robot_view/robot_view.gd:465-598`). It reuses three
  `ImageTexture`s of `FORMAT_L8` (Y full-size, U/V half-size; see
  `xr/scenes/robot_view/robot_view.gd:498-517`) and binds them to the
  shader (`xr/scenes/robot_view/robot_view.gd:527-530`). The
  per-frame call only does `set_data()` + `texture.update()` to avoid
  per-frame allocations.
- `stereo_display.gdshader` switches to the YUV branch when
  `use_yuv = true` (`xr/scenes/robot_view/stereo_display.gdshader:53-59`)
  and does BT.601 limited-range YUV→RGB in the fragment shader
  (`xr/scenes/robot_view/stereo_display.gdshader:26-36`).

### 4.3 CPU YUV→RGB safety net

Still present at
`xr/android/build/src/com/godot/game/video/KotlinVideoDecoderPlugin.kt:596-604`:
when `extractYuvPlanesTight` returns null (e.g. unexpected plane
layout), `convertToRgbaCpu` (line 818) does the BT.601 conversion in
Java integer math and emits the legacy `frame_ready(w, h, ts, rgba)`
signal. GDScript handler is
`RobotView._on_video_frame_ready`
(`xr/scenes/robot_view/robot_view.gd:601-689`). This branch only fires
when both the AHB path and the plane-copy fast path are unavailable.

### Branch points summary

| Where | Branch |
|---|---|
| `KotlinVideoDecoderPlugin.kt:62-78` | static AHB availability decision |
| `KotlinVideoDecoderPlugin.kt:424-449` | Surface mode (AHB) vs ByteBuffer mode in `configureCodec` |
| `KotlinVideoDecoderPlugin.kt:526-545` | `drainOutput` dispatches by `surfaceMode` |
| `KotlinVideoDecoderPlugin.kt:573-606` | plane-copy first, CPU fallback if `extractYuvPlanesTight` returns null |
| `robot_view.gd:99-106` | tries `ClassDB.instantiate("AhbVideoTexture")`; null → Plan B stays active |
| `robot_view.gd:115-123` | swaps shader to AHB texture once `is_ready()` |
| `robot_view.gd:478-479` | drops YUV planes if AHB already bound |

### Access-unit reassembly + stale guard (`xr/scenes/robot_view/robot_view.gd`)

NALs arrive one-per-packet with `nal_index` / `nal_count`. RobotView
reassembles into one access unit before handing to the decoder
(`xr/scenes/robot_view/robot_view.gd:849-867`).

- `MAX_INFLIGHT_PACKETS = 3`
  (`xr/scenes/robot_view/robot_view.gd:770`). Rationale comment at
  lines 754-769: cap=3 → ~19 fps with 100 ms total latency; cap=12 →
  ~25 fps with 400 ms latency. Teleop chose latency.
- `STALE_NAL_BUDGET_MS = 100`
  (`xr/scenes/robot_view/robot_view.gd:837`). Non-keyframe access
  units older than 100 ms are dropped before submission
  (`xr/scenes/robot_view/robot_view.gd:870-888`). IDR/SPS/PPS NALs
  (types 5/7/8) are exempted — `_access_unit_has_keyframe`
  (`xr/scenes/robot_view/robot_view.gd:776-801`) scans for them.
- `KEY_LOW_LATENCY` is set on MediaCodec (API 30+) so Adreno doesn't
  buffer 14 frames waiting for B-frame reorder
  (`xr/android/build/src/com/godot/game/video/KotlinVideoDecoderPlugin.kt:392-405`).

---

## 5. `xr/native/ahb_decoder/` GDExtension

C++17 GDExtension built via CMake against `godot-cpp` (submodule).
Produces `libahb_decoder.so` installed into both
`xr/addons/ahb_decoder/` (for the GDExtension manifest) and
`xr/android/build/libs/arm64-v8a/` (for `System.loadLibrary`).

### Source files

- `xr/native/ahb_decoder/src/register_types.cpp` — GDExtension entry
  point. Registers `AhbVideoTexture` at
  `MODULE_INITIALIZATION_LEVEL_SCENE` only
  (`xr/native/ahb_decoder/src/register_types.cpp:14-19`); earlier
  levels lack `RenderingServer`. Init function
  `ahb_decoder_init` at line 29.
- `xr/native/ahb_decoder/src/jni_bridge.cpp` — JNI entry point.
  Implements `Java_com_godot_game_video_KotlinVideoDecoderPlugin_nativeImportAhb`
  (`xr/native/ahb_decoder/src/jni_bridge.cpp:42-66`). Unwraps the
  `HardwareBuffer` Java object via
  `AHardwareBuffer_fromHardwareBuffer` and bumps the refcount
  (`xr/native/ahb_decoder/src/jni_bridge.cpp:51-57`) before calling
  `AhbVideoTexture::push_buffer`. The texture singleton is tracked
  via a `std::atomic<AhbVideoTexture*>` (`g_active_texture`, line 25);
  `ahb_register_active` / `ahb_unregister_active` are called from the
  C++ class ctor/dtor.
- `xr/native/ahb_decoder/src/ahb_video_texture.h` — class declaration.
  Subclass of `Texture2DRD`. The header is annotated with where each
  field lives in the per-frame flow
  (`xr/native/ahb_decoder/src/ahb_video_texture.h:1-7`).
- `xr/native/ahb_decoder/src/ahb_video_texture.cpp` — the meat.

### Vulkan import chain

The per-frame work runs on Godot's render thread (not the JNI thread)
to satisfy `ERR_RENDER_THREAD_GUARD`. `push_buffer` is a fast handoff
(`xr/native/ahb_decoder/src/ahb_video_texture.cpp:910-940`):

1. Swap incoming AHB into `_pending_buffer`; release any previous
   pending buffer (drop-stale).
2. `RenderingServer::call_on_render_thread(Callable(this, "_render_thread_tick"))`
   — gated on `_render_tick_scheduled` so flurries coalesce
   (`xr/native/ahb_decoder/src/ahb_video_texture.cpp:925-939`).

`_render_thread_tick`
(`xr/native/ahb_decoder/src/ahb_video_texture.cpp:945-1055`) does, in
order:

1. `_ensure_device()` — pulls `VkDevice`, `VkPhysicalDevice`,
   `VkQueue`, `VkQueue` family from
   `RenderingDevice::get_driver_resource` (lines 142-187). The PoC
   verified all four are non-zero on Pico
   (`xr/native/ahb_decoder/src/ahb_video_texture.cpp:178-184`).
   Resolves extension entry points
   (`vkGetAndroidHardwareBufferPropertiesANDROID`,
   `vkCreate/DestroySamplerYcbcrConversion`) via
   `vkGetDeviceProcAddr`
   (`xr/native/ahb_decoder/src/ahb_video_texture.cpp:162-176`).
2. `_ensure_ycbcr_sampler(buffer)` — queries AHB format props, builds
   `VkSamplerYcbcrConversion` from the buffer's suggested model/range/
   chroma-offset (`xr/native/ahb_decoder/src/ahb_video_texture.cpp:209-297`).
   Creates a `VkSampler` with the conversion in `pNext`.
3. `_import_buffer(buffer)` — creates `VkImage` (`VK_FORMAT_UNDEFINED`
   + `externalFormat`), allocates dedicated memory via
   `VkImportAndroidHardwareBufferInfoANDROID`
   (`xr/native/ahb_decoder/src/ahb_video_texture.cpp:351-381`), binds
   the image, creates a `VkImageView` referencing the YCbCr conversion
   in `pNext` (`xr/native/ahb_decoder/src/ahb_video_texture.cpp:394-422`).
4. **Plan A compute blit** — `_ensure_destination_image` creates a
   persistent `VK_FORMAT_R8G8B8A8_UNORM` `VkImage` with
   `STORAGE | SAMPLED | TRANSFER_DST`
   (`xr/native/ahb_decoder/src/ahb_video_texture.cpp:462-549`).
   `_ensure_compute_pipeline` builds a descriptor-set layout with the
   YCbCr sampler as an **immutable** combined image sampler at
   binding 0 (this is the key — issue 008's resolution)
   (`xr/native/ahb_decoder/src/ahb_video_texture.cpp:609-614`), plus a
   storage image at binding 1. The shader is embedded SPIR-V
   (`shaders/ycbcr_to_rgba.spv.h`,
   `xr/native/ahb_decoder/src/ahb_video_texture.cpp:642-651`).
5. `_dispatch_blit` runs the per-frame compute pass on Godot's queue.
   Same-queue submission gives implicit ordering against Godot's
   fragment-shader read, so no semaphores are needed
   (`xr/native/ahb_decoder/src/ahb_video_texture.cpp:880-882`).
   `_dst_first_use` flag handles the initial UNDEFINED→GENERAL barrier
   vs the steady-state SHADER_READ_ONLY→GENERAL one
   (`xr/native/ahb_decoder/src/ahb_video_texture.cpp:820-825`).
6. `texture_create_from_extension` registers the **destination** image
   (not the AHB source) with Godot's `RenderingDevice`, then
   `set_texture_rd_rid` on the `Texture2DRD` base
   (`xr/native/ahb_decoder/src/ahb_video_texture.cpp:1020-1046`). The
   RID is created once and reused — comment at lines 1034-1041
   documents that wrapping through `RenderingServer::texture_rd_create`
   (a different RID space) silently failed.

### Why it samples black on Pico (issue 008)

The original direct-sample path created a YCbCr-aware `VkSampler` but
Godot's `RenderingDevice` allocates a default sampler for the standard
`uniform sampler2D` binding — **without** the
`VkSamplerYcbcrConversion`, so sampling
`VK_FORMAT_UNDEFINED + externalFormat` returned zero. Documented in
`claw/issues/008-ahb-ycbcr-sampler-gap.md:24-38`.

Plan A (compute blit) is the in-tree resolution: convert AHB→RGBA in a
compute shader where we control the descriptor-set layout and can
register the YCbCr sampler as an immutable combined image sampler.
The compute pass writes a persistent RGBA8 image and Godot's standard
fragment shader samples that. As of the current tree the compute
pipeline is wired (`xr/native/ahb_decoder/src/ahb_video_texture.cpp:596-734`)
and dispatched per-frame, but the operator-visible bug ("AHB renders
black") is still tracked open in issue 008.

The shipped operator workaround is
`adb shell setprop debug.xrobo.force_yuv_plane 1`
(`xr/android/build/src/com/godot/game/video/KotlinVideoDecoderPlugin.kt:59`).

---

## 6. HUD / telemetry display

Two HUDs exist, with overlapping responsibilities.

### Static HUD (`xr/scenes/ui/hud.gd`)

Tied to a `Node3D` instanced in `main.tscn:31`. Three labels:
status / FPS / tracking / platform
(`xr/scenes/ui/hud.gd:4-7`). Counters tick in `_process`
(`xr/scenes/ui/hud.gd:22-41`). Driven by direct `set_status`,
`set_platform`, `set_tracking_mode` calls from `main.gd`.

### Dynamic HUD (`xr/scripts/ui/dynamic_hud.gd` + `xr/scenes/ui/dynamic_hud.tscn`)

Auto-generated from `DeviceDescriptor.telemetry_schema`. Loaded
lazily in `_create_v2_nodes` (`xr/scenes/main.gd:135-144`). Made
visible only after `_on_device_connected`
(`xr/scenes/main.gd:312-317`).

- `configure_for_device(descriptor)`
  (`xr/scripts/ui/dynamic_hud.gd:40-65`) reads
  `telemetry_schema.values[*]` and creates a `Label` per entry.
  `warn_below` thresholds are remembered and used in
  `update_telemetry` to recolour labels red when value < threshold
  (`xr/scripts/ui/dynamic_hud.gd:78-83`).
- `update_telemetry(data)` (line 67) reads `telemetry.values` from
  each `"Telemetry"` frame routed via `Session` →
  `main.gd::_on_telemetry_received` (`xr/scenes/main.gd:332-334`).
- `update_status(connected, fps)` (line 86) called by `main.gd`
  `_process` every tick (`xr/scenes/main.gd:391-396`).

### Latency HUD on the video panel (`xr/scenes/robot_view/robot_view.gd`)

`_latency_hud` is a `Label3D` child of the display mesh
(`xr/scenes/robot_view/robot_view.gd:10`). Updated every 200 ms in
`_update_latency_hud`
(`xr/scenes/robot_view/robot_view.gd:171-250`). Shows eight rows:

```
net     <ms>      // tx: receive_ns - (send_ns - clock_offset)
decode  <ms>      // decoded_ns - receive_ns
present <ms>      // now - decoded_ns
total   <ms>      // sum of the three smoothed stages
frames  <int>     // from AhbVideoTexture::get_latest_info()
stale   <int>     // _stale_dropped_count
busy    <int>     // _decoder_busy_count
udp     <int>     // _packet_source.get_drop_count() (TCP shows --)
```

All ms values are EWMA-smoothed (`_LATENCY_EWMA_ALPHA = 0.2`,
`xr/scenes/robot_view/robot_view.gd:27`). The comment at lines 213-221
explains why the total is the sum-of-smoothed-stages rather than raw
`now - send_ns_xr` — the AHB texture's `decoded_ns` and the last
packet's `receive_ns` are typically from different frames.

`net` only renders when `RobotClockSync.samples > 0`
(`xr/scenes/robot_view/robot_view.gd:204`) — until the first ClockPong
returns, no honest network number can be shown.

---

## 7. Build system specifics

### Template-AAR extraction trick (`xr/Makefile:23-35`)

The Godot Android exporter expects
`xr/android/build/libs/{debug,release}/godot-lib.template_{debug,release}.aar`
under the project directory. These ship inside the installed Godot
export template ZIP. The `prepare-android-libs` target probes the two
known install locations
(`xr/Makefile:11`) and extracts the AARs on first build. The `xr/.gitignore`
ignores those AARs (and `outputs/` and other gradle scratch), but the
`src/` Kotlin sources are committed.

`GRADLE_USER_HOME` is forced to `$(CURDIR)/.gradle` so gradle's caches
stay inside the project tree
(`xr/Makefile:4`). This isolates per-project gradle caches and lets
`make clean` (`xr/Makefile:19-22`) wipe the build dir without nuking
the user's home cache.

### Three export presets (`xr/export_presets.cfg`)

- `[preset.0]` name `"Meta Quest"` → `build/quest/XRoboToolkit.apk`
  (lines 1-44).
- `[preset.1]` name `"Pico"` → `build/pico/XRoboToolkit.apk`
  (lines 264-307).
- `[preset.2]` name `"Glass XR"` → `build/glassxr/XRoboToolkit.apk`
  (lines 527-570).

All three share `unique_name=org.xrobotoolkit.client` and package name
`XRoboToolkit`. Makefile targets `build-quest`/`build-pico`/`build-glassxr`
invoke `godot --headless --export-release "<preset>" <apk>`
(`xr/Makefile:37-47`).

### Pico smoke-test loop (`xr/Makefile:80-115`)

`make reverse` sets `adb reverse tcp:12345`, `tcp:63901`, `tcp:63900`
(`xr/Makefile:80-85`) so a robot on the Mac at `127.0.0.1` is
reachable from the tethered Pico. Must be re-run after every adb
restart.

`make ship-pico` is the one-shot iteration: build → install → restore
reverse forwards → force-stop → start → tail filtered logcat for the
new PID (`xr/Makefile:95-103`). `ship-pico-fast` skips the build for
relaunch-only iteration (lines 107-115).

**UDP does not traverse `adb reverse`** — only the Wi-Fi smoke-test
loop exercises the UDP video path (cross-referenced at
`xr/scripts/network/udp_video_handler.gd:13-14`).

---

## 8. Trip-wires and non-obvious behaviours

Comments that read like "tried X, reverted because Y":

- **`xr/scripts/network/tcp_handler.gd:6-24`** — Worker threads tried
  and reverted; `StreamPeerTCP` not thread-safe on swan. *Inline
  drain-loop is the final design.* `[opt 6 reverted]`.
- **`xr/scripts/network/tcp_handler.gd:22-24`** — `[opt 7]`
  drain-loop justification: single read per tick added 30+ ms of
  scheduling latency.
- **`xr/scripts/network/tcp_handler.gd:62-67`** — Don't disconnect on
  the first bad status tick; `BAD_STATUS_TOLERANCE = 5` ride-out.
- **`xr/scripts/network/tcp_handler.gd:111-118`** — `set_no_delay`
  applied twice (in `_ready` *and* post-connect) because Godot 4
  doesn't honour the pre-connect call.
- **`xr/scripts/network/clock_sync.gd:57-62`** — First ClockPing
  intentionally delayed; back-to-back sends post-connect were dropping
  the command socket on swan.
- **`xr/scenes/main.gd:48-53`** — `xr_failed` connect guarded with
  `has_signal()` because newer godot-xr-tools removed the signal and
  the strict connect raised a script error that aborted `_ready`
  before TCP wiring.
- **`xr/scenes/main.gd:156-162`** — `XRRuntimeName` defensively read
  as `Variant`; the strict `: String` annotation aborted
  `_on_xr_started` on Pico OpenXR (returned Nil).
- **`xr/scripts/network/udp_video_handler.gd:13-26`** — UDP design
  caveats: no retransmit, no FEC, `adb reverse` doesn't carry
  datagrams, Hello-driven fan-out re-sends every 5 s.
- **`xr/android/build/src/com/godot/game/video/KotlinVideoDecoderPlugin.kt:51-61`** —
  AHB renders black because Godot's default `sampler2D` lacks the
  YCbCr conversion; workaround is `debug.xrobo.force_yuv_plane=1`.
  Plan A compute blit is the in-tree fix; tracked in issue 008.
- **`xr/android/build/src/com/godot/game/video/KotlinVideoDecoderPlugin.kt:311-327`** —
  Async `MediaCodec.Callback` tried (`[opt 8]`) and reverted;
  `onOutputBufferAvailable` never fired on swan. *Synchronous polling
  is the final design.* `codecHandlerThread` field deliberately kept
  for a future async retry on a different device family.
- **`xr/android/build/src/com/godot/game/video/KotlinVideoDecoderPlugin.kt:120-123`** —
  Explicitly **not** OES SurfaceTexture; OES can't surface the
  AHardwareBuffer that Vulkan needs.
- **`xr/android/build/src/com/godot/game/video/KotlinVideoDecoderPlugin.kt:392-405`** —
  `KEY_LOW_LATENCY` works around Adreno's 14-frame DPB stall when SPS
  VUI omits `bitstream_restriction`.
- **`xr/scenes/robot_view/robot_view.gd:435-457`** — `[plan C]`
  reusable `Image` objects so per-frame work is `set_data()` only;
  comment chain documents the optimization path through Plan B → Plan
  C → Plan A (AHB).
- **`xr/scenes/robot_view/robot_view.gd:735-744`** — `ImageTexture` is
  recreated every frame rather than `update()`'d because the latter
  occasionally fails to push pixels to the GPU on mobile Vulkan.
  Documented as "will go away once we move to Surface-based decoding".
- **`xr/scenes/robot_view/robot_view.gd:754-769`** —
  `MAX_INFLIGHT_PACKETS = 3` tradeoff explained: latency over
  smoothness for teleop.
- **`xr/scenes/robot_view/robot_view.gd:22-31`** — Latency HUD uses
  EWMA + cached values because frame-to-frame raw stage numbers can be
  briefly invalid (decoded_ns is for frame N-1 while receive_ns is
  for frame N).
- **`xr/native/ahb_decoder/src/ahb_video_texture.cpp:434-444`** —
  Persistent destination RID must NOT be reset in
  `_release_vk_resources` or Godot displays placeholder colour.
- **`xr/native/ahb_decoder/src/ahb_video_texture.cpp:795-805`** — AHB
  pre-dispatch barrier uses
  `SHADER_READ_ONLY_OPTIMAL → SHADER_READ_ONLY_OPTIMAL` (not
  `UNDEFINED → ...`) because `oldLayout = UNDEFINED` would let the
  driver discard MediaCodec's decoded contents. Adreno surfaced this
  bug as solid red.
- **`xr/native/ahb_decoder/src/ahb_video_texture.cpp:880-891`** — Do
  NOT `vkWaitForFences` after submit; same-queue ordering gives the
  Godot-fragment-read dependency for free, and the next-frame wait at
  the top of `_dispatch_blit` is the natural sync point.
- **`xr/native/ahb_decoder/src/ahb_video_texture.cpp:1034-1041`** —
  `RenderingServer::texture_rd_create` lives in a different RID space
  than `RenderingDevice::texture_is_valid`; the bind silently failed
  and Godot kept showing the placeholder. Use
  `RenderingDevice::texture_create_from_extension` directly.
- **`xr/native/ahb_decoder/src/ahb_video_texture.cpp:132-147`** — All
  Vulkan + `RenderingDevice` access must happen on the render thread
  (`ERR_RENDER_THREAD_GUARD_V`). `push_buffer` is JNI-thread; it must
  hand off via `RenderingServer::call_on_render_thread`.
