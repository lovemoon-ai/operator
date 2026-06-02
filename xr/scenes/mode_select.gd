extends Node3D

const TELEOP_SCENE := "res://scenes/teleop_main.tscn"
const EGO_SCENE := "res://scenes/capture_app.tscn"

@onready var _start_xr: XRToolsStartXR = get_node_or_null("StartXR")
@onready var _mode_panel: Node3D = $XROrigin3D/XRCamera3D/ModePanel

var _mode_ui: Control
var _xr_started := false
var _changing_scene := false


func _ready() -> void:
	if Engine.is_editor_hint():
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
		_mode_ui.set_status("OpenXR failed")


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
	_change_scene(TELEOP_SCENE)


func _open_ego() -> void:
	_change_scene(EGO_SCENE)


func _change_scene(path: String) -> void:
	if _changing_scene:
		return
	_changing_scene = true
	print("[Operator] Mode selected: %s" % path)
	var err := get_tree().change_scene_to_file(path)
	if err != OK:
		_changing_scene = false
		push_error("[Operator] Failed to change scene to %s: %s" % [path, err])


func _configure_passthrough() -> void:
	var viewport := get_viewport()
	if viewport:
		viewport.transparent_bg = true
		var world := viewport.get_world_3d()
		if world and world.environment:
			world.environment.background_mode = Environment.BG_CLEAR_COLOR
			world.environment.background_color = Color(0, 0, 0, 0)

	var xr_interface := XRServer.find_interface("OpenXR")
	if xr_interface:
		xr_interface.environment_blend_mode = XRInterface.XR_ENV_BLEND_MODE_ALPHA_BLEND
