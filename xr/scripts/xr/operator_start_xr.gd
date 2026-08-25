@tool
class_name OperatorStartXR
extends XRToolsStartXR

const PICO_HAND_TRACKING_PERMISSION := "com.picovr.permission.HAND_TRACKING"

var _permission_request_pending := false
var _xr_initialization_started := false


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	if not _requires_pico_hand_permission(
			OS.get_name(),
			OS.has_feature("pico"),
			bool(ProjectSettings.get_setting_with_override("xr/openxr/extensions/hand_tracking")),
			OS.get_granted_permissions()
	):
		_initialize_once()
		return

	var permission_result := Callable(self, "_on_request_permissions_result")
	if not get_tree().on_request_permissions_result.is_connected(permission_result):
		get_tree().on_request_permissions_result.connect(permission_result)
	_permission_request_pending = true
	print("[Operator] Requesting PICO hand tracking permission before OpenXR")
	if OS.request_permission(PICO_HAND_TRACKING_PERMISSION):
		_finish_permission_request(true)


static func _requires_pico_hand_permission(
		platform_name: String,
		pico_build: bool,
		hand_tracking_enabled: bool,
		granted_permissions: PackedStringArray
) -> bool:
	return platform_name == "Android" \
			and pico_build \
			and hand_tracking_enabled \
			and not granted_permissions.has(PICO_HAND_TRACKING_PERMISSION)


func _on_request_permissions_result(permission: String, granted: bool) -> void:
	if not _permission_request_pending or permission != PICO_HAND_TRACKING_PERMISSION:
		return
	_finish_permission_request(granted)


func _finish_permission_request(granted: bool) -> void:
	_permission_request_pending = false
	var permission_result := Callable(self, "_on_request_permissions_result")
	if get_tree().on_request_permissions_result.is_connected(permission_result):
		get_tree().on_request_permissions_result.disconnect(permission_result)
	if granted:
		print("[Operator] PICO hand tracking permission granted")
	else:
		push_warning("[Operator] PICO hand tracking permission denied; continuing with controller input")
	_initialize_once()


func _initialize_once() -> void:
	if _xr_initialization_started:
		return
	_xr_initialization_started = true
	_initialize()
