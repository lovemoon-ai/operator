extends RefCounted
## Unit coverage for XRoboToolkit sender cadence and reconnect behavior. All
## transport and sampling dependencies are fakes; this test never opens TCP.

const CASE_ID := "teleop.xrt_sender"
const XrtProtocolScript := preload(
	"res://scripts/compat/xrobot_toolkit/xrt_protocol.gd"
)
const XrtSenderScript := preload(
	"res://scripts/compat/xrobot_toolkit/xrt_sender.gd"
)
const XrtTrackingEncoderScript := preload(
	"res://scripts/compat/xrobot_toolkit/xrt_tracking_encoder.gd"
)
const XrStateSenderScript := preload("res://scripts/input/xr_state_sender.gd")


class FakeClient:
	extends Node

	signal connected
	signal disconnected(reason: String)
	signal failed(reason: String)

	var packets: Array = []
	var send_results: Array = []
	var connected_state := false

	func is_connected_to_server() -> bool:
		return connected_state

	func send_packet(packet: PackedByteArray) -> Error:
		packets.append(packet.duplicate())
		if not send_results.is_empty():
			return int(send_results.pop_front())
		return OK

	func emit_connected() -> void:
		connected_state = true
		connected.emit()

	func emit_disconnected(reason := "test disconnect") -> void:
		connected_state = false
		disconnected.emit(reason)

	func emit_failed(reason := "test failure") -> void:
		connected_state = false
		failed.emit(reason)


class FakeSampler:
	extends RefCounted

	var tracking_provider: Node
	var configured: Dictionary = {}
	var configure_calls := 0
	var reset_calls := 0
	var sample_calls := 0
	var frames: Array = []

	func configure(options: Dictionary) -> void:
		configure_calls += 1
		configured = options.duplicate(true)

	func reset() -> void:
		reset_calls += 1

	func sample_frame() -> Dictionary:
		var index := sample_calls
		sample_calls += 1
		if index >= frames.size():
			return {}
		return (frames[index] as Dictionary).duplicate(true)


class DeterministicSender:
	extends XrtSender

	var unix_times: Array = []
	var monotonic_times: Array = []
	var default_device_sn := "hardware-default"
	var default_app_version := "project-default"

	func _default_device_sn() -> String:
		return default_device_sn

	func _default_app_version() -> String:
		return default_app_version

	func _unix_time_ns() -> int:
		if unix_times.is_empty():
			return 1
		return int(unix_times.pop_front())

	func _monotonic_time_ns() -> int:
		if monotonic_times.is_empty():
			return 1
		return int(monotonic_times.pop_front())


func run(_ctx: Dictionary, t: OperatorTestAssertions) -> void:
	_test_identity_fields_are_protocol_safe(t)
	_test_handshake_neutral_then_live_and_disable(t)
	_test_handshake_failure_blocks_protocol_traffic(t)
	_test_heartbeat_cadence(t)
	_test_reconnect_handshake_drops_stale_body(t)
	_test_dual_clock_conversion_and_strict_timestamps(t)
	_test_backward_clock_step_rebaselines(t)
	_test_focus_loss_sends_one_neutral(t)
	_test_v1_body_schema_keeps_a_fixed_joint_array(t)


func _test_identity_fields_are_protocol_safe(t: OperatorTestAssertions) -> void:
	var provider := Node.new()
	var client := FakeClient.new()
	var sampler := FakeSampler.new()
	var sender := DeterministicSender.new()
	sender.configure(provider, client, sampler, {
		"device_sn": "   ",
		"app_version": "",
	})
	t.eq(sender.device_sn, "hardware-default",
		"blank device_sn falls back to the hardware identifier")
	t.eq(sender.app_version, "project-default",
		"blank app_version falls back to the project version")

	sender.set_identity({
		"device_sn": "injected|serial",
		"app_version": "injected|version",
	})
	t.eq(sender.device_sn, "hardware-default",
		"device_sn containing the protocol delimiter falls back safely")
	t.eq(sender.app_version, "project-default",
		"app_version containing the protocol delimiter falls back safely")
	client.emit_connected()
	t.eq(_payload_text(client.packets[0]), "hardware-default|-1",
		"CONNECT contains only the expected device separator")
	t.eq(_payload_text(client.packets[1]), "hardware-default|1.0|project-default",
		"VERSION contains only the expected protocol separators")
	client.packets.clear()
	sender._process(10.0)
	t.eq(_payload_text(client.packets[0]), "hardware-default",
		"HEARTBEAT cannot inherit an injected separator")

	sender.default_device_sn = "invalid|hardware"
	sender.default_app_version = "invalid|project"
	sender.set_identity({"device_sn": "", "app_version": ""})
	t.eq(sender.device_sn, "operator-xr",
		"invalid hardware fallback uses the protocol-safe device identifier")
	t.eq(sender.app_version, "Operator",
		"invalid project fallback uses the protocol-safe app version")

	_free_fixture(sender, provider, client)


