class_name So101NativeRetargeter
extends RefCounted
## Small warm-started DLS IK for the five arm joints of the bundled SO101.
## It mirrors the Python service's position-first policy and reports explicit
## orientation degradation for the arm's underactuated 5-DoF wrist.

const JOINT_NAMES := ["shoulder_pan", "shoulder_lift", "elbow_flex", "wrist_flex", "wrist_roll"]
const HOME_Q := [0.0, -0.3, 0.6, 0.6, 0.0]
const LOWER := [-1.91986, -1.74533, -1.69, -1.65806, -2.74385]
const UPPER := [1.91986, 1.74533, 1.69, 1.65806, 2.84121]
const ORIGIN_XYZ := [
	Vector3(0.0388353, -8.97657e-09, 0.0624),
	Vector3(-0.0303992, -0.0182778, -0.0542),
	Vector3(-0.11257, -0.028, 1.73763e-16),
	Vector3(-0.1349, 0.0052, 3.62355e-17),
	Vector3(5.55112e-17, -0.0611, 0.0181),
]
const ORIGIN_RPY := [
	Vector3(3.14159, 4.18253e-17, -3.14159),
	Vector3(-1.5708, -1.5708, 0.0),
	Vector3(-3.63608e-16, 8.74301e-16, 1.5708),
	Vector3(4.02456e-15, 8.67362e-16, -1.5708),
	Vector3(1.5708, 0.0486795, 3.14159),
]
const TIP_ORIGIN := Vector3(-0.0079, -0.000218121, -0.0981274)
const TIP_RPY := Vector3(0.0, 3.14159, 0.0)
const MAX_ITERS := 48
const DAMPING := 0.002
const STEP_CLAMP := 0.18
const POSITION_TOLERANCE := 0.002
const ORIENTATION_TOLERANCE := deg_to_rad(5.0)

var _q := HOME_Q.duplicate()
var _origins: Array[Transform3D] = []
var _tip_transform := Transform3D.IDENTITY


func _init() -> void:
	for index in range(ORIGIN_XYZ.size()):
		_origins.append(Transform3D(_rpy_basis(ORIGIN_RPY[index]), ORIGIN_XYZ[index]))
	_tip_transform = Transform3D(_rpy_basis(TIP_RPY), TIP_ORIGIN)


func reset() -> void:
	_q = HOME_Q.duplicate()


func solve(target_position: Vector3, target_rotation: Quaternion) -> Dictionary:
	var iterations := 0
	var position_error := INF
	var orientation_error := INF
	for iteration in range(MAX_ITERS):
		iterations = iteration + 1
		var kinematics := _forward(_q)
		var tip: Transform3D = kinematics["tip"]
		var error_position := target_position - tip.origin
		var error_orientation := _orientation_error(
			target_rotation, tip.basis.get_rotation_quaternion()
		)
		position_error = error_position.length()
		orientation_error = error_orientation.length()
		if position_error < POSITION_TOLERANCE and orientation_error < ORIENTATION_TOLERANCE:
			break
		var jacobian := _jacobian(kinematics)
		var error := [
			error_position.x,
			error_position.y,
			error_position.z,
			error_orientation.x,
			error_orientation.y,
			error_orientation.z,
		]
		var weights := [1.0, 1.0, 1.0, 0.28, 0.28, 0.18]
		var normal: Array = []
		var rhs: Array = []
		for row in range(JOINT_NAMES.size()):
			var normal_row: Array = []
			for column in range(JOINT_NAMES.size()):
				var value := DAMPING if row == column else 0.0
				for axis in range(6):
					value += jacobian[axis][row] * weights[axis] * jacobian[axis][column]
				normal_row.append(value)
			normal.append(normal_row)
			var projected := 0.0
			for axis in range(6):
				projected += jacobian[axis][row] * weights[axis] * error[axis]
			rhs.append(projected)
		var delta := _solve_linear(normal, rhs)
		if delta.is_empty():
			break
		var norm_squared := 0.0
		for value in delta:
			norm_squared += value * value
		var scale := minf(1.0, STEP_CLAMP / maxf(sqrt(norm_squared), 0.000001))
		var moved := 0.0
		for index in range(_q.size()):
			var next := clampf(_q[index] + delta[index] * scale, LOWER[index], UPPER[index])
			moved += absf(next - _q[index])
			_q[index] = next
		if moved < 0.0000001:
			break
	var status := "converged"
	if position_error >= POSITION_TOLERANCE:
		status = "position_degraded"
	elif orientation_error >= ORIENTATION_TOLERANCE:
		status = "orientation_degraded"
	return {
		"type": "result",
		"output_type": "joint_positions_v1",
		"q": _q.duplicate(),
		"joint_names": JOINT_NAMES.duplicate(),
		"status": status,
		"iterations": iterations,
		"metrics":
		{
			"pos_err_m": position_error,
			"ori_err_rad": orientation_error,
			"saturated_joints": _saturated_joints(),
		},
		"degradation":
		{"reason": "underactuated_orientation" if status == "orientation_degraded" else ""},
	}


