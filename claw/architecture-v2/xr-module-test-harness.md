# XR module test harness

Status: target architecture.

This document defines how Godot XR modules expose automated testing
interfaces. It builds on
`claw/architecture-v2/xr-client-top-level-modules.md`.

The core rule is:

Every feature and every top-level module must expose a stable automation
surface that can be driven by tests without reaching into private scene
internals.

The goal is not to make every private function directly callable from a
test. The goal is that every product behavior can be exercised through a
module-level test driver, deterministic fixtures, fake dependencies, and
observable snapshots.

## Why this exists

Current XR tests are mostly end-to-end shell scripts. They are valuable,
but they are expensive, device-dependent, and often verify behavior only
after the whole APK has been built, installed, launched, and driven by
logcat or generated files.

The v2 module architecture needs a lower-level test harness so that:

- `core/` behavior can be tested without a real headset;
- `platform/` behavior can be tested with fake and real capability
  providers;
- `sinks/` can be tested with deterministic frames;
- `app/modes/` can be tested by composition rather than UI clicks;
- feature flags can be tested against `xr/export_presets.cfg`;
- device e2e tests become the final verification layer, not the only
  verification layer.

## Design principles

### Test through public automation ports

Tests should drive modules through explicit automation APIs. They should
not depend on private node paths, incidental scene names, or internal
boolean fields.

Each module should provide a `ModuleTestDriver` or equivalent adapter
that supports:

- setup with a fixture;
- explicit commands;
- deterministic stepping;
- snapshot inspection;
- invariant checks;
- teardown.

### Feature-based testing

Every `operator_feature_*` feature should have test coverage attached to
its feature definition.

Tests should prove:

- the feature exists in the feature registry;
- every Android export preset explicitly enables or disables it;
- enabled features are composed into the app;
- disabled features are absent;
- missing platform capabilities produce a degraded or unavailable state,
  not a crash;
- required feature dependencies and conflicts are validated.

### Capability-driven testing

Tests must separate product feature flags from runtime platform
capabilities.

Feature flags answer: "Is this module allowed in this APK?"

Platform capabilities answer: "Can this device/runtime provide the
required data or service?"

The test harness must support both fake capabilities and real device
capabilities.

### Deterministic inputs first

Most tests should use deterministic fake sources:

- fixed pose streams;
- fixed controller input;
- fixed hand/body frames;
- synthetic RGB/depth/audio frames;
- deterministic clocks;
- fake network peers;
- fake storage roots.

Real devices should be used for platform conformance and end-to-end
coverage, not for every module test.

### No desktop OpenXR runtime dependency

Do not use the production XR scene or desktop `godot --headless` as a
substitute for Android XR runtime testing.

Pure contract/static tests can run as normal host-side scripts. Godot
module tests that need Nodes should run either:

- inside a dedicated non-XR test runner scene that does not initialize
  OpenXR; or
- inside an Android test APK launched on a headset.

Anything that depends on OpenXR session state, passthrough, headset
sensors, Android permissions, or vendor plugins is a device test.

## Target layout

Testing code should be split into three layers:

1. Godot-side reusable test runtime under `xr/scripts/test_support/`.
2. Godot-side test cases and fixtures under `xr/tests/`.
3. Repository-level orchestration under root `tests/`.

The proposed folder structure is:

```text
xr/
  scripts/
    test_support/
      runner/
        test_runner.gd
        test_registry.gd
        test_reporter.gd
        test_assertions.gd
        test_clock.gd
      contracts/
        test_case.gd
        test_result.gd
        test_manifest.gd
        module_test_driver.gd
        test_failure.gd
      drivers/
        module_test_driver.gd
        mode_test_driver.gd
        capture_test_driver.gd
        pipeline_test_driver.gd
        teleop_test_driver.gd
      fakes/
        platform/
          fake_platform_runtime.gd
          fake_capability_registry.gd
          fake_permission_provider.gd
        sensors/
          fake_pose_provider.gd
          fake_controller_provider.gd
          fake_camera_provider.gd
          fake_depth_provider.gd
          fake_audio_provider.gd
          fake_body_provider.gd
        sinks/
          recording_sink.gd
          null_sink.gd
          failing_sink.gd
          slow_sink.gd
          fake_live_stream_sink.gd
          fake_robot_control_sink.gd
        network/
          fake_robot_peer.gd
          fake_live_feed_server.gd
        storage/
          temp_storage_root.gd
          in_memory_file_store.gd
  tests/
    manifests/
      features/
      modules/
    fixtures/
      sensors/
      platform/
      teleop/
      capture/
      pipeline/
      storage/
    unit/
      contracts/
      features/
      sensors/
      pipeline/
      capture/
      teleop/
    integration/
      modes/
      sinks/
      platform/
      capture/
      teleop/
    feature/
      mode_teleop/
      mode_ego_capture/
      mode_live_feed/
      robot_constraint/
    device/
      quest/
      pico/
      androidxr/

tests/
  xr_module_harness.sh
  validate_xr_features.py
  validate_xr_test_manifests.py
  01_rtsp_test.sh
  02_ego_record.sh
  03_live_feed_e2e.sh
  03_godot_mujoco_static.sh
  03_godot_mujoco_device.sh
```

