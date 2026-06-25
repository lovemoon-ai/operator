# XR Client Architecture

`xr/` is a Godot 4.5 Android XR project. It uses the mobile renderer, OpenXR
alpha-blend passthrough, and Android plugins for capture, QR scanning, live
streaming, and video decode.

## Top-Level Layout

```text
xr/
  project.godot
  scenes/                  .tscn scene resources and shaders
  scripts/
    app/                   launcher, modes, feature composition
    core/                  reusable capture/sensor/time/pipeline logic
    contracts/             typed data contracts
    sinks/                 output adapters
    ui/                    UI controls and XR panels
    network/               teleop protocol clients
    platform/              Quest/Pico/OpenXR capability registry
    xr/                    OpenXR helpers and capture provider registry
    test_support/          on-device test framework
  addons/
    live_video/            reusable H.264 video panel
    live-push/             XR-to-server live feed path
    live-pull/             server-to-XR result path
    *_capture_android/     vendor capture providers
```

`xr/scripts` root is intentionally empty. New scripts should be placed under
the responsibility-specific directories above.

## Scenes And Scripts

Scenes remain necessary because they define Godot node graphs, transforms,
SubViewport/Viewport2DIn3D resources, shaders, and plugin scene instances. UI
logic does not live in scenes anymore; scene resources attach scripts from
`xr/scripts/ui` or `xr/scripts/app`.

| Scene | Script | Notes |
| --- | --- | --- |
| `scenes/main.tscn` | `scripts/app/launcher/mode_select.gd` | Mode launcher. |
| `scenes/teleop_main.tscn` | `scripts/app/modes/teleop_mode.gd` | Thin mode entry point extending `teleop_controller.gd`. |
| `scenes/robot_view/robot_view.tscn` | `scripts/ui/teleop_panel.gd` | Teleop video panel scene. |
| `scenes/capture_app.tscn` | `scripts/app/modes/ego_capture_mode.gd` | Ego capture mode. |
| `scenes/live_feed_app.tscn` | `scripts/app/modes/live_feed_mode.gd` | Capture mode pinned to live server sink. |
| `scenes/vr_mode.tscn` | `scripts/app/modes/vr_mode.gd` | Minimal OpenXR VR mode. |
| `scenes/mujoco/mujoco_device_test.tscn` | `scripts/app/modes/mujoco/mujoco_device_test.gd` | Device smoke scene. |
| `scenes/test_runner.tscn` | `scripts/test_support/runner/test_runner_root.gd` | Module test harness. |

`scripts/ui/teleop_panel.gd` is a small Operator wrapper around
`addons/live_video/live_video_view.gd`. Video decode, access-unit assembly,
AHB/YUV/RGBA presentation, and latency HUD behavior belong to the addon.

## App Modules

`scripts/app/launcher/mode_select.gd` is the boot scene script. It reads
feature tags through `FeatureSet`, renders launcher cards, handles automation
mode intent extras, and routes to mode scenes.

`scripts/app/modes/` contains scene lifecycle entry points:

- `teleop_mode.gd` extends `teleop_controller.gd`.
- `ego_capture_mode.gd` extends `capture_app_base.gd`.
- `live_feed_mode.gd` extends `capture_app_base.gd` and sets
  `capture_sink = "server"`.
- `vr_mode.gd` owns the standalone VR scene.
- `mujoco/mujoco_device_test.gd` owns the MuJoCo device smoke flow.

`scripts/app/composition/` builds feature-specific dependency graphs:

- `teleop_composition.gd` wires command output and robot control.
- `ego_capture_composition.gd` wires SpatialMP4, manifest/upload artifacts,
  optional sidecars, and sensors.
- `live_feed_composition.gd` wires live-push writers and live-stream sinks.

## Core Modules

- `scripts/core/capture/` - session state machine, writer adapters, spool
  writers, and live writer adapters.
- `scripts/core/sensors/` - pose, depth, controller, hand, body, and motion
  frame primitives.
- `scripts/core/pipeline/stream_binding.gd` - binds capture streams to sinks.
- `scripts/core/time/timebase.gd` - timestamp domains and conversion metadata.
- `scripts/contracts/` - stable GDScript contracts used by modes, sinks, and
  tests.
- `scripts/sinks/` - concrete outputs: SpatialMP4, upload queue, live stream,
  robot control, JSONL sidecar, and sink contract.

## Teleop Runtime

`teleop_controller.gd` creates the v2 teleop stack at runtime:

