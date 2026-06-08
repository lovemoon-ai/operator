# RFC 003: Godot MuJoCo Addon for Standalone VR Robot Data Collection

- Status: Draft
- Date: 2026-06-08
- Target Engine: Godot 4
- Physics Engine: MuJoCo native
- Target Devices: Meta Quest and PICO standalone VR headsets
- Primary Use Case: VR teleoperation data collection for mobile manipulators
- Dataset Target: LeRobot dataset format

## 1. Context

This RFC proposes a product-oriented Godot addon that embeds MuJoCo as the authoritative physics simulation engine for standalone Android VR headsets. The goal is to let users run physically realistic mobile manipulator simulation scenes inside Godot, interact with those scenes through VR teleoperation, and collect robot training datasets locally on-device.

The immediate objective is to build a solid simulation plugin first. The longer-term product objective is a robot data collection tool. This means the early milestones should prioritize runtime stability, Godot integration, MuJoCo correctness, and Android VR deployment before expanding into richer dataset workflows.

The target deployment must support both Quest and PICO devices and must not depend on a desktop simulator at runtime. All simulation, rendering, VR input, and recording should run inside the headset application.

## 2. Decisions

- First target devices: Quest and PICO standalone VR headsets.
- First robot class: mobile manipulator.
- Primary control mode: VR teleoperation.
- Required observation modalities: state, RGB, depth, segmentation, contact, and force.
- Dataset format: LeRobot dataset format.
- URDF import: implemented inside the addon.
- Authoring scope: import MJCF and URDF only; no full Godot scene-to-MJCF authoring for v1.
- Product direction: build the simulation plugin first, then build the data collection product on top.

## 3. Design Principles

- MuJoCo owns physical truth.
- Godot owns product experience, VR interaction, rendering, UI, visualization, and import workflows.
- Native code owns determinism, stepping, snapshots, and performance-critical paths.
- Godot scripts should call high-level APIs, not manipulate MuJoCo arrays directly.
- Simulation frame rate and VR render frame rate must be decoupled.
- Quest and PICO compatibility must be considered from the first runtime milestone.
- Dataset quality, replayability, and validation are first-class product concerns, but they should not destabilize the initial simulation plugin scope.
- v1 should import MJCF and URDF rather than attempting full visual scene authoring in Godot.

## 4. Reference Architecture

```text
Godot Application
│
├── Godot MuJoCo Addon
│   │
│   ├── Import Layer
│   │   ├── MJCF importer
│   │   ├── URDF importer
│   │   ├── Robot asset registry
│   │   ├── Visual mesh mapping
│   │   └── Collision asset mapping
│   │
│   ├── Runtime Layer
│   │   ├── MjWorld
│   │   ├── MjSimulation
│   │   ├── MjRobot
│   │   ├── MjBodyTracker
│   │   ├── MjJointState
│   │   ├── MjActuatorControl
│   │   └── Transform sync
│   │
│   ├── VR Teleoperation Layer
│   │   ├── OpenXR controller bridge
│   │   ├── Headset pose bridge
│   │   ├── Mocap target bridge
│   │   ├── Mobile base teleop mapper
│   │   ├── Arm teleop mapper
│   │   ├── Gripper / grasp bridge
│   │   └── Haptics bridge
│   │
│   ├── Sensor and Observation Layer
│   │   ├── State sampler
│   │   ├── RGB camera capture
│   │   ├── Depth capture
│   │   ├── Segmentation capture
│   │   ├── Contact sampler
│   │   ├── Force sampler
│   │   └── Timestamp alignment
│   │
│   ├── Dataset Layer
│   │   ├── Episode manager
│   │   ├── LeRobot writer
│   │   ├── Replay player
│   │   ├── Dataset validator
│   │   └── Export tools
│   │
│   └── Developer Tools
│       ├── Profiler
│       ├── Model inspector
│       ├── Contact viewer
│       ├── Sensor preview
│       └── Native log viewer
│
├── Native Simulation Core
│   ├── MuJoCo C/C++ wrapper
│   ├── mjModel / mjData lifecycle
│   ├── Fixed-step simulation
│   ├── Control / mocap / force APIs
│   ├── Sensor / contact queries
│   ├── Snapshot / restore
│   └── Deterministic reset
│
└── Android VR Runtime
    ├── Quest runtime compatibility
    ├── PICO runtime compatibility
    ├── arm64-v8a native libraries
    ├── Asset unpacking / VFS
    ├── Simulation thread
    ├── Sensor capture thread
    ├── Recorder thread
    ├── Thermal / performance monitoring
    └── Crash / log collection
```

