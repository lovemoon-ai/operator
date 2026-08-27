extends RefCounted

const CASE_ID := "teleop.xr_tracking_sampler"


class FakeProvider:
	extends TrackingProvider

	func get_all_tracking_data() -> Dictionary:
		return {
			"head": {
				"position": Vector3(0.1, 1.6, -0.2),
				"rotation": Quaternion.IDENTITY,
				"timestamp_ns": 101,
			},
			"left_controller_pose": {
				"position": Vector3(-0.2, 1.2, -0.4),
				"rotation": Quaternion.IDENTITY,
				"is_active": true,
			},
			"right_controller_pose": {
				"position": Vector3(0.2, 1.2, -0.4),
				"rotation": Quaternion.IDENTITY,
				"is_active": true,
			},
			"left_controller_input": {
				"trigger": 0.25,
				"menu_button": true,
				"timestamp_ns": 102,
			},
			"right_controller_input": {"grip": 0.75, "timestamp_ns": 103},
			"left_hand_joints": [{
				"tracked": true,
				"position": Vector3(-0.1, 1.0, -0.3),
				"rotation": Quaternion.IDENTITY,
				"radius": 0.01,
			}],
			"right_hand_joints": [],
		}

	func get_controller_profile(hand: int) -> String:
		return "/interaction_profiles/test/%s" % ("left" if hand == 0 else "right")

	func is_hand_tracking_active(hand: int) -> bool:
		return hand == 0


class FakePicoBridge:
	extends RefCounted
	var body_samples := 0
	var motion_samples := 0
	var body_starts := 0
	var body_stops := 0
	var motion_requests := 0
	var predicted_time_calls := 0
	var predicted_display_time_ns := 9_876_543_210
	var body_source_timestamp_ns := 8_765_432_100
	var body_status := 1
	var body_tracking2_enabled := true
	var collapsed_body := false
	var body_start_succeeds := true

	func get_predicted_display_time_ns() -> int:
		predicted_time_calls += 1
		return predicted_display_time_ns

	func get_status() -> Dictionary:
		return {"pico_body_tracking2_extension": body_tracking2_enabled}

	func start_body_tracking(_bone_lengths: Dictionary) -> bool:
		body_starts += 1
		return body_start_succeeds

	func stop_body_tracking() -> void:
		body_stops += 1

	func request_motion_trackers(_count: int) -> bool:
		motion_requests += 1
		return true

	func sample_body_joints() -> Dictionary:
		body_samples += 1
		var joints: Array = []
		for joint_index in range(24):
			var position := Vector3(1.0, 2.0, 3.0) if collapsed_body else \
				Vector3(float(joint_index) * 0.01, 2.0, 3.0)
			joints.append({
				"joint": joint_index,
				"flags": 0 if joint_index == 5 else 15,
				"radius_m": 0.02,
				"source_timestamp_ns": body_source_timestamp_ns + joint_index,
				"position": {"x": position.x, "y": position.y, "z": position.z},
				"rotation": {"x": 0.0, "y": 0.0, "z": 0.0, "w": 1.0},
				"posture": 4,
				"velocity_flags": 5,
				"linear_velocity": {"x": 0.1, "y": 0.2, "z": 0.3},
				"angular_velocity": {"x": 0.4, "y": 0.5, "z": 0.6},
				"acceleration_flags": 6,
				"linear_acceleration": {"x": 0.7, "y": 0.8, "z": 0.9},
				"angular_acceleration": {"x": 1.0, "y": 1.1, "z": 1.2},
			})
		return {
			"active": true,
			"status": body_status,
			"body_flags": 7,
			"source_timestamp_ns": body_source_timestamp_ns,
			"joints": joints,
		}

	func sample_motion_trackers(_count: int) -> Array:
		motion_samples += 1
		return [{
			"id": "tracker-0",
			"tracker_index": 0,
			"tracking_valid": true,
			"position": {"x": 0.3, "y": 0.4, "z": 0.5},
			"rotation": {"x": 0.0, "y": 0.0, "z": 0.0, "w": 1.0},
			"battery_level": 0.8,
			"velocity_flags": 3,
			"linear_velocity": {"x": 1.1, "y": 1.2, "z": 1.3},
			"angular_velocity": {"x": 1.4, "y": 1.5, "z": 1.6},
			"linear_acceleration": {"x": 1.7, "y": 1.8, "z": 1.9},
			"angular_acceleration": {"x": 2.0, "y": 2.1, "z": 2.2},
			}]


