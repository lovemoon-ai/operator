extends "res://scripts/ui/composition_viewport_ui.gd"
class_name BaseSettingsPanel

signal confirmed
signal exit_requested

const COL_PANEL_BG := Color(0.055, 0.067, 0.08, 0.96)
const COL_PANEL_BORDER := Color(0.18, 0.22, 0.26, 1.0)
const COL_TITLE := Color(0.94, 0.96, 0.98)
const COL_SECTION := Color(0.65, 0.70, 0.75)
const COL_STATUS := Color(0.55, 0.80, 0.66)
const EXIT_HOLD_SECONDS := 2.0

class HoldIndicator:
	extends Control

	var progress := 0.0

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func set_progress(value: float) -> void:
		progress = clampf(value, 0.0, 1.0)
		queue_redraw()

	func _draw() -> void:
		if progress <= 0.0:
			return
		var inset := 8.0
		var y := size.y - 5.0
		var end_x := inset + (size.x - inset * 2.0) * progress
		draw_line(Vector2(inset, y), Vector2(end_x, y), Color(1.0, 0.647, 0.169, 0.98), 4.0, true)

var _content: VBoxContainer
var _highlighted_slot: PanelContainer
var _exit_indicator: HoldIndicator
var _exit_holding := false
var _exit_hold_seconds := 0.0


func _setup_settings_panel(
		viewport_size: Vector2i,
		quad_size_m: Vector2,
		title_key: String,
		confirm_key: String,
		layer_sort_order: int = 2,
		initial_visible: bool = true
) -> void:
	var viewport := _setup_viewport_layer("SettingsViewport", viewport_size, quad_size_m, layer_sort_order, 18.0)
	_build_panel(viewport, title_key, confirm_key)
	visible = initial_visible


func _process(delta: float) -> void:
	if not _exit_holding:
		return
	_exit_hold_seconds = minf(_exit_hold_seconds + delta, EXIT_HOLD_SECONDS)
	if _exit_indicator:
		_exit_indicator.set_progress(_exit_hold_seconds / EXIT_HOLD_SECONDS)
	if _exit_hold_seconds < EXIT_HOLD_SECONDS:
		return
	_cancel_exit_hold()
	exit_requested.emit()


func open() -> void:
	visible = true


func close() -> void:
	clear_pointer()
	visible = false


func add_section_label(text_key: String) -> Label:
	var lbl := Label.new()
	lbl.text = tr(text_key)
	lbl.add_theme_font_size_override("font_size", 21)
	lbl.add_theme_color_override("font_color", COL_SECTION)
	_content.add_child(lbl)
	return lbl


func add_status_label(initial_text: String = "") -> Label:
	var lbl := Label.new()
	lbl.text = initial_text
	lbl.add_theme_font_size_override("font_size", 18)
	lbl.add_theme_color_override("font_color", COL_STATUS)
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_content.add_child(lbl)
	return lbl


func add_interactive(parent: Container, control: Control) -> PanelContainer:
	var slot := PanelContainer.new()
	slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	slot.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slot.add_theme_stylebox_override("panel", _interactive_style(false))
	control.mouse_entered.connect(_on_interactive_mouse_entered.bind(slot))
	control.mouse_exited.connect(_on_interactive_mouse_exited.bind(slot))
	slot.add_child(control)
	parent.add_child(slot)
	return slot


func add_toggle(parent: Container, label: String, default_on: bool = true, font_size: int = 23) -> CheckButton:
	var toggle := CheckButton.new()
	toggle.text = label
	toggle.button_pressed = default_on
	toggle.custom_minimum_size.y = 47
	toggle.add_theme_font_size_override("font_size", font_size)
	add_interactive(parent, toggle)
	return toggle


func _build_settings_content(_parent: VBoxContainer) -> void:
	pass


func _on_confirm_requested() -> void:
	confirmed.emit()


func _on_pointer_cleared() -> void:
	_cancel_exit_hold()
	_set_highlighted_slot(null)


func _build_panel(viewport: SubViewport, title_key: String, confirm_key: String) -> void:
	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = COL_PANEL_BG
	panel_style.border_color = COL_PANEL_BORDER
	panel_style.set_border_width_all(2)
	panel_style.set_corner_radius_all(8)
	panel.add_theme_stylebox_override("panel", panel_style)
	viewport.add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 38)
	margin.add_theme_constant_override("margin_right", 38)
	margin.add_theme_constant_override("margin_top", 30)
	margin.add_theme_constant_override("margin_bottom", 30)
	panel.add_child(margin)

	_content = VBoxContainer.new()
	_content.add_theme_constant_override("separation", 14)
	margin.add_child(_content)

	var title := Label.new()
	title.text = tr(title_key)
	title.add_theme_font_size_override("font_size", 36)
	title.add_theme_color_override("font_color", COL_TITLE)
	_content.add_child(title)

	_build_settings_content(_content)

	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_content.add_child(spacer)

	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 14)
	_content.add_child(actions)

	var confirm_button := Button.new()
	confirm_button.text = tr(confirm_key)
	confirm_button.custom_minimum_size.y = 68
	confirm_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	confirm_button.add_theme_font_size_override("font_size", 28)
	confirm_button.pressed.connect(_on_confirm_button_pressed)
	add_interactive(actions, confirm_button)

	var exit_button := Button.new()
	exit_button.text = tr("UI_EXIT")
	exit_button.custom_minimum_size.y = 68
	exit_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	exit_button.add_theme_font_size_override("font_size", 28)
	exit_button.button_down.connect(_on_exit_button_down)
	exit_button.button_up.connect(_on_exit_button_up)
	exit_button.mouse_exited.connect(_on_exit_mouse_exited)
	var exit_slot := add_interactive(actions, exit_button)
	_exit_indicator = HoldIndicator.new()
	_exit_indicator.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	exit_slot.add_child(_exit_indicator)


func _on_confirm_button_pressed() -> void:
	_cancel_exit_hold()
	_on_confirm_requested()


func _on_exit_button_down() -> void:
	_cancel_exit_hold()
	_exit_holding = true


func _on_exit_button_up() -> void:
	_cancel_exit_hold()


func _on_exit_mouse_exited() -> void:
	_cancel_exit_hold()


func _cancel_exit_hold() -> void:
	_exit_holding = false
	_exit_hold_seconds = 0.0
	if _exit_indicator:
		_exit_indicator.set_progress(0.0)


func _on_interactive_mouse_entered(slot: PanelContainer) -> void:
	_set_highlighted_slot(slot)


func _on_interactive_mouse_exited(slot: PanelContainer) -> void:
	if _highlighted_slot == slot:
		_set_highlighted_slot(null)


func _set_highlighted_slot(slot: PanelContainer) -> void:
	if _highlighted_slot == slot:
		return
	if _highlighted_slot != null:
		_highlighted_slot.add_theme_stylebox_override("panel", _interactive_style(false))
	_highlighted_slot = slot
	if _highlighted_slot != null:
		_highlighted_slot.add_theme_stylebox_override("panel", _interactive_style(true))


func _interactive_style(highlighted: bool) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color.TRANSPARENT
	style.border_color = COL_ACCENT if highlighted else Color.TRANSPARENT
	style.set_border_width_all(2)
	style.set_corner_radius_all(6)
	return style
