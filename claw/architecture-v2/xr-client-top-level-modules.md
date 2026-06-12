# XR client v2 foundation: modules and feature-based development

Status: target architecture.

This document defines the bottom-level architectural logic for the Godot
XR project. It is not a description of the current implementation. It is
the contract future XR refactors should follow as the client adds more
modes, more sensor streams, and more OpenXR Android devices.

This document has two core responsibilities:

1. Define the top-level module split and dependency direction.
2. Define the feature-based development model built around
   `xr/export_presets.cfg`.

Everything else in this document supports those two points.

## Background

The XR client is a VR app that collects sensor data from the headset and
controllers, then uses that data in multiple ways:

- record egocentric datasets to local storage;
- stream live sensor/video data to a remote service;
- teleoperate a robot body;
- run debug, calibration, simulation, and future application modes.

The client should be portable across Quest, Pico, and Google AndroidXR.
OpenXR is the baseline runtime abstraction, but sensor access,
permissions, timebase, camera, depth, body tracking, and encoder support
remain platform-specific. The architecture therefore must be capability
driven rather than device-name driven.

## Foundation rules

### Sensor data is the domain model

Sensor data is a first-class domain model, not an implementation detail
of one mode.

The acquisition side has the same fundamental job across modes: produce
pose, controller, hand, camera, depth, audio, body, boundary, and timing
data with consistent timestamps, coordinate spaces, and source metadata.
The differences are in consumption:

- recording needs completeness, manifests, durable files, and replay;
- live streaming needs encoding, bandwidth control, and low latency;
- teleoperation needs low-latency control frames and explicit drop
  policy;
- debugging needs readable sidecars and metrics.

The architecture should therefore unify sensor frame contracts while
allowing each sink to choose its own quality-of-service policy.

### Platform abstraction is a capability union

The platform layer is not a lowest-common-denominator API.

It represents the union of all capabilities exposed by supported
devices. Other modules should not branch on Quest, Pico, or AndroidXR.
They should query whether the current runtime has a capability and then
use the provider for that capability.

Example:

```gdscript
if platform.has_capability(SensorCapability.DEPTH):
    pipeline.attach_source(platform.depth_provider())
```

Avoid:

```gdscript
if platform.name == "quest":
    ...
elif platform.name == "pico":
    ...
```

Device-specific decisions belong inside `platform/`.

### Explicit contracts and state machines are required now

The current system is already complex enough that dynamic dictionaries,
string method calls, and scattered boolean flags are no longer a safe
foundation for future modes.

Contracts should be introduced at module boundaries first:

- Godot to Android plugin;
- platform provider to app/core;
- sensor source to pipeline;
- pipeline to sink;
- teleop descriptor to command mapper;
- capture session to manifest/uploader.

Lifecycle should be modeled with explicit state machines for capture,
platform permission, source availability, sink health, and mode
activation.

## Part 1: top-level module boundaries

This section defines what each top-level module owns, what it must not
own, and which directions dependencies may flow. This is the main
modularization contract for the Godot XR codebase.

### Target source layout

The proposed Godot-side layout is:

```text
xr/
  scripts/
    app/
      modes/
      features/
      composition/
      ui/
    core/
      sensors/
      capture/
      pipeline/
      teleop/
      time/
    platform/
      openxr/
      quest/
      pico/
      androidxr/
      registry/
    sinks/
      spatialmp4/
      jsonl/
      live_stream/
      robot_control/
      upload/
      debug/
    contracts/
      features/
      sensor/
      platform/
      capture/
      teleop/
      storage/
      wire/
```

This layout is a logical boundary. Exact file paths can be adapted to
Godot's resource loading constraints, but dependency direction should
remain stable.

### Dependency rule

Dependencies flow inward and downward:

```text
app/modes
  -> app/features
  -> core/capture
  -> core/pipeline
  -> core/sensors
  -> contracts

app/composition
  -> app/features
  -> platform
  -> core
  -> sinks
  -> contracts

app/modes
  -> platform
  -> contracts

sinks
  -> core/sensors
  -> contracts

platform
  -> contracts
```

