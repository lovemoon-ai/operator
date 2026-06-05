extends "res://scripts/ui/base_settings_panel.gd"
class_name TwoColumnSettingsPanel

## Settings panel with a left-side group nav + right-side detail pane.
##
## Subclasses call _setup_two_column_panel() (instead of _setup_settings_panel)
## in their _init(), and then in _build_settings_content() they:
##   1. call build_two_column(parent)
##   2. for each group, call register_group(key, title_key, icon_name)
##      and populate the returned VBoxContainer using the inherited
##      add_toggle / add_interactive / add_section_label helpers
##   3. optionally call select_group(key) — otherwise the first group wins.
##
## NOTE: group_changed is emitted via call_deferred when fired during _init,
## so callers that connect after construction still receive the initial event
## on the next idle frame.

signal group_changed(key: String)

const SIDEBAR_WIDTH := 200
const SIDEBAR_BUTTON_HEIGHT := 56
const SIDEBAR_BUTTON_HSEP := 8
const SIDEBAR_ICON_WIDTH := 26
const DETAIL_PADDING := 12

const COL_SIDEBAR_BG := Color(0.04, 0.05, 0.06, 0.55)
const COL_DETAIL_BG := Color(0.07, 0.085, 0.10, 0.45)
const COL_SIDEBAR_FONT := Color(0.88, 0.91, 0.94)
const COL_SIDEBAR_FONT_SELECTED := Color(1.0, 0.78, 0.40)

var _sidebar: VBoxContainer
var _detail_stack: VBoxContainer        # holds all group containers as siblings
var _detail_scroll: ScrollContainer
var _group_containers: Dictionary = {}  # key -> VBoxContainer
var _group_buttons: Dictionary = {}     # key -> Button
var _active_group: String = ""

# Cached styles — built lazily on first use so we don't allocate a fresh
# StyleBoxFlat per _set_button_selected call (5 groups × N user clicks).
var _style_unselected_normal: StyleBoxFlat
var _style_unselected_hover: StyleBoxFlat
var _style_selected_normal: StyleBoxFlat
var _style_selected_pressed: StyleBoxFlat


func _setup_two_column_panel(
		viewport_size: Vector2i,
		quad_size_m: Vector2,
		title_key: String,
		confirm_key: String,
		layer_sort_order: int = 2,
		initial_visible: bool = true
) -> void:
	# Pass use_outer_scroll=false so the base mounts _content directly under
	# the title; we install per-group ScrollContainers on the right pane.
	_setup_settings_panel(
		viewport_size, quad_size_m, title_key, confirm_key,
		layer_sort_order, initial_visible, false
	)


func build_two_column(parent: VBoxContainer) -> void:
	# Outer split: sidebar | detail
	var split := HBoxContainer.new()
	split.add_theme_constant_override("separation", 14)
	split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	parent.add_child(split)

	_build_sidebar(split)
	_build_detail(split)


func register_group(key: String, title_key: String, icon_name: String = "") -> VBoxContainer:
	if _sidebar == null or _detail_stack == null:
		push_error("[TwoColumnSettingsPanel] build_two_column() must be called before register_group()")
		return null
	if _group_containers.has(key):
		push_warning("[TwoColumnSettingsPanel] group key already registered: %s" % key)
		return _group_containers[key] as VBoxContainer

	# Sidebar button
	var btn := _build_sidebar_button(key, tr(title_key), icon_name)
	_sidebar.add_child(btn)
	_group_buttons[key] = btn

	# Detail container (initially hidden until select_group)
	var container := VBoxContainer.new()
	container.add_theme_constant_override("separation", 14)
	container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	container.size_flags_vertical = Control.SIZE_FILL
	container.visible = false
	_detail_stack.add_child(container)
	_group_containers[key] = container

	# Auto-select the first group registered.
	if _active_group.is_empty():
		select_group(key)
	return container