class FakeBridgeWithoutPredictedTime:
	extends RefCounted


class DeterministicSampler:
	extends XrTrackingSampler
	var now_us := 0
	var fake_bridge: Object

	func _ticks_usec() -> int:
		return now_us

	func _resolve_pico_bridge() -> void:
		_pico_bridge = fake_bridge


func run(_ctx: Dictionary, t: OperatorTestAssertions) -> void:
	_test_snapshot_shape_and_default_rate(t)
	_test_predicted_display_time_is_opt_in(t)
	_test_predicted_display_time_fallback(t)
	_test_configurable_body_rate_and_reset(t)
	_test_body_shutdown_ownership(t)
	_test_requested_streams(t)
	_test_pico_body_validation_is_opt_in(t)
	_test_pico_body_status_gate(t)
	_test_pico_body_collapsed_gate(t)
	_test_sender_filters_v1_body_extensions(t)


func _test_snapshot_shape_and_default_rate(t: OperatorTestAssertions) -> void:
	var provider := FakeProvider.new()
	var bridge := FakePicoBridge.new()
	var sampler := DeterministicSampler.new()
	sampler.tracking_provider = provider
	sampler.fake_bridge = bridge
	sampler.configure({
		"streams": ["head", "controllers", "hands", "body", "motion_trackers"],
	})

	var first := sampler.sample_frame()
	t.eq(first.get("schema_version"), 1, "snapshot keeps XrStateFrame schema version")
	t.eq(first.get("frame_id"), 1, "snapshot frame id starts at one")
	t.eq(first.get("timestamp_ns"), 0, "snapshot uses one captured timestamp")
	t.eq(bridge.predicted_time_calls, 0,
		"default Operator sampling does not query native predicted display time")
	t.eq(first.get("coordinate_space"), "godot_world", "snapshot keeps coordinate space")
	t.eq(bridge.body_starts, 1, "body tracking starts when requested")
	t.eq(bridge.motion_requests, 1, "motion trackers are requested when selected")
	t.eq(bridge.body_samples, 1, "first frame samples Pico body")
	t.eq(bridge.motion_samples, 1, "first frame samples Pico motion trackers")

	var left_controller: Dictionary = first.get("controllers", {}).get("left", {})
	t.eq(
		left_controller.get("input", {}).get("values", {}).get("menu_button"),
		1.0,
		"controller booleans retain v1 numeric encoding"
	)
	var body: Dictionary = first.get("body", {})
	t.eq(body.get("joint_set"), "pico_bd_24", "Pico body uses the existing joint set")
	t.eq(body.get("sample_timestamp_ns"), first.get("timestamp_ns"),
		"Pico body sample time stays in the Godot frame-ticks domain")
	t.eq(body.get("source_timestamp_ns"), bridge.body_source_timestamp_ns,
		"Pico body retains its native source timestamp")
	t.ne(body.get("sample_timestamp_ns"), body.get("source_timestamp_ns"),
		"Pico body sample and source timestamps remain in separate clock domains")
	var body_joints: Array = body.get("joints", [])
	t.eq(body_joints.size(), 24, "Pico body preserves the fixed 24-slot joint array")
	for joint_index in range(body_joints.size()):
		var body_joint: Dictionary = body_joints[joint_index]
		t.eq(body_joint.get("joint"), joint_index,
			"fixed Pico body slot %d retains its index" % joint_index)
		t.eq(body_joint.get("source_timestamp_ns"), bridge.body_source_timestamp_ns + joint_index,
			"Pico body slot %d retains its source timestamp" % joint_index)
		t.eq(body_joint.get("pose", {}).get("sample_timestamp_ns"),
			bridge.body_source_timestamp_ns + joint_index,
			"Pico body slot %d pose uses its source timestamp" % joint_index)
	t.eq(body_joints[5].get("flags"), 0, "Pico body retains an untracked fixed slot")
	t.is_false(body_joints[5].get("tracked"), "zero-flag Pico body slot remains untracked")
	var joint: Dictionary = body_joints[0]
	for field in [
		"posture", "velocity_flags", "linear_velocity", "angular_velocity",
		"acceleration_flags", "linear_acceleration", "angular_acceleration",
	]:
		t.contains(joint, field, "internal snapshot keeps Pico %s" % field)
	t.eq(joint.get("linear_acceleration"), [0.7, 0.8, 0.9],
		"Pico acceleration is normalized in the internal snapshot")
	t.contains(joint.get("pose", {}), "linear_velocity",
		"existing v1 pose velocity remains available")
	var motion: Dictionary = first.get("motion_trackers", [])[0]
	t.eq(motion.get("linear_acceleration"), [1.7, 1.8, 1.9],
		"internal snapshot keeps Pico motion-tracker acceleration")

	sampler.now_us = 33_332
	var cached := sampler.sample_frame()
	t.eq(cached.get("frame_id"), 2, "high-rate frames continue while body is cached")
	t.eq(bridge.body_samples, 1, "default body cadence remains 30 Hz")
	t.eq(bridge.motion_samples, 1, "motion tracker cache shares the slow cadence")
	sampler.now_us = 33_333
	sampler.sample_frame()
	t.eq(bridge.body_samples, 2, "default body cache refreshes at 33333 us")
	t.eq(bridge.motion_samples, 2, "motion tracker cache refreshes with body")

	provider.free()


