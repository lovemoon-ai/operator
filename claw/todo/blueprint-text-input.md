# TODO: Blueprint `text_input` primitive for in-headset free text

Status: proposal, not started
Recorded: 2026-09-21

## Why

`examples/light-o1` drives a Unitree G1 from natural-language prompts. The
shipped Blueprint v1 spec has no way for the wearer to *type* text: prompts
are chosen from a host-published library through `menu_item` rows, and
arbitrary text has to be entered on the host terminal. The headset already
has `VirtualKeyboardBar` for `LineEdit` fields in its settings panels, so the
missing piece is a Blueprint contract, not a keyboard.

## Contract sketch

Add one primitive to `specs/blueprint/v1.json`, then regenerate the three
bindings with `python3 scripts/generate_blueprint_spec.py`:

- `text_input`, host kind `system_menu`, not a singleton, anchor `world` only,
  user visibility override allowed (like `menu_item`).
- Properties: `title` (required), `action` (required), `item_key` (default
  `""`), `placeholder` (default `""`), `max_length` (integer, default 200,
  range 1..4000), `submit_text` (default `"Send"`).
- Bindings: `value` (string, required; the host echoes the accepted text),
  `available` (boolean, optional), `visible` (common).
- Event: `action` with `value_type: string` carrying the submitted text.
  Empty submissions are dropped on the headset; the host trims and validates.

The generator must learn nothing new: `string` properties/bindings and a
`string` event value already exist (`input_binding` emits a string).

## Headset work

- `menu_declarations.gd` / `blueprint_runtime.menu_entries()`: a `text_input`
  row composes into the system menu like a `menu_item` whose button opens an
  editor instead of toggling.
- `system_menu_view.gd`: an editor state with one `LineEdit`, the existing
  `VirtualKeyboardBar`, and Submit/Cancel. Ray and index-touch input must both
  work; the menu already synthesizes mouse events for its buttons.
- `dispatch_menu` gains a string payload path; the runtime emits
  `BlueprintEvent.value = <text>` through the existing `event_emitted` signal.
- Registries in `xr/tests/unit/blueprint/blueprint_runtime_test.gd` and the
  primitive/implementation comparison tests need the new entry. Add a device
  case under `xr/tests/device/blueprint/` that types and submits.
- Update `claw/architecture/blueprint.md` (Version 1 Primitives, menu section).

## Host work

- `pyoperator.BlueprintComponent.text_input(...)` factory and Rust/C++ parity
  through the shared `operator` core (validation is spec-driven already).
- `examples/light-o1`: replace the host-terminal path with a `text_input` row
  whose event calls `MotionSession.submit()`; keep the library rows.

## Validation

- `python3 scripts/generate_blueprint_spec.py --check`, `cicd/validate_xr_features.py`.
- `bash cicd/xr_module_harness.sh --suite teleop.settings` plus the new
  `blueprint` device case on Quest and Pico; the APK must be rebuilt because
  the spec hash changes and all three sides must match.