Important rules:

- `core/` must not know Quest, Pico, AndroidXR, or Godot plugin
  singleton names.
- `sinks/` must not branch on device names.
- `app/modes/` composes modules but should not directly call platform
  plugin singletons.
- `app/features/` is the only app-level module that should translate
  export-preset feature tags into runtime feature decisions.
- `platform/` is the only layer allowed to know vendor-specific
  singleton names, permissions, extension names, and native plugin
  method names.
- `contracts/` should contain data shapes and validation helpers, not
  business workflows.

### Module responsibilities

#### `app/modes/`

Mode entry points and scene-level composition.

Examples:

- `TeleopMode`
- `EgoCaptureMode`
- `LiveFeedMode`
- `CalibrationMode`
- `MujocoMode`
- future task-specific modes

Responsibilities:

- own the Godot scene lifecycle for a mode;
- create and wire platform, sources, pipeline, and sinks;
- choose which capabilities are needed for the mode;
- map high-level mode state to UI state;
- handle user intent such as start, stop, connect, record, upload.

Non-responsibilities:

- no vendor-specific platform checks;
- no direct Android plugin singleton calls;
- no manual sensor file formats;
- no low-level transport parsing.

#### `app/composition/`

Composition roots and dependency assembly.

This layer should turn mode intent into concrete object graphs. For
example, an ego capture composition root can attach camera, pose, audio,
depth, and body sources when available, then attach spatial MP4, JSONL,
and uploader sinks.

Responsibilities:

- instantiate providers, sources, pipelines, controllers, and sinks;
- apply mode-specific configuration;
- keep dependency wiring out of large scene scripts.

#### `app/features/`

Export-preset feature management and runtime feature lookup.

This module converts Godot export features into a typed runtime feature
set. It should be the only app-level place that calls
`OS.has_feature("operator_feature_*")`.

Responsibilities:

- read exported feature tags;
- expose typed feature ids to modes and composition roots;
- provide editor/dev defaults when the app is not running from an
  exported APK;
- validate feature dependencies and conflicts;
- keep launcher-card visibility, module enablement, and optional
  workflow activation aligned.

Non-responsibilities:

- no platform capability detection;
- no vendor-specific branching;
- no direct plugin singleton calls;
- no business workflow implementation.

Feature decisions should be made from both build-time feature flags and
runtime platform capabilities:

```gdscript
if features.enabled(OperatorFeature.ROBOT_CONSTRAINT) \
		and platform.has_capability(SensorCapability.ROBOT_CONTROL):
	composition.attach_robot_constraint_module()
```

The feature controls whether the product module is enabled in this APK.
The platform capability controls whether the current device/runtime can
actually provide what the module needs.

#### `core/sensors/`

Unified sensor domain model.

This module defines the canonical frame contracts for all sensor data.
Every source should emit these contracts before data reaches a sink.

Candidate contracts:

- `PoseFrame`
- `ControllerFrame`
- `HandFrame`
- `BodyFrame`
- `CameraFrame`
- `DepthFrame`
- `AudioFrame`
- `BoundaryFrame`
- `InputEventFrame`
- `ClockSample`

Each frame should include:

- monotonic timestamp;
- XR/runtime timestamp when available;
- device/source timestamp when available;
- coordinate space;
- source id;
- capability id;
- sequence number when available;
- validity and confidence metadata;
- payload format metadata.

Coordinate spaces should be explicit. A pose frame without a coordinate
space is invalid at module boundaries.

#### `core/time/`

Shared timebase conversion.

Responsibilities:

- represent Godot monotonic time, OpenXR predicted display time, Android
  elapsed realtime, camera sensor timestamp, and remote robot time;
- provide conversion metadata and confidence;
- expose clock sync results to consumers that need remote time
  correlation.

This module prevents pose, depth, camera, and robot telemetry from each
inventing their own timestamp interpretation.

