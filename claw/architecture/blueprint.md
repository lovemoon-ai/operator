# Blueprint Architecture

Blueprint is Operator's mode-independent declarative XR UI contract. A source
publishes a versioned component tree, latest-wins state snapshots, and receives
ordered interaction events. The headset owns rendering and interaction; a
source cannot send executable code, scenes, shaders, or arbitrary assets.

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
- property names, types, defaults, and numeric ranges;
- state bindings, required bindings, binding groups, and emitted events;
- whether a primitive supports headset-side visibility overrides.

Run this after changing the spec:

```bash
python3 scripts/generate_blueprint_spec.py
```

The generator writes checked-in bindings for all three consumers:

- `python/pyoperator/_blueprint_spec.py`
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
are part of each binding contract, and a state key reused by multiple
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

- `event_emitted` for interactions that must return to the source;
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

Blueprint is enabled only when the source, bridge, and headset use the exact
same generated primitive spec:

- the source descriptor advertises `blueprint_v1=true` and
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

## Version 1 Primitives

The canonical spec currently defines `label`, `status_lamp`, `palm_menu`,
`fingertip_tactile`, `video_panel`, `controller_help`, `control_frame`, and
`operation_trajectory`. Consult `specs/blueprint/v1.json` for the authoritative
property, binding, anchor, event, and constraint definitions; prose documents
must not duplicate those tables as normative definitions.
