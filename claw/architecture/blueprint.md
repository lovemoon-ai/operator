# Blueprint Architecture

Blueprint is Operator's mode-independent declarative XR UI contract. A host
publishes a versioned component tree, latest-wins state snapshots, and receives
ordered interaction events. The headset owns rendering and interaction; a
host cannot send executable code, Godot scenes, shaders, or arbitrary resource
paths. The `robot_model` primitive accepts a restricted data-only model asset.

The current production adapter connects Blueprint to Outside Robot Teleop. The
contract and XR runtime do not depend on Teleop, so VR operation, Realtime Feed,
or another mode can attach the same runtime to its own lifecycle and transport.
Inside Robot remains independent because it has no external robot session.

## Canonical Primitive Spec

`specs/blueprint/v1.json` is the only hand-maintained source of truth for:

- wire schema names, command names, capability name, and limits;
- supported anchors and transform fields;
- every primitive's host kind, implementation key, singleton rule, and allowed
  anchors;
- property names, types, defaults, numeric ranges, and array length bounds;
- state bindings, required bindings, binding groups, and emitted events;
- whether a primitive supports headset-side visibility overrides.

Run this after changing the spec:

```bash
python3 scripts/generate_blueprint_spec.py
```

The generator writes checked-in bindings for all three consumers:

- `python/operator_xr/_blueprint_spec.py`
- `robot/crates/teleop-protocol/src/blueprint_spec.rs`
- `xr/scripts/contracts/blueprint/blueprint_spec.gd`

`python3 scripts/generate_blueprint_spec.py --check` fails when a generated
binding is stale. `cicd/validate_xr_features.py` runs that check as part of the
normal static validation path. The generator rejects unknown field keywords,
constraint kinds, event shapes, anchor tracking kinds, and host kinds. Adding a
new semantic therefore requires updating the generator and every consumer
instead of silently producing bindings that no runtime understands.

Generated conformance cases define the accepted value types. Python, Rust, and
GDScript tests all execute those same cases. Array lengths and numeric ranges
are part of each binding contract (`length` is exact, `max_length` an upper
bound), and a state key reused by multiple
components must have the same value contract; whether a binding is required on
the component, or carries implementation semantics such as freshness, does not
change the value type of that shared key. String colors use HTML hexadecimal
forms (`#rgb`, `#rgba`, `#rrggbb`, or `#rrggbbaa`); arbitrary color names are
not part of the wire contract.

Envelope counters and timestamps use non-negative JSON integers, not integral
JSON floats, and are capped at signed 64-bit maximum so Python, Rust, and Godot
accept exactly the same wire values. The canonical conformance cases cover this
separately from primitive fields whose `integer` type intentionally accepts an
integral numeric value such as `1.0`.

For `fingertip_tactile`, the optional `sample` binding is a freshness token.
When present, the headset refreshes tactile age only when that integer changes;
unrelated Blueprint state updates therefore cannot make an old sensor sample
look fresh.

The XR tests also compare the generated spec against explicit implementation
registries for anchors, node primitives, interaction events, and mode-owned
external views, including every property, binding, and event consumed by each
implementation. A new primitive field or anchor cannot be added to the spec
without a corresponding headset implementation and test update.

## System and Robot Scopes

Outside/Operator has two independent `BlueprintRuntime` instances. The local
system Blueprint owns connection controls and controller status lamps; it lives
for the Teleop scene and survives disconnect. The robot Blueprint owns models,
application input bindings and their state; disconnect destroys that scope and
cancels pending input/acknowledgements. Runtime ownership, not an ID/action-name
prefix, determines authority. Only events from the locally created system runtime
reach the allowlisted `connection.toggle` and `view.recenter` handlers. Robot
events continue through the session to their host, even if they use those names.

The system menu reconnects the selected/saved endpoint and disconnects through
the existing connection manager. It cannot receive a new endpoint from remote
Blueprint properties. Local connection truth overrides any stale robot-ready
state. Controller lamps are grey when disconnected, flashing blue while
connecting or resetting, orange when reset is required, and green when ready.
Robot messages and errors appear in the controller menu, not a head-locked HUD.