#### `core/pipeline/`

Sensor source to sink orchestration.

Responsibilities:

- attach and detach sensor sources;
- attach and detach sinks;
- route frames by capability and stream id;
- fan out one source to multiple sinks;
- apply sink-specific backpressure and drop policies;
- collect pipeline health metrics.

The pipeline should not assume all sinks have the same latency or
durability requirements. A robot-control sink can request latest-only
frames, while a recording sink can request ordered durable frames.

Suggested concepts:

- `SensorSource`: produces one or more sensor frame types.
- `SensorSink`: consumes one or more sensor frame types.
- `PipelinePolicy`: controls buffering, drop-old/drop-new, batching,
  and thread/main-loop constraints.
- `StreamBinding`: connects a source stream to one or more sinks.

#### `core/capture/`

Capture session lifecycle and recording semantics.

Responsibilities:

- model recording lifecycle explicitly;
- coordinate permission readiness, source readiness, sink readiness, and
  session start/stop;
- create capture session ids;
- produce session metadata for manifests;
- surface recoverable and fatal errors.

Minimum state machine:

```text
Idle
RequestingPermission
Ready
Starting
Running
Stopping
Stopped
Error
Recovering
```

The capture state machine should own transitions. Mode scripts should
request transitions, not mutate recording booleans directly.

#### `core/teleop/`

Teleoperation domain logic.

Responsibilities:

- consume pose/controller/hand/input frames;
- apply robot descriptor mappings;
- produce robot command frames;
- enforce teleop-specific frequency, latest-only semantics, and safety
  handoff policy;
- stay independent of the platform device name.

Teleop can use a low-latency fast path while still consuming the same
canonical sensor frame contracts as other modes.

#### `platform/`

Runtime platform abstraction and capability providers.

Responsibilities:

- discover current runtime and available platform plugins;
- expose a capability registry;
- handle platform permissions;
- own vendor-specific plugin calls;
- normalize vendor-specific data into `core/sensors` contracts;
- provide timebase information;
- isolate Quest, Pico, and AndroidXR differences.

The top-level platform object should avoid becoming a large interface.
It should act as a registry for capability providers.

Suggested provider interfaces:

- `PoseProvider`
- `ControllerProvider`
- `HandProvider`
- `CameraProvider`
- `DepthProvider`
- `AudioProvider`
- `BodyProvider`
- `BoundaryProvider`
- `InputProvider`
- `TimebaseProvider`
- `PassthroughProvider`
- `PermissionProvider`

Each provider should expose both capability metadata and a source
factory.

#### `platform/registry/`

Capability registry and platform selection.

Responsibilities:

- load platform adapters in priority order;
- ask each adapter which capabilities are available;
- expose `has_capability`, `provider_for`, and `capabilities`;
- report unsupported capabilities with actionable reasons;
- prevent app code from knowing vendor singleton names.

Capability metadata should include:

- capability id;
- provider id;
- availability state;
- permission state;
- payload format;
- frequency/rate limits;
- coordinate space;
- timestamp source;
- known platform constraints.

#### `sinks/`

Sensor data consumers.

Sinks consume canonical sensor frames. They should not pull data from
platform plugins directly.

Candidate sinks:

- `SpatialMp4Sink`: writes camera/audio/depth/pose/body data into
  spatial MP4 or native muxer contracts.
- `JsonlSidecarSink`: writes debug and replay sidecars.
- `LiveStreamSink`: publishes live frames to a local or remote server.
- `RobotControlSink`: sends commands or low-latency control packets.
- `UploadQueueSink`: owns durable upload queue and resume behavior.
- `MetricsSink`: tracks frame rates, drops, latency, and errors.
- `DebugOverlaySink`: feeds in-headset diagnostic UI.

Each sink should declare:

- accepted frame types;
- ordering requirements;
- backpressure policy;
- durability requirements;
- startup/shutdown behavior;
- error semantics.

#### `contracts/`

