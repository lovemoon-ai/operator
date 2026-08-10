extends OpenXRCompositionLayerQuad
class_name RecordingFrameGuide

## A compositor-only frame guide for the Quest Camera2 recording surface.
## The guide is positioned from the exact recording intrinsics and lens pose,
## so it describes the saved left-eye image without being burned into the MP4.

const VIEWPORT_SIZE := Vector2i(1280, 960)
const GUIDE_DISTANCE_METERS := 1.5


class FrameCanvas:
	extends Control
	const GUIDE_COLOR := Color(1.0, 0.647, 0.169, 0.28)
	const CORNER_COLOR := Color(1.0, 0.72, 0.34, 0.52)

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		queue_redraw()

	func _draw() -> void:
		var inset := 7.0
		var frame := Rect2(
			Vector2(inset, inset),
			Vector2(maxf(size.x - inset * 2.0, 0.0), maxf(size.y - inset * 2.0, 0.0))
		)
		draw_rect(frame, GUIDE_COLOR, false, 4.0, true)

		# Slightly brighter, short corners remain legible over mixed passthrough
		# backgrounds while the rest of the boundary stays unobtrusive.
		var corner := minf(size.x, size.y) * 0.075
		var left := frame.position.x
		var top := frame.position.y
		var right := frame.end.x
		var bottom := frame.end.y
		for segment in [
			[Vector2(left, top + corner), Vector2(left, top), Vector2(left + corner, top)],
			[Vector2(right - corner, top), Vector2(right, top), Vector2(right, top + corner)],
			[Vector2(right, bottom - corner), Vector2(right, bottom), Vector2(right - corner, bottom)],
			[Vector2(left + corner, bottom), Vector2(left, bottom), Vector2(left, bottom - corner)],
		]:
			draw_polyline(PackedVector2Array(segment), CORNER_COLOR, 6.0, true)


var _viewport: SubViewport
var _head_from_guide := Transform3D.IDENTITY
var _recording_resolution := Vector2i.ZERO
var _configured := false


func _init() -> void:
	quad_size = Vector2(2.0, 1.5)
	alpha_blend = true
	sort_order = 1
	visible = false

	_viewport = SubViewport.new()
	_viewport.name = "RecordingFrameGuideViewport"
	_viewport.size = VIEWPORT_SIZE
	_viewport.transparent_bg = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_viewport)
	layer_viewport = _viewport

	var canvas := FrameCanvas.new()
	canvas.name = "FrameCanvas"
	_viewport.add_child(canvas)


static func geometry_from_metadata(metadata: Dictionary, distance_m: float = GUIDE_DISTANCE_METERS) -> Dictionary:
	var intrinsics_value: Variant = metadata.get("recording_intrinsics", {})
	if not intrinsics_value is Dictionary:
		return {}
	var intrinsics: Dictionary = intrinsics_value
	var width := float(intrinsics.get("width", 0.0))
	var height := float(intrinsics.get("height", 0.0))
	var fx := float(intrinsics.get("fx", 0.0))
	var fy := float(intrinsics.get("fy", 0.0))
	var cx := float(intrinsics.get("cx", -1.0))
	var cy := float(intrinsics.get("cy", -1.0))
	if width <= 0.0 or height <= 0.0 or fx <= 0.0 or fy <= 0.0 or distance_m <= 0.0:
		return {}
	if cx < 0.0 or cy < 0.0:
		return {}

	var translation_value: Variant = metadata.get("lens_pose_translation", [])
	var rotation_value: Variant = metadata.get("lens_pose_rotation", [])
	if not translation_value is Array or not rotation_value is Array:
		return {}
	var translation: Array = translation_value
	var rotation: Array = rotation_value
	if translation.size() != 3 or rotation.size() != 4:
		return {}

	var raw_rotation := Quaternion(
		-float(rotation[0]),
		-float(rotation[1]),
		float(rotation[2]),
		float(rotation[3])
	)
	if raw_rotation.length_squared() <= 0.000001:
		return {}
	var camera_image_to_godot := Basis(
		Vector3(1.0, 0.0, 0.0),
		Vector3(0.0, -1.0, 0.0),
		Vector3(0.0, 0.0, -1.0)
	)
	var head_from_camera := Transform3D(
		Basis(raw_rotation.normalized()).transposed() * camera_image_to_godot,
		Vector3(
			float(translation[0]),
			float(translation[1]),
			-float(translation[2])
		)
	)

	var center_in_camera := Vector3(
		(width * 0.5 - cx) * distance_m / fx,
		(height * 0.5 - cy) * distance_m / fy,
		distance_m
	)
	var camera_from_guide := Transform3D(camera_image_to_godot, center_in_camera)
	return {
		"quad_size": Vector2(width * distance_m / fx, height * distance_m / fy),
		"head_from_guide": head_from_camera * camera_from_guide,
		"resolution": Vector2i(int(width), int(height)),
	}


func configure_from_metadata_json(raw_metadata: String) -> bool:
	hide_guide()
	var parsed: Variant = JSON.parse_string(raw_metadata)
	if not parsed is Dictionary:
		return false
	var geometry := geometry_from_metadata(parsed)
	if geometry.is_empty():
		return false
	quad_size = geometry["quad_size"]
	_head_from_guide = geometry["head_from_guide"]
	_recording_resolution = geometry["resolution"]
	_configured = true
	return true


func show_guide() -> void:
	visible = _configured


func hide_guide() -> void:
	visible = false
	_configured = false


func update_from_head_transform(head_transform: Transform3D) -> void:
	if _configured:
		transform = head_transform * _head_from_guide


func resolution_text() -> String:
	return "%dx%d" % [_recording_resolution.x, _recording_resolution.y]
