extends Node3D
## Host goal/waypoint marker: a small unshaded mesh per shape plus optional
## billboard text. `size` is the marker extent in metres. An arrow starts at
## the marker point and points along local -Z; a pin's tip is at the point.
## Pulse animates the shape's scale only while the marker is visible.

signal warning_raised(message: String)

const SHAPES := ["sphere", "ring", "arrow", "pin"]
const PULSE_HZ := 1.0
const PULSE_AMOUNT := 0.15

var _content: Node3D # Offset by the bound position.
var _shape_root: Node3D # Scaled by the pulse.
var _label: Label3D
var _material := StandardMaterial3D.new()
var _size := 0.15
var _pulse := false


func _init() -> void:
	set_process(false)


func configure(properties: Dictionary) -> void:
	_size = float(properties["size"])
	_pulse = bool(properties["pulse"])
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var shape := str(properties["shape"])
	if shape not in SHAPES:
		warning_raised.emit("Unsupported Blueprint marker shape %s; using sphere" % shape)
		shape = "sphere"
	_content = Node3D.new()
	add_child(_content)
	_shape_root = Node3D.new()
	_content.add_child(_shape_root)
	_build_shape(shape)
	_label = Label3D.new()
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.font_size = 32
	_label.pixel_size = 0.0015
	_label.outline_size = 6
	_label.position = Vector3(0.0, _size * (1.1 if shape == "pin" else 0.6), 0.0)
	_label.visible = false
	_content.add_child(_label)


## `offset` is the bound [x, y, z] position or null. Returns false and keeps
## the previous offset when it is malformed or not finite.
func update_marker(offset: Variant, color: Color, text: String) -> bool:
	_material.albedo_color = color
	var transparency: BaseMaterial3D.Transparency = (
		BaseMaterial3D.TRANSPARENCY_ALPHA if color.a < 1.0
		else BaseMaterial3D.TRANSPARENCY_DISABLED
	)
	if _material.transparency != transparency:
		_material.transparency = transparency
	_label.text = text
	_label.visible = not text.is_empty()
	if offset == null:
		_content.position = Vector3.ZERO
		return true
	if not offset is Array or (offset as Array).size() != 3:
		warning_raised.emit("Blueprint marker position must be [x, y, z]")
		return false
	var values := offset as Array
	var point := Vector3(float(values[0]), float(values[1]), float(values[2]))
	if not point.is_finite():
		warning_raised.emit("Blueprint marker rejected a non-finite position")
		return false
	_content.position = point
	return true


func _ready() -> void:
	_refresh_processing()


func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED:
		_refresh_processing()


func _process(_delta: float) -> void:
	var phase := float(Time.get_ticks_usec()) / 1000000.0 * TAU * PULSE_HZ
	_shape_root.scale = Vector3.ONE * (1.0 + PULSE_AMOUNT * sin(phase))


func _refresh_processing() -> void:
	var active: bool = _pulse and _shape_root != null and is_inside_tree() \
		and is_visible_in_tree()
	set_process(active)
	if not active and _shape_root != null:
		_shape_root.scale = Vector3.ONE


func _build_shape(shape: String) -> void:
	match shape:
		"ring":
			var torus := TorusMesh.new()
			torus.outer_radius = _size * 0.5
			torus.inner_radius = _size * 0.38
			torus.rings = 32
			torus.ring_segments = 8
			_add_part(torus, Transform3D.IDENTITY)
		"arrow":
			var forward := Basis(Vector3.RIGHT, -PI * 0.5) # Mesh +Y -> local -Z.
			_add_part(
				_cylinder(_size * 0.06, _size * 0.06, _size * 0.6),
				Transform3D(forward, Vector3(0.0, 0.0, -_size * 0.3)),
			)
			_add_part(
				_cylinder(0.0, _size * 0.18, _size * 0.4),
				Transform3D(forward, Vector3(0.0, 0.0, -_size * 0.8)),
			)
		"pin":
			_add_part(
				_cylinder(_size * 0.2, 0.0, _size * 0.7),
				Transform3D(Basis.IDENTITY, Vector3(0.0, _size * 0.35, 0.0)),
			)
			_add_part(
				_sphere(_size * 0.25),
				Transform3D(Basis.IDENTITY, Vector3(0.0, _size * 0.75, 0.0)),
			)
		_:
			_add_part(_sphere(_size * 0.5), Transform3D.IDENTITY)


func _add_part(part_mesh: Mesh, part_transform: Transform3D) -> void:
	var part := MeshInstance3D.new()
	part.mesh = part_mesh
	part.transform = part_transform
	part.material_override = _material
	part.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_shape_root.add_child(part)


static func _cylinder(top_radius: float, bottom_radius: float, height: float) -> CylinderMesh:
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = top_radius
	cylinder.bottom_radius = bottom_radius
	cylinder.height = height
	cylinder.radial_segments = 12
	cylinder.rings = 1
	return cylinder


static func _sphere(radius: float) -> SphereMesh:
	var sphere := SphereMesh.new()
	sphere.radius = radius
	sphere.height = radius * 2.0
	sphere.radial_segments = 16
	sphere.rings = 8
	return sphere
