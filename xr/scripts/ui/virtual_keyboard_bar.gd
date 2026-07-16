class_name VirtualKeyboardBar
extends VBoxContainer
## In-panel virtual keyboard for CompositionViewportUI panels.
##
## Quest immersive sessions cannot summon the Android IME, and panel UI lives
## in an offscreen SubViewport, so LineEdits need an in-viewport keyboard.
## Keys are plain Buttons — the panel's ray pointer synthesizes mouse events,
## which TouchScreenButton-based keyboards (godot-xr-tools) never receive.
## Each press is re-injected as an InputEventKey through this SubViewport so
## the focused LineEdit keeps native caret/selection handling.
##
## Usage: add as a child anywhere in the panel, then attach(line_edit) for
## every field that should summon it. The bar shows while an attached
## LineEdit has focus and hides otherwise.

const KEY_FONT_SIZE := 20
const KEY_HEIGHT := 46.0
const KEY_SEPARATION := 5

const ROWS: Array = [
	["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"],
	["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"],
	["a", "s", "d", "f", "g", "h", "j", "k", "l", "."],
	["z", "x", "c", "v", "b", "n", "m", "-", "_", ":"],
]

var _line_edits: Array[LineEdit] = []


func _init() -> void:
	visible = false
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", KEY_SEPARATION)

	for row: Array in ROWS:
		var hbox := _make_row()
		for ch: String in row:
			hbox.add_child(_make_key(ch, _send_char.bind(ch)))

	var bottom := _make_row()
	var backspace := _make_key("⌫", _send_keycode.bind(KEY_BACKSPACE))
	backspace.size_flags_stretch_ratio = 2.0
	bottom.add_child(backspace)
	var clear := _make_key("✕", _clear_focused)
	bottom.add_child(clear)
	var done := _make_key("▼", _dismiss)
	done.size_flags_stretch_ratio = 2.0
	bottom.add_child(done)


## Register a LineEdit whose focus summons this keyboard.
func attach(line_edit: LineEdit) -> void:
	_line_edits.append(line_edit)
	# The Android IME can't surface in an immersive OpenXR session; disable
	# the automatic request so the OS doesn't try.
	line_edit.virtual_keyboard_enabled = false
	line_edit.focus_entered.connect(func() -> void: visible = true)
	# Deferred: focus may be moving between two attached LineEdits, in which
	# case the bar should stay up.
	line_edit.focus_exited.connect(func() -> void: _update_visibility.call_deferred())


func _make_row() -> HBoxContainer:
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", KEY_SEPARATION)
	hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(hbox)
	return hbox


func _make_key(label: String, action: Callable) -> Button:
	var key := Button.new()
	key.text = label
	# FOCUS_NONE keeps the LineEdit focused while keys are clicked.
	key.focus_mode = Control.FOCUS_NONE
	key.custom_minimum_size.y = KEY_HEIGHT
	key.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	key.add_theme_font_size_override("font_size", KEY_FONT_SIZE)
	key.pressed.connect(action)
	return key


func _focused_line_edit() -> LineEdit:
	var focus_owner := get_viewport().gui_get_focus_owner() as LineEdit
	if focus_owner != null and _line_edits.has(focus_owner):
		return focus_owner
	return null


func _update_visibility() -> void:
	visible = _focused_line_edit() != null


func _send_char(ch: String) -> void:
	if _focused_line_edit() == null:
		return
	var event := InputEventKey.new()
	event.pressed = true
	event.keycode = OS.find_keycode_from_string(ch)
	event.physical_keycode = event.keycode
	event.unicode = ch.unicode_at(0)
	# Deferred: pressed fires mid-GUI-event processing; pushing synchronously
	# would re-enter the viewport's input handling.
	get_viewport().push_input.call_deferred(event)


func _send_keycode(keycode: Key) -> void:
	if _focused_line_edit() == null:
		return
	var event := InputEventKey.new()
	event.pressed = true
	event.keycode = keycode
	event.physical_keycode = keycode
	get_viewport().push_input.call_deferred(event)


func _clear_focused() -> void:
	var focused := _focused_line_edit()
	if focused:
		focused.clear()


func _dismiss() -> void:
	var focused := _focused_line_edit()
	if focused:
		focused.release_focus()
	visible = false