func _test_predicted_display_time_is_opt_in(t: OperatorTestAssertions) -> void:
	var provider := FakeProvider.new()
	var bridge := FakePicoBridge.new()
	var sampler := DeterministicSampler.new()
	sampler.tracking_provider = provider
	sampler.fake_bridge = bridge
	sampler.now_us = 1_111
	sampler.configure({"streams": ["head"]})
	var default_frame := sampler.sample_frame()
	t.eq(bridge.predicted_time_calls, 0,
		"predicted display time is disabled unless explicitly requested")
	t.eq(default_frame.get("predicted_display_time_ns"), 1_111_000,
		"default sampling keeps the frame timestamp as the predicted-time fallback")

	var xrt_bridge := FakePicoBridge.new()
	var xrt_sampler := DeterministicSampler.new()
	xrt_sampler.tracking_provider = provider
	xrt_sampler.fake_bridge = xrt_bridge
	xrt_sampler.now_us = 2_222
	xrt_sampler.configure({
		"streams": ["head"],
		"include_predicted_display_time": true,
	})
	var xrt_frame := xrt_sampler.sample_frame()
	t.eq(xrt_bridge.predicted_time_calls, 1,
		"XRoboToolkit sampling queries native predicted display time when opted in")
	t.eq(xrt_frame.get("predicted_display_time_ns"), xrt_bridge.predicted_display_time_ns,
		"opted-in sampling exposes the native predicted display timestamp")

	provider.free()


func _test_predicted_display_time_fallback(t: OperatorTestAssertions) -> void:
	var provider := FakeProvider.new()
	var sampler := DeterministicSampler.new()
	sampler.tracking_provider = provider
	sampler.fake_bridge = FakeBridgeWithoutPredictedTime.new()
	sampler.now_us = 1_234
	sampler.configure({
		"streams": ["head"],
		"include_predicted_display_time": true,
	})
	var frame := sampler.sample_frame()
	t.eq(frame.get("predicted_display_time_ns"), 1_234_000,
		"snapshot falls back to frame ticks without a native display-time method")

	var zero_bridge := FakePicoBridge.new()
	zero_bridge.predicted_display_time_ns = 0
	var zero_sampler := DeterministicSampler.new()
	zero_sampler.tracking_provider = provider
	zero_sampler.fake_bridge = zero_bridge
	zero_sampler.now_us = 2_345
	zero_sampler.configure({
		"streams": ["head"],
		"include_predicted_display_time": true,
	})
	var zero_frame := zero_sampler.sample_frame()
	t.eq(zero_frame.get("predicted_display_time_ns"), 2_345_000,
		"snapshot falls back to frame ticks when native display time is unavailable")
	t.eq(zero_bridge.predicted_time_calls, 1,
		"opted-in sampling attempts the native display-time query once")

	provider.free()