func _test_handshake_neutral_then_live_and_disable(t: OperatorTestAssertions) -> void:
	var provider := Node.new()
	var client := FakeClient.new()
	var sampler := FakeSampler.new()
	sampler.frames = [_snapshot(0.625, true)]
	var sender = XrtSenderScript.new()
	var protocol_ready_packet_counts: Array = []
	sender.protocol_ready.connect(
		func() -> void: protocol_ready_packet_counts.append(client.packets.size())
	)
	sender.configure(provider, client, sampler, {
		"device_sn": "sender-test",
		"app_version": "test-version",
	})

	t.eq(sampler.configure_calls, 0,
		"creating the compatibility target does not start tracking while inactive")
	sender.set_sending(true)
	t.eq(sampler.configure_calls, 1, "enabling the sender configures the injected sampler")
	t.eq(sampler.configured.get("rate_hz"), 72, "sender configures 72 Hz tracking")
	t.eq(sampler.configured.get("body_rate_hz"), 72,
		"body ships on every frame, matching the reference client and staying above "
		+ "the receiver's own retargeting loop")
	t.eq(sampler.configured.get("strict_pico_body_validation"), true,
		"compatibility sampling rejects invalid or collapsed PICO body frames")
	t.eq(sampler.configured.get("include_predicted_display_time"), true,
		"compatibility sampling requests the native predicted display timestamp")
	t.eq(sampler.configured.get("streams"), ["head", "controllers", "hands", "body"],
		"compatibility sampling prioritizes Body and does not request motion trackers")
	t.eq(client.packets.size(), 0, "enabling before connection sends no packets")

	client.emit_connected()
	t.eq(_commands(client.packets), [
		XrtProtocolScript.CMD_CONNECT,
		XrtProtocolScript.CMD_VERSION,
		XrtProtocolScript.CMD_TRACKING,
	], "connection sends CONNECT and VERSION before the neutral Tracking frame")
	t.eq(_payload_text(client.packets[0]), "sender-test|-1",
		"CONNECT identifies the configured device")
	t.eq(_payload_text(client.packets[1]), "sender-test|1.0|test-version",
		"VERSION identifies the configured app version")
	t.eq(sampler.sample_calls, 0, "the first Tracking frame does not sample live state")
	_assert_neutral(t, _tracking(client.packets[2]), "initial enabled frame")
	t.eq(protocol_ready_packet_counts, [3],
		"protocol_ready fires only after the neutral Tracking packet succeeds")

	sender._process(0.02)
	t.eq(sampler.sample_calls, 1, "the next cadence tick samples one live frame")
	t.eq(client.packets.size(), 4, "the sampled live frame is sent after neutral")
	var live := _tracking(client.packets[3])
	t.eq(live.get("Controller", {}).get("left", {}).get("axisX"), 0.625,
		"live Tracking carries sampled controller input")
	t.contains(live, "Body", "live Tracking carries the sampled body")

	sender.set_sending(false)
	t.eq(client.packets.size(), 5, "disabling sends one final Tracking frame")
	_assert_neutral(t, _tracking(client.packets[4]), "disabled frame")
	t.eq(sampler.sample_calls, 1, "disabling does not sample another live frame")

	_free_fixture(sender, provider, client)


func _test_handshake_failure_blocks_protocol_traffic(t: OperatorTestAssertions) -> void:
	var provider := Node.new()
	var client := FakeClient.new()
	var sampler := FakeSampler.new()
	var sender = XrtSenderScript.new()
	var protocol_ready_count := [0]
	sender.protocol_ready.connect(func() -> void: protocol_ready_count[0] += 1)
	sender.configure(provider, client, sampler, {"device_sn": "failure-test"})
	sender.set_sending(true)
	client.send_results = [OK, ERR_CANT_CONNECT]

	client.emit_connected()
	t.eq(_commands(client.packets), [
		XrtProtocolScript.CMD_CONNECT,
		XrtProtocolScript.CMD_VERSION,
	], "a failed VERSION write prevents the protocol neutral frame")
	t.eq(protocol_ready_count[0], 0, "failed handshake does not emit protocol_ready")

	sender._process(20.0)
	t.eq(client.packets.size(), 2,
		"failed handshake blocks heartbeat and Tracking while the socket remains connected")
	t.eq(sampler.sample_calls, 0, "failed handshake never samples live tracking")

	_free_fixture(sender, provider, client)