- `Session` for Hello, descriptor, telemetry, and legacy fallback.
- `CommandSender` for controller/tracking command frames.
- `RobotControlSink` as the mode-facing command output.
- `TcpHandler` for command and TCP video streams.
- `UdpVideoHandler` for UDP timed video packets.
- `RobotClockSync` for latency reporting.
- settings and controller overlays from `scripts/ui`.

Video transport is descriptor-driven. TCP is the default and supports USB
`adb reverse`; UDP is selected when the descriptor advertises a usable UDP
port and `transport` is `udp` or `auto`.

## Capture Runtime

`capture_app_base.gd` handles shared capture-mode lifecycle:

- intent extras and automation entry points for device tests;
- permission and platform provider setup;
- capture start/stop UI;
- QR-based ingest configuration;
- upload queue integration.

Mode-specific composition chooses the sink chain:

- Ego capture writes local SpatialMP4 artifacts and can upload through TUS.
- Live Feed streams selected sensor/video data to a server through OLCP.

## Ego Recording Container Contract

Raw ego recordings should converge on a self-contained SpatialMP4 as the
canonical replay artifact. A consumer that only has `media.mp4` must be able to
recover the sensor payloads and metadata required for spatial interpretation:
RGB/depth pixels, audio, head/controller/hand/body tracks, Camera2 calibration,
RGB frame timing, depth frame metadata, body frame extras, and motion trackers.
JSONL sidecars may still exist for debug, export, or legacy compatibility, but
they must not be required to correctly parse a new raw MP4.

`manifest.json` remains a first-class upload artifact. Its role is file and
session inventory, not sensor interpretation. It records artifact filenames,
kinds, sizes, hashes such as `sha256`, upload status, derivation status, optional
debug sidecars, and any file-level metadata that cannot live inside the MP4
without creating circular dependencies. In particular, `media.mp4` cannot embed
its own final hash; that belongs in `manifest.json` or the ingest database.

The MP4 container contract uses media tracks for high-volume samples and `mett`
timed-metadata tracks for structured metadata:

| Track | Payload | Timing |
| --- | --- | --- |
| RGB / depth / audio | Encoded media samples and existing ICAM/ECAM/DSTR side-data. | Per media sample. |
| head / controllers / hands / body joints | Existing pose and joint `mett` payloads. | Per sensor sample. |
| `operator_static` | Static replay metadata: schema, capture options needed for parsing, device/provider identity, Camera2 characteristics, and Android timebase. | Single packet at PTS 0. |
| `rgb_frame_index` | Eye, frame index, Camera2 sensor timestamp, timestamp source, camera id, dimensions. | Per RGB frame. |
| `depth_frame_meta` | OpenXR depth metadata such as timestamp source, runtime display time, projection/inverse-projection columns, near/far range, FOV tangents, and `local_from_depth_eye`. | Per depth frame. |
| `body_frame_meta` | Frame-level `body_flags` and provider-specific body extras that do not fit the compact body-joints payload. | Per body frame. |
| `motion_trackers` | PICO motion tracker pose samples, velocities, accelerations, battery state, and power-key events. | Per tracker sample/event. |

Readers should use this precedence:

1. Prefer embedded MP4 metadata tracks.
2. Fall back to uploaded sidecars for old recordings.
3. Treat `manifest.json` as artifact inventory and integrity metadata, not as
   the source of geometry or timing needed to render the recording.

Migration should be incremental. First embed `operator_static` and
`rgb_frame_index` so Quest hand-to-RGB projection no longer depends on external
Camera2 sidecars. Then embed `depth_frame_meta`, `body_frame_meta`, and
`motion_trackers`. During migration, keep writing the current sidecars and keep
reader fallback paths so existing recordings remain usable. Once the reader and
ingest paths prefer embedded metadata, default uploads should only require
`manifest.json` and `media.mp4`; debug sidecars become opt-in artifacts listed by
the manifest.

## Platform Registry

`scripts/platform/registry/platform_registry.gd` chooses the best provider for
platform capabilities. Quest, Pico, and generic OpenXR adapters report capture,
QR, live-stream, and sensor capability availability. Device tests can use fake
providers from `scripts/test_support/fakes/platform`.

## Test Harness

`scripts/test_support/` is an in-app module test framework. It is activated by
exporting an APK with the test-harness feature and launching with intent extras:

```bash
bash cicd/xr_module_harness.sh --suite capture.pipeline --serial <serial>
```

The harness runs on the target headset, logs `OPERATOR_TEST_*` markers, and
pulls JSON result files from the app external files directory.

Static manifest validation is host-side only:

```bash
python3 cicd/validate_xr_features.py
python3 cicd/validate_xr_test_manifests.py
```
