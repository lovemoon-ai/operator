class_name ControlFrameGizmo
extends Node3D
## Axis overlay showing which way the ARM actually moves.
##
## The origin follows the driving controller, but the ORIENTATION is the robot's
## control frame -- the yaw-only operator frame the adapter captured when the
## deadman was squeezed. Push the controller along the 前 arrow and the arm goes
## forward, regardless of how the controller itself is rotated.
##
## The frame and the lateral convention are taken from TELEMETRY, not re-derived
## here: the retarget's `mirror`/`scale` live in robot-side config, and a client
## that recomputed the rule would silently start lying the moment that config
## changed. See `robot/configs/so101_real_descriptor.yaml` (telemetry_schema:
## operator_frame / pose_mirror).

## Arm length in metres. Small enough to sit on the controller without hiding it.
const AXIS_LEN := 0.12
const AXIS_RADIUS := 0.005
const LABEL_GAP := 0.025
const LABEL_SIZE := 0.035

const COLOR_FORWARD := Color(1.0, 0.32, 0.32)   # 前
const COLOR_LATERAL := Color(0.36, 0.95, 0.45)  # 右
const COLOR_UP := Color(0.40, 0.60, 1.0)        # 上

var _axes: Array[MeshInstance3D] = []
var _labels: Array[Label3D] = []


func _ready() -> void:
	for spec in [[COLOR_FORWARD, "前"], [COLOR_LATERAL, "右"], [COLOR_UP, "上"]]:
		_axes.append(_make_axis(spec[0]))
		_labels.append(_make_label(spec[1], spec[0]))
	visible = false


func _make_axis(color: Color) -> MeshInstance3D:
	var mesh_instance := MeshInstance3D.new()
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = AXIS_RADIUS
	cylinder.bottom_radius = AXIS_RADIUS
	cylinder.height = AXIS_LEN
	cylinder.radial_segments = 8
	mesh_instance.mesh = cylinder
	mesh_instance.material_override = _make_material(color)
	# An operator aid must never be hidden by the robot model or panels.
	mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mesh_instance)
	return mesh_instance


func _make_label(text: String, color: Color) -> Label3D:
	var label := Label3D.new()
	label.text = text
	label.modulate = color
	label.pixel_size = LABEL_SIZE / 64.0
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.shaded = false
	add_child(label)
	return label


func _make_material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	# Unshaded + no depth test so the gizmo reads clearly in any lighting and is
	# never occluded by whatever the operator is reaching into.
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.no_depth_test = true
	return material


var _oriented_frame: Quaternion = Quaternion.IDENTITY
var _oriented_mirror := true
var _has_orientation := false


## Place the gizmo. `frame` is the captured operator frame (xyzw, world space);
## `mirror` is the robot's lateral convention.
##
## Called every frame so the origin tracks the controller, but the ORIENTATION
## only changes when the operator re-squeezes (the adapter captures a new frame).
## Re-orienting six child nodes every frame measurably slowed the client's render
## loop -- and since commands are sent from `_process`, that directly cut the
## delivered command rate. So the arms are only rebuilt when the frame actually
## changes.
func apply(origin: Vector3, frame: Quaternion, mirror: bool) -> void:
	# Keep our own basis identity and orient each arm explicitly, so the child
	# offsets below can be plain world-space directions.
	global_transform = Transform3D(Basis.IDENTITY, origin)

	if _has_orientation and mirror == _oriented_mirror and frame.is_equal_approx(_oriented_frame):
		return
	_oriented_frame = frame
	_oriented_mirror = mirror
	_has_orientation = true

	var basis := Basis(frame)
	# Operator local axes are OpenXR/Godot style: +X right, +Y up, -Z forward.
	# robot +X (forward) = -operator Z.
	var forward := -basis.z
	# robot lateral = lateral_sign * operator X, with lateral_sign = -1 when
	# mirrored. mirror=true (the shipped config) is the "same side" convention:
	# move the hand right and the arm goes right, so the 右 arrow is +X. With
	# mirror=false the arm goes the other way and the arrow must flip.
	var lateral := basis.x if mirror else -basis.x
	var up := basis.y

	_orient(0, forward)
	_orient(1, lateral)
	_orient(2, up)


func _orient(index: int, direction: Vector3) -> void:
	var dir := direction.normalized()
	var axis := _axes[index]
	# CylinderMesh runs along local +Y centred on the origin, so shift by half a
	# length to make it read as an arrow growing out of the controller.
	axis.position = dir * (AXIS_LEN * 0.5)
	if absf(dir.dot(Vector3.UP)) > 0.9999:
		# Quaternion(from, to) is undefined for (anti)parallel vectors.
		axis.basis = Basis.IDENTITY if dir.y > 0.0 else Basis(Vector3.RIGHT, PI)
	else:
		axis.basis = Basis(Quaternion(Vector3.UP, dir))
	_labels[index].position = dir * (AXIS_LEN + LABEL_GAP)