Exact paths can be adapted to Godot's loading constraints. The
architectural rule is that tests consume the same contracts as
production modules.

### Folder ownership

`xr/scripts/test_support/` contains reusable test runtime code that may
be loaded by a test APK or by a non-XR Godot test runner.

It owns:

- test runner and registry;
- assertion and reporting helpers;
- module test driver base classes;
- fake platform providers;
- fake sensor providers;
- fake sinks;
- fake network/storage dependencies.

It must not contain product behavior. Production modules may define
automation ports, but they should not depend on `test_support`.

`xr/tests/` contains Godot-side test data and test cases.

It owns:

- feature test manifests;
- module test manifests;
- deterministic fixtures;
- unit tests for contracts and pure logic;
- integration tests using fake platform providers and fake sinks;
- device test case definitions consumed by Android test APKs.

It should not contain reusable harness infrastructure. Shared test
runtime belongs in `xr/scripts/test_support/`.

Root `tests/` contains repository-level orchestration.

It owns:

- shell entry points;
- Python/static validators;
- adb orchestration;
- CI glue;
- host-side package checks;
- full workflow e2e scripts.

It should not contain Godot module assertions that would be better
expressed as `xr/tests/` test cases.

### Packaging rules

Production APKs must not include `xr/tests/**`.

Production APKs should not include `xr/scripts/test_support/**` unless a
small shared test-support contract is intentionally reused by a debug
build. The default should be exclusion from production exports.

Test APKs may include both:

```text
xr/scripts/test_support/**
xr/tests/**
```

Test APK behavior must be gated by:

```text
operator_feature_test_harness=true
```

Production presets must set:

```text
operator_feature_test_harness=false
```

The app should enter test mode only when the feature is enabled and an
explicit test suite/case is requested. A test-enabled APK should still
launch normally when no test request is provided.

### Naming rules

Test files should mirror module or feature ids.

Examples:

```text
xr/tests/unit/capture/capture_state_machine_test.gd
xr/tests/integration/pipeline/pipeline_backpressure_test.gd
xr/tests/feature/robot_constraint/robot_constraint_manifest.tres
xr/tests/device/quest/camera_depth_capability_smoke_test.gd
```

Feature directories should use the same ids as `operator_feature_*`
without the prefix. For example,
`operator_feature_robot_constraint` maps to
`xr/tests/feature/robot_constraint/`.

## Test levels

### Level 0: static validation

Runs on the host without Godot runtime or headset.

Scope:

- parse `xr/export_presets.cfg`;
- validate `operator_feature_*` options;
- validate feature dependencies and conflicts;
- validate test manifests;
- validate addon export plugin declarations;
- validate package contents after APK build.

Examples:

- every feature declared in the export plugin appears in every Android
  preset;
- no unknown `operator_feature_*` appears in `export_presets.cfg`;
- every feature has at least one test manifest;
- production presets do not enable `operator_feature_test_harness`;
- APK contains native libraries only when required features/platform
  tags are enabled.

### Level 1: contract tests

Runs on the host or in a non-XR Godot test runner.

Scope:

- DTO validation;
- sensor frame schemas;
- timestamp and coordinate-space conversions;
- feature registry logic;
- protocol codecs;
- capture/session config parsing;
- manifest generation;
- pure state machines.

These tests should avoid Android, OpenXR, and scene tree dependencies
where possible.

### Level 2: module integration tests with fakes

Runs in a controlled Godot runner with fake platform providers and fake
sinks.

Scope:

- pipeline fanout and backpressure;
- capture lifecycle with fake sources and fake sinks;
- teleop mapping from synthetic controller/pose frames to command
  frames;