func _test_configurable_body_rate_and_reset(t: OperatorTestAssertions) -> void:
	var provider := FakeProvider.new()
	var bridge := FakePicoBridge.new()
	var sampler := DeterministicSampler.new()
	sampler.tracking_provider = provider
	sampler.fake_bridge = bridge
	sampler.configure({"streams": ["body"], "body_rate_hz": 50})
	sampler.sample_frame()
	sampler.now_us = 19_999
	sampler.sample_frame()
	t.eq(bridge.body_samples, 1, "50 Hz body rate caches samples below 20 ms")
	sampler.now_us = 20_000
	sampler.sample_frame()
	t.eq(bridge.body_samples, 2, "50 Hz body rate refreshes at 20 ms")
	sampler.now_us = 20_001
	sampler.reset()
	sampler.sample_frame()
	t.eq(bridge.body_samples, 3, "reset invalidates the slow tracking cache")

	provider.free()


func _test_body_shutdown_ownership(t: OperatorTestAssertions) -> void:
	var provider := FakeProvider.new()

	var body_bridge := FakePicoBridge.new()
	var body_sampler := DeterministicSampler.new()
	body_sampler.tracking_provider = provider
	body_sampler.fake_bridge = body_bridge
	body_sampler.configure({"streams": ["body"]})
	t.eq(body_bridge.body_starts, 1, "body configuration starts PICO body tracking once")
	body_sampler.reset()
	t.eq(body_bridge.body_stops, 0, "reset clears caches without stopping PICO body tracking")
	body_sampler.call("shutdown")
	t.eq(body_bridge.body_stops, 1, "shutdown stops PICO body tracking owned by the sampler")
	body_sampler.call("shutdown")
	t.eq(body_bridge.body_stops, 1, "shutdown is idempotent after releasing body tracking")

	var head_bridge := FakePicoBridge.new()
	var head_sampler := DeterministicSampler.new()
	head_sampler.tracking_provider = provider
	head_sampler.fake_bridge = head_bridge
	head_sampler.configure({"streams": ["head"]})
	head_sampler.call("shutdown")
	t.eq(head_bridge.body_stops, 0,
		"shutdown does not stop PICO body tracking when this sampler never started it")

	var failed_bridge := FakePicoBridge.new()
	failed_bridge.body_start_succeeds = false
	var failed_sampler := DeterministicSampler.new()
	failed_sampler.tracking_provider = provider
	failed_sampler.fake_bridge = failed_bridge
	failed_sampler.configure({"streams": ["body"]})
	failed_sampler.call("shutdown")
	t.eq(failed_bridge.body_stops, 0,
		"shutdown does not stop PICO body tracking after a failed start")

	provider.free()


func _test_requested_streams(t: OperatorTestAssertions) -> void:
	var provider := FakeProvider.new()
	var bridge := FakePicoBridge.new()
	var sampler := DeterministicSampler.new()
	sampler.tracking_provider = provider
	sampler.fake_bridge = bridge
	sampler.configure({"streams": ["head"]})
	var frame := sampler.sample_frame()
	t.eq(frame.get("controllers", {}).get("left"), {}, "unrequested controllers stay empty")
	t.eq(frame.get("hands", {}).get("left"), {}, "unrequested hands stay empty")
	t.eq(frame.get("body"), null, "unrequested body stays absent")
	t.eq(frame.get("motion_trackers"), [], "unrequested motion trackers stay empty")
	t.eq(bridge.body_starts, 0, "unrequested body tracking is not started")
	t.eq(bridge.motion_requests, 0, "unrequested motion trackers are not requested")

	provider.free()


func _test_pico_body_validation_is_opt_in(t: OperatorTestAssertions) -> void:
	var provider := FakeProvider.new()
	var bridge := FakePicoBridge.new()
	bridge.body_status = 0
	bridge.collapsed_body = true
	var sampler := DeterministicSampler.new()
	sampler.tracking_provider = provider
	sampler.fake_bridge = bridge
	sampler.configure({"streams": ["body"]})
	var frame := sampler.sample_frame()
	t.is_true(frame.get("body") is Dictionary,
		"existing Operator sampling keeps its previous permissive body behavior")

	provider.free()


