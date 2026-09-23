extends MeshInstance3D
## Host polyline in the component frame, drawn as a constant-width unshaded
## tube with a square cross-section so it reads the same from any angle.
## The mesh is rebuilt only when the points change, never per frame.

signal warning_raised(message: String)

const SIDES := 4
const SEGMENT_INDICES := SIDES * 6

var _material := StandardMaterial3D.new()
var _array_mesh := ArrayMesh.new()
var _half_width := 0.025
var _closed := false
var _source_points: Array = []
var _partial_point_warned := false
# Open-segment indices only depend on the segment number; cache the prefix.
var _segment_indices := PackedInt32Array()
var _cached_segments := 0


func configure(properties: Dictionary) -> void:
	_half_width = float(properties["width"]) * 0.5
	_closed = bool(properties["closed"])
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_material.no_depth_test = bool(properties["no_depth_test"])
	mesh = _array_mesh
	material_override = _material
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


## Flat [x0, y0, z0, x1, ...] points. Returns false and keeps the previous
## mesh when a point is not finite; a trailing partial point is ignored.
func update_path(points: Variant, color: Color) -> bool:
	_material.albedo_color = color
	var transparency: BaseMaterial3D.Transparency = (
		BaseMaterial3D.TRANSPARENCY_ALPHA if color.a < 1.0
		else BaseMaterial3D.TRANSPARENCY_DISABLED
	)
	if _material.transparency != transparency:
		_material.transparency = transparency
	if not points is Array:
		warning_raised.emit("Blueprint path points must be an array")
		return false
	var values := points as Array
	if values == _source_points:
		return true
	var usable := values.size() - values.size() % 3
	if usable != values.size() and not _partial_point_warned:
		warning_raised.emit(
			"Blueprint path ignores a trailing partial point (%d values)" % values.size()
		)
	_partial_point_warned = usable != values.size()
	var parsed := PackedVector3Array()
	for index: int in range(0, usable, 3):
		var point := Vector3(
			float(values[index]), float(values[index + 1]), float(values[index + 2])
		)
		if not point.is_finite():
			warning_raised.emit("Blueprint path rejected a non-finite point")
			return false
		if parsed.is_empty() or not point.is_equal_approx(parsed[parsed.size() - 1]):
			parsed.append(point)
	_source_points = values
	_rebuild(parsed)
	return true


func _rebuild(points: PackedVector3Array) -> void:
	_array_mesh.clear_surfaces()
	var closed: bool = _closed and points.size() > 2
	if closed and points[0].is_equal_approx(points[points.size() - 1]):
		points.remove_at(points.size() - 1)
		closed = points.size() > 2
	var count := points.size()
	if count < 2:
		return
	var vertices := PackedVector3Array()
	vertices.resize(count * SIDES)
	var previous_side := Vector3.BACK
	for i: int in count:
		var point: Vector3 = points[i]
		var incoming := Vector3.ZERO
		var outgoing := Vector3.ZERO
		if i > 0 or closed:
			var previous: Vector3 = points[(i + count - 1) % count]
			incoming = (point - previous).normalized()
		if i < count - 1 or closed:
			var following: Vector3 = points[(i + 1) % count]
			outgoing = (following - point).normalized()
		var tangent := (incoming + outgoing).normalized()
		var miter := 1.0
		if tangent.is_zero_approx():
			tangent = outgoing # Full reversal.
		elif not incoming.is_zero_approx() and not outgoing.is_zero_approx():
			miter = 1.0 / maxf(tangent.dot(incoming), 0.5)
		var side := tangent.cross(Vector3.UP)
		if side.length_squared() < 0.000001:
			side = previous_side # Vertical tangent: keep the last horizontal side.
		side = side.normalized()
		previous_side = side
		var across := side * (_half_width * miter)
		var lift := side.cross(tangent).normalized() * _half_width
		var base := i * SIDES
		vertices[base] = point + across
		vertices[base + 1] = point + lift
		vertices[base + 2] = point - across
		vertices[base + 3] = point - lift
	var segments := count - 1
	while _cached_segments < segments:
		var a := _cached_segments * SIDES
		for k: int in SIDES:
			var k1 := (k + 1) % SIDES
			_segment_indices.append_array(PackedInt32Array([
				a + k, a + SIDES + k, a + SIDES + k1, a + k, a + SIDES + k1, a + k1,
			]))
		_cached_segments += 1
	var indices := _segment_indices.slice(0, segments * SEGMENT_INDICES)
	var last := (count - 1) * SIDES
	if closed:
		for k: int in SIDES:
			var k1 := (k + 1) % SIDES
			indices.append_array(PackedInt32Array([
				last + k, k, k1, last + k, k1, last + k1,
			]))
	else:
		indices.append_array(PackedInt32Array([
			0, 1, 2, 0, 2, 3, last, last + 1, last + 2, last, last + 2, last + 3,
		]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_INDEX] = indices
	_array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