- mode composition under feature/capability combinations;
- UI command routing through automation ids;
- uploader queue behavior against a fake server.

These tests should not require a real headset. They should also not
initialize the production OpenXR scene.

### Level 3: Android plugin and native contract tests

Runs as JVM/native tests where possible, or inside a test APK when
Android framework APIs are required.

Scope:

- Kotlin contract adapters;
- manifest and permission behavior;
- native muxer wrapper contracts;
- encoder/session configuration serialization;
- plugin method availability;
- hot-path data sink contract compatibility.

These tests validate Android-side modules without driving full user
workflows.

### Level 4: headset device tests

Runs on Quest, Pico, AndroidXR, or other supported Android XR devices.

Scope:

- real platform capability discovery;
- permission request/result behavior;
- OpenXR timebase availability;
- real camera/depth/audio/body providers;
- native plugin loading;
- platform-specific sinks;
- feature behavior in a real exported APK.

Device tests should emit machine-readable results and logcat markers.
They should not require humans to inspect the headset UI.

### Level 5: end-to-end workflow tests

Runs full APK workflows with shell orchestration.

Existing tests such as ego recording, live feed, RTSP, and MuJoCo device
tests belong here.

Scope:

- build/install/launch;
- adb reverse;
- robot or cloud service integration;
- output files and manifests;
- final MP4 or dataset validation;
- logcat-level pass/fail markers.

These tests verify that the whole system works. They should not be the
only place where module logic is tested.

## Module automation contract

Every testable module should expose a test driver. The driver can be a
real class, a RefCounted adapter, or a scene-local wrapper, but it should
follow this shape:

```gdscript
class_name ModuleTestDriver
extends RefCounted

func module_id() -> String:
	return ""

func supported_cases() -> Array:
	return []

func setup(fixture: Dictionary) -> Dictionary:
	return {}

func command(name: String, args: Dictionary = {}) -> Dictionary:
	return {}

func step(delta_s: float, ticks: int = 1) -> Dictionary:
	return {}

func snapshot() -> Dictionary:
	return {}

func assert_invariants() -> Array:
	return []

func teardown() -> void:
	pass
```

Return values should be dictionaries that conform to
`contracts/test/TestResult`. Failures should be structured, not only log
strings.

### Commands

Commands are the automation equivalent of user or system intent.

Examples:

```text
start_capture
stop_capture
grant_permission
deny_permission
inject_pose_frame
inject_depth_frame
inject_controller_input
connect_fake_robot
disconnect_fake_robot
start_upload
tick_pipeline
```

Commands should be stable. Tests should not call private helper methods.

### Snapshots

Snapshots are structured observable state.

Examples:

```text
capture_state
active_sources
active_sinks
frames_received
frames_dropped
last_error
last_command
manifest_preview
feature_set
capability_set
ui_visible_actions
```

Snapshots should avoid exposing internal implementation fields unless
they are part of the module's public behavior.

### Invariants

Each module should define invariants that can be checked after commands
or at teardown.

Examples:

- no sink receives a frame type it did not declare;
- frame timestamps are monotonic per stream;
- disabled features are not composed;
- capture cannot transition from `Idle` directly to `Running`;
- teleop command output never references unmapped controls;
- uploader never drops a completed local session before successful
  acknowledgement.

## Feature test manifest

Every feature should provide a test manifest. This ties the
feature-based development model to test coverage.

Example:

```text
id: robot_constraint
feature: operator_feature_robot_constraint
owner: core/teleop
required_features:
  - operator_feature_robot_control
required_capabilities:
  - ROBOT_CONTROL
test_cases:
  - id: robot_constraint.disabled_not_composed
    level: static
    preset_matrix: true
  - id: robot_constraint.enabled_without_capability
    level: integration
    fixture: fake_platform_without_robot_control
  - id: robot_constraint.enabled_with_capability
    level: integration
    fixture: fake_robot_control_platform
  - id: robot_constraint.device_smoke
    level: device
    required_device: quest_or_pico
```

The test manifest is not just documentation. Validation should fail if a
feature has no test manifest or if a manifest references unknown
features/capabilities.

## Harness registry

The test harness should have a central registry:

```text
TestRegistry
  -> feature definitions
  -> test manifests
  -> module test drivers
  -> fixture providers
  -> fake platform providers
  -> reporters
```

Responsibilities:

- list all available tests;
- filter tests by feature, module, level, platform, and capability;
- construct test fixtures;
- create module drivers;
- run test cases;
- aggregate structured results.

The registry should be data-driven so new modules do not require editing
a giant runner script.

## Fixtures

Fixtures describe deterministic input worlds.

Fixture examples:

```text
fake_platform_quest_like
fake_platform_pico_like
fake_platform_without_depth
fake_platform_with_depth_and_audio
synthetic_walk_pose_stream
synthetic_controller_grip_sequence
synthetic_depth_plane
fake_robot_descriptor_so101
fake_live_feed_server
temp_storage_root
```

Fixtures should be versioned when they become part of regression tests.
Generated data should include seeds.

## Fake platform providers

The fake platform layer is the most important piece of the harness.

It should implement the same provider contracts as real `platform/`
adapters:

- `PoseProvider`
- `ControllerProvider`
- `CameraProvider`
- `DepthProvider`
- `AudioProvider`
- `BodyProvider`
- `PermissionProvider`
- `TimebaseProvider`
- `PassthroughProvider`

A fake provider should be able to:

- declare capabilities;
- change capability availability during a test;
- emit deterministic sensor frames;
- simulate permission grant/deny;
- simulate source disconnect/reconnect;
- simulate timestamp drift;
- simulate provider errors.

This lets module tests cover capability behavior without checking device
names.

## Fake sinks

Fake sinks should consume real sensor frame contracts and expose
snapshots.

Examples:

- `RecordingSink`: records received frames in memory.
- `NullSink`: accepts frames and reports counts.
- `FailingSink`: fails after N frames.
- `SlowSink`: exercises backpressure.
- `FakeRobotControlSink`: stores emitted robot command frames.
- `FakeLiveStreamSink`: simulates network ack, timeout, and disconnect.

The fake sink contract should match production sink expectations:
accepted frame types, ordering requirements, durability, and error
semantics.

## Test runner modes

### Host static runner

Use shell/Python for static validation that does not need Godot runtime.

Examples:

```text
tests/validate_xr_features.py
tests/validate_xr_test_manifests.py
tests/03_godot_mujoco_static.sh
```

### Non-XR Godot runner

Use a dedicated test scene that does not start OpenXR. This runner is for
Node-level module tests that need Godot objects but not headset runtime.

Rules:

- do not instantiate the production XR root scene;
- do not start `StartXR`;
- use fake platform providers;
- use deterministic clocks;
- emit JSON results.

If this cannot be kept free of XR runtime assumptions, run the case as an
Android device test instead.

### Android test APK runner

Build an APK with a test harness feature:

```text
operator_feature_test_harness=true
```

Production presets must set this feature to `false`.

The app should enter test mode only when both are true:

- the APK contains `operator_feature_test_harness`;
- a test suite/case is explicitly requested through command-line args,
  Android intent extras, or debug properties.

Example launch shape:

```text
adb shell am start \
  -n com.lovemoon.operator/com.godot.game.GodotApp \
  --es operator_test_suite capture.pipeline \
  --es operator_test_case capture.start_stop_with_fake_sources
```

The runner should write:

- machine-readable JSON under app-private storage;
- concise logcat markers:

```text
OPERATOR_TEST_START suite=capture.pipeline case=capture.start_stop
OPERATOR_TEST_PASS suite=capture.pipeline case=capture.start_stop
OPERATOR_TEST_FAIL suite=capture.pipeline case=capture.start_stop reason=...
```

## Test lifecycle

Each harness test follows the same lifecycle:

```text
select suite/case
load feature definitions
load test manifest
load fixture
create FeatureSet
create fake or real PlatformRuntime
create composition root
create module driver
setup
run commands and deterministic steps
collect snapshots
assert expected results
assert module invariants
teardown
write report
```

Tests should fail fast on setup errors, but teardown must still run to
clean storage, network ports, and platform hooks.

## Reports

All runners should produce a shared result schema:

```text
suite_id
case_id
module_id
feature_ids
level
status
duration_ms
device_kind
preset_name
capabilities
fixture_id
failures
artifacts
logs
```

This makes host tests, Godot module tests, Android plugin tests, and
device e2e tests comparable in CI.

## Module coverage requirements

### `app/features`

Required tests:

- parse enabled feature tags;
- handle missing `operator_features_configured` in editor/dev mode;
- validate dependencies and conflicts;
- validate every preset explicitly sets every feature;
- verify launcher-card compatibility aliases during migration.