func _forward(q: Array) -> Dictionary:
	var transform := Transform3D.IDENTITY
	var positions: Array[Vector3] = []
	var axes: Array[Vector3] = []
	for index in range(q.size()):
		transform = transform * _origins[index]
		positions.append(transform.origin)
		var axis := (transform.basis * Vector3.BACK).normalized()
		axes.append(axis)
		transform = transform * Transform3D(Basis(Vector3.BACK, q[index]), Vector3.ZERO)
	transform = transform * _tip_transform
	return {"tip": transform, "positions": positions, "axes": axes}


func _jacobian(kinematics: Dictionary) -> Array:
	var rows: Array = []
	for _axis in range(6):
		rows.append([])
	var tip: Transform3D = kinematics["tip"]
	var positions: Array = kinematics["positions"]
	var axes: Array = kinematics["axes"]
	for index in range(JOINT_NAMES.size()):
		var angular: Vector3 = axes[index]
		var linear := angular.cross(tip.origin - (positions[index] as Vector3))
		rows[0].append(linear.x)
		rows[1].append(linear.y)
		rows[2].append(linear.z)
		rows[3].append(angular.x)
		rows[4].append(angular.y)
		rows[5].append(angular.z)
	return rows


func _solve_linear(matrix: Array, vector: Array) -> Array:
	var size := vector.size()
	var augmented: Array = []
	for row in range(size):
		var values: Array = (matrix[row] as Array).duplicate()
		values.append(vector[row])
		augmented.append(values)
	for pivot in range(size):
		var best := pivot
		for row in range(pivot + 1, size):
			if absf(augmented[row][pivot]) > absf(augmented[best][pivot]):
				best = row
		if absf(augmented[best][pivot]) < 0.0000000001:
			return []
		var swap: Array = augmented[pivot]
		augmented[pivot] = augmented[best]
		augmented[best] = swap
		var divisor: float = augmented[pivot][pivot]
		for column in range(pivot, size + 1):
			augmented[pivot][column] /= divisor
		for row in range(size):
			if row == pivot:
				continue
			var factor: float = augmented[row][pivot]
			for column in range(pivot, size + 1):
				augmented[row][column] -= factor * augmented[pivot][column]
	var result: Array = []
	for row in range(size):
		result.append(float(augmented[row][size]))
	return result


func _orientation_error(target: Quaternion, current: Quaternion) -> Vector3:
	var difference := (target * current.inverse()).normalized()
	if difference.w < 0.0:
		difference = Quaternion(-difference.x, -difference.y, -difference.z, -difference.w)
	var angle := difference.get_angle()
	if angle < 0.0000001:
		return Vector3.ZERO
	return difference.get_axis() * angle


func _rpy_basis(rpy: Vector3) -> Basis:
	return Basis(Vector3.BACK, rpy.z) * Basis(Vector3.UP, rpy.y) * Basis(Vector3.RIGHT, rpy.x)


func _saturated_joints() -> Array[String]:
	var out: Array[String] = []
	for index in range(_q.size()):
		if _q[index] <= LOWER[index] + 0.001 or _q[index] >= UPPER[index] - 0.001:
			out.append(JOINT_NAMES[index])
	return out
