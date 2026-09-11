# GDScript Strict Typing And Export Validation

Date: 2026-09-10

## Symptom

After the Teleop Blueprint refactor, entering Teleop on PICO showed no
settings or robot-authored Blueprint UI. The installed APK logged:

```text
Parse Error: Could not resolve class "res://scripts/app/modes/teleop_controller.gd"
```

The APK had still been produced and installed, so the existence of an export
artifact was incorrectly treated as proof that the GDScript graph was valid.

## Cause

The branch had been rebased onto local `main`, and `main` already contained
explicit type annotations for earlier Teleop dynamic expressions. The rebase
was not the problem: the Blueprint refactor then introduced new, uncommitted
code outside the scope of that earlier fix.

Two patterns failed under the project's warnings-as-errors configuration:

- A return value from a method on a dynamically loaded script was inferred with
  `:=`. Godot could only prove that the result was `Variant`.
- Boolean expressions included dynamic method calls. Godot could not infer a
  concrete type for the complete expression.

The first reported `Could not resolve class` message was downstream. A clean
export exposed the actual errors in the referenced scripts:

```gdscript
var fingertip: Variant = HandGestureMapperScript.index_tip_position(pointer_joints)
var was_streaming: bool = mode.has_method("...") and bool(mode.call("..."))
```

## Why Rebase Did Not Prevent It

Rebase only reapplies committed changes on top of another commit. It does not:

- apply an old bug fix semantically to newly written code;
- validate uncommitted or newly created scripts;
- prove that a newly exported APK contains a parseable scene dependency graph.

After the rebase, `HEAD` and local `main` were the same commit, while the new
Blueprint runtime and controller changes remained working-tree changes.
Therefore the old fix was present and the new regression was present at the
same time.

## Fix

- Explicitly annotate dynamic return values as `Variant` or their verified
  concrete type.
- Explicitly annotate boolean expressions as `bool`, and convert dynamic call
  results with `bool(...)` where necessary.
- Read the earliest parse error in a clean Android export log instead of fixing
  only a downstream `Could not resolve class` error.
- Make Android export fail when Godot logs `SCRIPT ERROR`, `Parse Error`, or
  `Could not resolve class`, even if Godot returns success or writes an APK.

## Required Rule

For GDScript that crosses a dynamic boundary (`call`, `get`, a dynamically
loaded script, an untyped dictionary value, or a nullable ternary), do not use
`:=` unless the static type is unambiguous. Declare `Variant` or the intended
concrete type explicitly.

Any change that adds or rewires XR scripts must pass the relevant Android
export, not only Python/Rust/static validators:

```bash
cd xr
make build-pico-teleop
# or the corresponding full/Quest target for the changed product surface
```

The export is accepted only when its log contains zero GDScript parser errors.
An APK file, a zero Godot exit status, or a successful rebase is not sufficient
validation.
