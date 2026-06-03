extends Node
## Bridges multiple XR controller actions into XRToolsFunctionPointer clicks.
##
## XRToolsFunctionPointer only accepts one button action. Some OpenXR runtimes
## expose trigger clicks as an analog trigger value, so this script synthesizes
## press/release events while leaving XRTools' raycast and viewport mapping intact.

@export var pointer_path: NodePath
@export var controller_path: NodePath
@export var click_actions: PackedStringArray = PackedStringArray(["trigger_click", "primary_click", "select_button"])
@export var analog_trigger_action: StringName = &"trigger"
@export var trigger_press_threshold: float = 0.55
@export var trigger_release_threshold: float = 0.35

var _pointer: Node
var _controller: XRController3D
var _pressed := false
var _pressed_source := ""
var _trigger_down := false


func _ready() -> void:
	_resolve_nodes()
	_connect_controller()
	set_process(true)


func _exit_tree() -> void:
	_disconnect_controller()


func _process(_delta: float) -> void:
	if _controller == null:
		_resolve_nodes()
		_connect_controller()
		if _controller == null:
			return

	_update_analog_trigger()


func _resolve_nodes() -> void:
	if _pointer == null and not pointer_path.is_empty():
		_pointer = get_node_or_null(pointer_path)
	if _controller == null and not controller_path.is_empty():
		_controller = get_node_or_null(controller_path) as XRController3D


func _connect_controller() -> void:
	if _controller == null:
		return
	if not _controller.button_pressed.is_connected(_on_button_pressed):
		_controller.button_pressed.connect(_on_button_pressed)
	if not _controller.button_released.is_connected(_on_button_released):
		_controller.button_released.connect(_on_button_released)


func _disconnect_controller() -> void:
	if _controller == null:
		return
	if _controller.button_pressed.is_connected(_on_button_pressed):
		_controller.button_pressed.disconnect(_on_button_pressed)
	if _controller.button_released.is_connected(_on_button_released):
		_controller.button_released.disconnect(_on_button_released)


func _on_button_pressed(action: StringName) -> void:
	var action_name := String(action)
	if click_actions.has(action_name):
		_press(_source_for_action(action_name))


func _on_button_released(action: StringName) -> void:
	var action_name := String(action)
	if click_actions.has(action_name):
		_release(_source_for_action(action_name))


func _update_analog_trigger() -> void:
	if analog_trigger_action == &"" or _controller == null:
		return

	var value := _controller.get_float(analog_trigger_action)
	var was_down := _trigger_down
	if _trigger_down:
		_trigger_down = value > trigger_release_threshold
	else:
		_trigger_down = value >= trigger_press_threshold

	if _trigger_down == was_down:
		return
	if _trigger_down:
		_press("trigger")
	else:
		_release("trigger")


func _press(source: String) -> void:
	if _pressed or _pointer == null or not _is_pointer_enabled():
		return
	if not _pointer.has_method("_button_pressed"):
		return

	_pointer.call("_button_pressed")
	if _pointer.get("target") != null:
		_pressed = true
		_pressed_source = source


func _release(source: String) -> void:
	if not _pressed or source != _pressed_source or _pointer == null:
		return
	if _pointer.has_method("_button_released"):
		_pointer.call("_button_released")
	_pressed = false
	_pressed_source = ""


func _source_for_action(action_name: String) -> String:
	if action_name == "trigger_click":
		return "trigger"
	return action_name


func _is_pointer_enabled() -> bool:
	var value: Variant = _pointer.get("enabled")
	if typeof(value) == TYPE_NIL:
		return true
	return bool(value)
