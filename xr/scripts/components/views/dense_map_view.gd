class_name DenseMapView
extends LivePullDenseMapView
## Capability layer (components/views): renders the dense point cloud that a
## host or ingest server returns on `media_down` (the OLCP result channel).
## The Ego ingest composition mounts it for live results; a host session
## mounts it under the Blueprint `dense_map` external view.
##
## The addon's hard-wired minimap default becomes the `display` property:
## `minimap` is the scaled, view-anchored preview and `world` renders the cloud
## 1:1 at the server-supplied T_openxr_map. The transport and rendering stay in
## the frozen addon.

const DISPLAY_WORLD := "world"
const DISPLAY_MINIMAP := "minimap"

var display := DISPLAY_MINIMAP:
	set = set_display

## Last full server map pose, kept so switching back to `world` restores it.
var _world_transform := Transform3D.IDENTITY


static func normalize_display(value: String) -> String:
	return DISPLAY_WORLD if value.strip_edges().to_lower() == DISPLAY_WORLD else DISPLAY_MINIMAP


func configure(head: Node3D, display_mode: String = DISPLAY_MINIMAP) -> void:
	head_lock_target = head
	set_display(display_mode)


func set_display(value: String) -> void:
	display = normalize_display(value)
	var minimap := display == DISPLAY_MINIMAP
	if minimap == display_as_minimap:
		return
	set_minimap_display(minimap)
	if not minimap:
		transform = _world_transform


## Minimap placement parameters; NAN keeps the current value.
func set_minimap_layout(scale_value: float, distance_value: float, height_below_head_value: float) -> void:
	set_minimap_display(display_as_minimap, scale_value, distance_value, height_below_head_value)


func _apply_map_pose(matrix: Variant) -> void:
	_world_transform = _matrix_to_transform(matrix)
	super._apply_map_pose(matrix)