func _test_heartbeat_cadence(t: OperatorTestAssertions) -> void:
	var provider := Node.new()
	var client := FakeClient.new()
	var sampler := FakeSampler.new()
	var sender = XrtSenderScript.new()
	var protocol_ready_count := [0]
	sender.protocol_ready.connect(func() -> void: protocol_ready_count[0] += 1)
	sender.configure(provider, client, sampler, {"device_sn": "heartbeat-test"})
	client.emit_connected()
	t.eq(_commands(client.packets), [
		XrtProtocolScript.CMD_CONNECT,
		XrtProtocolScript.CMD_VERSION,
		XrtProtocolScript.CMD_TRACKING,
	], "handshake sends neutral even while control is disabled")
	_assert_neutral(t, _tracking(client.packets[2]), "control-disabled protocol frame")
	t.eq(protocol_ready_count[0], 1, "control-disabled neutral completes protocol readiness")
	client.packets.clear()

	sender._process(9.0)
	t.eq(client.packets.size(), 0, "heartbeat is not sent before ten seconds")
	sender._process(1.0)
	t.eq(_commands(client.packets), [XrtProtocolScript.CMD_HEARTBEAT],
		"ten elapsed seconds sends one HEARTBEAT")
	t.eq(_payload_text(client.packets[0]), "heartbeat-test",
		"HEARTBEAT identifies the configured device")

	_free_fixture(sender, provider, client)


func _test_dual_clock_conversion_and_strict_timestamps(t: OperatorTestAssertions) -> void:
	var provider := Node.new()
	var client := FakeClient.new()
	var sampler := FakeSampler.new()
	var frame_monotonic_ns := 5_000_000_000
	var predicted_display_time_ns := 5_050_000_000
	var body_monotonic_ns := 4_900_000_000
	var first := _snapshot(
		0.1, true, frame_monotonic_ns, body_monotonic_ns, predicted_display_time_ns)
	first["motion_trackers"] = [{
		"id": "must-not-send",
		"pose": _pose([1.0, 2.0, 3.0]),
	}]
	sampler.frames = [first, _snapshot(0.2, false, frame_monotonic_ns + 1, 0)]
	var sender := DeterministicSender.new()
	var unix_ns := 1_700_000_000_000_000_000
	sender.unix_times = [unix_ns, unix_ns, unix_ns - 100]
	sender.monotonic_times = [4_000_000_000]
	var sent_timestamps: Array = []
	sender.frame_sent.connect(func(timestamp_ns: int) -> void: sent_timestamps.append(timestamp_ns))
	sender.configure(provider, client, sampler, {"device_sn": "clock-test"})

	client.emit_connected()
	sender.set_sending(true)
	sender._process(0.02)
	sender._process(0.02)

	t.eq(sent_timestamps, [unix_ns, unix_ns + 1, unix_ns + 2],
		"top Tracking timestamps remain strictly increasing across repeated and regressed clocks")
	var first_live := _tracking(client.packets[3])
	t.eq(first_live.get("predictTime"), float(predicted_display_time_ns) / 1000.0,
		"predictTime preserves the sampler's predicted display timestamp")
	t.eq(first_live.get("Body", {}).get("timeStampNs"),
		unix_ns + 1 + body_monotonic_ns - frame_monotonic_ns,
		"cached Body timestamp is converted into the top-frame Unix clock domain")
	t.is_false(first_live.has("Motion"),
		"XRoboToolkit compatibility output suppresses motion trackers")

	_free_fixture(sender, provider, client)


