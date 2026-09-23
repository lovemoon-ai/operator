extends RefCounted
## StreamPlanner: the permission-layer merge of a stream request with local
## limits, user permissions and what this APK can produce.

const CASE_ID := "capture.stream_planner"

const ADVERTISED := [
	"rgb.hevc",
	"depth.u16",
	"head_pose.json",
	"controller_pose.json",
	"controller_input.json",
	"hand_joints.json",
]
const DECLARATION := {
	"schema_version": 1,
	"streams": [
		{"name": "rgb.hevc", "required": true, "max_hz": 4, "max_bitrate_bps": 2000000, "eye": "left"},
		{"name": "depth.u16", "required": false, "max_hz": 5},
		{"name": "head_pose.json"},
		{"name": "audio.aac"},
	],
}


func run(_ctx: Dictionary, t: OperatorTestAssertions) -> void:
	_check_ingest_request(t)
	_check_host_pending_then_allowed(t)
	_check_host_denied_and_revoked(t)
	_check_host_control(t)
	_check_host_without_rgb(t)


func _check_ingest_request(t: OperatorTestAssertions) -> void:
	var planner := StreamPlanner.new()
	var updates := planner.apply_ingest_request({
		"algorithm": "vggt",
		"selected_streams": ["rgb.hevc", "depth.u16", "hand_joints.json"],
		"limits": {"rgb_max_hz": 90, "rgb_bitrate_bps": 100, "rgb_eye": "left"},
	}, "controllers")
	t.is_true(bool(updates.get("record_depth")), "requested depth is enabled")
	t.is_false(bool(updates.get("record_head_pose")), "unrequested head pose is disabled")
	t.eq(int(updates.get("rgb_fps")), StreamPlanner.MAX_RGB_FPS, "rgb fps clamps to the local maximum")
	t.eq(int(updates.get("rgb_bitrate")), StreamPlanner.MIN_RGB_BITRATE, "rgb bitrate clamps to the local minimum")
	t.is_false(bool(updates.get("stereo_rgb")), "rgb_eye=left selects mono")
	t.is_false(bool(updates.get("record_audio")), "audio has no OLCP stream")
	t.is_false(bool(updates.get("record_hand_data")), "the physical input source narrows hands away")
	t.eq(planner.input_source_notice_key("controllers"), "UI_SERVER_WANTS_HANDS",
		"an algorithm that wants hands asks a controller user to switch")
	var options := {"record_head_pose": true, "record_depth": true}
	planner.narrow(options)
	t.is_false(bool(options.get("record_head_pose")), "narrow() never widens past the request")
	t.is_true(bool(options.get("record_depth")), "narrow() keeps requested streams")


func _check_host_pending_then_allowed(t: OperatorTestAssertions) -> void:
	var planner := StreamPlanner.new()
	var pending := planner.plan_host(DECLARATION, ADVERTISED, {"xr_state": "allow"}, "controllers")
	var status: Dictionary = pending.get("status", {})
	t.eq(str(status.get("schema")), "operator.streams_status.v1", "status carries its schema")
	t.eq(_state(status, "rgb.hevc"), "pending", "camera streams wait for the user")
	t.eq(_state(status, "head_pose.json"), "pending", "OLCP pose waits for the RGB session")
	t.eq(_reason(status, "audio.aac"), "unsupported", "streams this APK cannot produce are unsupported")
	t.is_false(bool(pending.get("media_up")), "nothing is pushed while pending")
	t.eq(planner.pending_streams().size(), 3, "rgb, depth and pose are pending")

	var allowed := planner.plan_host(DECLARATION, ADVERTISED, {"camera": "allow", "xr_state": "allow"}, "controllers")
	status = allowed.get("status", {})
	var rgb: Dictionary = (status.get("streams", {}) as Dictionary).get("rgb.hevc", {})
	t.eq(str(rgb.get("state")), "active", "granted rgb is active")
	t.eq(int(rgb.get("hz")), 4, "rgb runs at the declared max_hz")
	t.eq(int(rgb.get("bitrate_bps")), 2000000, "rgb runs at the declared max bitrate")
	t.eq(str(rgb.get("eye")), "left", "declared eye is honored")
	t.is_false(rgb.has("granted"), "planner bookkeeping never reaches the wire")
	t.is_true(bool(allowed.get("media_up")), "an active rgb stream runs media_up")
	var updates: Dictionary = allowed.get("updates", {})
	t.eq(int(updates.get("rgb_fps")), 4, "capture fps follows the plan")
	t.is_false(bool(updates.get("stereo_rgb")), "left eye captures mono")
	t.is_true(bool(updates.get("record_depth")), "granted depth is captured")
	t.is_true(bool(updates.get("record_head_pose")), "granted pose is captured")
	t.is_false(bool(updates.get("record_body_tracking")), "body tracking is never pushed")


