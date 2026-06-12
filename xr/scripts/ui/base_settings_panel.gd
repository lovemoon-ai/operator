extends "res://scripts/ui/composition_viewport_ui.gd"
class_name BaseSettingsPanel

signal confirmed
signal exit_requested

const COL_PANEL_BG := Color(0.055, 0.067, 0.08, 0.96)
const COL_PANEL_BORDER := Color(0.18, 0.22, 0.26, 1.0)
const COL_TITLE := Color(0.94, 0.96, 0.98)
const COL_SECTION := Color(0.65, 0.70, 0.75)
const COL_STATUS := Color(0.55, 0.80, 0.66)
const ACTION_BUTTON_HEIGHT := 68
const ACTION_BUTTON_MIN_WIDTH := 260
const ICON_PATH := "res://assets/icons/%s.svg"

# Exit used to be a hold-to-confirm action (2 s hold + ring indicator). We
# moved to single-click because the launcher now owns the actual app-quit
# affordance — the in-panel Exit only navigates back to the launcher, so
# the long-hold friction was overkill. The `HoldIndicator` ring and the
# `_exit_holding`/`_exit_hold_seconds` machinery were removed along with
# `EXIT_HOLD_SECONDS`. Subclasses that still call `super._process(delta)`
# get a no-op stub below.

var _content: VBoxContainer
var _scroll_container: ScrollContainer
var _highlighted_slot: PanelContainer
# 内部 PanelContainer，用于 open/close 缩放与淡入淡出动效
var _panel: PanelContainer
# 当前激活的开/关补间，避免并发冲突
var _panel_tween: Tween
var _icon_cache: Dictionary = {}
var _title_row: HBoxContainer
var _actions_row: HBoxContainer

# Title-bar indicator that surfaces the auto-detected input source (hand vs
# controller). Subclasses don't need to know it exists; capture and teleop
# mode controllers drive it via `set_input_mode_indicator()`. The icon alone
# carries the meaning; a text label proved redundant in user testing so the
# slot is icon-only now.
var _input_mode_indicator: TextureRect
var _input_mode_indicator_current := ""


func _setup_settings_panel(
		viewport_size: Vector2i,
		quad_size_m: Vector2,
		title_key: String,
		confirm_key: String,
		layer_sort_order: int = 2,
		initial_visible: bool = true,
		use_outer_scroll: bool = true
) -> void:
	# `use_outer_scroll`: when true, _content is wrapped in a single ScrollContainer
	# so the entire form scrolls as one. Subclasses like TwoColumnSettingsPanel pass
	# false because they install per-section ScrollContainers inside _content instead.
	var viewport := _setup_viewport_layer("SettingsViewport", viewport_size, quad_size_m, layer_sort_order, 18.0)
	_build_panel(viewport, title_key, confirm_key, use_outer_scroll)
	visible = initial_visible


func _process(_delta: float) -> void:
	# Kept as a no-op stub so subclasses' `super._process(delta)` continues
	# to resolve cleanly. There's nothing per-frame for the panel itself
	# now that the exit hold-to-confirm flow is gone.
	pass


func _settings_path() -> String:
	return ""


func _settings_section() -> String:
	return "settings"


func _settings_defaults() -> Dictionary:
	return {}


func _settings_loaded_key() -> String:
	return ""


func _settings_log_tag() -> String:
	return "Settings"


func _settings_secret_keys() -> Dictionary:
	return {}


func _load_settings() -> Dictionary:
	return BaseSettingsPanel.load_settings_from_config(
			_settings_path(),
			_settings_section(),
			_settings_defaults(),
			_settings_loaded_key(),
			_settings_secret_keys()
	)


func _save_settings(options: Dictionary) -> Error:
	return BaseSettingsPanel.save_settings_to_config(
			_settings_path(),
			_settings_section(),
			_settings_defaults(),
			options,
			_settings_log_tag(),
			_settings_secret_keys()
	)