## 5. Scope

### 5.1 In Scope for v1

- Native MuJoCo runtime inside a Godot Android VR application.
- Quest and PICO support.
- MJCF import.
- URDF import inside the addon.
- Mobile manipulator runtime support.
- VR teleoperation for base, arm, and gripper control.
- Observation capture for state, RGB, depth, segmentation, contact, and force.
- LeRobot dataset writer.
- Episode replay and dataset validation.
- Performance profiling and device stability checks.

### 5.2 Out of Scope for v1

- Full Godot scene-to-MJCF authoring.
- Full MJCF feature coverage.
- On-device robot policy training.
- Desktop-hosted runtime simulation.
- General-purpose game physics replacement.
- Soft-body or deformable simulation.
- Cloud dataset management.

## 6. Milestones

### Milestone 0: Android Native MuJoCo Validation

Goal: verify that MuJoCo native can run reliably on both Quest and PICO.

Core modules:

- `mujoco_native_core`
- Android `arm64-v8a` build pipeline
- Minimal Godot `GDExtension`
- Device smoke-test scene

Scope:

- Build and package MuJoCo native libraries for Android.
- Load a built-in MJCF model from app storage.
- Run `mj_step` in a native simulation loop.
- Read body transforms and expose them to Godot.
- Render primitive visual proxies in Godot.
- Collect basic metrics: step time, FPS, memory, temperature where available.

Acceptance criteria:

- Runs inside Quest and PICO APKs without desktop dependency.
- Runs continuously for at least 10 minutes on both device families.
- Simulation step and VR render loop are decoupled.
- Native library load, model load, step, reset, and release paths are validated.

Out of scope:

- Robot import.
- Dataset recording.
- VR teleoperation.
- Full sensor capture.

### Milestone 1: Runtime Bridge MVP

Goal: provide stable Godot runtime APIs for loading, stepping, controlling, and visualizing MuJoCo simulations.

Core modules:

- `MjWorld`
- `MjSimulation`
- `MjModelResource`
- `MjBodyTracker`
- `MjJointState`
- `MjActuatorControl`

Scope:

- Load MJCF from Godot resources or app storage.
- Start, pause, reset, and step simulation.
- Query body poses, joint positions, joint velocities, actuator states, and simulation time.
- Set actuator controls.
- Sync selected MuJoCo bodies to Godot `Node3D` visual nodes.
- Provide a minimal debug overlay for simulation status.

Acceptance criteria:

- A simple articulated robot can be controlled from Godot.
- Godot visuals follow MuJoCo state reliably.
- Godot scripts interact with high-level addon APIs, not raw MuJoCo memory.
- Runtime behavior is consistent on Quest and PICO.

Out of scope:

- URDF import.
- LeRobot export.
- Advanced VR teleoperation.

### Milestone 2: Mobile Manipulator Import Pipeline

Goal: support realistic mobile manipulator models through MJCF and URDF import.

Core modules:

- `MjRobotImporter`
- `MjMJCFImporter`
- `MjURDFImporter`
- `MjAssetRegistry`
- `MjMeshPipeline`
- `MjCollisionMapper`
- `MjRobotProfile`

Scope:

- Import MJCF robots as first-class simulation assets.
- Import URDF inside the addon and convert or compile it into MuJoCo-compatible assets.
- Generate Godot visual hierarchy from robot assets.
- Preserve stable IDs for bodies, joints, geoms, actuators, sensors, and visual nodes.
- Separate visual meshes from collision geometry.
- Support mobile base, arm, and gripper conventions.
- Package robot assets reliably inside Android APK or app storage.

Acceptance criteria:

- A mobile manipulator model can be imported from MJCF.
- A mobile manipulator model can be imported from URDF.
- Imported models simulate stably on Quest and PICO under a constrained scene.
- Body, joint, actuator, and visual IDs are stable across runs.

Out of scope:

- Full CAD import.
- Full MJCF authoring in Godot.
- Arbitrary high-poly mesh collision as default.

### Milestone 3: VR Teleoperation MVP

Goal: route VR input into MuJoCo controls for mobile manipulator data collection.

Core modules:

- `MjVRControllerBridge`
- `MjTeleopRig`
- `MjMobileBaseTeleop`
- `MjArmTeleop`
- `MjGripperTeleop`
- `MjMocapTarget`
- `MjHapticsBridge`

Scope:

- Map OpenXR controller poses and actions to robot controls.
- Support base teleoperation.
- Support arm end-effector teleoperation.
- Support gripper open/close or grasp commands.
- Optionally use MuJoCo mocap bodies or target controllers for manipulation.
- Provide basic haptic feedback from contact or force signals.
- Record operator input as action candidates.

