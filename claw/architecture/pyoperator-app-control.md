# RFC: pyoperator Application Control Plane

## Status

Proposed. This document records direction only; it contains no implementation.

## Owner

TBD

## Date

2026-07-23

## Summary

Make `pyoperator` a first-class control surface for the Operator headset app,
at the same architectural level as the in-headset Godot UI. Python should be
able to manage the Android app lifecycle and, after the app starts, enter the
launcher or another mode, inspect state, update settings, and invoke supported
in-app operations. The UI and Python API should call the same application
services so their behavior cannot silently diverge.

This is an additive control plane. Existing XR state streaming, robot-service,
hosted Python, and standalone APK workflows remain supported.

## Context

`pyoperator` currently provides a Python-first XR data and robot integration
surface. `XrSession` receives immutable `XrFrame` snapshots, and `xr_bridge`
provides its convenient singleton API. It does not control the headset
application itself.

Application lifecycle automation currently lives in ADB commands and test
scripts. Inside the APK, launcher routing belongs to `mode_select.gd`, settings
are owned by individual UI or mode scripts, and many runtime controllers live
only as long as the active scene. A Python developer therefore needs to know
Android intents, Godot scene details, UI layout, and mode-specific conventions
to automate the app.

Starting an Android process and operating an already-running application are
different concerns. The former requires an external device-management channel;
the latter requires a persistent service inside Godot. `pyoperator` should
compose both behind one understandable product surface.

## Goals

- Let Python manage app install, launch, force-stop, restart, and status through
  a pluggable device backend.
- Let Python enter the launcher, transition modes, read and update settings,
  invoke app actions, and observe their outcomes.
- Provide coherent state snapshots, structured errors, and observable action
  completion so automation can synchronize reliably.
- Make the Godot UI and Python clients of the same domain services.
- Let each APK advertise the capabilities its platform and feature preset
  actually support.
- Preserve current APK-only, Python-embedded, hosted Python, and robot-service
  integrations.
- Provide a safe foundation for a future CLI and AI-facing tool layer.

## Non-Goals

- Exposing arbitrary Godot nodes, methods, properties, shell commands, or code
  execution.
- Treating simulated controller input or UI click automation as the product
  control API.
- Replacing `XrStateFrame`, `DeviceCommand`, video, telemetry, robot adapters,
  retargeting, or IK APIs.
- Requiring a Python host for normal interactive APK use.
- Enumerating every future setting and action in this RFC.
- Implementing the proposal as part of this document change.

## Design Principles

1. **One operation, multiple front ends.** UI, Python, CLI, and future AI tools
   call the same validated domain operation.
2. **Capabilities, not internals.** The APK exposes stable operations and
   schemas, never its scene tree.
3. **Separate lifecycle from in-app control.** Python may compose the two, but
   each has a distinct backend and failure model.
4. **Separate control from realtime data.** App commands do not change XR state
   or robot-stream timing and compatibility.
5. **Observable state.** Commands have explicit outcomes, and reconnecting
   clients can obtain a fresh coherent snapshot.
6. **Backward compatibility by default.** With no control client, the APK works
   exactly as an interactive app.

## Options Considered

### A. ADB and Intent Extras Only

Wrapping current ADB and intent commands is useful for process lifecycle, but
cannot provide persistent state, completion events, or general in-app control.
ADB remains the first lifecycle backend, not the entire architecture.

### B. UI Automation

Synthesizing controller input or targeting visual controls is brittle across
layout, localization, timing, and headset state. It remains useful for focused
UI tests, not as the public API.

### C. Reuse the XR/Robot Data Connection

Adding app commands to `DeviceCommand` or `XrStateFrame` couples unrelated
lifecycles, permissions, rates, and compatibility. Framing code may be shared,
but app control needs a separate protocol and connection.

### D. Persistent Typed Application Control Service

Add an app-global Godot service and a matching `pyoperator` client, with an
external device backend handling Android process lifecycle. This is the
proposed direction.