static func load_settings_from_config(
		path: String,
		section: String,
		defaults: Dictionary,
		loaded_key: String = "",
		secret_keys: Dictionary = {}
) -> Dictionary:
	var out := defaults.duplicate(true)
	var cfg := ConfigFile.new()
	var err := cfg.load(path)
	if not loaded_key.is_empty():
		out[loaded_key] = err == OK
	if err != OK:
		return out

	for key in defaults.keys():
		var default_value: Variant = defaults[key]
		if secret_keys.has(key):
			var encoded_key := str(secret_keys[key])
			if cfg.has_section_key(section, encoded_key):
				out[key] = _decode_setting_secret(str(cfg.get_value(section, encoded_key, "")))
			elif cfg.has_section_key(section, key):
				# Compatibility with older builds that stored the field under
				# its plain key before the base settings persistence handled
				# secret obfuscation centrally.
				out[key] = _coerce_setting_value(cfg.get_value(section, key, default_value), default_value)
			continue
		out[key] = _coerce_setting_value(cfg.get_value(section, key, default_value), default_value)
	return out


static func save_settings_to_config(
		path: String,
		section: String,
		defaults: Dictionary,
		options: Dictionary,
		log_tag: String = "Settings",
		secret_keys: Dictionary = {}
) -> Error:
	if path.is_empty():
		push_warning("[%s] Cannot save settings: empty path" % log_tag)
		return ERR_INVALID_PARAMETER
	var cfg := ConfigFile.new()
	# Preserve unknown keys so newer builds or external tooling do not lose
	# data when an older panel saves its known fields.
	cfg.load(path)
	for key in defaults.keys():
		var value: Variant = options.get(key, defaults[key])
		if secret_keys.has(key):
			var encoded_key := str(secret_keys[key])
			var secret := str(value)
			if secret.is_empty():
				if cfg.has_section_key(section, encoded_key):
					cfg.erase_section_key(section, encoded_key)
			else:
				cfg.set_value(section, encoded_key, _encode_setting_secret(secret))
			if cfg.has_section_key(section, key):
				cfg.erase_section_key(section, key)
			continue
		cfg.set_value(section, key, value)
	var err := cfg.save(path)
	if err != OK:
		push_warning("[%s] Failed to save %s: error %d" % [log_tag, path, err])
	return err


static func _coerce_setting_value(value: Variant, default_value: Variant) -> Variant:
	match typeof(default_value):
		TYPE_BOOL:
			return bool(value)
		TYPE_INT:
			return int(value)
		TYPE_FLOAT:
			return float(value)
		TYPE_STRING:
			return str(value)
		_:
			return value


static func _encode_setting_secret(plain: String) -> String:
	return Marshalls.utf8_to_base64(plain)


static func _decode_setting_secret(encoded: String) -> String:
	if encoded.is_empty():
		return ""
	return Marshalls.base64_to_utf8(encoded)


func open() -> void:
	# 开启面板：缩放 + 淡入
	visible = true
	_play_ui_sound("hover")
	if _panel == null:
		return
	# 取消上一次进行中的补间
	if _panel_tween != null and _panel_tween.is_valid():
		_panel_tween.kill()
	# pivot 需要在面板尺寸就绪后再设置，故延迟一帧执行
	call_deferred("_play_open_tween")


func close() -> void:
	clear_pointer()
	if _panel == null:
		visible = false
		return
	if _panel_tween != null and _panel_tween.is_valid():
		_panel_tween.kill()
	_apply_pivot()
	_panel_tween = _panel.create_tween()
	_panel_tween.set_parallel(true)
	_panel_tween.set_trans(Tween.TRANS_BACK)
	_panel_tween.set_ease(Tween.EASE_IN)
	_panel_tween.tween_property(_panel, "scale", Vector2(0.9, 0.9), 0.15)
	_panel_tween.tween_property(_panel, "modulate:a", 0.0, 0.15)
	_panel_tween.chain().tween_callback(Callable(self, "_on_close_tween_finished"))


func _play_open_tween() -> void:
	# 在面板布局完成后再启动开启补间
	if _panel == null:
		return
	_apply_pivot()
	_panel.scale = Vector2(0.9, 0.9)
	_panel.modulate.a = 0.0
	_panel_tween = _panel.create_tween()
	_panel_tween.set_parallel(true)
	_panel_tween.set_trans(Tween.TRANS_BACK)
	_panel_tween.set_ease(Tween.EASE_OUT)
	_panel_tween.tween_property(_panel, "scale", Vector2(1.0, 1.0), 0.25)
	_panel_tween.tween_property(_panel, "modulate:a", 1.0, 0.25)


