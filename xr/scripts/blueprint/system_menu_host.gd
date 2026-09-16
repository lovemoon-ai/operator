extends Node
## One system-owned menu, shared across input modes and robot sessions.
signal connection_requested(connect_requested: bool)

const Runtime := preload("res://scripts/blueprint/blueprint_runtime.gd")
const SystemBlueprint := preload("res://scripts/blueprint/system_menu_blueprint.gd")
const Composer := preload("res://scripts/blueprint/menu_composer.gd")
const MenuView := preload("res://scripts/ui/system_menu_view.gd")
const HandMapper := preload("res://scripts/input/hand_gesture_mapper.gd")
var menu: Node3D
var _camera: XRCamera3D
var _origin: XROrigin3D
var _tracking: Node
var _detail := ""
var runtime: BlueprintRuntime
var robot_runtime: BlueprintRuntime
var _left: XRController3D
var _right: XRController3D
var _sequence := 0
var _last_values: Dictionary = {}
var _enabled := false
var _connected := false
var _can_recenter := false
var _last_error := ""


func configure(origin: XROrigin3D, camera: XRCamera3D, left: XRController3D, right: XRController3D,
		tracking: Node, remote_runtime: BlueprintRuntime) -> void:
	_left = left
	_right = right
	_origin = origin
	_camera = camera
	_tracking = tracking
	robot_runtime = remote_runtime
	runtime = Runtime.new()
	runtime.name = "SystemControllerBlueprint"
	runtime.configure(origin, camera, left, right, tracking)
	runtime.event_emitted.connect(_on_local_action)
	origin.add_child(runtime)
	runtime.apply_blueprint(SystemBlueprint.definition())
	runtime.set_suspended(true)
	menu = MenuView.new()
	menu.name = "SystemMenu"
	origin.add_child(menu)
	menu.call("configure_controller", left, right.tracker if right != null else &"right_hand", camera)
	menu.connect("item_activated", _on_menu_item)
	runtime.menu_changed.connect(_refresh_menu)
	if robot_runtime != null:
		robot_runtime.menu_changed.connect(_refresh_menu)
	_refresh_menu()


func set_error(message: String) -> void:
	_last_error = message


func update_context(connected: bool, connecting: bool, enabled: bool) -> void:
	if runtime == null:
		return
	_connected = connected
	if _enabled != enabled:
		_enabled = enabled
		runtime.set_suspended(not enabled)
	var remote: Dictionary = robot_runtime.controller_status() if robot_runtime != null and connected else {}
	_can_recenter = connected and robot_runtime != null and robot_runtime.can_recenter()
	var state := indicator_state(connected, connecting, remote)
	var detail := str(remote.get("message", "")) if connected else tr("UI_CONNECT_ROBOT_HINT")
	if not _last_error.is_empty():
		detail = _last_error
	elif connecting:
		detail = tr("UI_CONNECTION_PENDING")
	_detail = detail
	var values := {
		"local.connection_active": connected or connecting,
		# Always actionable while the menu is live: it disconnects a session, or
		# while disconnected asks to connect, which the owner routes to Settings.
		"local.connection_available": enabled,
		"local.can_recenter": enabled and _can_recenter,
		"local.recenter_value": false, "local.state": state,
		"local.left_tracked": enabled and _tracked(_left),
		"local.right_tracked": enabled and _tracked(_right),
	}
	if values == _last_values:
		_refresh_menu()
		return
	_last_values = values.duplicate()
	_sequence += 1
	runtime.apply_state({
		"schema": BlueprintContract.STATE_SCHEMA, "blueprint_id": SystemBlueprint.ID,
		"blueprint_revision": 1, "sequence": _sequence, "timestamp_ns": Time.get_ticks_usec() * 1000,
		"values": values,
	})
	_refresh_menu()


func _refresh_menu() -> void:
	if not is_instance_valid(menu):
		return
	var remote: Array[Dictionary] = robot_runtime.menu_entries() if _connected and robot_runtime != null else []
	menu.call("set_content", Composer.compose(runtime.menu_entries(), remote), _detail)


func _process(delta: float) -> void:
	if not is_instance_valid(menu):
		return
	var interaction := get_node_or_null("/root/OperatorInteraction")
	var mode := str(interaction.get("current_mode")) if interaction != null else "head"
	var enabled := _enabled and _camera != null
	# Do not allow a reset chord to become a menu click through either source.
	if interaction != null and bool(interaction.call("_blueprint_input_reserved")):
		menu.call("cancel_interaction")
		return
	var palm: Dictionary = {}
	var tip: Variant = null
	if mode == "hands" and enabled and _tracking != null:
		var left: Array = _tracking.call("get_hand_joints", 0)
		var right: Array = _tracking.call("get_hand_joints", 1)
		palm = HandMapper.palm_menu_state(left, _camera.transform.origin, 0)
		tip = HandMapper.index_tip_position(right)
	menu.call("update_presentation", mode, enabled, palm,
		_camera.transform if _camera != null else Transform3D.IDENTITY, tip, delta)


func _on_menu_item(item: Dictionary) -> void:
	if not _enabled:
		return
	var token: Dictionary = item.get("token", {})
	if item.get("owner") == "system":
		runtime.dispatch_menu(token, bool(item.get("value", false)))
	elif item.get("owner") == "robot" and _connected and robot_runtime != null:
		robot_runtime.dispatch_menu(token, bool(item.get("value", false)))


static func indicator_state(connected: bool, connecting: bool, remote: Dictionary) -> String:
	if connecting:
		return "busy"
	if not connected:
		return "disconnected"
	if bool(remote.get("pending", false)):
		return "busy"
	if bool(remote.get("required", false)):
		return "needs_reset"
	return "ready"


func _tracked(controller: XRController3D) -> bool:
	if not is_instance_valid(controller) or not controller.global_transform.is_finite():
		return false
	var interaction := get_node_or_null("/root/OperatorInteraction")
	return interaction != null and bool(interaction.call("is_controller_source_active", controller))


func _on_local_action(event: Dictionary) -> void:
	if not _enabled:
		return
	match str(event.get("component_id", "")):
		"connection":
			_last_error = ""
			connection_requested.emit(bool(event.get("value", false)))
		"recenter":
			if _can_recenter and not robot_runtime.recenter_robot(2.0):
				_last_error = tr("UI_RECENTER_ROBOT_FAILED")


func _exit_tree() -> void:
	if is_instance_valid(menu):
		menu.queue_free()
	if is_instance_valid(runtime):
		runtime.queue_free()