Acceptance criteria:

- A user can teleoperate a mobile manipulator locally on Quest and PICO.
- Base, arm, and gripper control are represented in a robot-learnable action schema.
- Teleoperation does not directly teleport physical objects through Godot transforms.
- Contact and force feedback are available for UI or haptics.

Out of scope:

- Full hand-tracking manipulation.
- High-fidelity dexterous hand physics.
- Policy inference runtime.

### Milestone 4: Sensor and Observation Layer

Goal: produce synchronized robot-learning observations from MuJoCo and Godot sensors.

Core modules:

- `MjObservationSpace`
- `MjStateSampler`
- `MjCameraSensor`
- `MjDepthSensor`
- `MjSegmentationSensor`
- `MjContactSensor`
- `MjForceSensor`
- `MjTimestampSync`

Required modalities:

- State.
- RGB.
- Depth.
- Segmentation.
- Contact.
- Force.

Scope:

- Sample robot state from MuJoCo.
- Capture RGB frames from Godot cameras.
- Capture depth images from Godot rendering pipeline where feasible.
- Capture segmentation masks from dedicated render layers or object IDs.
- Sample contact and force data from MuJoCo.
- Align all observations with simulation step index, simulation timestamp, render frame index, and episode frame index.
- Define observation schemas compatible with later LeRobot export.

Acceptance criteria:

- A complete teleoperation episode can produce synchronized state, RGB, depth, segmentation, contact, and force streams.
- Observations are timestamped and frame-indexed consistently.
- Sensor capture does not block the simulation thread.
- Missing or delayed sensor frames are explicitly represented.

Out of scope:

- Photorealistic sensor simulation guarantees.
- Full physical camera calibration model.
- Every possible MuJoCo sensor type.

### Milestone 5: LeRobot Dataset Recorder

Goal: turn VR teleoperation sessions into valid LeRobot-format datasets.

Core modules:

- `MjEpisodeManager`
- `MjLeRobotRecorder`
- `MjActionLogger`
- `MjObservationEncoder`
- `MjReplayPlayer`
- `MjDatasetValidator`

Scope:

- Start, stop, abort, annotate, and replay episodes.
- Record teleoperation actions.
- Record state, RGB, depth, segmentation, contact, and force observations.
- Store episode metadata, task metadata, robot metadata, device metadata, and random seed where applicable.
- Write data in LeRobot-compatible structure.
- Validate schema, timestamps, missing frames, action/observation alignment, and replayability.
- Support interruption-safe recording where feasible.

Acceptance criteria:

- A VR teleoperation session can be exported as a LeRobot-compatible dataset.
- Dataset can be loaded by a downstream LeRobot training or inspection pipeline.
- At least one mobile manipulator task can be recorded, replayed, and validated.
- Recorder does not cause unbounded memory growth during 30-minute sessions.

Out of scope:

- Cloud upload.
- Dataset version control.
- On-device training.
- Multiple dataset formats beyond LeRobot unless required later.

### Milestone 6: Scenario Runtime and Task Templates

Goal: provide repeatable task environments for mobile manipulator data collection.

Core modules:

- `MjScenario`
- `MjTask`
- `MjResetPolicy`
- `MjRandomizationProfile`
- `MjSuccessCondition`
- `MjFailureCondition`

Scope:

- Define reusable mobile manipulator task templates.
- Support reset policies for robot and objects.
- Support controlled randomization of object pose, mass, friction, lighting, materials, and camera pose.
- Record seed and randomization metadata in the dataset.
- Provide success/failure event logging.

Acceptance criteria:

- Same seed can reproduce the same initial scene configuration.
- Successful and failed demonstrations can be marked and exported.
- Randomization does not destabilize common mobile manipulation tasks.

Out of scope:

- Large-scale RL environment API.
- Full procedural scene generation.
- Unbounded domain randomization.

### Milestone 7: Product Hardening and Cross-Device Compatibility

Goal: make the addon reliable enough for product use across Quest and PICO.

Core modules:

- `MjProfiler`
- `MjDeviceCapabilityProfile`
- `MjCrashReporter`
- `MjNativeLogCollector`
- `MjMemoryTracker`
- `MjThermalMonitor`
- `MjModelComplexityReport`

Scope:

- Profile simulation step time, render time, sensor capture time, recorder throughput, contact count, and memory usage.
- Detect thermal throttling and performance degradation.
- Provide per-device capability profiles for Quest and PICO.
- Collect native logs and crash diagnostics.
- Provide model complexity reports and optimization hints.
- Add QA scenes for runtime, import, teleop, sensor capture, and recording.