Versioned data contracts and validation helpers.

Responsibilities:

- define stable data shapes across module boundaries;
- validate dictionaries received from old code or native plugins;
- version wire/native contracts;
- keep schema migration explicit.

Candidate contract groups:

- `contracts/sensor`: frame schemas and metadata.
- `contracts/platform`: capabilities, provider ids, permission state.
- `contracts/capture`: capture options, session config, manifest.
- `contracts/teleop`: device descriptor, control mappings, command
  frames.
- `contracts/storage`: file layout, sidecar schema, manifest schema.
- `contracts/wire`: TCP/UDP/live-stream protocol DTOs.

Godot can still use dictionaries at dynamic boundaries, but dictionaries
should be parsed into explicit contract objects before entering core
logic.

#### `contracts/features`

Feature ids, feature metadata, and validation rules.

Candidate contracts:

- `OperatorFeatureId`
- `FeatureDefinition`
- `FeatureDependency`
- `FeatureConflict`
- `FeatureAvailability`

Each feature definition should declare:

- stable feature id;
- export option name;
- runtime feature tag;
- default value for new presets;
- owning module;
- optional launcher card mapping;
- required product features;
- conflicting product features;
- required platform capabilities;
- required Android permissions or native libraries when applicable.

Feature ids should be stable and spelled correctly. For example, prefer
`robot_constraint` and `operator_feature_robot_constraint`; do not bake a
misspelling such as `robot_contraint` into permanent contracts. If a
misspelled option has already shipped, keep it only as a temporary alias
inside `contracts/features`.

### Capability-driven mode examples

#### Ego capture mode

```text
EgoCaptureMode
  -> asks platform for CAMERA, POSE, AUDIO, DEPTH, BODY
  -> attaches available providers as sources
  -> creates CaptureSessionController
  -> attaches SpatialMp4Sink, JsonlSidecarSink, UploadQueueSink
  -> starts capture state machine
```

If depth is unavailable, the mode records without depth and writes that
capability absence into the manifest. It does not check whether the
device is Quest, Pico, or AndroidXR.

#### Live feed mode

```text
LiveFeedMode
  -> asks platform for CAMERA, POSE, optional DEPTH
  -> attaches LiveStreamSink
  -> applies low-latency pipeline policy
```

The same camera and pose frame contracts can feed both live streaming
and local recording if both sinks are attached.

#### Teleop mode

```text
TeleopMode
  -> asks platform for POSE, CONTROLLER, HAND, INPUT
  -> loads RobotControlDescriptor
  -> attaches RobotControlSink
  -> applies latest-only low-latency policy
```

Teleop uses the same sensor model but a different sink policy.

## Part 2: feature-based development

This section defines how new product modules are introduced, enabled,
disabled, reviewed, and validated. The source of truth is
`xr/export_presets.cfg`; runtime code consumes those decisions through a
typed `FeatureSet`.

Feature-based development is the rule for optional product behavior in
the Godot XR project:

- every optional mode, sink, workflow, robot-control extension, or
  experimental module must have a named `operator_feature_*` feature;
- every exported APK preset must explicitly enable or disable every
  product feature;
- runtime code must read product features through `app/features`, not
  scattered `OS.has_feature()` calls;
- composition roots use feature flags to decide which product modules to
  wire;
- platform providers use capabilities to decide what the current device
  can actually support;
- a module runs only when the product feature is enabled and the required
  platform capabilities are available.

In short: feature flags decide what this APK is allowed to expose;
platform capabilities decide what this runtime can provide; composition
connects the two.

### Export-preset feature management

`xr/export_presets.cfg` should be the source of truth for product
feature enablement in each exported APK.

The current launcher-card options already follow this pattern:

```text
operator_launcher_card_teleop=false
operator_launcher_card_ego=true
operator_launcher_card_live=false
operator_launcher_card_vr=false
operator_launcher_card_exit=true
```

The v2 architecture should generalize this into module-level product
features:

```text
operator_feature_mode_teleop=false
operator_feature_mode_ego_capture=true
operator_feature_mode_live_feed=false
operator_feature_mode_vr=false
operator_feature_robot_constraint=false
```

Launcher cards become one consumer of the feature system, not the whole
feature system. A mode feature can choose to expose a launcher card, but
some features may be internal modules, sinks, providers, or workflow
extensions with no card.

### Two kinds of export features

Keep platform tags and product features separate.

Platform tags live in Godot's `custom_features` field:

```text
custom_features="quest"
custom_features="pico"
custom_features="glassxr"
```

These tags select platform/export behavior such as vendor plugins,
native libraries, Android manifest additions, and platform adapters.

Product feature options live under each `[preset.N.options]` section:

```text
operator_feature_robot_constraint=true
```

These options decide which Operator modules are enabled in that APK.
They should be converted by an export plugin into runtime feature tags
with the same stable names, then read through `app/features/`.

### Naming convention

Use stable, namespaced option names:

```text
operator_feature_<feature_id>
```

Recommended feature id groups:

```text
mode_teleop
mode_ego_capture
mode_live_feed
mode_vr
sink_spatialmp4
sink_jsonl
sink_live_stream
sink_upload
robot_control
robot_constraint
debug_metrics
experimental_<name>
```

Use `operator_launcher_card_*` only for legacy launcher-card switches or
as a compatibility layer during migration. New module-level features
should use `operator_feature_*`.

### Export plugin shape

Create or extend an Android export plugin that declares feature options
and maps enabled options to Godot runtime feature tags.

Target shape:

```gdscript
@tool
extends EditorPlugin

class OperatorFeaturesExportPlugin:
	extends EditorExportPlugin

	const CONFIGURED_FEATURE := "operator_features_configured"
	const FEATURE_OPTIONS := [
		{
			"id": "mode_ego_capture",
			"option": "operator_feature_mode_ego_capture",
			"default": true,
		},
		{
			"id": "robot_constraint",
			"option": "operator_feature_robot_constraint",
			"default": false,
		},
	]

	func _get_export_options(platform: EditorExportPlatform) -> Array[Dictionary]:
		var options: Array[Dictionary] = []
		for feature in FEATURE_OPTIONS:
			options.append({
				"option": {
					"name": String(feature["option"]),
					"type": TYPE_BOOL,
				},
				"default_value": bool(feature["default"]),
			})
		return options

	func _get_export_features(platform: EditorExportPlatform, debug: bool) -> PackedStringArray:
		var tags := PackedStringArray([CONFIGURED_FEATURE])
		for feature in FEATURE_OPTIONS:
			var option_name := String(feature["option"])
			if bool(get_option(option_name)):
				tags.append(option_name)
		return tags
```

This mirrors the current launcher export plugin pattern but expands it
from cards to product modules.

### Runtime feature access

Runtime code should not scatter raw `OS.has_feature()` checks.

Allowed places:

- `app/features/FeatureSet`;
- composition roots;
- export-aware platform registry code;
- legacy compatibility shims while migrating.

Disallowed places:

- sensor samplers;
- sinks;
- core capture state machines;
- teleop mapping logic;
- UI components other than launcher/card composition.

Target access pattern:

```gdscript
var features := FeatureSet.from_export_tags()

if features.enabled(OperatorFeature.MODE_EGO_CAPTURE):
	mode_registry.register(EgoCaptureModeDefinition.new())

if features.enabled(OperatorFeature.ROBOT_CONSTRAINT):
	teleop_composition.enable_robot_constraint()
```

`FeatureSet` should also expose a clear fallback when the app runs in the
Godot editor and `operator_features_configured` is absent. Editor
fallbacks should be local developer defaults, not silently assumed
release behavior.

### Feature definition contract

Each feature should have a single definition in `contracts/features`.

Example:

