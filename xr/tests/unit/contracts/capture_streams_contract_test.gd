extends RefCounted
## Host-declared capture streams: descriptor `capture_streams` and session
## `media` parsing, the declaration hash that keys permission memory,
## StreamsControl validation, the PermissionTable policies, and the Session's
## Hello advertisement / StreamsControl routing.

const CASE_ID := "contracts.capture_streams"

const DECLARATION := {
	"schema_version": 1,
	"streams": [
		{"name": "rgb.hevc", "required": true, "max_hz": 4, "max_bitrate_bps": 2000000, "eye": "left"},
		{"name": "head_pose.json"},
	],
	"local_tasks": [{"kind": "record"}],
}


func run(_ctx: Dictionary, t: OperatorTestAssertions) -> void:
	_check_capture_streams(t)
	_check_media(t)
	_check_declaration_hash(t)
	_check_control(t)
	_check_permission_table(t)
	_check_session(t)


func _check_capture_streams(t: OperatorTestAssertions) -> void:
	var absent := StreamsContract.parse_capture_streams(null)
	t.eq(absent.get("config"), {}, "absent capture_streams is no declaration")
	t.eq((absent.get("errors") as Array).size(), 0, "absent capture_streams is not an error")

	var valid := StreamsContract.parse_capture_streams(DECLARATION)
	t.eq((valid.get("errors") as Array).size(), 0, "a well-formed declaration parses")
	t.eq(valid.get("config"), DECLARATION, "the parsed declaration is the host's envelope")

	var unknown := StreamsContract.parse_capture_streams({"streams": [{"name": "lidar.pcd"}]})
	t.eq((unknown.get("errors") as Array).size(), 0,
		"unknown stream names are left to the planner (reported unsupported)")

	for bad in [
		"not an object",
		{"schema_version": 2, "streams": []},
		{"streams": [{"name": "rgb.hevc", "max_hz": 0}]},
		{"streams": [{"name": "rgb.hevc", "eye": "right"}]},
		{"streams": [{"name": "rgb.hevc"}, {"name": "rgb.hevc"}]},
		{"streams": [{"max_hz": 1}]},
		{"local_tasks": [{"kind": "delete"}]},
		# Status and planning key local tasks by kind, so a duplicate would be
		# silently dropped; teleop-protocol and operator_xr reject it too.
		{"local_tasks": [{"kind": "record"}, {"kind": "record"}]},
		{"local_tasks": [{"kind": "upload", "endpoint_ref": "https://example.com/upload"}]},
	]:
		var parsed := StreamsContract.parse_capture_streams(bad)
		t.is_false((parsed.get("errors") as Array).is_empty(), "rejects %s" % JSON.stringify(bad))
		t.eq(parsed.get("config"), {}, "a rejected declaration yields no config: %s" % JSON.stringify(bad))


func _check_media(t: OperatorTestAssertions) -> void:
	var media := {"protocol": "olcp.v1", "push_port": 63905, "result_port": 63906, "auth_token": "tok"}
	t.eq(StreamsContract.parse_media(media),
		{"push_port": 63905, "result_port": 63906, "auth_token": "tok"},
		"the session media block yields the media_up / media_down ports and token")
	t.eq(StreamsContract.parse_media(null), {}, "no media block: the session carries no media")
	for bad in [
		{"protocol": "rtsp", "push_port": 1, "result_port": 2, "auth_token": "tok"},
		{"protocol": "olcp.v1", "push_port": 0, "result_port": 2, "auth_token": "tok"},
		{"protocol": "olcp.v1", "push_port": 1, "result_port": 70000, "auth_token": "tok"},
		{"protocol": "olcp.v1", "push_port": 1, "result_port": 2, "auth_token": ""},
	]:
		t.eq(StreamsContract.parse_media(bad), {}, "rejects media %s" % JSON.stringify(bad))


func _check_declaration_hash(t: OperatorTestAssertions) -> void:
	var reordered := {
		"local_tasks": [{"kind": "record"}],
		"streams": [
			{"eye": "left", "max_bitrate_bps": 2000000, "max_hz": 4, "required": true, "name": "rgb.hevc"},
			{"name": "head_pose.json"},
		],
		"schema_version": 1,
	}
	var base := StreamsContract.declaration_hash(DECLARATION)
	t.eq(base.length(), 64, "the declaration hash is a sha256 hex digest")
	t.eq(StreamsContract.declaration_hash(reordered), base, "key order does not change the declaration")
	var with_media := DECLARATION.duplicate(true)
	with_media["media"] = {"auth_token": "per-connection"}
	t.eq(StreamsContract.declaration_hash(with_media), base,
		"only what the user grants is hashed (a per-connection token is not)")
	var more := DECLARATION.duplicate(true)
	(more["streams"] as Array)[0]["max_hz"] = 30
	t.ne(StreamsContract.declaration_hash(more), base, "a changed envelope is a new declaration")


