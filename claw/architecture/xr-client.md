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

Every launcher card is gated by one `operator_feature_mode_*` flag, Exit
included; there is no separate launcher-card mechanism. A card is visible
only when its flag is set in the preset that produced the APK, so the
shipped card set is a build-time decision. Automation intent extras
(`--es operator.mode <id>`) bypass the cards entirely and are not gated by
these flags, which is how the Live Feed E2E enters a mode whose card is off.

`scripts/app/modes/` contains scene lifecycle entry points:

- `teleop_mode.gd` extends `teleop_controller.gd`.
- `ego_capture_mode.gd` extends `capture_app_base.gd`.
- `vr_mode.gd` owns the standalone VR scene.
- `mujoco/mujoco_device_test.gd` owns the MuJoCo device smoke flow.

`live_feed_app.tscn` attaches `capture_app_base.gd` directly with
`capture_sink = "server"`; `live_feed_mode.gd` is a thin wrapper that no
scene currently references.

`scripts/app/composition/` builds feature-specific dependency graphs:

- `teleop_composition.gd` wires command output and robot control.
- `ego_capture_composition.gd` wires SpatialMP4, manifest/upload artifacts, and
  sensors.
- `live_feed_composition.gd` wires live-push writers and live-stream sinks.

## Core Modules

- `scripts/core/capture/` - session state machine, writer adapters, spool
  writers, and live writer adapters.
- `scripts/core/sensors/` - pose, depth, and controller samplers plus the
  GDScript decision logic for hand/body/motion capture.
- `scripts/core/pipeline/stream_binding.gd` - binds capture streams to sinks.
- `scripts/core/time/timebase.gd` - timestamp domains and conversion metadata.
- `scripts/contracts/` - stable GDScript contracts used by modes, sinks, and
  tests.
- `scripts/sinks/` - concrete outputs: SpatialMP4, upload queue, live stream,
  robot control, and sink contract.
- `native/hand_capture/` - GDExtension owning the hot joint-capture paths in
  C++: `NativeOpenXRHandCapture` owns Quest/PICO `XR_EXT_hand_tracking`
  trackers and writes MP4 HJNT on an independent 60 Hz worker clock;
  `NativeHandSampler` handles render-driven live push;
  `NativeBodyMotionWriter`
  packs/serializes body joints and motion-tracker records into MP4 metadata
  tracks. GDScript keeps only the
  per-frame trigger, runtime selection, and diagnostics.
- `native/pico_openxr/` - PICO OpenXR bridge; camera RGB frames are pumped
  by a dedicated native worker: `XR_PICO_camera_image` raw RGBA pointer -> GLES
  eye textures -> GPU stereo composition -> NDK MediaCodec input Surface ->
  native SpatialMP4 ABI. The hot path never creates a GDScript
  `PackedByteArray` or Java `ByteArray`; a reusable CPU staging buffer is used
  only for an incompatible runtime pixel/row layout. The shared
  `native/hand_capture` worker supplies the independent 60 Hz hand stream for
  both Quest and PICO. GDScript starts/stops the workers, provides the
  OpenXR-to-Godot clock offset, and drains small
  `QcCamera` diagnostic counters only. The PICO API currently exposes raw RGBA
  instead of a texture/AHardwareBuffer, so one native client-memory-to-GPU
  upload remains unavoidable.

PICO RGB configuration is runtime capability-driven. After the OpenXR session
starts, the bridge enumerates camera ids, per-eye resolutions, formats,
transfer types, and frame rates through `XR_PICO_camera_image`. The settings UI
shows the common stereo resolution set (or the left-camera set for mono) and an
`Auto` choice. `Auto` passes no preferred dimensions, allowing the runtime to
select a supported configuration; an explicit choice must be negotiated
exactly or capture is rejected. No product model, codename, or device serial is
used to select a camera profile, so the same `Pico` export is shared by PICO
headsets with different camera shapes.

## Teleop Runtime

`teleop_controller.gd` creates the v2 teleop stack at runtime:

- `Session` for Hello, descriptor, telemetry, and legacy fallback.
- `CommandSender` for controller/tracking command frames.
- `XrStateSender` for one atomic raw tracking snapshot when `xr_stream` is
  advertised by an embedded `pyoperator` session.