```text
id: robot_constraint
option: operator_feature_robot_constraint
runtime_tag: operator_feature_robot_constraint
default: false
owner: core/teleop
requires_features:
  - robot_control
requires_capabilities:
  - ROBOT_CONTROL
conflicts: []
launcher_card: null
```

The feature definition is the place to describe dependencies. The
export preset is the place to choose enabled/disabled for a concrete
APK.

### Example: adding `robot_constraint`

Adding a new `robot_constraint` feature should follow this flow:

1. Add a feature definition in `contracts/features`.
2. Add `operator_feature_robot_constraint` to the feature export plugin
   option list, with a conservative default.
3. Update every Android preset in `xr/export_presets.cfg` with an
   explicit value:

```text
[preset.0.options]
operator_feature_robot_constraint=false

[preset.1.options]
operator_feature_robot_constraint=false

[preset.2.options]
operator_feature_robot_constraint=false
```

4. Register the module only from composition code:

```gdscript
if features.enabled(OperatorFeature.ROBOT_CONSTRAINT):
	teleop_composition.attach_robot_constraint()
```

5. If the module needs runtime support, guard it with platform
   capabilities:

```gdscript
if features.enabled(OperatorFeature.ROBOT_CONSTRAINT) \
		and platform.has_capability(SensorCapability.ROBOT_CONTROL):
	teleop_composition.attach_robot_constraint()
```

6. If the module requires native libraries, Android permissions, or
   manifest entries, make the relevant export plugin include those only
   when the export feature is enabled.
7. Add a preset matrix entry to the build documentation that states
   which presets enable the feature.

### Launcher-card migration

Launcher cards should eventually be derived from mode features.

Migration path:

```text
operator_launcher_card_ego
  -> operator_feature_mode_ego_capture

operator_launcher_card_teleop
  -> operator_feature_mode_teleop

operator_launcher_card_live
  -> operator_feature_mode_live_feed

operator_launcher_card_vr
  -> operator_feature_mode_vr
```

During migration, `FeatureSet` can accept both the old card tag and the
new mode feature tag. New code should depend on the new
`operator_feature_*` names.

### Preset discipline

Every preset must set every product feature explicitly. Do not rely on
export-plugin defaults after a feature has been committed.

This makes product variants reviewable in diffs. A reviewer should be
able to open `xr/export_presets.cfg` and answer:

- which modes appear in the launcher;
- which sinks are compiled/enabled;
- which robot-control extensions are enabled;
- which experimental modules are present;
- which features differ between Quest, Pico, and AndroidXR builds.

### Validation

Add a lightweight validation script or editor check with these rules:

- every `operator_feature_*` declared by the feature export plugin is
  present in every Android preset;
- no unknown `operator_feature_*` option exists in `export_presets.cfg`;
- required feature dependencies are enabled together;
- conflicting features are not enabled together;
- features that require platform tags are only enabled on compatible
  presets;
- launcher cards reference enabled mode features.

Validation should run before release builds and in CI. It does not need
an XR runtime because it only parses `export_presets.cfg` and feature
definitions.

### Relationship to platform capabilities

Feature flags are build/product decisions. Platform capabilities are
runtime/device decisions.

Both are required:

```text
feature enabled + capability available      -> module can run
feature enabled + capability unavailable    -> show unavailable/degraded state
feature disabled + capability available     -> module stays hidden/off
feature disabled + capability unavailable   -> module stays hidden/off
```

This rule keeps platform providers focused on what the device can do and
keeps export presets focused on what the APK is allowed to expose.

## Supporting material

The sections below support the two core rules above. They are not a
third architectural axis: platform capabilities support module
boundaries, while migration and success criteria support the
feature-based development workflow.

### Platform capability model

Capabilities should be explicit values rather than ad-hoc strings spread
through the app.

Example capability set:

```text
POSE
CONTROLLER
HAND_TRACKING
BODY_TRACKING
CAMERA_RGB
CAMERA_STEREO
DEPTH_MAP
AUDIO_CAPTURE
PASSTHROUGH
BOUNDARY
HAPTICS
OPENXR_TIMEBASE
ANDROID_CAMERA_TIMEBASE
SPATIAL_MP4_MUX
LIVE_STREAM_SERVER
```

