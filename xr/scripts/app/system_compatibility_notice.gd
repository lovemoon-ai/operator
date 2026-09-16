extends Node3D
## One dismissible warning per app launch, shared by launcher and quick entries.
const PopupScript := preload("res://scripts/ui/view_locked_status_popup.gd")
const BIND_TIMEOUT_SECONDS := 30.0
const NOTICE_OFFSET := Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -0.9))

var _popup: ViewLockedStatusPopup
var _camera: XRCamera3D
var _scene: Node
var _elapsed := 0.0
var _check_elapsed := 1.0
var _shown := false
var _dismissed := false
var _report: Dictionary = {}


func _ready() -> void:
	var enabled := not Engine.is_editor_hint() and PicoPlatformAdapter.is_pico_build()
	set_process(enabled)
	if enabled:
		var xr := XRServer.find_interface("OpenXR")
		if xr != null and xr.has_signal("session_focussed"):
			xr.connect("session_focussed", _on_session_focused)


func _on_session_focused() -> void:
	if not _dismissed:
		_elapsed = 0.0
		_check_elapsed = 1.0
		set_process(true)


func _process(delta: float) -> void:
	if _dismissed:
		set_process(false)
		return
	var scene := get_tree().current_scene
	if not is_instance_valid(_scene) or scene != _scene or not is_instance_valid(_camera):
		_scene = scene
		_camera = _find_camera(scene)
	var xr := XRServer.find_interface("OpenXR") as OpenXRInterface
	if xr == null or not xr.is_initialized() or _camera == null:
		if is_instance_valid(_popup):
			_popup.visible = false
		_elapsed += delta
		if not _shown and _elapsed >= BIND_TIMEOUT_SECONDS:
			set_process(false)
		return
	# Show as soon as XR and its camera exist. The notice has no timeout, so
	# it cannot disappear before the user dons a headset that started unfocused.
	if not _shown:
		_check_elapsed += delta
		if _check_elapsed < 1.0:
			return
		_check_elapsed = 0.0
		var adapter: Object = PlatformRegistry.shared().pico_adapter()
		_report = adapter.call("system_compatibility")
		if not bool(_report.get("needs_upgrade", false)):
			_elapsed += 1.0
			if _elapsed >= BIND_TIMEOUT_SECONDS:
				set_process(false)
			return
		show_for_camera(_camera, _report)
	elif not is_instance_valid(_popup):
		# Composition layers belong to the active XROrigin, which is replaced
		# on scene changes. Keep acknowledgement state here, not on the layer.
		show_for_camera(_camera, _report)
	if is_instance_valid(_popup) and _camera.global_transform.is_finite():
		_popup.global_transform = _camera.global_transform * NOTICE_OFFSET
		_popup.visible = true


func show_for_camera(camera: XRCamera3D, report: Dictionary) -> void:
	if _dismissed or not bool(report.get("needs_upgrade", false)):
		return
	if camera == null or not camera.global_transform.is_finite():
		return
	var origin: Node = camera.get_parent()
	while origin != null and not origin is XROrigin3D:
		origin = origin.get_parent()
	if origin == null:
		return
	if is_instance_valid(_popup):
		if _popup.get_parent() != origin:
			_popup.reparent(origin, false)
		return
	_shown = true
	_report = report.duplicate()
	_popup = PopupScript.new()
	_popup.name = "PicoSystemUpgradeNotice"
	_popup.interaction_priority = 100
	# Godot's native composition-layer pose is relative to the XR origin,
	# not an arbitrary autoload parent (unlike an ordinary Node3D mesh).
	origin.add_child(_popup)
	_popup.dismissed.connect(_on_dismissed)
	_popup.global_transform = camera.global_transform * NOTICE_OFFSET
	var version := str(report.get("version", "")).strip_edges()
	if version.is_empty():
		version = tr("UI_OS_VERSION_UNKNOWN")
	var detail := tr("UI_PICO_OS_UPDATE_CAPABILITY") % version
	if report.get("reason") == "old_os":
		detail = tr("UI_PICO_OS_UPDATE_OLD") % [version, str(report["minimum_version"])]
	_popup.show_notice(tr("UI_PICO_OS_UPDATE_TITLE"), detail)
	print("[SystemCompatibility] %s" % detail)


func _on_dismissed() -> void:
	_dismissed = true
	set_process(false)


func _find_camera(node: Node) -> XRCamera3D:
	if node == null:
		return null
	if node is XRCamera3D:
		return node as XRCamera3D
	for child in node.get_children():
		var camera := _find_camera(child)
		if camera != null:
			return camera
	return null