func _check_control(t: OperatorTestAssertions) -> void:
	var control := {
		"schema": StreamsContract.CONTROL_SCHEMA,
		"streams": {"rgb.hevc": {"hz": 2, "bitrate_bps": 1000000, "paused": false}},
		"local_tasks": {"record": {"active": true}},
	}
	var parsed := StreamsContract.parse_control(control)
	t.eq((parsed.get("errors") as Array).size(), 0, "a well-formed StreamsControl parses")
	t.eq(parsed.get("control"), control, "the parsed control is the host's payload")
	for bad in [
		[],
		{"schema": "operator.streams_control.v2", "streams": {}},
		{"schema": StreamsContract.CONTROL_SCHEMA, "streams": {"rgb.hevc": {"hz": 0}}},
		{"schema": StreamsContract.CONTROL_SCHEMA, "streams": {"rgb.hevc": {"paused": 1}}},
		{"schema": StreamsContract.CONTROL_SCHEMA, "streams": {"rgb.hevc": 3}},
		{"schema": StreamsContract.CONTROL_SCHEMA, "local_tasks": {"format": {}}},
		# A non-object task entry reached the host composition as a typed
		# assignment and aborted the handler before it could re-plan or report.
		{"schema": StreamsContract.CONTROL_SCHEMA, "local_tasks": {"record": 5}},
		{"schema": StreamsContract.CONTROL_SCHEMA, "local_tasks": {"record": {"running": "yes"}}},
	]:
		var rejected := StreamsContract.parse_control(bad)
		t.is_false((rejected.get("errors") as Array).is_empty(), "rejects control %s" % JSON.stringify(bad))
		t.eq(rejected.get("control"), {}, "a rejected control applies nothing")


func _check_permission_table(t: OperatorTestAssertions) -> void:
	PermissionTable.forget_all()
	var host := "10.0.0.7"
	var digest := StreamsContract.declaration_hash(DECLARATION)
	var categories := [PermissionTable.CATEGORY_XR_STATE, PermissionTable.CATEGORY_CAMERA]
	var first := PermissionTable.decisions(host, digest, categories)
	t.eq(first.get(PermissionTable.CATEGORY_XR_STATE), PermissionTable.DECISION_ALLOW,
		"xr_state is allowed by connecting")
	t.eq(first.get(PermissionTable.CATEGORY_CAMERA), PermissionTable.DECISION_ASK,
		"camera asks the user the first time")
	t.eq(PermissionTable.decisions(host, digest, [PermissionTable.CATEGORY_TRACKING]).get(
		PermissionTable.CATEGORY_TRACKING), PermissionTable.DECISION_ALLOW,
		"tracking is decided by the tracking lease, not a prompt")

	PermissionTable.remember(host, digest, categories, true)
	t.eq(PermissionTable.decisions(host, digest, categories).get(PermissionTable.CATEGORY_CAMERA),
		PermissionTable.DECISION_ALLOW, "a confirmed declaration is not asked again on reconnect")
	t.eq(PermissionTable.decisions("10.0.0.8", digest, categories).get(PermissionTable.CATEGORY_CAMERA),
		PermissionTable.DECISION_ASK, "another host address asks again")
	t.eq(PermissionTable.decisions(host, "other", categories).get(PermissionTable.CATEGORY_CAMERA),
		PermissionTable.DECISION_ASK, "a changed declaration asks again")

	PermissionTable.revoke(host, digest)
	t.eq(PermissionTable.decisions(host, digest, categories).get(PermissionTable.CATEGORY_CAMERA),
		PermissionTable.DECISION_REVOKED, "Stop revokes the grant until the host declares again")
	PermissionTable.remember(host, digest, categories, false)
	t.eq(PermissionTable.decisions(host, digest, categories).get(PermissionTable.CATEGORY_CAMERA),
		PermissionTable.DECISION_DENY, "Deny is remembered for the declaration")
	PermissionTable.forget_all()
	t.eq(PermissionTable.decisions(host, digest, categories).get(PermissionTable.CATEGORY_CAMERA),
		PermissionTable.DECISION_ASK, "forget_all drops every grant")


func _check_session(t: OperatorTestAssertions) -> void:
	var plain: Array = Session.hello_payload().get("capabilities", [])
	t.is_false(plain.has(StreamsContract.CAPABILITY), "Hello does not advertise capture streams by default")
	var extras := [StreamsContract.CAPABILITY, StreamsContract.stream_capability("rgb.hevc"), "xr_state_v1"]
	var advertised: Array = Session.hello_payload(extras).get("capabilities", [])
	t.is_true(advertised.has(StreamsContract.CAPABILITY), "capture streams are advertised when present")
	t.is_true(advertised.has("stream.rgb.hevc"), "each producible stream is advertised")
	t.eq(advertised.count("xr_state_v1"), 1, "extra capabilities never duplicate the fixed set")

	var session := Session.new()
	var received: Array = []
	session.streams_control_received.connect(func(control: Dictionary) -> void: received.append(control))
	var payload := JSON.stringify({
		"schema": StreamsContract.CONTROL_SCHEMA,
		"streams": {"rgb.hevc": {"hz": 2}},
	}).to_utf8_buffer()
	t.is_true(session.handle_command(StreamsContract.CONTROL_COMMAND, payload),
		"StreamsControl is a session command")
	t.eq(received.size(), 0, "StreamsControl is ignored unless capture streams were advertised")
	session.extra_capabilities = extras
	session.handle_command(StreamsContract.CONTROL_COMMAND, payload)
	t.eq(received.size(), 1, "an advertised session routes StreamsControl")
	session.handle_command(StreamsContract.CONTROL_COMMAND, "{\"schema\": \"x\"}".to_utf8_buffer())
	t.eq(received.size(), 1, "an invalid StreamsControl is dropped")
	t.eq(session.send_streams_status({}), ERR_CONNECTION_ERROR, "StreamsStatus needs a connected ctrl channel")
	session.free()