func select_group(key: String) -> void:
	if not _group_containers.has(key):
		push_warning("[TwoColumnSettingsPanel] unknown group: %s" % key)
		return
	if _active_group == key:
		return

	if not _active_group.is_empty() and _group_containers.has(_active_group):
		(_group_containers[_active_group] as VBoxContainer).visible = false
	if not _active_group.is_empty() and _group_buttons.has(_active_group):
		_set_button_selected(_group_buttons[_active_group] as Button, false)

	_active_group = key
	(_group_containers[key] as VBoxContainer).visible = true
	_set_button_selected(_group_buttons[key] as Button, true)
	# Reset scroll to top so each group starts at the same anchor.
	if _detail_scroll:
		_detail_scroll.scroll_vertical = 0
	# When select_group fires from inside register_group() (which fires from
	# inside _build_settings_content() during _init()), the node isn't in the
	# tree yet and external subscribers have no chance to connect. Defer the
	# signal so they receive the initial event on the next idle frame.
	if is_inside_tree():
		group_changed.emit(key)
	else:
		call_deferred("emit_signal", "group_changed", key)


# --- Internal builders -----------------------------------------------------

func _build_sidebar(split: HBoxContainer) -> void:
	var sidebar_panel := PanelContainer.new()
	sidebar_panel.custom_minimum_size.x = SIDEBAR_WIDTH
	sidebar_panel.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	sidebar_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var sidebar_style := StyleBoxFlat.new()
	sidebar_style.bg_color = COL_SIDEBAR_BG
	sidebar_style.set_corner_radius_all(6)
	sidebar_panel.add_theme_stylebox_override("panel", sidebar_style)
	split.add_child(sidebar_panel)

	var sidebar_margin := MarginContainer.new()
	sidebar_margin.add_theme_constant_override("margin_left", 6)
	sidebar_margin.add_theme_constant_override("margin_right", 6)
	sidebar_margin.add_theme_constant_override("margin_top", 8)
	sidebar_margin.add_theme_constant_override("margin_bottom", 8)
	sidebar_panel.add_child(sidebar_margin)

	var sidebar_scroll := ScrollContainer.new()
	sidebar_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sidebar_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	sidebar_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sidebar_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sidebar_margin.add_child(sidebar_scroll)

	_sidebar = VBoxContainer.new()
	_sidebar.add_theme_constant_override("separation", 4)
	_sidebar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sidebar_scroll.add_child(_sidebar)


func _build_detail(split: HBoxContainer) -> void:
	var detail_panel := PanelContainer.new()
	detail_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var detail_style := StyleBoxFlat.new()
	detail_style.bg_color = COL_DETAIL_BG
	detail_style.set_corner_radius_all(6)
	detail_panel.add_theme_stylebox_override("panel", detail_style)
	split.add_child(detail_panel)

	var detail_margin := MarginContainer.new()
	detail_margin.add_theme_constant_override("margin_left", DETAIL_PADDING)
	detail_margin.add_theme_constant_override("margin_right", DETAIL_PADDING)
	detail_margin.add_theme_constant_override("margin_top", DETAIL_PADDING)
	detail_margin.add_theme_constant_override("margin_bottom", DETAIL_PADDING)
	detail_panel.add_child(detail_margin)

	_detail_scroll = ScrollContainer.new()
	_detail_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_detail_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_detail_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_detail_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	detail_margin.add_child(_detail_scroll)

	# Single VBox holds all group containers as siblings; we just toggle
	# visibility — VBoxContainer skips hidden children when laying out, so
	# only the active group occupies space. SIZE_FILL (not EXPAND) so the
	# stack matches its content height; ScrollContainer activates the
	# scrollbar only when content exceeds the viewport.
	_detail_stack = VBoxContainer.new()
	_detail_stack.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_detail_stack.size_flags_vertical = Control.SIZE_FILL
	_detail_scroll.add_child(_detail_stack)