### `app/modes`

Required tests:

- mode is registered only when its feature is enabled;
- mode requests required capabilities;
- missing capabilities produce unavailable/degraded state;
- mode composition does not call vendor plugin singletons directly.

### `core/sensors`

Required tests:

- frame schema validation;
- timestamp monotonicity;
- coordinate-space presence;
- source id and capability id presence;
- invalid frames rejected before entering sinks.

### `core/pipeline`

Required tests:

- route by frame type and stream id;
- fan out to multiple sinks;
- drop-old and drop-new policies;
- slow sink backpressure;
- sink failure isolation;
- detach source/sink during running pipeline.

### `core/capture`

Required tests:

- all legal state transitions;
- illegal transition rejection;
- permission grant/deny flows;
- source unavailable at start;
- sink failure during recording;
- manifest metadata for available and missing capabilities;
- deterministic start/stop without real platform providers.

### `core/teleop`

Required tests:

- descriptor parsing;
- input mapping;
- pose/control command output;
- latest-only behavior;
- robot constraint feature gating;
- safety handoff semantics;
- no device-name branching.

### `platform`

Required tests:

- fake capability registry;
- Quest/Pico/AndroidXR provider registration;
- missing plugin behavior;
- permission state transitions;
- provider error reporting;
- real device capability snapshot smoke tests.

### `sinks`

Required tests:

- accepted/rejected frame types;
- ordering requirements;
- backpressure behavior;
- error semantics;
- durable file layout where applicable;
- fake sink conformance to sink contract.

### `contracts`

Required tests:

- schema parsing;
- version compatibility;
- missing/unknown field behavior;
- serialization round trips;
- manifest and wire DTO compatibility.

### UI

UI modules should expose automation ids and command-level drivers.

Required tests:

- visible actions match enabled features;
- disabled features do not appear;
- command routing works without XR pointer hardware;
- UI state reflects module snapshots;
- no test depends on pixel coordinates unless it is explicitly a visual
  regression test.

## Feature development workflow

When adding a new feature:

1. Add the `operator_feature_*` definition.
2. Add explicit values for every Android preset.
3. Add a test manifest for the feature.
4. Add or extend module test drivers.
5. Add fake providers/sinks needed by the tests.
6. Add at least one static or contract test.
7. Add an integration test for enabled/disabled behavior.
8. Add a device test if the feature depends on real platform APIs.
9. Add e2e coverage only when the feature changes a full user workflow.

The feature is not complete until its automation surface exists.

## Relationship to existing tests

Existing shell tests should be kept and gradually moved to the top of
the test pyramid:

- `tests/01_rtsp_test.sh`: workflow e2e for video/robot side.
- `tests/02_ego_record.sh`: workflow e2e for ego capture.
- `tests/03_live_feed_e2e.sh`: workflow e2e for live feed.
- `tests/03_godot_mujoco_static.sh`: static/package validation.
- `tests/03_godot_mujoco_device.sh`: device e2e for MuJoCo.

New module tests should reduce the amount of behavior that only these
scripts can verify.

## CI strategy

Recommended CI stages:

```text
static
  -> feature/preset validation
  -> test manifest validation
  -> package validation when APK exists

contract
  -> schema and pure state-machine tests

module
  -> fake platform/fake sink Godot module tests

android-plugin
  -> JVM/native plugin tests

device-smoke
  -> selected headset tests

e2e
  -> full workflow tests
```

The default PR path should run static, contract, and module tests. Device
and e2e tests can run on scheduled, release, or hardware-backed CI.

## Non-goals

- The harness does not require every private helper function to be
  exposed.
- The harness does not replace full headset e2e tests.
- The harness does not fake platform behavior for final conformance.
- The harness does not rely on desktop OpenXR for XR runtime behavior.
- The harness does not make tests depend on incidental scene tree
  layout.

## Success criteria

The test harness architecture is working when:

- every `operator_feature_*` feature has a test manifest;
- every top-level module exposes an automation driver or declares why it
  is purely passive;
- feature-disabled behavior is tested for every optional module;
- fake platform providers can exercise core flows without a headset;
- real platform providers can report capability snapshots on device;
- capture, teleop, pipeline, and sink logic can be tested before APK e2e;
- device tests emit structured JSON results and logcat pass/fail markers;
- adding a new feature requires updating tests as part of the normal
  development workflow.