## Proposed Design

### Responsibility Split

```text
Python application / future CLI / future AI tools
                     |
                 pyoperator
             ________|____________________
            |                 |            |
   device lifecycle       app control    existing XR/robot APIs
   (ADB initially)        session
            |                 |
      Android package     Godot autoload service
                              |
                 state + modes + settings + actions
                              |
                         headset UI
```

The package presents one top-level aggregate, tentatively `Operator` or
`OperatorApp`, while retaining focused facades:

- `device`: install, start, stop, restart, package/version, and process status;
- `app`: connect, inspect state, navigate, configure, invoke, and subscribe;
- `xr`: the existing immutable XR frame stream;
- `robot`: the existing robot and control-loop surface.

The final public names are deliberately undecided. The intended experience is
conceptually:

```python
from pyoperator import Operator

operator = Operator.connect()
operator.device.start_app()
operator.app.open_launcher()
operator.app.settings.update({"capture.rgb_resolution": "1280x960"})
operator.app.capture.start()
```

These calls represent typed domain operations, not UI clicks or direct Godot
method calls.

### Device Lifecycle Layer

An external `DeviceBackend` owns operations that cannot run when the APK is
stopped. The initial backend should use ADB over USB or TCP because current
build and device-test workflows already depend on it. Vendor management, MDM,
or a paired device agent may be added later without changing the in-app API.

The backend may pass a bootstrap control endpoint and short-lived credential
when launching the APK. It must not become the ongoing in-app transport.

### Godot Application Control Service

The APK gains an autoload service, tentatively `OperatorControlService`, so its
transport and state survive scene changes. It owns four logical facilities:

- an app state store for the current mode, transition state, active operations,
  configuration revision, and connection health;
- a mode router used by both the launcher UI and remote commands;
- a settings registry that describes, validates, reads, writes, and persists
  configuration;
- an allowlisted action registry for mode and application operations.

Mode scenes register their currently available settings and actions on entry
and unregister them on exit. Long-lived capabilities may be global. Existing
scene-local controllers can remain implementation details while their public
operations migrate behind these registries.

The headset UI must use the same services. Python and UI actions must therefore
share validation, state transitions, persistence, and error handling.

### Capability Model

The client discovers capabilities instead of inferring them from a headset
model or hard-coding all future features. A capability identifies a stable
setting or action and describes its availability, owning mode, typed inputs and
outputs, and safety requirements.

The first slice should cover app identity and health, launcher and mode
navigation, settings discovery and updates, and start/stop operations for the
enabled teleop, ego-capture, and live-feed features.

Long-term completeness is measured by a parity inventory: every user-visible
mutable setting or action is either registered for automation or explicitly
documented as intentionally non-automatable.

### Control Protocol

The control protocol remains independent of XR and robot data protocols. It
may initially reuse the repository's length-prefixed JSON framing, but its
versioned contract should be shared rather than implemented separately in
Python and GDScript.

It needs three categories of communication:

- request/response for snapshots, capabilities, navigation, configuration,
  action invocation, and cancellation;
- operation events for accepted, progress, completed, failed, or cancelled
  work;
- state events for mode, configuration, availability, and connection changes.

Requests and events need stable identity, structured errors, version
negotiation, and enough state revision information to detect races or recover
after reconnecting. Mode transitions are serialized and report success only
when the destination service is ready.

The APK should connect outbound to the Python control endpoint. Intent extras
are the initial bootstrap mechanism; later deployments may add discovery and
pairing. Without an endpoint, the app continues normally.

### Python API

The persistent protocol client should have an asynchronous core for I/O,
events, cancellation, and reconnect. `pyoperator` should also expose a simple
synchronous facade for common robotics and data-collection scripts. Both use
the same typed models and explicit timeouts.

The existing `pyoperator.xr_bridge` and `XrSession` APIs remain available. The
new aggregate may compose them but cannot require existing programs to migrate.

### Safety and Ownership