## Unified System Menu and Input Bindings

`menu_item` contributes a row to the **system-owned** menu, not a scene node.
`palm_menu` and `controller_menu` remain compatible declaration forms with host
kind `system_menu`; neither allocates a panel or listens for input. Legacy
anchors/transforms no longer position menus: placement is exclusively local.
`controller_menu` can contribute its existing secondary action as a second row.
Remote visibility overrides apply only to remote items, never the system menu.

`SystemMenuHost` creates one `system_menu_view.gd` for the active Teleop scene.
Its local Blueprint declares connection and recenter items plus status lamps.
`MenuComposer` combines these fixed system rows with paginated robot rows.
Both hand and controller input present the same content on that one panel:
left-palm pose plus opposite index touch, or left Menu plus right-controller ray.
Only one presenter is active, selected by the shared source arbitration (including
Pico stale-profile recovery). Switching source closes/cancels the old interaction;
held Menu or an already-touching finger cannot activate the new presenter.

An optional `item_key` explicitly merges identical declarations **within one
Blueprint**; empty keys keep rows distinct. No merging by text/action-name occurs.
Python, Rust and XR reject shared-key conflicts in actions, labels, state bindings,
defaults, and override policy. The first declaration is canonical and retains its
original event identity; hiding either alias hides the merged row. Controller
secondary rows have their own optional `secondary_item_key`. Local and remote
items never share an identity namespace.

Every composed row carries an internal source-runtime/generation/Blueprint/
component/event token. Clicks are checked against the live item and expected
bound value before the originating runtime emits its original `BlueprintEvent`.
Only the locally created runtime reaches local connection/recenter callbacks;
remote actions named `connection.toggle` or `view.recenter` still go to the robot.
Disconnect/replacement/suspension invalidate old tokens. Changing pages, item
state, source or visibility cancels active presses, and disconnect removes only
remote contributions. Normal Button cancellation sends an outside mouse motion
before release, clearing Godot's `pressing_inside` state instead of firing a click.

`input_binding` declares a bounded `dual_trigger_hold` gesture and an action.
XR requires both physical controllers,
press/release hysteresis, continuous samples, and a fresh release baseline after
activation, tracking loss, pause, or a frame gap. Both triggers must be released
before another completed hold can trigger. While the chord owns input, pending
ray clicks are canceled (not released over a button), and controller command
inputs are neutralized. No hold timing is inferred from network packets.

A completed hold emits a fresh opaque string request ID in `BlueprintEvent.value`.
The host echoes it in the `acknowledged_request` binding and publishes `success`
and `required` in the same state update. Only a current, matched, successful ack
with `required=false` produces confirmation vibration on both controllers.
Failures/timeouts use error feedback and retain an uncertain/reset-required
state. Replayed, late or post-disconnect acknowledgements cannot confirm a new
request. The headset supplies bounded haptic presets; robot state cannot request
arbitrary vibration intensity or duration. `target_component` optionally names
the associated model, gating input until its asset is ready and selecting the
local recenter target.
A recognized hold that is not currently available is rejected locally with error
feedback and menu status; it does not send a request or give success vibration.