func _check_host_denied_and_revoked(t: OperatorTestAssertions) -> void:
	var planner := StreamPlanner.new()
	var denied: Dictionary = planner.plan_host(DECLARATION, ADVERTISED, {"camera": "deny", "xr_state": "allow"}, "hands").get("status", {})
	t.eq(_reason(denied, "rgb.hevc"), "permission_denied", "a denied camera reports permission_denied")
	t.eq(_reason(denied, "head_pose.json"), "unsupported", "OLCP pose cannot run without the rgb session")
	var revoked: Dictionary = planner.plan_host(DECLARATION, ADVERTISED, {"camera": "revoked", "xr_state": "allow"}, "hands").get("status", {})
	t.eq(_reason(revoked, "depth.u16"), "revoked", "a revoked grant reports revoked")


func _check_host_control(t: OperatorTestAssertions) -> void:
	var planner := StreamPlanner.new()
	planner.plan_host(DECLARATION, ADVERTISED, {"camera": "allow", "xr_state": "allow"}, "controllers")
	var changed := planner.apply_control({"streams": {"rgb.hevc": {"hz": 2, "bitrate_bps": 1000000}}})
	t.is_true(changed, "an in-envelope control changes the plan")
	var rgb := planner.effective("rgb.hevc")
	t.eq(int(rgb.get("hz")), 2, "hz follows the control")
	t.is_false(rgb.has("reason"), "an in-envelope control is not clipped")
	planner.apply_control({"streams": {"rgb.hevc": {"hz": 30, "bitrate_bps": 9000000}}})
	rgb = planner.effective("rgb.hevc")
	t.eq(int(rgb.get("hz")), 4, "hz beyond the envelope is clipped to max_hz")
	t.eq(int(rgb.get("bitrate_bps")), 2000000, "bitrate beyond the envelope is clipped")
	t.eq(str(rgb.get("reason")), "limit", "clipping is reported as limit")
	t.is_false(planner.apply_control({"streams": {"audio.aac": {"hz": 1}}}), "ungranted streams ignore controls")
	# A later control that says nothing about the rate must not make a still
	# clipped stream look honoured.
	planner.apply_control({"streams": {"rgb.hevc": {"paused": false}}})
	rgb = planner.effective("rgb.hevc")
	t.eq(int(rgb.get("hz")), 4, "the clipped rate stays clipped")
	t.eq(str(rgb.get("reason")), "limit", "a control that omits the rate keeps reporting limit")
	# The capture pipeline runs at whole frames per second, so a fractional
	# request is clipped too (hz is a float on the wire).
	planner.apply_control({"streams": {"rgb.hevc": {"hz": 2.5, "bitrate_bps": 1000000}}})
	rgb = planner.effective("rgb.hevc")
	t.eq(int(rgb.get("hz")), 2, "a fractional rate floors to whole frames")
	t.eq(str(rgb.get("reason")), "limit", "a floored fractional rate is reported as limit")
	planner.apply_control({"streams": {"rgb.hevc": {"hz": 2, "bitrate_bps": 1000000}}})
	t.is_false(planner.effective("rgb.hevc").has("reason"), "an honoured request clears limit")
	planner.apply_control({"streams": {"rgb.hevc": {"hz": 30}}})
	planner.plan_host(DECLARATION, ADVERTISED, {"camera": "allow", "xr_state": "allow"}, "controllers")
	t.eq(str(planner.effective("rgb.hevc").get("reason")), "limit",
		"a re-plan keeps reporting the host's still-clipped request")
	planner.apply_control({"streams": {"rgb.hevc": {"hz": 4, "bitrate_bps": 2000000}}})
	planner.apply_control({"streams": {"rgb.hevc": {"paused": true}}})
	t.eq(str(planner.effective("rgb.hevc").get("state")), "paused", "a paused rgb stream is paused")
	t.eq(str(planner.effective("depth.u16").get("state")), "paused", "streams riding the rgb session pause with it")
	t.is_false(planner.media_up_running(), "a paused rgb stream stops media_up")
	# A re-plan (e.g. after a reconnect) keeps what StreamsControl set.
	planner.plan_host(DECLARATION, ADVERTISED, {"camera": "allow", "xr_state": "allow"}, "controllers")
	t.eq(str(planner.effective("rgb.hevc").get("state")), "paused", "pause survives a re-plan")
	t.eq(int(planner.effective("rgb.hevc").get("hz")), 4, "hz survives a re-plan")
	t.is_false(planner.effective("rgb.hevc").has("reason"), "an in-envelope rate survives without limit")
	planner.apply_control({"streams": {"rgb.hevc": {"paused": false}}})
	t.eq(str(planner.effective("depth.u16").get("state")), "active", "resuming rgb resumes its riders")


func _check_host_without_rgb(t: OperatorTestAssertions) -> void:
	var planner := StreamPlanner.new()
	var status: Dictionary = planner.plan_host(
		{"streams": [{"name": "head_pose.json"}]}, ADVERTISED, {"xr_state": "allow"}, "controllers"
	).get("status", {})
	t.eq(_reason(status, "head_pose.json"), "unsupported", "OLCP pose alone has no media_up session in v1")


static func _state(status: Dictionary, stream_name: String) -> String:
	return str(((status.get("streams", {}) as Dictionary).get(stream_name, {}) as Dictionary).get("state", ""))


static func _reason(status: Dictionary, stream_name: String) -> String:
	return str(((status.get("streams", {}) as Dictionary).get(stream_name, {}) as Dictionary).get("reason", ""))