func _build_sidebar_button(key: String, label: String, icon_name: String) -> Button:
	var btn := Button.new()
	btn.text = label
	btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	btn.clip_text = true
	btn.custom_minimum_size = Vector2(0, SIDEBAR_BUTTON_HEIGHT)
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.add_theme_font_size_override("font_size", 22)
	btn.add_theme_constant_override("h_separation", SIDEBAR_BUTTON_HSEP)
	if icon_name != "":
		var icon := _load_icon(icon_name)
		if icon != null:
			btn.icon = icon
			btn.expand_icon = true
			btn.icon_alignment = HORIZONTAL_ALIGNMENT_LEFT
			btn.add_theme_constant_override("icon_max_width", SIDEBAR_ICON_WIDTH)
	# Kill default focus rect — looks noisy on an XR composition layer.
	btn.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	# Initial unselected styling (also covers font colors).
	_set_button_selected(btn, false)
	btn.mouse_entered.connect(_on_sidebar_button_hover)
	btn.pressed.connect(_on_sidebar_button_pressed.bind(key))
	return btn


func _set_button_selected(btn: Button, selected: bool) -> void:
	_ensure_sidebar_styles()
	# When selected, all states (normal / hover / pressed) keep the selected
	# look — selection wins over hover. When unselected, hover shows a faint
	# border, and `pressed` briefly flashes the selected style as press
	# feedback (the click handler will make it actually selected on release).
	if selected:
		btn.add_theme_stylebox_override("normal", _style_selected_normal)
		btn.add_theme_stylebox_override("hover", _style_selected_normal)
		btn.add_theme_stylebox_override("pressed", _style_selected_pressed)
		btn.add_theme_stylebox_override("disabled", _style_selected_normal)
	else:
		btn.add_theme_stylebox_override("normal", _style_unselected_normal)
		btn.add_theme_stylebox_override("hover", _style_unselected_hover)
		btn.add_theme_stylebox_override("pressed", _style_selected_pressed)
		btn.add_theme_stylebox_override("disabled", _style_unselected_normal)
	var font_color := COL_SIDEBAR_FONT_SELECTED if selected else COL_SIDEBAR_FONT
	btn.add_theme_color_override("font_color", font_color)
	btn.add_theme_color_override("font_hover_color", font_color)
	# `font_pressed_color` matches the press-feedback stylebox: shows the
	# operator that the click registered even before select_group runs.
	btn.add_theme_color_override("font_pressed_color", COL_SIDEBAR_FONT_SELECTED)
	btn.add_theme_color_override("font_focus_color", font_color)


func _ensure_sidebar_styles() -> void:
	if _style_unselected_normal != null:
		return
	_style_unselected_normal = _sidebar_btn_style(false, false)
	_style_unselected_hover = _sidebar_btn_style(true, false)
	_style_selected_normal = _sidebar_btn_style(false, true)
	_style_selected_pressed = _sidebar_btn_style(true, true)


func _sidebar_btn_style(hovered: bool, selected: bool) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	if selected:
		style.bg_color = Color(COL_ACCENT.r, COL_ACCENT.g, COL_ACCENT.b, 0.18)
		style.border_color = COL_ACCENT
	elif hovered:
		style.bg_color = Color(1.0, 1.0, 1.0, 0.05)
		style.border_color = Color(COL_ACCENT.r, COL_ACCENT.g, COL_ACCENT.b, 0.55)
	else:
		style.bg_color = Color.TRANSPARENT
		style.border_color = Color.TRANSPARENT
	style.set_border_width_all(2)
	style.set_corner_radius_all(6)
	style.content_margin_left = 12
	style.content_margin_right = 12
	style.content_margin_top = 8
	style.content_margin_bottom = 8
	return style


func _on_sidebar_button_hover() -> void:
	_play_ui_sound("hover", -5.0)


func _on_sidebar_button_pressed(key: String) -> void:
	_play_ui_sound("click")
	select_group(key)