## An NTP step backwards used to wedge the stream: the top timestamp was bumped
## by one nanosecond per frame forever, and reset() never cleared the latch.
func _test_backward_clock_step_rebaselines(t: OperatorTestAssertions) -> void:
	var provider := Node.new()
	var client := FakeClient.new()
	var sampler := FakeSampler.new()
	sampler.frames = [
		_snapshot(0.1, false),
		_snapshot(0.2, false),
		_snapshot(0.3, false),
	]
	var sender := DeterministicSender.new()
	var unix_ns := 1_700_000_000_000_000_000
	var stepped_back_ns := unix_ns - 5_000_000_000
	sender.unix_times = [
		unix_ns,
		unix_ns + 1_000_000,
		stepped_back_ns,
		stepped_back_ns + 1_000_000,
	]
	var sent: Array = []
	sender.frame_sent.connect(func(timestamp_ns: int) -> void: sent.append(timestamp_ns))
	sender.configure(provider, client, sampler, {"device_sn": "clock-step-test"})

	client.emit_connected()
	sender.set_sending(true)
	sender._process(0.02)
	sender._process(0.02)
	sender._process(0.02)

	t.eq(sent.size(), 4, "the handshake neutral and three live frames are sent")
	t.eq(sent[1], unix_ns + 1_000_000, "an advancing clock is used as-is")
	t.eq(sent[2], stepped_back_ns,
		"a wall clock more than a second behind re-baselines instead of nudging by 1 ns")
	t.eq(sent[3], stepped_back_ns + 1_000_000,
		"the stream tracks the new wall clock after the step instead of 1 ns per frame")

	# A small regression is nudged, not re-baselined, so this value only survives
	# intact when reset() has cleared the last-timestamp latch.
	sender.unix_times = [stepped_back_ns - 500]
	client.emit_disconnected()
	client.emit_connected()
	t.eq(sent.back(), stepped_back_ns - 500,
		"reset() clears the timestamp latch so a reconnect starts from the wall clock")

	_free_fixture(sender, provider, client)


## APPLICATION_PAUSED must not leave a live grasp pose as the last frame a
## receiver saw.
func _test_focus_loss_sends_one_neutral(t: OperatorTestAssertions) -> void:
	var provider := Node.new()
	var client := FakeClient.new()
	var sampler := FakeSampler.new()
	sampler.frames = [_snapshot(0.5, true), _snapshot(0.5, true)]
	var sender = XrtSenderScript.new()
	sender.configure(provider, client, sampler, {"device_sn": "focus-test"})
	sender.set_sending(true)
	client.emit_connected()
	sender._process(0.02)
	t.eq(_tracking(client.packets.back()).get("appState", {}).get("focus"), true,
		"a focused session reports focus on every frame")
	client.packets.clear()

	sender.set_app_focused(false)
	t.eq(client.packets.size(), 1, "losing focus sends exactly one frame")
	var paused := _tracking(client.packets[0])
	t.eq(paused.get("appState", {}).get("focus"), false,
		"the pause frame reports the lost focus")
	_assert_neutral(t, paused, "focus-loss frame")

	sender.set_app_focused(false)
	t.eq(client.packets.size(), 1, "repeating the same focus state sends nothing more")

	# A headset the operator is not wearing must not keep streaming live poses.
	# Going quiet is the safe state: receivers fall back to a held, zero-velocity
	# stance when frames stop arriving.
	var sampled_before := sampler.sample_calls
	sender._process(0.02)
	sender._process(0.02)
	t.eq(client.packets.size(), 1, "an unfocused session streams no further frames")
	t.eq(sampler.sample_calls, sampled_before,
		"an unfocused session does not even sample tracking")

	sender.set_app_focused(true)
	t.eq(client.packets.size(), 1, "regaining focus sends no extra frame")

	sender._process(0.02)
	t.eq(_tracking(client.packets.back()).get("appState", {}).get("focus"), true,
		"resumed frames report focus again")

	_free_fixture(sender, provider, client)