Acceptance criteria:

- Long-running recording sessions remain stable under expected workloads.
- Device-specific failures are diagnosable.
- Large or invalid models fail with actionable errors.
- QA can validate core behavior before release.

Out of scope:

- Desktop-class simulation complexity on mobile hardware.
- Supporting every Android headset variant at v1.
- Exposing all internal debug tools to end users.

## 7. Suggested Version Plan

```text
v0.1  Android native smoke test
- Quest and PICO load MuJoCo native library
- Built-in MJCF runs on device
- Godot displays body poses

v0.2  Runtime bridge
- Load MJCF
- Step / reset / control
- Body, joint, and actuator sync

v0.3  Mobile manipulator import
- MJCF robot import
- URDF import inside addon
- Visual / collision asset mapping

v0.4  VR teleoperation
- Controller to robot control
- Base / arm / gripper teleop
- Contact or force haptics

v0.5  Sensor and observation layer
- State, RGB, depth, segmentation, contact, force
- Timestamp and frame alignment

v0.6  LeRobot recorder
- Episode writer
- Replay
- Dataset validator

v0.7  Scenario runtime
- Task templates
- Reset policies
- Controlled randomization

v1.0  Product hardening
- Quest / PICO compatibility profiles
- Profiler
- Crash logs
- QA suite
- Documentation
```

## 8. Recommended Minimum Product Loop

The first useful end-to-end product loop should be:

```text
Quest / PICO app starts
→ MuJoCo native runtime loads a mobile manipulator MJCF or URDF asset
→ Godot visual scene syncs to MuJoCo state
→ VR operator teleoperates base, arm, and gripper
→ State, RGB, depth, segmentation, contact, force, and actions are sampled
→ Episode is written in LeRobot-compatible format
→ Episode can be replayed and validated
```

The simulation plugin should be proven before the dataset product becomes complex. However, the observation and dataset schema should be designed early so that runtime APIs do not need to be redesigned later.

## 9. Major Risks

### 9.1 Android Native Port Risk

MuJoCo may require non-trivial Android build and dependency work. Quest and PICO should both be tested in the first milestone.

### 9.2 Cross-Device Runtime Risk

Quest and PICO may differ in OpenXR behavior, input profiles, performance limits, filesystem behavior, and thermal characteristics.

### 9.3 Mobile Performance Risk

Mobile manipulators with contacts, sensors, RGB-D capture, segmentation, and recording may exceed standalone headset budgets.

### 9.4 URDF Import Scope Risk

Built-in URDF import can become large. v1 should support a constrained, robotics-practical subset and preserve MJCF import as the most direct path.

### 9.5 Sensor Fidelity Risk

Godot-rendered RGB, depth, and segmentation may not match real robot camera characteristics without additional calibration.

### 9.6 Dataset Quality Risk

VR teleoperation actions may not directly match robot policy action spaces. The action schema must be designed for downstream learning.

### 9.7 Synchronization Risk

Simulation, rendering, sensor capture, and recording run on different clocks. Timestamp and frame-index discipline must be enforced from the beginning.

## 10. Open Questions

- Which exact Quest devices are supported first: Quest 2, Quest 3, Quest Pro, or a narrower subset?
- Which exact PICO devices are supported first?
- What is the first mobile manipulator model?
- What is the first manipulation task?
- What action schema should LeRobot receive for VR teleoperation: joint targets, end-effector delta pose, base velocity, gripper command, or a hybrid schema?
- What depth and segmentation implementation is acceptable in Godot on Quest and PICO?
- What minimum recording duration and frame rate define v1 success?
- Should the addon support both online recording and offline export conversion, or write LeRobot format directly during capture?
- What URDF subset is required for v1?
- What debugging tools are mandatory for product users versus internal developers?

## 11. Non-Goals for v1

- Full Godot scene-to-MJCF authoring.
- Full MJCF feature coverage.
- On-device policy training.
- Cloud dataset management.
- Desktop-hosted simulation runtime.
- General-purpose game physics replacement.
- Full hand-tracking dexterous manipulation.
- Soft-body or deformable simulation.

## 12. Summary

The addon should be designed as a Godot-native MuJoCo runtime for standalone VR robot simulation, with a product path toward LeRobot-compatible mobile manipulator data collection.

The most important sequencing decision is to build the simulation plugin first: Android native MuJoCo, Godot runtime bridge, MJCF/URDF import, and VR teleoperation. Once that foundation is stable on Quest and PICO, the dataset product layer should add synchronized observations, LeRobot recording, replay, validation, and scenario templates.