Availability states:

```text
Unavailable
Available
RequiresPermission
PermissionDenied
RequiresRuntimeExtension
RequiresBuildFeature
TemporarilyUnavailable
Error
```

This lets app code make capability decisions without importing platform
names.

### Android/native boundary

Android plugins should expose narrow provider and sink contracts rather
than large mode-specific APIs.

Target shape:

- vendor capture plugins expose capability providers;
- muxer plugins expose sink contracts;
- live-feed plugins expose sink contracts;
- shared hot-path contracts stay in `android_plugin/contract`;
- Godot wrappers convert native data into `contracts/` and
  `core/sensors` objects.

Vendor plugins can remain platform-specific internally. The important
rule is that platform-specific names do not escape into `core/`,
`sinks/`, or `app/modes/`.

### Migration strategy

Refactoring should be incremental.

#### Phase 1: introduce feature contracts and export-preset registry

- Define `OperatorFeatureId`, `FeatureDefinition`, and `FeatureSet`.
- Add `operator_feature_*` export options through an export plugin.
- Make every Android preset in `xr/export_presets.cfg` set every
  product feature explicitly.
- Keep existing `operator_launcher_card_*` options as compatibility
  inputs while mode features are introduced.
- Add validation for preset/feature drift.

#### Phase 2: introduce contracts and platform facade

- Define `PlatformCapabilities`, `CapabilityState`, and provider ids.
- Wrap Quest/Pico plugin access behind platform providers.
- Replace direct plugin singleton calls in mode scripts with provider
  calls.
- Preserve current behavior.

#### Phase 3: extract capture session lifecycle

- Move recording booleans into `CaptureSessionController`.
- Introduce explicit capture states.
- Keep current writer and sampler implementations behind adapters.

#### Phase 4: normalize sensor frames

- Introduce canonical frame contracts for pose, depth, body, camera, and
  audio.
- Make existing samplers emit these contracts.
- Keep existing sinks working through adapter shims.

#### Phase 5: split sinks

- Extract `SpatialMp4Sink`, `JsonlSidecarSink`, `LiveStreamSink`,
  `RobotControlSink`, and `UploadQueueSink`.
- Move manifest and file layout contracts into `contracts/storage`.

#### Phase 6: make modes composition-only

- Reduce large mode scripts to scene lifecycle and composition.
- Move business workflows into core controllers and sinks.
- Remove device-name checks outside `platform/`.

#### Phase 7: add AndroidXR as a capability provider

- Implement AndroidXR providers by capability.
- Add build and export verification for Quest, Pico, and AndroidXR.
- Treat missing capabilities as normal runtime states, not errors.

### Non-goals

- This architecture does not require all modes to share the same latency
  policy.
- This architecture does not hide platform differences inside a fake
  lowest-common-denominator API.
- This architecture does not require all contracts to be heavy classes
  immediately. Dynamic dictionaries can remain at boundaries if they are
  validated and converted before entering core logic.
- This architecture does not require a big-bang rewrite.

### Architectural success criteria

The v2 architecture is working when:

- adding a new platform only changes `platform/` and build/export files;
- adding a new sink does not change platform providers;
- adding a new mode mostly changes `app/modes/` and composition code;
- adding a new product feature requires one feature definition, one
  export-plugin option, and explicit preset values, not scattered
  `OS.has_feature()` checks;
- core sensor contracts are reused by recording, live streaming, and
  teleoperation;
- app code asks for capabilities, not device names;
- app code asks `FeatureSet` for product features, not raw export tags;
- `xr/export_presets.cfg` makes product variants reviewable in diffs;
- capture lifecycle transitions are visible and testable;
- storage manifests describe available and missing capabilities
  explicitly;
- current Quest/Pico behavior remains compatible while AndroidXR can be
  added without duplicating mode logic.