Headset input and Python commands may arrive concurrently, so all mutations go
through the domain service rather than directly changing UI state. Mode
transitions are serialized, settings use revision checks, and actions declare
whether they are cancellable or exclusive.

The public API never exposes arbitrary Godot or Android execution. Network
clients require pairing and authentication before mutations. Secrets are
redacted, and mutating actions emit audit events. Robot motion, deletion,
upload, recording, and similar operations require explicit safety policy and
controller ownership. Future AI tools deny hazardous actions by default unless
the caller has explicit authority.

## Compatibility

- The normal APK and all headset UI flows work without Python.
- Existing robot-service descriptors and `DeviceCommand` behavior are
  unchanged.
- Existing `pyoperator.xr_bridge`, `XrSession`, and hosted Python integrations
  remain supported.
- The control channel is optional and version-negotiated.
- An unavailable capability produces a structured result, never an implicit
  fallback to UI automation.

## Risks

- **Duplicated logic:** remote handlers could drift from UI behavior. Both must
  call the same domain services.
- **Scene races:** commands may arrive during scene changes. Transport and state
  stay global, transitions are serialized, and readiness is explicit.
- **Configuration inconsistency:** current settings have multiple owners.
  Migration must establish one registry as the source of truth incrementally.
- **Safety exposure:** automation can trigger physical or irreversible effects.
  Capabilities need authentication, risk policy, ownership, and auditing.
- **Scope growth:** "everything" can become an unbounded API. A capability
  contract and parity inventory replace ad-hoc functions.
- **Platform dependence:** ADB is not universal. Lifecycle backends remain
  pluggable and separate from the platform-neutral app protocol.

## Rollout

1. Define the app snapshot, capability, operation, error, versioning, and parity
   contracts.
2. Add the ADB lifecycle backend and a minimal global Godot service for health,
   snapshots, and launcher/mode navigation.
3. Introduce settings and action registries; migrate launcher, capture,
   live-feed, and teleop features incrementally.
4. Stabilize synchronous and asynchronous Python facades while keeping current
   `xr_bridge` behavior.
5. Build a CLI from the typed client. Add AI tooling only after authentication,
   safety policy, and auditing are complete.

Each phase is additive. A partially migrated APK advertises only implemented
capabilities.

## Test Strategy

- Protocol, revision, timeout, and reconnect behavior has device-independent
  loopback tests.
- Godot service, routing, and UI/domain parity run through the existing
  on-device test harness on a target headset.
- Marked `pytest` hardware tests use the normal target APK for lifecycle,
  navigation, settings, actions, and reconnect. Without a matching device,
  reports show these cases as skipped rather than replacing them with fakes.
- Fakes complement but do not replace real-device coverage at hardware and
  safety boundaries.

## Acceptance

This RFC is implemented only when:

- Python can query, start, stop, and restart the target APK through a documented
  backend and receives actionable startup failures.
- Python can connect to a running APK, obtain a coherent snapshot, reconnect,
  open the launcher, enter advertised modes, configure advertised settings,
  and invoke advertised actions with explicit final outcomes.
- The UI and Python use the same navigation, validation, persistence, and
  action services.
- Capability discovery reflects the APK feature preset and runtime platform.
- Existing APK-only, robot-service, hosted Python, and `xr_bridge` workflows
  remain compatible.
- The UI/API parity inventory has no unexplained gaps, and test reports clearly
  separate device from device-independent coverage.
- No public operation depends on arbitrary Godot calls or UI coordinates.

## Open Questions

- What are the final Python aggregate and facade names?
- Should shared protocol types live beside `teleop-protocol` or in a separate
  app-control module?
- Which bootstrap, discovery, and pairing model should be used without ADB?
- Is one controlling client plus observers sufficient, or are multiple writers
  required?
- Which settings and actions define the first parity milestone?
- Which hazardous actions always require wearer confirmation?
- Should the public Python API default to synchronous or asynchronous usage?