- `RobotControlSink` as the mode-facing command output.
- `TcpHandler` for command and TCP video streams.
- `UdpVideoHandler` for UDP timed video packets.
- `RobotClockSync` for latency reporting.
- settings and controller overlays from `scripts/ui`.
- `EEPoseTrajectory` for the optional descriptor-driven operation trail. It
  observes successfully queued `DeviceCommand` poses, renders independent
  left/right world-space paths, keeps the latest two deadman segments per hand,
  and starts a new segment after each release so inactive controller motion is
  never joined into the trail. A successfully queued reset-to-home command
  clears both hands' trails before its bundled poses can be rendered.

Video transport is descriptor-driven. TCP is the default and supports USB
`adb reverse`; UDP is selected when the descriptor advertises a usable UDP
port and `transport` is `udp` or `auto`.

`XrStateSender` samples in `_process` after Godot advances OpenXR for the render
frame. Head/controllers/input/hands are collected without yielding; body and
motion trackers retain their own lower-rate sample timestamp. It is disabled
for normal robot descriptors, so `CommandSender` behavior and bandwidth are
unchanged outside Python SDK mode.

## Capture Runtime

`capture_app_base.gd` handles shared capture-mode lifecycle:

- intent extras and automation entry points for device tests;
- permission and platform provider setup;
- capture start/stop UI;
- QR-based ingest configuration;
- upload queue integration.

The Output panel also owns the export reference-space contract. Operators
choose `STAGE`, `LOCAL`, or `LOCAL_FLOOR`; before recording starts the app asks
Godot's OpenXR interface to activate the corresponding play space and waits
for the runtime to confirm it. Capture is blocked if the runtime falls back to
a different space. Head and controller samples use their unadjusted `XRPose`
transforms, while the independent native hand worker locates joints against
that same active `XrSpace`. The selected value is fixed for the session and is
stored in capture options and `operator_static` metadata.

RGB calibration is intentionally not rebased: Camera2/OpenXR camera
extrinsics remain `T_head_camera`. A reader obtains a camera pose in the chosen
export space by composing
`T_export_camera = T_export_head * T_head_camera`. `operator_static` declares
both the export space and this head-relative extrinsics contract.

Mode-specific composition chooses the sink chain:

- Ego capture writes local SpatialMP4 artifacts and can upload through TUS.
- Live Feed streams selected sensor/video data to a server through OLCP.

Each local Ego recording is stored as one movable session directory:

```text
<capture_root>/
  <session_id>/
    <session_id>.mp4
    manifest.json
```

This is the complete recording. Pose, body, depth, camera calibration, timebase,
and RGB frame-index metadata are embedded in MP4 tracks/metadata. Local-session
discovery continues to recognize the historical `<capture_root>/<session_id>.mp4`
sibling layout so existing recordings remain available for preview, upload, and
deletion.

## Ego Recording Container Contract

Raw ego recordings should converge on a self-contained SpatialMP4 as the
canonical replay artifact. A consumer that only has `media.mp4` must be able to
recover the sensor payloads and metadata required for spatial interpretation:
RGB/depth pixels, audio, head/controller/hand/body tracks, Camera2 calibration,
RGB frame timing, depth frame metadata, body frame extras, and motion trackers.
MP4 metadata is the source of truth.

`manifest.json` remains a first-class upload artifact. Its role is file and
session inventory, not sensor interpretation. It records artifact filenames,
kinds, sizes, hashes such as `sha256`, upload status, derivation status, and any
file-level metadata that cannot live inside the MP4 without creating circular
dependencies. In particular, `media.mp4` cannot embed its own final hash; that
belongs in `manifest.json` or the ingest database.

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

Environment-depth replay uses each frame's `local_from_depth_eye` and
inverse-projection metadata for every OpenXR provider. Metric depth points are
unprojected in RDF image coordinates (X right, Y down, Z forward), then mapped
into the OpenXR/Godot eye basis (X right, Y up, Z back) with an explicit Y/Z
axis flip before RGB reprojection. This is selected by the embedded depth
metadata contract, never by headset model, codename, or serial number.

Readers should use embedded MP4 metadata tracks for geometry and timing, while
`manifest.json` remains artifact inventory and integrity metadata. Default
uploads require only `manifest.json` and `media.mp4`. Unbounded raw depth dumps
remain local diagnostics and are not part of the upload artifact contract.

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
