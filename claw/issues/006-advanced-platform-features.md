# Advanced Platform Feature Gaps

Status: open
Category: advanced platform features

## Scope Update

This issue should not be treated as a broad platform request for arbitrary
multi-device teleoperation. The actionable multi-device requirement is
**paired sim-real control**: one XR client controls one logical device while
the same command stream is applied to both a simulator and a real device.

The primary use case is measuring and debugging sim-to-real gap, for example
between the MuJoCo SO-101 simulator and a real SO-101-style arm.

## Primary RFC: Paired Sim-Real Control

One XR session connects to two homogeneous endpoints:

- **sim endpoint**: a simulator-backed device, such as MuJoCo SO-101.
- **real endpoint**: the physical robot/device driver.

Both endpoints must expose the same or explicitly compatible
`DeviceDescriptor`. XR still sends one `DeviceCommand` stream for one logical
device; a paired-session layer fans out those commands to sim and real, then
records and compares the resulting state.

### Requirements

- Treat sim and real as two backends for one logical device, not as unrelated
  devices in a general multi-device scene.
- Reject paired mode at startup when descriptor compatibility cannot be proven.
- Keep the XR-side control model single-target: XR sends one command stream
  and does not need to manually route each input to sim versus real.
- Route real-device commands through the existing safety path; real commands
  must still pass through `SafeDevice::execute`.
- Record command frames, telemetry, safety decisions, endpoint role, descriptor
  identity, timestamps, sequence numbers, and enough timing metadata to
  reproduce and analyze the session.
- Compare sim and real state using explicit metrics such as joint position
  error, joint velocity error, end-effector pose error, command-to-state
  latency, tracking error, and safety rejection differences.
- Allow sim-only replay from a recorded session so a real run can be inspected
  or reproduced without moving hardware.

### Session Model

- One logical session owns one logical device id.
- The session has exactly two endpoint roles for this RFC: `sim` and `real`.
- Commands carry a stable sequence number and timestamp before fanout.
- Telemetry from both endpoints is associated back to command sequence and
  session time when possible.
- Endpoint health is tracked separately, but emergency stop and real-device
  safety failure must be able to stop the paired session globally.

### Command Routing Model

- XR sends commands to the logical device target.
- The paired-session layer fans out each command to the sim and real endpoints.
- The real endpoint remains behind the normal safety gate.
- If the real endpoint rejects or times out on a command, the session records
  the reason and applies a defined policy:
  - MVP policy: stop real output and continue only in safe sim/replay mode.
  - Future policy: configurable stop-all, sim-only, or real-only recovery.

### UI Model

MVP UI does not need a general multi-device control surface. It only needs to
make paired mode visible and inspectable:

- paired session status: sim connected, real connected, descriptor compatible.
- real view as the primary operator view.
- optional sim overlay, ghost pose, or side-by-side state view.
- compact gap indicator for current tracking error and latency.
- recording/replay toggle.

## RFC Notes: Sim-Real Gap Discovery

The value of paired sim-real control is not that one operator can "drive two
devices". The value is that the system can inject the same timestamped command
stream into sim and real, then compare the two command-to-state response
functions.

This should be treated as a paired experiment:

- command input is shared.
- sim and real telemetry are recorded independently.
- timestamps and sequence numbers provide alignment.
- gap analysis is performed after alignment, not by visual inspection alone.

### Discoverable Gap Classes

- **Kinematic and calibration gap**: joint zero offsets, axis direction,
  scale, units, limits, and forward-kinematics mismatch. Same joint pose should
  produce the same end-effector pose within tolerance.
- **Control response gap**: real hardware may have deadband, backlash,
  friction, smoothing, velocity limits, acceleration limits, saturation, or
  controller tuning that the simulator does not model.
- **Dynamic gap**: error grows with velocity, acceleration, payload, workspace
  region, or proximity to joint limits. This points to inertia, damping,
  friction, motor torque, or limit modeling problems.
- **Contact and task gap**: grasping, pushing, collision, insertion, pick-place,
  and object interaction may succeed in sim but fail on real hardware. This
  requires object state, contact events, force/torque, tactile, or visual
  observations to quantify well.
- **Timing and latency gap**: real command-to-state latency, telemetry latency,
  control-loop rate, video latency, and network jitter can make the same command
  stream produce different closed-loop behavior.
- **Safety and constraint gap**: real commands may be rejected by safety,
  limits, watchdogs, or emergency-stop policy while sim keeps executing. That
  means the simulator is missing part of the operational envelope.

### Experiment Plan

Start with controlled open-loop experiments before using free teleoperation:

- step commands for response latency, overshoot, and settling time.
- sine or chirp trajectories for phase lag and frequency response.
- slow and fast path replays for speed-dependent tracking error.
- workspace grid sweeps for calibration, kinematic, and region-specific error.
- near-limit paths for saturation and safety-envelope mismatch.
- loaded and unloaded paths for dynamic and payload-dependent error.

