class_name HandTargetFilter
extends RefCounted
## Low-latency One-Euro smoothing plus a small output deadband for Revo2 targets.

const MIN_CUTOFF_HZ := 1.0
const SPEED_COEFFICIENT := 3.0
const DERIVATIVE_CUTOFF_HZ := 1.0
const OUTPUT_DEADBAND := 0.008
const MIN_DELTA_SECONDS := 0.001
const MAX_DELTA_SECONDS := 0.1
const CHANNEL_ENDPOINTS := [0.50, 0.87, 1.0, 1.0, 1.0, 1.0]

var _previous_raw := PackedFloat64Array()
var _previous_filtered := PackedFloat64Array()
var _previous_derivative := PackedFloat64Array()
var _previous_output := PackedFloat64Array()
var _previous_timestamp_usec := -1


func filter(values: PackedFloat64Array, timestamp_usec: int = -1) -> PackedFloat64Array:
	var current := _clamped(values)
	var now_usec := Time.get_ticks_usec() if timestamp_usec < 0 else timestamp_usec
	if _previous_raw.size() != current.size() or _previous_timestamp_usec < 0:
		_initialize(current, now_usec)
		return current

	var delta_seconds := clampf(
		float(now_usec - _previous_timestamp_usec) / 1_000_000.0,
		MIN_DELTA_SECONDS,
		MAX_DELTA_SECONDS
	)
	var derivative_alpha := _alpha(DERIVATIVE_CUTOFF_HZ, delta_seconds)
	var filtered := PackedFloat64Array()
	var derivative := PackedFloat64Array()
	var output := PackedFloat64Array()
	filtered.resize(current.size())
	derivative.resize(current.size())
	output.resize(current.size())
	for index in range(current.size()):
		var raw_derivative := (current[index] - _previous_raw[index]) / delta_seconds
		derivative[index] = lerpf(
			_previous_derivative[index], raw_derivative, derivative_alpha
		)
		var cutoff := MIN_CUTOFF_HZ + SPEED_COEFFICIENT * absf(derivative[index])
		filtered[index] = lerpf(
			_previous_filtered[index], current[index], _alpha(cutoff, delta_seconds)
		)
		var endpoint := float(CHANNEL_ENDPOINTS[index]) \
			if index < CHANNEL_ENDPOINTS.size() else 1.0
		if is_zero_approx(current[index]):
			output[index] = 0.0
		elif is_equal_approx(current[index], endpoint):
			output[index] = endpoint
		elif absf(filtered[index] - _previous_output[index]) < OUTPUT_DEADBAND:
			output[index] = _previous_output[index]
		else:
			output[index] = filtered[index]

	_previous_raw = current
	_previous_filtered = filtered
	_previous_derivative = derivative
	_previous_output = output
	_previous_timestamp_usec = now_usec
	return output


func reset() -> void:
	_previous_raw = PackedFloat64Array()
	_previous_filtered = PackedFloat64Array()
	_previous_derivative = PackedFloat64Array()
	_previous_output = PackedFloat64Array()
	_previous_timestamp_usec = -1


func _initialize(values: PackedFloat64Array, timestamp_usec: int) -> void:
	_previous_raw = values.duplicate()
	_previous_filtered = values.duplicate()
	_previous_derivative = PackedFloat64Array()
	_previous_derivative.resize(values.size())
	_previous_output = values.duplicate()
	_previous_timestamp_usec = timestamp_usec


static func _alpha(cutoff_hz: float, delta_seconds: float) -> float:
	var time_constant := 1.0 / (2.0 * PI * cutoff_hz)
	return 1.0 / (1.0 + time_constant / delta_seconds)


static func _clamped(values: PackedFloat64Array) -> PackedFloat64Array:
	var result := values.duplicate()
	for index in range(result.size()):
		var value := float(result[index])
		result[index] = clampf(value, 0.0, 1.0) if is_finite(value) else 0.0
	return result