The `whole-body-control` examples do not declare this trigger binding: ScaleBFM
and SONIC share a host-side, UI-filtered `XrFrame` gamepad mapping. ABXY resets,
left-stick click cycles LOCOMOTION/VR/BODY, sticks send velocity commands in the
first two modes, and triggers/grips control articulated hands when present
(no-op on ScaleBFM's default 29-DoF model). Status is a
controller-attached Blueprint label. Buttons require a fresh release baseline
after tracking loss; reset does not re-arm a held chord. This changes example
interaction only, not the generic `input_binding` protocol or its ack behavior.

Recenter is a translation-only local view offset computed from the model's
actual current root and the head's horizontal forward direction (default 2 m).
It preserves heading, joint pose and ground height. It neither sends robot
commands nor mutates host `base_pose`, remains world-locked as the head moves,
and is retained when subsequent robot states arrive. It is cleared with the
robot Blueprint/session, not applied to the system menu or its lamps.

## SDK Ownership

`robot/crates/operator` is the authoritative publisher implementation. It owns
Blueprint and state validation, patch merging, sequence allocation, descriptor
capability injection, adapter-envelope serialization, and inbound event
validation. `teleop-protocol` provides the internal wire data types; robot
integrations should depend on the public `operator` facade instead of
reimplementing those behaviors.

The three language surfaces share that core:

- Rust uses `operator::BlueprintPublisher` directly;
- Python `XrSession.blueprint` and `HostedBlueprint` call it through
  `pyoperator-native`;
- C++ uses the `liboperator` C ABI and the RAII wrapper in
  `cpp/liboperator/include/operator/operator.hpp`.

Python dataclasses and C++ JSON builders remain language-level authoring
ergonomics. The Rust core is the final authority before any descriptor,
Blueprint, state, or event enters the adapter protocol. This keeps embedded
Python, hosted Python, and native robot adapters behaviorally identical.

## Runtime Boundary

`BlueprintRuntime` is a reusable XR host under `xr/scripts/blueprint/`. It
accepts only validated `Blueprint` and `BlueprintState` dictionaries and emits:

- `event_emitted` for interactions that must return to the host;
- `external_view_changed` for primitives implemented by an owning mode rather
  than by a new scene node, such as `video_panel`.

The runtime receives XR origin, camera, controller, and hand-tracking providers
through `configure()`. It does not open sockets, inspect robot descriptors, or
send control commands. A mode adapter is responsible for:

1. forwarding Blueprint messages from its transport to the runtime;
2. forwarding runtime events back to that transport;
3. mapping external-view primitives to mode-owned views;
4. suspending or clearing the runtime with the mode lifecycle.

Outside Robot Teleop currently implements that adapter in
`xr/scripts/app/modes/teleop_controller.gd`. A future VR or Realtime Feed
integration should reuse `BlueprintRuntime` and provide its own external-view
mapping instead of adding mode checks to the runtime.

## Compatibility Negotiation

Blueprint is enabled only when the host, bridge, and headset use the exact
same generated primitive spec:

- the host descriptor advertises `blueprint_v1=true` and
  `blueprint_spec_sha256=<digest>`;
- the headset `Hello.capabilities` advertises both `blueprint_v1` and
  `blueprint_v1@sha256:<digest>`;
- `xr-bridge` compares both sides with its generated digest before forwarding
  any Blueprint, state, or event message;
- the headset independently checks the returned descriptor capability and hash
  before accepting Blueprint or state messages or sending events.

The hosted Python adapter adds these descriptor capabilities only when a
`HostedBlueprint` publisher is attached. A mismatch disables Blueprint with an
explicit bridge log while leaving control, telemetry, and video transport
available. Deploy the Python package, `xr-bridge`, and headset APK from the same
checkout whenever the canonical spec changes.

## Data Flow And Performance

Blueprint definitions are structural and expected to change rarely. State uses
complete latest-wins snapshots: Rust `watch` channels and the hosted Python
wrapper around the same Rust publisher coalesce superseded updates instead of
building an unbounded queue.
A snapshot may omit a bound value to use the component's property/default
fallback, but every key it does publish must be declared by at least one
component binding and satisfy that generated value contract. Binding typos
therefore fail visibly instead of silently leaving UI on its default state.
Events remain ordered and bounded.

Video transport is independent. Declaring or hiding `video_panel` changes only
the existing view's visibility and options; packet receive, decode, texture
upload, and frame cadence continue unchanged. The per-frame Blueprint work is
limited to primitives attached to moving XR anchors and local hand interaction.
The optional `status_state`, `status_text`, and `system_performance_text`
bindings decorate that mode-owned video view without giving the Blueprint
runtime knowledge of application-specific IDs. Whether video and performance
diagnostics are visible remains a headset-local Settings preference; robot state
supplies content, not the user's diagnostic preference.

`robot_model` may describe either an articulated model or a rigid scene object.
A rigid asset declares an empty `joint_names`/`joints` list and is updated using
only its required `base_pose` and `sample` bindings. This lets a host publish
dynamic props without inventing dummy joints or shipping executable scenes.

## Version 1 Primitives

The canonical spec currently defines `robot_model`, `ground_grid`, `model_lighting`, `label`, `status_lamp`, `path`, `marker`, `menu_item`, `palm_menu`, `controller_menu`, `input_binding`,
`fingertip_tactile`, `video_panel`, `controller_help`, `control_frame`,
`operation_trajectory`, and `dense_map`. Consult `specs/blueprint/v1.json` for the authoritative
property, binding, anchor, event, and constraint definitions; prose documents
must not duplicate those tables as normative definitions.

## Navigation Overlays: Path, Marker, and Dense Map

`path` and `marker` let a host such as a navigation service draw a route and
its goals. `path` is a world-anchored polyline in the component's local XR
frame (metres, Y up). `points` is a flat `[x0, y0, z0, x1, ...]` array bounded
by the spec's `max_length` (2048 points); a trailing partial point is ignored
with a warning. The headset draws a constant-width unshaded tube, rebuilding
the mesh only when the points change; `closed` joins the last point to the first.

`marker` is a `sphere`, `ring`, `arrow`, or `pin` of `size` metres with optional
text. Its optional `position` binding offsets it within the component frame, so
a moving goal needs no new revision. The contract language has no enums:
authoring helpers reject unknown shapes and the headset falls back to a sphere
with one warning. An arrow starts at the point and points along local -Z; a
pin's tip is at the point. `pulse` animates scale only while visible.

`dense_map` is a singleton external view. Its point-cloud content never travels
through Blueprint: it arrives on the host's `media_down` result stream (dense
map chunks and map transform). Blueprint only gates visibility and presentation.
`display` is `world` (the cloud rendered 1:1 at the host-supplied map transform)
or `minimap` (a `scale`d preview `distance` metres ahead of and
`height_below_head` metres below the viewer, keeping the map's heading). The
owning mode maps it onto `scripts/components/views/dense_map_view.gd` and
treats unknown values as `world`. In Teleop the view is mounted under the
external view and pulls results from the session's own `media` result port, so
the same component serves a host session and an ingest session.

## Robot Presentation: Ground and Lighting

The host can declare `ground_grid` and `model_lighting` alongside a model. These
are ordinary world-anchored Blueprint components, not implicit Teleop scenery.
Both support visible bindings and user visibility overrides, and are hidden on
suspension and destroyed with their Blueprint on disconnect/replacement.

`ground_grid` is a finite transparent XZ plane with metre-based size, spacing,
and line width, independently colored minor/major lines, derivative antialiasing,
and fading edges. It has no collider and does not change simulation contacts.
Its shader is shipped client code; the host sends only validated parameters.
The optional `placement_target` identifies a component whose **local recenter
offset** is shared by the grid (an absent target has zero offset). It does not
copy the model's animated base pose. The host sets ground height and initial
offset through the grid's transform, so walking/jumping does not move the floor,
while explicitly recentering the robot moves the grid with the display.

`model_lighting` is a singleton key/fill directional-light rig with bounded
energies, separate colors, and optional energy bindings. The component rotation
rotates both default light directions; translation has no lighting effect.
Two shadow-free lights reveal the robot's shape without shadow-map cost. Layer
20 is reserved for Blueprint robot-model lighting: imported model geometry adds
that bit to its existing camera-visible layers, and these lights cull everything
else. They do not change materials, exposure, WorldEnvironment, passthrough,
controller UI, or Inside Robot. The unshaded ground grid needs no lighting.

## Render-only Robot Models

`robot_model` displays a **robot/host-owned model**, never an APK-bundled robot.
`scripts/make-robot/` is exclusively for Inside Robot. Outside applications do
not run it, import it, or read `xr/assets/robots/` or bundled joint tables.
Adding a new Outside robot requires no headset rebuild once its asset profile
is supported. This renderer does not start Inside Robot, a retargeter, or physics.

The host declares `asset_sha256`, `asset_size`, `asset_port`, and a complete
ordered `joint_names` list. The connected transport supplies the peer hostname;
Blueprint cannot supply a different host or an arbitrary URL/path. XR downloads
`http://<connected-peer>:<asset_port>/blueprint-assets/<sha256>.glb` asynchronously,
with redirects and compression disabled, a timeout, and a 64 MiB response cap.
Exact length and SHA-256 are verified before import. A content-addressed cache
under `user://blueprint_robot_assets/` is reverified on reuse, atomically written,
and bounded to 256 MiB; oldest entries are evicted. Disconnect/replacement frees
the consumer and cancels pending HTTP. Hashes provide integrity, not peer
authentication: this HTTP service shares the robot protocol's trusted-LAN
boundary. `RobotAssetServer` exposes only registered immutable bytes, never a
filesystem directory. Static asset traffic is separate from high-rate state.

The initial asset profile is self-contained GLB 2.0 with triangle meshes and
solid PBR colors. It rejects external/data URIs, textures, animations, skins,
cameras, glTF extensions, and unknown resource fields before runtime GLTF import.
Budgets include 512 nodes, 256 movable joints, 3 million mesh vertices, 9 million
indices (counted per primitive, even for shared accessors), and 2 MiB
of JSON. Missing or invalid models report errors, not an implicit built-in G1.

`extras.operator_robot` contains `schema: "operator.robot_asset.v1"`,
`coordinate_space: "xr_y_up"`, the glTF root-node index, and a `joints` array.
Node instances are charged again against the vertex/index render budgets, so
reusing binary data cannot create unbounded import or draw work.
Each joint specifies `name`, its glTF `node` index, `type` (`hinge` or `slide`),
unit `axis`, local `pivot`, and `reference` position. glTF supplies the rest
transforms and link hierarchy. Joint lists must match the Blueprint exactly;
node indices avoid ambiguity from imported/sanitized node names. Positions are
in radians (metres for sliders). Hinge motion is applied about the transmitted
pivot relative to the rest transform; the root receives the floating base pose.

`operator_xr.mujoco_asset.from_mujoco` exports this model directly from the host's
compiled MuJoCo model, including its real visual meshes, transforms, scalar
joint axes/pivots, and reference offsets. It has no Inside Robot dependency.
Current exporter support is one scalar joint per non-root body, one externally
driven root, and mesh, box, or sphere geoms in explicitly selected visual
groups (default 1). Box and sphere primitives are tessellated into the same
triangle-only GLB asset contract.

The base pose is `[x,y,z,qx,qy,qz,qw]`, relative to the component transform in
the XR Y-up coordinate system. The host publishes joints, base pose and sample
token together. A missing or stale sample hides the model; unrelated state
updates with the same token do not refresh it. The renderer rejects invalid
dimensions/non-finite transforms, normalizes nonzero quaternions, and smooths
joint/base motion locally. This is presentation smoothing, not robot control.
The latest state is retained while a model loads; asset arrival does not refresh
its tracking timestamp. A late model with stale state remains hidden.

Unlike low-rate status UI, robot state can update at policy frequency; latest-wins
snapshots still prevent unbounded queues. Structural definitions are not resent
per sample. `examples/whole-body-control` demonstrates host ScaleBFM or SONIC +
MuJoCo with this component, returning actual simulated state rather than target
joint commands. The example shares session lifecycle, tracking validation and
presentation; each controller owns its point selection, calibration, policy
observations, model parameters and physics. The former standalone ScaleBFM
example has been consolidated into this implementation.