## XrStateFrame v1 consumers index a fixed 24-entry PICO body array. Dropping
## untracked joints in the sender shortens that array and mis-indexes every
## joint after the gap; per-source filtering belongs in XrTrackingSampler.
func _test_v1_body_schema_keeps_a_fixed_joint_array(t: OperatorTestAssertions) -> void:
	var sender = XrStateSenderScript.new()
	var joints: Array = []
	for index in range(24):
		joints.append({
			"joint": index,
			"flags": 0 if index == 7 else 3,
			"tracked": index != 7,
			"radius_m": 0.0,
			"pose": {"valid": index != 7, "position": [0.0, 0.0, 0.0]},
			"posture": "not part of the v1 schema",
		})
	var frame: Dictionary = sender._frame_v1({
		"schema_version": 1,
		"frame_id": 3,
		"timestamp_ns": 111,
		"body": {
			"active": true,
			"joint_set": "pico_bd_24",
			"sample_timestamp_ns": 222,
			"source_timestamp_ns": 333,
			"body_flags": 0,
			"joints": joints,
		},
		"motion_trackers": [],
	})

	var body: Dictionary = frame.get("body", {})
	var encoded: Array = body.get("joints", [])
	t.eq(encoded.size(), 24, "a v1 PICO body keeps its fixed 24-entry joint array")
	var indices: Array = []
	var expected_indices: Array = []
	for index in range(24):
		expected_indices.append(index)
	for joint_v in encoded:
		indices.append(int((joint_v as Dictionary).get("joint", -1)))
	t.eq(indices, expected_indices,
		"an untracked PICO joint keeps its slot instead of shifting later joints")
	var untracked: Dictionary = encoded[7]
	t.eq(int(untracked.get("flags", -1)), 0, "the untracked joint still reports flags 0")
	t.is_false(untracked.has("posture"), "v1 projection still drops non-schema fields")
	t.eq(int(untracked.get("pose", {}).get("sample_timestamp_ns", 0)), 222,
		"every joint pose carries the body sample timestamp")
	t.is_false(body.has("source_timestamp_ns"),
		"v1 body still hides the internal source timestamp")

	sender.free()


func _test_reconnect_handshake_drops_stale_body(t: OperatorTestAssertions) -> void:
	var provider := Node.new()
	var client := FakeClient.new()
	var sampler := FakeSampler.new()
	sampler.frames = [
		_snapshot(0.25, true),
		_snapshot(-0.75, false),
	]
	var sender = XrtSenderScript.new()
	sender.configure(provider, client, sampler, {
		"device_sn": "reconnect-test",
		"app_version": "reconnect-version",
	})
	sender.set_sending(true)
	client.emit_connected()
	sender._process(0.02)
	var first_live := _tracking(client.packets.back())
	t.contains(first_live, "Body", "the pre-disconnect live frame contains Body")
	t.eq(sampler.sample_calls, 1, "one live sample is consumed before disconnect")

	var resets_before_disconnect := sampler.reset_calls
	client.emit_disconnected()
	t.eq(sampler.reset_calls, resets_before_disconnect + 1,
		"disconnect resets sampler state and cached slow streams")
	client.packets.clear()

	client.emit_connected()
	t.eq(_commands(client.packets), [
		XrtProtocolScript.CMD_CONNECT,
		XrtProtocolScript.CMD_VERSION,
		XrtProtocolScript.CMD_TRACKING,
	], "reconnect repeats the handshake before Tracking")
	t.eq(sampler.sample_calls, 1, "reconnect neutral does not consume or replay a sample")
	_assert_neutral(t, _tracking(client.packets[2]), "post-reconnect frame")
	t.eq(sampler.reset_calls, resets_before_disconnect + 2,
		"reconnect resets sampler state before resuming")

	sender._process(0.02)
	t.eq(sampler.sample_calls, 2, "post-reconnect cadence obtains a fresh sample")
	var fresh_live := _tracking(client.packets[3])
	t.eq(fresh_live.get("Controller", {}).get("left", {}).get("axisX"), -0.75,
		"post-reconnect Tracking uses the fresh sample")
	t.is_false(fresh_live.has("Body"), "stale pre-disconnect Body is not replayed")

	_free_fixture(sender, provider, client)


func _snapshot(
		axis_x: float,
		with_body: bool,
		frame_timestamp_ns := 1_234_567_890,
		body_timestamp_ns := 1_234_000_000,
		predicted_display_time_ns := 0,
	) -> Dictionary:
	var snapshot := {
		"timestamp_ns": frame_timestamp_ns,
		"predicted_display_time_ns": (
			predicted_display_time_ns if predicted_display_time_ns > 0 else frame_timestamp_ns
		),
		"head": _pose([0.0, 1.6, 0.0]),
		"controllers": {
			"left": {
				"pose": _pose([-0.2, 1.2, -0.4]),
				"input": {"values": {"primary_x": axis_x}},
			},
		},
		"hands": {},
		"body": null,
		"motion_trackers": [],
	}
	if with_body:
		var joints: Array = []
		for joint_index in range(24):
			joints.append({
				"joint": joint_index,
				"flags": 15,
				"tracked": true,
				"timestamp_ns": body_timestamp_ns + joint_index,
				"pose": _pose([float(joint_index), 0.0, 0.0]),
			})
		snapshot["body"] = {
			"active": true,
			"joint_set": "pico_bd_24",
			"sample_timestamp_ns": body_timestamp_ns,
			"joints": joints,
		}
	return snapshot