func _test_pico_body_status_gate(t: OperatorTestAssertions) -> void:
	for accepted_status in [1, 2]:
		var provider := FakeProvider.new()
		var bridge := FakePicoBridge.new()
		bridge.body_status = accepted_status
		var sampler := DeterministicSampler.new()
		sampler.tracking_provider = provider
		sampler.fake_bridge = bridge
		sampler.configure({"streams": ["body"], "strict_pico_body_validation": true})
		var accepted_frame := sampler.sample_frame()
		t.is_true(accepted_frame.get("body") is Dictionary,
			"body_tracking2 status %d is accepted" % accepted_status)
		provider.free()

	var invalid_provider := FakeProvider.new()
	var invalid_bridge := FakePicoBridge.new()
	invalid_bridge.body_status = 0
	var invalid_sampler := DeterministicSampler.new()
	invalid_sampler.tracking_provider = invalid_provider
	invalid_sampler.fake_bridge = invalid_bridge
	invalid_sampler.configure({"streams": ["body"], "strict_pico_body_validation": true})
	var invalid_frame := invalid_sampler.sample_frame()
	t.eq(invalid_frame.get("body"), null,
		"body_tracking2 rejects body status outside VALID and LIMITED")
	invalid_provider.free()

	var legacy_provider := FakeProvider.new()
	var legacy_bridge := FakePicoBridge.new()
	legacy_bridge.body_status = 0
	legacy_bridge.body_tracking2_enabled = false
	var legacy_sampler := DeterministicSampler.new()
	legacy_sampler.tracking_provider = legacy_provider
	legacy_sampler.fake_bridge = legacy_bridge
	legacy_sampler.configure({"streams": ["body"], "strict_pico_body_validation": true})
	var legacy_frame := legacy_sampler.sample_frame()
	t.is_true(legacy_frame.get("body") is Dictionary,
		"legacy Pico body remains accepted without body_tracking2 capability")
	legacy_provider.free()


func _test_pico_body_collapsed_gate(t: OperatorTestAssertions) -> void:
	var provider := FakeProvider.new()
	var bridge := FakePicoBridge.new()
	bridge.collapsed_body = true
	var sampler := DeterministicSampler.new()
	sampler.tracking_provider = provider
	sampler.fake_bridge = bridge
	sampler.configure({"streams": ["body"], "strict_pico_body_validation": true})
	var frame := sampler.sample_frame()
	t.eq(frame.get("body"), null, "Pico body rejects joint spans below 0.05 m")

	provider.free()


func _test_sender_filters_v1_body_extensions(t: OperatorTestAssertions) -> void:
	var provider := FakeProvider.new()
	var bridge := FakePicoBridge.new()
	var sampler := DeterministicSampler.new()
	sampler.tracking_provider = provider
	sampler.fake_bridge = bridge
	sampler.configure({"streams": ["body", "motion_trackers"]})
	var snapshot := sampler.sample_frame()
	var sender := XrStateSender.new()
	var frame: Dictionary = sender.call("_frame_v1", snapshot)
	t.is_false(frame.has("predicted_display_time_ns"),
		"v1 wire omits the sampler-only predicted display timestamp")
	var body: Dictionary = frame.get("body", {})
	t.is_false(body.has("source_timestamp_ns"),
		"v1 body omits the sampler-only source timestamp")
	t.eq(body.get("joints", []).size(), 23,
		"v1 body preserves the previous behavior of omitting untracked joints")
	var joint: Dictionary = body.get("joints", [])[0]
	t.eq(joint.keys(), ["joint", "flags", "tracked", "radius_m", "pose"],
		"v1 body joint keeps the existing wire fields and ordering")
	t.contains(joint.get("pose", {}), "linear_velocity",
		"v1 keeps velocity already present in the existing pose schema")
	t.eq(joint.get("pose", {}).get("sample_timestamp_ns"), body.get("sample_timestamp_ns"),
		"v1 body pose keeps the previous Godot sample timestamp domain")
	for field in [
		"posture", "velocity_flags", "linear_velocity", "angular_velocity",
		"acceleration_flags", "linear_acceleration", "angular_acceleration",
	]:
		t.is_false(joint.has(field), "v1 wire body joint filters internal %s" % field)
	var motion: Dictionary = frame.get("motion_trackers", [])[0]
	t.eq(motion.keys(), ["id", "tracker_index", "pose", "battery_level"],
		"v1 motion tracker keeps the existing wire fields and ordering")
	var payload := JSON.stringify(frame)
	t.is_false(payload.contains("linear_acceleration"),
		"v1 wire JSON does not expose new acceleration fields")
	t.is_false(payload.contains("acceleration_flags"),
		"v1 wire JSON does not expose new acceleration flags")

	provider.free()
	sender.free()
