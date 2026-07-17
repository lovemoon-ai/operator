# IsaacTeleop Plugin

`plugins/isaac-teleop` is the Operator backend for Isaac Sim teleoperation.
It is one logical plugin with three runtime components:

- Godot `IsaacTeleopSink` samples the Operator-owned OpenXR session.
- `xr-bridge` validates and forwards the high-rate data plane.
- the `operator-isaacteleop` Python wheel supplies external inputs to an
  IsaacTeleop retargeting graph inside Isaac Sim / Isaac Lab.

Operator continues to own the headset display through its existing timed
H.264 relay. The Isaac process must not create CloudXR, Televiz or a second
OpenXR session.

## Runtime Flow

```text
PoseSampler / IsaacTeleopBodySampler
  -> SensorFrame / StreamBinding
  -> IsaacTeleopSink (Godot coordinate space, device monotonic time)
  -> UDP canonical channel packets
  -> xr-bridge (CRC, token, per-kind drop-old)
  -> /tmp/operator-isaacteleop.sock
  -> LatestSampleStore (expiry, clock map, optional coordinate adapter)
  -> Isaac standard TensorGroups / ValueInput leaves
  -> TeleopSession(SessionMode.EXTERNAL)
  -> DefaultTeleopStateManager + existing retargeting pipeline
  -> Isaac Lab action tensor
```

The plugin feature is `operator_feature_sink_isaac_teleop`. It is disabled in
all shipped presets by default. When enabled, teleop composition still creates
the legacy command sink for compatibility but leaves it disabled after device
negotiation; only `IsaacTeleopSink` emits control data.

## Data Contract

The transport header is documented in `wire-protocol.md`. Version 1 payloads
are compact little-endian values carrying the tracking fields consumed by the
corresponding IsaacTeleop standard TensorGroups:

- pose: valid byte, position XYZ and quaternion XYZW float32;
- controller: grip pose, aim pose, four buttons and four analog values;
- hand: exactly 26 OpenXR joints with pose, validity and radius;
- body: exactly 24 Pico BD joints on the wire; Pico input is identity-mapped
  and Meta/Godot 87-joint input is semantically projected to the same slots;
- control: kill, run-toggle pulse, reset pulse and deadman;
- anchor: one pose.

The Meta/Godot projection indexes sparse input records by their explicit
`joint` id; it never truncates the first 24 array entries. The reviewed target
topology is:

```text
pelvis/hips             <- hips
left/right hip          <- left/right upper_leg
spine1/spine2/spine3    <- spine/chest/upper_chest
left/right knee         <- left/right lower_leg
left/right ankle/foot   <- left/right foot/toes
neck/head               <- neck/head
left/right collar       <- left/right shoulder
left/right shoulder     <- left/right upper_arm
left/right elbow        <- left/right lower_arm
left/right wrist/hand   <- left/right wrist/palm
```

Missing targets remain invalid within the fixed 24 slots. Because BODY v1 has
one validity bit for the complete pose, Meta records require both Godot
orientation-valid and position-valid flags. The position mapping is semantic;
Meta orientations are best-effort because the vendor wrapper applies
joint-specific basis corrections before exposing `XRBodyTracker` transforms.

The schema snapshot and checksums live in
`plugins/isaac-teleop/schema`. Version 1 converts canonical payloads directly
to IsaacTeleop's standard TensorGroups. A future codec can replace the payload
with the corresponding FlatBuffers Record without changing the envelope or
gateway.

## Time and Coordinate Domains

The packet timestamp is the headset's monotonic sample time. The host stores:

- raw sample time: headset monotonic nanoseconds;
- common sample time: mapped host monotonic nanoseconds;
- available time: host receive monotonic nanoseconds.

The first packet can bootstrap an offset for development. Production should
feed four-timestamp control exchanges into `MonotonicOffsetEstimator`.

The default path preserves the OpenXR basis and XYZW quaternions exactly.
This matches IsaacTeleop's own `HeadSource`, `ControllersSource`,
`HandsSource`, and `FullBodySource`, which copy DeviceIO/OpenXR values into
the standard TensorGroups without an implicit Isaac-world axis conversion.
An explicit coordinate adapter remains available for a graph that documents
a different input convention, but it is off by default. Robot-base
calibration and `world_T_anchor` remain inputs to the IsaacTeleop graph; the
headset does not run Operator PoseMapper or robot IK in this mode.

## Session and Safety

IsaacTeleop `v1.3.131` accepts `external_inputs` but its LIVE context manager
still creates OpenXR/DeviceIO. The plugin pins commit
`7002ed63d69454ae4f15c0ee19f803fd2846592b` and ships an upstream-style patch
under `plugins/isaac-teleop/upstream` that adds `SessionMode.EXTERNAL`.

Production graphs connect external bool `ValueInput` leaves to upstream
`DefaultTeleopStateManager`. Absence/expiry of the CTRL channel, kill, or a
released deadman forces STOPPED. Hand/body/head samples expire after the host
receiver's configured maximum age instead of holding an old action.

Token zero is an explicitly unauthenticated development mode. The gateway can
recover its per-channel sequence state when an anonymous UDP peer changes or
restarts after an idle interval. Deployment outside a trusted LAN must add a
non-zero token minted by the TCP handshake.

## Physical SO-101 Consumer

`examples/operator_to_so101` is a second consumer of the same canonical UDS
stream. It replaces the upstream LeRobot example's CloudXR/ControllersSource
reader with `UnixDatagramReceiver`, then reuses its relative clutch, EE bounds,
Placo IK, real `SOFollower`, and LeRobotDataset lifecycle. It does not create an
IsaacTeleop `TeleopSession`: the referenced SO-101 controller graph performed
no NVIDIA retargeting beyond exposing the raw controller pose.

For this clutch workflow, A/X maintains a local arm/pause latch, Grip is the
continuous deadman and re-clutch control, and B/Y disarms and re-anchors from
measured FK. A stale CTRL channel disarms, while releasing Grip only holds the
latched pose so the operator can reposition without repeating state-manager
transitions. Kill exits through `SOFollower.disconnect()`, which disables
torque by default.

Only one consumer may bind `/tmp/operator-isaacteleop.sock`, and only LeRobot
may own the follower serial device in this mode. The Isaac Sim receiver and
Rust `robot-adapter` must not run concurrently with the physical SO-101
example. Its recorder stores camera/joint observations, the action actually
returned by `SOFollower.send_action()` after safety clipping, and exact XR
pose/control/timestamp provenance columns.

## Startup

1. Apply/build the pinned IsaacTeleop external-session patch described in
   `plugins/isaac-teleop/upstream/README.md`.
2. Install `plugins/isaac-teleop/python` in the Isaac Sim Python environment.
3. Start the Python receiver/session factory so it binds the Unix socket.
4. Start `xr-bridge` with `robot/configs/isaac-teleop-example.yaml`.
5. Install a normal Operator APK and run `make -C xr run-isaac-teleop`. The
   explicit Android extra enables teleop mode and `sink_isaac_teleop` for that
   process while normal launches remain unchanged. Then connect to the
   bridge's normal TCP endpoint.

The dependency-free `python/examples/fake_session.py` is the host smoke test;
real robot/task factories replace only its fake session and action consumer.
