extends MeshInstance3D
## Shared ground-reference grid for Inside Robot scenes.
##
## Sits at the base (lowest point) of whatever renders the robot — bespoke
## overlay, mesh view, or debug skeleton — so the operator can read the robot's
## height and see it standing on a surface instead of floating. It is model-
## agnostic: it measures the robot's rendered world bounds, so no per-robot foot
## constant is needed and any future robot gets a correct grid for free.

const HALF_EXTENT_M := 1.0
const CELL_M := 0.2
var _follow: Node3D
var _placed := false


## `follow` is the node that renders the robot (overlay or simulation view). The
## grid measures its subtree, so it does not matter which embodiment is in use.
func configure(follow: Node3D) -> void:
	_follow = follow
	_build_mesh()
	# Do not expose intermediate measurements. Robot overlays place themselves
	# in front of the operator on a deferred frame, and the generic MuJoCo view
	# waits for its model binding. Showing the grid before either is ready made
	# it visibly jump and flicker.
	visible = false
	_placed = false
	set_process(true)


func _build_mesh() -> void:
	var im := ImmediateMesh.new()
	mesh = im
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(0.5, 0.8, 1.0, 0.45)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	material_override = mat
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var cell := maxf(CELL_M, 0.02)
	var n := int(HALF_EXTENT_M / cell)
	im.surface_begin(Mesh.PRIMITIVE_LINES, mat)
	for i in range(-n, n + 1):
		var t := i * cell
		im.surface_add_vertex(Vector3(t, 0.0, -HALF_EXTENT_M))
		im.surface_add_vertex(Vector3(t, 0.0, HALF_EXTENT_M))
		im.surface_add_vertex(Vector3(-HALF_EXTENT_M, 0.0, t))
		im.surface_add_vertex(Vector3(HALF_EXTENT_M, 0.0, t))
	im.surface_end()


func _process(_delta: float) -> void:
	if _placed:
		set_process(false)
		return
	if _follow == null or not is_instance_valid(_follow):
		return
	if not _follow_is_ready():
		return
	# One measurement, one placement. From this point on the node has no
	# processing and its global transform is fixed in the world coordinate
	# system; animated robot bounds can never move the floor.
	place_under_robot()


## Center the grid under the robot at its lowest point. Public so a synchronous
## caller (a device test) can place it without waiting for a frame.
func place_under_robot() -> bool:
	if _follow == null or not is_instance_valid(_follow):
		return false
	var box := world_aabb(_follow)
	# No renderable geometry yet (the GLB may still be loading); try again next
	# tick rather than snapping the grid to the origin.
	if box.size == Vector3.ZERO:
		return false
	var center := box.position + box.size * 0.5
	global_transform = Transform3D(Basis(), Vector3(center.x, box.position.y, center.z))
	_placed = true
	visible = true
	set_process(false)
	return true


## Robot renderers finish their one-time front-of-view placement differently.
## Wait for that renderer-specific ready state while the grid is still hidden;
## this is readiness detection, not continued following.
func _follow_is_ready() -> bool:
	if "_debug_front_locked" in _follow and not bool(_follow.get("_debug_front_locked")):
		return false
	if _follow.has_method("matched_link_count"):
		return int(_follow.call("matched_link_count")) > 0
	return true


## Merged world-space bounds of every VisualInstance3D under `root`.
static func world_aabb(root: Node) -> AABB:
	var out := AABB()
	var has := false
	var stack: Array = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is VisualInstance3D:
			var vi := node as VisualInstance3D
			var local := vi.get_aabb()
			if local.size != Vector3.ZERO:
				var world := vi.global_transform * local
				out = world if not has else out.merge(world)
				has = true
		for child in node.get_children():
			stack.append(child)
	return out if has else AABB()