func _apply_pivot() -> void:
	# pivot 必须设为面板中心，否则缩放会从左上角发生
	if _panel == null:
		return
	_panel.pivot_offset = _panel.size * 0.5


func _on_close_tween_finished() -> void:
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
	if control is CheckButton:
		(control as CheckButton).toggled.connect(func(enabled: bool) -> void:
			_play_ui_sound("toggle_on" if enabled else "toggle_off")
		)
	elif control is Button:
		(control as Button).pressed.connect(func() -> void: _play_ui_sound("click"))
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
	_set_highlighted_slot(null)


func scroll_by_pixels(delta_pixels: float) -> bool:
	return _scroll_container_by_pixels(_scroll_container, delta_pixels)


func _scroll_container_by_pixels(scroll: ScrollContainer, delta_pixels: float) -> bool:
	if scroll == null or absf(delta_pixels) < 0.01:
		return false
	var vbar := scroll.get_v_scroll_bar()
	if vbar == null:
		return false
	var max_scroll := maxi(0, int(round(vbar.max_value - vbar.page)))
	if max_scroll <= 0:
		return false
	var before := scroll.scroll_vertical
	scroll.scroll_vertical = clampi(before + int(round(delta_pixels)), 0, max_scroll)
	return scroll.scroll_vertical != before


func _build_panel(viewport: SubViewport, title_key: String, confirm_key: String, use_outer_scroll: bool = true) -> void:
	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# 保存引用以便 open/close 做缩放与淡入淡出动效
	_panel = panel
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

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 14)
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	margin.add_child(root)

	# Title row: panel title on the left, auto-detected input-mode indicator
	# pinned to the right. The indicator is hidden until a controller / hand
	# update arrives via set_input_mode_indicator(); we don't want a blank
	# square sitting next to the title for the brief window before XR
	# tracking warms up.
	var title_row := HBoxContainer.new()
	_title_row = title_row
	title_row.add_theme_constant_override("separation", 14)
	title_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_child(title_row)

	var title := Label.new()
	title.text = tr(title_key)
	title.add_theme_font_size_override("font_size", 36)
	title.add_theme_color_override("font_color", COL_TITLE)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(title)

	_input_mode_indicator = TextureRect.new()
	_input_mode_indicator.custom_minimum_size = Vector2(40, 40)
	_input_mode_indicator.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
	_input_mode_indicator.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_input_mode_indicator.size_flags_horizontal = Control.SIZE_SHRINK_END
	_input_mode_indicator.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_input_mode_indicator.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# The SVGs bake the orange accent (#ffaa2b) into their stroke, so no
	# modulate tint here -- tinting orange-on-orange would darken the icon.
	_input_mode_indicator.visible = false
	title_row.add_child(_input_mode_indicator)

	_content = VBoxContainer.new()
	_content.add_theme_constant_override("separation", 14)
	_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	if use_outer_scroll:
		_scroll_container = ScrollContainer.new()
		_scroll_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_scroll_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
		_scroll_container.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		_scroll_container.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
		root.add_child(_scroll_container)
		_scroll_container.add_child(_content)
	else:
		root.add_child(_content)

	_build_settings_content(_content)

	var actions := HBoxContainer.new()
	_actions_row = actions
	actions.add_theme_constant_override("separation", 14)
	actions.custom_minimum_size.y = ACTION_BUTTON_HEIGHT
	actions.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_child(actions)

	var confirm_button := Button.new()
	confirm_button.text = tr(confirm_key)
	_apply_button_icon(confirm_button, "check")
	confirm_button.clip_text = true
	confirm_button.custom_minimum_size = Vector2(ACTION_BUTTON_MIN_WIDTH, ACTION_BUTTON_HEIGHT)
	confirm_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	confirm_button.add_theme_font_size_override("font_size", 28)
	confirm_button.pressed.connect(_on_confirm_button_pressed)
	_configure_action_slot(add_interactive(actions, confirm_button))

	var exit_button := Button.new()
	exit_button.text = tr("UI_EXIT")
	_apply_button_icon(exit_button, "power")
	exit_button.clip_text = true
	exit_button.custom_minimum_size = Vector2(ACTION_BUTTON_MIN_WIDTH, ACTION_BUTTON_HEIGHT)
	exit_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	exit_button.add_theme_font_size_override("font_size", 28)
	# Single-click exit. Replaces the previous hold-to-confirm flow — the
	# launcher's own Exit card now owns the irreversible "quit app" affordance,
	# so the in-panel button just navigates back. No ring indicator needed.
	exit_button.pressed.connect(_on_exit_button_pressed)
	var exit_slot := add_interactive(actions, exit_button)
	_configure_action_slot(exit_slot)