Free XR teleoperation is useful later, but it is not a clean first measurement.
The operator reacts to real feedback, so the human closed loop can mask real
hardware error and send sim a command stream that has already been corrected
for real-world behavior. Free teleop should therefore be recorded as realistic
workload data, then replayed for analysis.

### Required Data

Each recorded sample should preserve enough context to align and compare sim
and real:

- session id and logical device id.
- endpoint role: `sim` or `real`.
- descriptor identity and compatibility result.
- command sequence id and command timestamp before fanout.
- command payload after any XR-side mapping.
- safety decision for the real endpoint.
- telemetry timestamp from each endpoint.
- joint positions and velocities when available.
- commanded target state when available.
- end-effector pose when the driver or descriptor can provide it.
- task-level observations for contact tasks, such as object pose, grasp state,
  collision/contact events, or success/failure labels.

### Metrics

Joint-space error:

```text
joint_error_i(t) = q_real_i(t) - q_sim_i(t)
```

Report per joint:

- mean absolute error.
- root mean square error.
- max error.
- p95 error.
- error by workspace region, speed, and acceleration bucket.

End-effector error:

```text
ee_translation_error(t) = ||p_real(t) - p_sim(t)||
ee_rotation_error(t) = angle(R_real(t)^-1 * R_sim(t))
```

Response and timing metrics:

```text
response_latency = first_state_change_time - command_time
settling_time = time_until_error_below_threshold
phase_lag = delay estimated by cross-correlation
```

Tracking comparison:

```text
real_tracking_error = q_real(t) - q_commanded(t)
sim_tracking_error = q_sim(t) - q_commanded(t)
tracking_gap = real_tracking_error - sim_tracking_error
```

Task-level metrics:

- task success rate.
- object final pose error.
- contact event timing delta.
- collision count.
- safety rejection count.
- retry count.
- completion time delta.

### Analysis Heuristics

- Constant offset usually indicates zero calibration or frame alignment issues.
- Sign, scale, or axis-specific error usually indicates descriptor, mapping, or
  unit mismatch.
- Fixed time shift usually indicates latency or timestamp alignment issues.
- Error that grows with velocity suggests control-loop, damping, friction, or
  velocity-limit mismatch.
- Error that grows with acceleration suggests inertia, torque, or acceleration
  limit mismatch.
- Error that appears near limits suggests saturation, limit, or safety-envelope
  mismatch.
- Error that appears only after contact suggests contact, friction, object
  model, grasp, or perception mismatch.
- Real safety rejection while sim continues suggests the sim model is missing
  constraints that affect real operation.

### Open Questions

- Which component owns paired-session fanout: XR bridge, robot adapter, or a new
  session service?
- What is the minimum descriptor compatibility contract for paired mode?
- Which telemetry fields are mandatory for SO-101 gap reports?
- Should the first report target only joint-space and timing gap, deferring
  contact and object-level gap until object state is available?
- How should real endpoint failure affect sim recording and replay continuity?

## Supporting Advanced Items

- **Command recording and replay** is in scope when it supports sim-real gap
  reproduction and offline comparison.
- **Latency compensation and predictive display** is related, but should be
  scoped after timestamped sim-real measurements exist.
- **Telemetry dashboard** is useful as an analysis surface, but needs an agreed
  API and auth/security model before implementation.

## Deferred / Non-Goals

- General multi-device simultaneous control for unrelated robots, drones,
  cameras, or mixed device types is not accepted as a current requirement.
- Device config sharing or marketplace is deferred.
- Broader robot dog, drone, humanoid, or full-body device support is deferred
  until a concrete device model and descriptor contract exists.

## Current Evidence

- Runtime currently loads one configured device descriptor and creates one
  device instance.
- Command, telemetry, and video flows are organized around one active
  robot/device.
- MuJoCo SO-101 simulation support and physical arm drivers already provide a
  credible sim-real pairing target.
- No paired-session layer, descriptor compatibility check, command fanout,
  aligned sim-real telemetry comparison, or sim-real recording/replay module is
  present.

## Acceptance Criteria

- The first implementation scope is paired sim-real control for one logical,
  descriptor-compatible device.
- Paired mode has an explicit session model, UI model, and command routing
  model as described above.
- Startup validates that sim and real endpoints are descriptor-compatible.
- A single XR command stream is fanned out to both endpoints without requiring
  XR-side multi-device input routing.
- Real endpoint commands continue to pass through `SafeDevice::execute`.
- Recording persists enough command, telemetry, safety, descriptor, and timing
  data to reproduce a session and compute sim-real gap offline.
- Gap reports include at least joint position error and command-to-state
  latency; end-effector pose error should be included when the descriptor or
  driver can provide it.
- Deferred advanced features stay out of scope until each has a concrete use
  case, API surface, and safety/security model.