func _pose(position: Array) -> Dictionary:
	return {
		"valid": true,
		"position": position,
		"rotation": [0.0, 0.0, 0.0, 1.0],
	}


func _commands(packets: Array) -> Array:
	var commands: Array = []
	for packet_v in packets:
		var packet := packet_v as PackedByteArray
		commands.append(packet[1] if packet.size() > 1 else -1)
	return commands


func _payload_text(packet: PackedByteArray) -> String:
	if packet.size() < XrtProtocolScript.FRAME_OVERHEAD_SIZE:
		return ""
	var payload_size := packet.decode_s32(2)
	if payload_size < 0 or packet.size() < payload_size + XrtProtocolScript.FRAME_OVERHEAD_SIZE:
		return ""
	return packet.slice(6, 6 + payload_size).get_string_from_utf8()


func _tracking(packet: PackedByteArray) -> Dictionary:
	var envelope_value: Variant = JSON.parse_string(_payload_text(packet))
	if not (envelope_value is Dictionary):
		return {}
	var inner_value: Variant = JSON.parse_string(str(envelope_value.get("value", "")))
	return inner_value as Dictionary if inner_value is Dictionary else {}


func _assert_neutral(
		t: OperatorTestAssertions,
		tracking: Dictionary,
		label: String,
	) -> void:
	t.eq(tracking.get("Head", {}).get("status"), 0, "%s has a neutral Head" % label)
	t.eq(tracking.get("Controller", {}).get("left", {}).get("axisX"), 0.0,
		"%s has a neutral left controller" % label)
	t.eq(tracking.get("Controller", {}).get("right", {}).get("axisX"), 0.0,
		"%s has a neutral right controller" % label)
	_assert_neutral_hands(t, tracking, label)
	_assert_neutral_body(t, tracking, label)


## The stop frame has to overwrite Hand, Head and Controller, not omit them: a
## receiver latches those sections and only clears them when a new one arrives,
## so a missing Hand keeps driving physical fingers from the last live grasp
## pose. Body is the exact opposite and is asserted absent below.
func _assert_neutral_hands(
		t: OperatorTestAssertions,
		tracking: Dictionary,
		label: String,
	) -> void:
	var hands: Dictionary = tracking.get("Hand", {})
	for side in ["leftHand", "rightHand"]:
		var hand: Dictionary = hands.get(side, {})
		t.eq(int(hand.get("isActive", -1)), 0,
			"%s marks %s as not tracking" % [label, side])
		t.eq(int(hand.get("count", -1)), XrtTrackingEncoderScript.HAND_JOINT_COUNT,
			"%s declares every %s joint" % [label, side])
		t.eq(float(hand.get("scale", -1.0)), 1.0, "%s resets the %s scale" % [label, side])
		var joints: Array = hand.get("HandJointLocations", [])
		t.eq(joints.size(), XrtTrackingEncoderScript.HAND_JOINT_COUNT,
			"%s carries every %s joint" % [label, side])
		var live_joints := 0
		for joint_v in joints:
			var joint: Dictionary = joint_v if joint_v is Dictionary else {}
			if str(joint.get("p", "")) != XrtTrackingEncoderScript.IDENTITY_POSE:
				live_joints += 1
			elif int(joint.get("s", -1)) != 0:
				live_joints += 1
		t.eq(live_joints, 0, "%s zeroes every %s joint pose and status" % [label, side])


## Body must be ABSENT from a stop frame, not zeroed. A receiver reads a missing
## Body as "no body this frame" and stops; it reads 24 identity poses as a valid
## skeleton in its rest pose and walks the robot's limbs there. Sending a zeroed
## Body turned every pause, focus loss and disarm into a commanded T-pose.
func _assert_neutral_body(
		t: OperatorTestAssertions,
		tracking: Dictionary,
		label: String,
	) -> void:
	t.is_false(tracking.has("Body"),
		"%s omits Body entirely rather than commanding a rest pose" % label)


func _free_fixture(sender: Node, provider: Node, client: Node) -> void:
	sender.free()
	provider.free()
	client.free()
