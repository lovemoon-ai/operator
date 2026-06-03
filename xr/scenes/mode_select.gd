extends Node3D

const TELEOP_SCENE := "res://scenes/teleop_main.tscn"
const EGO_SCENE := "res://scenes/capture_app.tscn"
const MODE_TELEOP := "teleop"
const MODE_EGO := "ego"

@onready var _start_xr: XRToolsStartXR = get_node_or_null("StartXR")
@onready var _mode_panel: Node3D = $XROrigin3D/XRCamera3D/ModePanel

var _mode_ui: Control
var _xr_started := false
var _changing_scene := false


func _ready() -> void:
	if Engine.is_editor_hint():
		return

	var automation_mode := _get_automation_mode()
	if not automation_mode.is_empty():
		print("[Operator] Automation mode selected: %s" % automation_mode)
		_open_mode(automation_mode)
		return

	_configure_passthrough()
	_mode_panel.visible = false

	if _start_xr:
		_start_xr.xr_started.connect(_on_xr_started)
		if _start_xr.has_signal("xr_failed"):
			_start_xr.xr_failed.connect(_on_xr_failed)
	else:
		call_deferred("_on_xr_started")

	print("[Operator] Mode select initialized")


func _on_xr_started() -> void:
	if _xr_started:
		return
	_xr_started = true
	_configure_passthrough()
	_mode_panel.visible = true

	for i in range(60):
		await get_tree().process_frame
		if _mode_panel.has_method("get_scene_instance") and _mode_panel.get_scene_instance() != null:
			break

	_wire_mode_ui()
	print("[Operator] Mode select ready")


func _on_xr_failed() -> void:
	_mode_panel.visible = true
	_wire_mode_ui()
	if _mode_ui and _mode_ui.has_method("set_status"):
		_mode_ui.set_status(tr("UI_OPENXR_FAILED"))


func _wire_mode_ui() -> void:
	if _mode_ui != null:
		return
	if _mode_panel and _mode_panel.has_method("get_scene_instance"):
		_mode_ui = _mode_panel.get_scene_instance() as Control

	if _mode_ui == null:
		push_warning("[Operator] ModeSelect UI is not ready")
		return
	if _mode_ui.has_signal("teleop_selected"):
		_mode_ui.teleop_selected.connect(_open_teleop)
	if _mode_ui.has_signal("ego_selected"):
		_mode_ui.ego_selected.connect(_open_ego)


func _open_teleop() -> void:
	_open_mode(MODE_TELEOP)


func _open_ego() -> void:
	_open_mode(MODE_EGO)


func _open_mode(mode: String) -> void:
	var path := _scene_for_mode(mode)
	if path.is_empty():
		push_warning("[Operator] Ignoring unknown mode: %s" % mode)
		return
	_change_scene(path)


func _change_scene(path: String) -> void:
	if _changing_scene:
		return
	_changing_scene = true
	print("[Operator] Mode selected: %s" % path)
	_mode_panel.visible = false
	call_deferred("_change_scene_deferred", path)


func _change_scene_deferred(path: String) -> void:
	await get_tree().process_frame
	var err := get_tree().change_scene_to_file(path)
	if err != OK:
		_changing_scene = false
		_mode_panel.visible = true
		push_error("[Operator] Failed to change scene to %s: %s" % [path, err])


func _scene_for_mode(mode: String) -> String:
	match _normalize_mode(mode):
		MODE_TELEOP:
			return TELEOP_SCENE
		MODE_EGO:
			return EGO_SCENE
		_:
			return ""


func _get_automation_mode() -> String:
	var mode := _mode_from_args(OS.get_cmdline_user_args())
	if mode.is_empty():
		mode = _mode_from_args(OS.get_cmdline_args())
	if mode.is_empty():
		mode = _mode_from_environment()
	return _normalize_mode(mode)


func _mode_from_args(args: PackedStringArray) -> String:
	for i in range(args.size()):
		var arg := String(args[i]).strip_edges()
		if arg == "--operator-mode" or arg == "--mode":
			if i + 1 < args.size():
				return String(args[i + 1]).strip_edges()
			push_warning("[Operator] %s requires a value" % arg)
			return ""
		if arg.begins_with("--operator-mode="):
			return arg.substr("--operator-mode=".length()).strip_edges()
		if arg.begins_with("--mode="):
			return arg.substr("--mode=".length()).strip_edges()
		if arg.begins_with("operator.mode="):
			return arg.substr("operator.mode=".length()).strip_edges()
		if arg.begins_with("operator_mode="):
			return arg.substr("operator_mode=".length()).strip_edges()
	return ""


func _mode_from_environment() -> String:
	for key in ["OPERATOR_MODE", "XR_OPERATOR_MODE"]:
		if OS.has_environment(key):
			return OS.get_environment(key).strip_edges()
	return ""


func _normalize_mode(raw_mode: String) -> String:
	var mode := raw_mode.strip_edges().to_lower().replace("-", "_")
	match mode:
		MODE_TELEOP, "teleoperation", "remote", "remote_control", "driver":
			return MODE_TELEOP
		MODE_EGO, "egocentric", "capture", "capture_app":
			return MODE_EGO
		"":
			return ""
		_:
			push_warning("[Operator] Unknown automation mode '%s' (expected teleop or ego)" % raw_mode)
			return ""


func _configure_passthrough() -> void:
	var viewport := get_viewport()
	if viewport:
		viewport.transparent_bg = true
		viewport.physics_object_picking = false
		var world := viewport.get_world_3d()
		if world and world.environment:
			world.environment.background_mode = Environment.BG_CLEAR_COLOR
			world.environment.background_color = Color(0, 0, 0, 0)

	var xr_interface := XRServer.find_interface("OpenXR")
	if xr_interface:
		xr_interface.environment_blend_mode = XRInterface.XR_ENV_BLEND_MODE_ALPHA_BLEND
