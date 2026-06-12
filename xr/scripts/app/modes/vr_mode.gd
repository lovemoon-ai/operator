extends Node3D

@onready var _start_xr: XRToolsStartXR = get_node_or_null("StartXR")
@onready var _origin: XROrigin3D = $XROrigin3D
@onready var _camera: XRCamera3D = $XROrigin3D/XRCamera3D

var _label: Label3D


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	_configure_vr_world()
	_build_placeholder()
	if _start_xr:
		_start_xr.xr_started.connect(_on_xr_started)
		if _start_xr.has_signal("xr_failed"):
			_start_xr.xr_failed.connect(_on_xr_failed)
	else:
		call_deferred("_on_xr_started")
	var xr_interface := XRServer.find_interface("OpenXR")
	if xr_interface and xr_interface.is_initialized():
		call_deferred("_on_xr_started")
	print("[Operator] VR mode entry initialized")


func _process(_delta: float) -> void:
	if _label == null or _camera == null:
		return
	_label.global_transform = _camera.global_transform * Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -1.25))


func _on_xr_started() -> void:
	var viewport := get_viewport()
	if viewport:
		viewport.use_xr = true
	print("[Operator] VR mode ready")


func _on_xr_failed() -> void:
	push_warning("[Operator] OpenXR failed in VR mode")


func _configure_vr_world() -> void:
	var viewport := get_viewport()
	if viewport:
		viewport.transparent_bg = false
	var world := WorldEnvironment.new()
	world.name = "WorldEnvironment"
	world.environment = Environment.new()
	world.environment.background_mode = Environment.BG_COLOR
	world.environment.background_color = Color(0.02, 0.025, 0.028, 1.0)
	add_child(world)
	var light := DirectionalLight3D.new()
	light.name = "KeyLight"
	light.light_energy = 1.1
	light.rotation_degrees = Vector3(-42.0, 34.0, 0.0)
	add_child(light)


func _build_placeholder() -> void:
	_label = Label3D.new()
	_label.name = "PlaceholderLabel"
	_label.text = tr("UI_VR_MODE_PLACEHOLDER")
	_label.font_size = 42
	_label.modulate = Color(0.94, 0.96, 0.98, 1.0)
	_label.outline_modulate = Color(0.0, 0.0, 0.0, 0.86)
	_label.outline_size = 8
	_origin.add_child(_label)
