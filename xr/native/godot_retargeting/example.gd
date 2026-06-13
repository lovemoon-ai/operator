# Example: drive a robot configuration from VR body/hand poses with GMRRetargeter.
#
# Attach to a Node3D in an XR scene. Ship the robot MJCF + ik_config (and, for
# MuJoCo, the *meshless* MJCF) under res://data/ and extract them to user:// at
# startup — res:// inside an APK is not a real filesystem path.
extends Node3D

var rt := GMRRetargeter.new()

# Map your tracked nodes (headset / controllers / body-tracking joints) to the
# source skeleton names the ik_config expects.
@onready var _sources := {
	"Hips":       $XRBody/Hips,
	"Chest":      $XRBody/Chest,
	"Head":       $XROrigin3D/XRCamera3D,
	"LeftWrist":  $XROrigin3D/LeftHand,
	"RightWrist": $XROrigin3D/RightHand,
}

func _ready() -> void:
	var robot := _extract("res://data/robot/unitree_g1/g1_mocap_29dof_nomesh.xml")
	var ikcfg := _extract("res://data/ik_configs/quest3_upper_to_g1.json")
	# upper-body G1: hold the floating base + 12 leg DoFs fixed (19 qpos entries).
	if not rt.configure("upper_body", robot, ikcfg, 1.75, 19):
		push_error("GMRRetargeter.configure failed: %s" % rt.get_last_error())
		return
	print("retargeter ready: scenario=%s nq=%d" % [rt.get_scenario(), rt.get_nq()])

func _process(_delta: float) -> void:
	if not rt.is_configured():
		return
	for name in _sources:
		var node: Node3D = _sources[name]
		if node:
			rt.set_pose(name, node.global_transform)
	var qpos: PackedFloat64Array = rt.step()
	if qpos.is_empty():
		push_warning("retarget failed: %s" % rt.get_last_error())
		return
	_apply_to_robot(qpos)

# Copy a res:// asset to a real user:// path and return the absolute path.
func _extract(res_path: String) -> String:
	var dst := "user://".path_join(res_path.get_file())
	if not FileAccess.file_exists(dst):
		var data := FileAccess.get_file_as_bytes(res_path)
		var f := FileAccess.open(dst, FileAccess.WRITE)
		f.store_buffer(data)
		f.close()
	return ProjectSettings.globalize_path(dst)

func _apply_to_robot(_qpos: PackedFloat64Array) -> void:
	# TODO: push qpos into your robot model / MuJoCo sim / network stream.
	pass
