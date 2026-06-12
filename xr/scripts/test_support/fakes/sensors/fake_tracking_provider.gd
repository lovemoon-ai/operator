class_name FakeTrackingProvider
extends TrackingProvider
## v2 test harness (WP7): scriptable TrackingProvider for core/teleop tests.
## Overrides every getter ControlMode reads so command mapping can be
## driven from synthetic controller/pose fixtures without an XR runtime.
## The node never needs to enter the scene tree (XR discovery only happens
## in _ready, which does not run for free-standing nodes).

var _inputs: Array = [{}, {}]          # hand (0=left,1=right) -> input dict
var _controller_poses: Array = [{}, {}]
var _head_pose: Dictionary = {}
var _hand_joints_left: Array[Dictionary] = []
var _hand_joints_right: Array[Dictionary] = []


func set_controller_input(hand: int, input: Dictionary) -> void:
	if hand >= 0 and hand < 2:
		_inputs[hand] = input


func set_controller_pose(hand: int, pose: Dictionary) -> void:
	if hand >= 0 and hand < 2:
		_controller_poses[hand] = pose


func set_head_pose(pose: Dictionary) -> void:
	_head_pose = pose


func set_hand_joints(hand: int, joints: Array[Dictionary]) -> void:
	if hand == 0:
		_hand_joints_left = joints
	elif hand == 1:
		_hand_joints_right = joints


func get_controller_input(hand: int) -> Dictionary:
	if hand >= 0 and hand < 2:
		return _inputs[hand]
	return {}


func get_controller_pose(hand: int) -> Dictionary:
	if hand >= 0 and hand < 2:
		return _controller_poses[hand]
	return {}


func get_head_pose() -> Dictionary:
	return _head_pose


func get_hand_joints(hand: int) -> Array[Dictionary]:
	if hand == 0:
		return _hand_joints_left
	if hand == 1:
		return _hand_joints_right
	var empty: Array[Dictionary] = []
	return empty
