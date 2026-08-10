extends Node3D

const EgoQRScannerScript := preload("res://scripts/ui/ego_qr_scanner.gd")
const TrackingProviderScript := preload("res://scripts/xr/tracking_provider.gd")
const MemWorldClientScript := preload("res://addons/memworld/memworld_client.gd")
const PoseInferenceDisplayScript := preload("res://addons/pose-inference/pose_inference_display.gd")
const XRCaptureProviderScript := preload("res://addons/quest_capture_android/api/XRCaptureProvider.gd")
const SettingsInteractionRouterScript := preload("res://scripts/ui/settings_interaction_router.gd")
const OperatorUIPointerVisualScript := preload("res://scripts/xr/operator_ui_pointer_visual.gd")

const QR_OFFSET := Transform3D(Basis.IDENTITY, Vector3(0.0, -0.04, -0.92))
const LAUNCHER_SCENE := "res://scenes/main.tscn"

var _origin: XROrigin3D
var _camera: XRCamera3D
var _scanner: EgoQRScanner
var _client: MemWorldClient
var _pointer_router: SettingsInteractionRouter


func _ready() -> void:
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color(0.0, 0.0, 0.0, 0.0)
	add_child(environment)
	var xr := XRServer.find_interface("OpenXR")
	if xr:
		xr.environment_blend_mode = XRInterface.XR_ENV_BLEND_MODE_ALPHA_BLEND

	_origin = XROrigin3D.new()
	_origin.current = true
	add_child(_origin)
	_camera = XRCamera3D.new()
	_origin.add_child(_camera)
	for hand in ["left_hand", "right_hand"]:
		var controller := XRController3D.new()
		controller.tracker = StringName(hand)
		controller.pose = &"grip"
		_origin.add_child(controller)

	var left_aim := _create_aim_pointer("LeftAimPointer", &"left_hand")
	var right_aim := _create_aim_pointer("RightAimPointer", &"right_hand")
	var pointer_visual := OperatorUIPointerVisualScript.new()
	_origin.add_child(pointer_visual)
	_pointer_router = SettingsInteractionRouterScript.new()
	_pointer_router.configure(_origin, _camera, left_aim, right_aim, pointer_visual)
	_origin.add_child(_pointer_router)

	var tracking: TrackingProvider = TrackingProviderScript.new()
	add_child(tracking)
	_client = MemWorldClientScript.new()
	_client.set_tracking_provider(tracking)
	_client.set_calibration(_query_left_camera_calibration())
	_client.connection_failed.connect(_on_connection_failed)
	_client.disconnected_from_server.connect(_on_disconnected)
	add_child(_client)

	var display: PoseInferenceDisplay = PoseInferenceDisplayScript.new()
	display.head_lock_target = _camera
	_origin.add_child(display)
	_client.image_received.connect(display.show_jpeg)

	_scanner = EgoQRScannerScript.new()
	_scanner.payload_accepted.connect(_on_qr_payload)
	_scanner.cancelled.connect(_return_to_launcher)
	_origin.add_child(_scanner)
	call_deferred("_open_scanner")


func _query_left_camera_calibration() -> Dictionary:
	var provider: XRCaptureProvider = XRCaptureProviderScript.new()
	if not provider.bind():
		push_error("[memWorld] QuestCapturePlugin is unavailable")
		return {}
	var parsed: Variant = JSON.parse_string(provider.query_passthrough_camera_metadata_json("left"))
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("[memWorld] Camera metadata response is not JSON")
		return {}
	var calibration := parsed as Dictionary
	if not bool(calibration.get("ok", false)):
		push_error("[memWorld] Camera metadata failed: %s" % calibration.get("error", "unknown"))
		return {}
	print("[memWorld] metadata-only calibration: %s" % JSON.stringify(calibration))
	return calibration


func _process(_delta: float) -> void:
	if _scanner != null and _scanner.visible:
		_scanner.transform = _camera.transform * QR_OFFSET
		_pointer_router.interaction_mode = "controllers"
		_pointer_router.busy = false
		_pointer_router.set_targets([_scanner])
		_pointer_router.update_pointer()


func _open_scanner() -> void:
	_scanner.open()


func _on_qr_payload(payload: String) -> void:
	if _client.configure_from_qr(payload):
		_scanner.close()


func _on_connection_failed(reason: String) -> void:
	_client.disconnect_from_server()
	_scanner.show_error(reason)


func _on_disconnected() -> void:
	_client.disconnect_from_server()
	_scanner.show_error("Connection lost. Scan the MemWorld QR code again.")


func _return_to_launcher() -> void:
	_client.disconnect_from_server()
	get_tree().change_scene_to_file(LAUNCHER_SCENE)


func _create_aim_pointer(node_name: String, tracker: StringName) -> XRController3D:
	var pointer := XRController3D.new()
	pointer.name = node_name
	pointer.tracker = tracker
	pointer.pose = &"aim"
	_origin.add_child(pointer)
	return pointer