func _set_panel_chrome_visible(visible_value: bool) -> void:
	if _title_row:
		_title_row.visible = visible_value
	if _actions_row:
		_actions_row.visible = visible_value


func _configure_action_slot(slot: PanelContainer) -> void:
	slot.custom_minimum_size = Vector2(ACTION_BUTTON_MIN_WIDTH, ACTION_BUTTON_HEIGHT)
	slot.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slot.size_flags_stretch_ratio = 1.0


func _on_confirm_button_pressed() -> void:
	_play_ui_sound("confirm")
	_on_confirm_requested()


func _on_exit_button_pressed() -> void:
	_play_ui_sound("confirm")
	exit_requested.emit()


func _on_interactive_mouse_entered(slot: PanelContainer) -> void:
	_play_ui_sound("hover", -5.0)
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


## Surface the auto-detected input source at the top-right of the panel.
## `mode` accepts:
##   "hands"        -> hand-gesture icon
##   "controllers"  -> VR-controller icon
##   "head"         -> reuses the controller icon (operator is still holding one)
##   ""             -> hide the indicator entirely
## Icon-only; no accompanying label — the glyph carries the meaning and the
## label proved noisy beside the panel title.
func set_input_mode_indicator(mode: String) -> void:
	if mode == _input_mode_indicator_current:
		return
	_input_mode_indicator_current = mode
	if _input_mode_indicator == null:
		return
	var icon_name := ""
	match mode:
		"hands":
			icon_name = "hand"
		"controllers", "head":
			# "head" (volume-button capture) still maps to the controller icon
			# because the user is physically holding one.
			icon_name = "controller"
		_:
			icon_name = ""
	var has_indicator := icon_name != ""
	_input_mode_indicator.visible = has_indicator
	if not has_indicator:
		_input_mode_indicator.texture = null
		return
	var icon := _load_icon(icon_name)
	if icon != null:
		_input_mode_indicator.texture = icon


func _apply_button_icon(button: Button, icon_name: String) -> void:
	button.icon = _load_icon(icon_name)
	button.expand_icon = true
	button.icon_alignment = HORIZONTAL_ALIGNMENT_LEFT
	button.add_theme_constant_override("icon_max_width", 30)


func _load_icon(icon_name: String) -> Texture2D:
	# Load the IMPORTED texture (.ctex) via Godot's standard resource loader.
	#
	# Earlier this function read the raw .svg via FileAccess and decoded with
	# Image.load_svg_from_string() at runtime. That depended on the runtime SVG
	# decoder being compiled into the *export template* — Meta Quest / Pico
	# templates frequently omit it, so every icon silently came back blank in
	# the headset (success in the editor, failure on device). load() returns
	# the .ctex that Godot baked at import time and works in every export
	# configuration.
	if _icon_cache.has(icon_name):
		return _icon_cache[icon_name]
	var path := ICON_PATH % icon_name
	var texture: Texture2D = null
	if not ResourceLoader.exists(path):
		push_warning("[Icon] resource not registered: %s (missing .svg or stale .import?)" % path)
	else:
		var res := load(path)
		if res is Texture2D:
			texture = res
			print("[Icon] loaded %s (%dx%d)" % [icon_name, texture.get_width(), texture.get_height()])
		else:
			push_warning("[Icon] load() returned %s, not Texture2D, for %s" % [typeof(res), path])
	if texture == null:
		push_warning("[Icon] returning null texture for '%s'" % icon_name)
	_icon_cache[icon_name] = texture
	return texture


func _play_ui_sound(action: String, volume_db: float = 0.0) -> void:
	_play_feedback(action, volume_db, self)
