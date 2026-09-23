class_name StreamsContract
extends RefCounted
## Host-declared capture streams: the descriptor's `capture_streams` envelope,
## the session-owned `media` transport block, and the ctrl commands
## StreamsStatus (headset -> host) / StreamsControl (host -> headset). Mirrors
## robot/crates/teleop-protocol/src/streams.rs; see
## claw/architecture/wire-protocol.md, "Host-declared capture streams".
## Pure validation and encoding: no engine singletons, no transport.

const CAPABILITY := "capture_streams_v1"
const SCHEMA_VERSION := 1
const MEDIA_PROTOCOL := "olcp.v1"
const STATUS_COMMAND := "StreamsStatus"
const CONTROL_COMMAND := "StreamsControl"
const STATUS_SCHEMA := "operator.streams_status.v1"
const CONTROL_SCHEMA := "operator.streams_control.v1"
const STREAM_NAMES := [
	"rgb.hevc",
	"depth.u16",
	"head_pose.json",
	"controller_pose.json",
	"controller_input.json",
	"hand_joints.json",
]
const EYES := ["left", "mono", "stereo"]
const LOCAL_TASK_KINDS := ["record", "upload"]


static func stream_capability(stream_name: String) -> String:
	return "stream.%s" % stream_name


## Parses a descriptor `capture_streams` value. Returns
## {"config": Dictionary ({} when absent or invalid), "errors": Array[String]}.
## Unknown stream names are not errors: the planner reports them unsupported.
static func parse_capture_streams(value: Variant) -> Dictionary:
	var errors: Array[String] = []
	if value == null:
		return {"config": {}, "errors": errors}
	if not (value is Dictionary):
		errors.append("'capture_streams' must be an object")
		return {"config": {}, "errors": errors}
	var config := value as Dictionary
	if int(_number(config.get("schema_version", SCHEMA_VERSION))) != SCHEMA_VERSION:
		errors.append("'capture_streams.schema_version' must be %d" % SCHEMA_VERSION)
	var names: Dictionary = {}
	var streams_v: Variant = config.get("streams", [])
	if not (streams_v is Array):
		errors.append("'capture_streams.streams' must be an array")
	else:
		var index := 0
		for entry_v in streams_v as Array:
			if not (entry_v is Dictionary):
				errors.append("capture_streams.streams[%d] must be an object" % index)
			else:
				var entry := entry_v as Dictionary
				var stream_name := str(entry.get("name", "")).strip_edges()
				if stream_name.is_empty():
					errors.append("capture_streams.streams[%d] missing 'name'" % index)
				elif names.has(stream_name):
					errors.append("capture_streams.streams[%d] duplicates %s" % [index, stream_name])
				names[stream_name] = true
				if entry.has("max_hz") and not (_number(entry.get("max_hz")) > 0.0):
					errors.append("capture_streams.streams[%d].max_hz must be > 0" % index)
				if entry.has("max_bitrate_bps") and not (_number(entry.get("max_bitrate_bps")) > 0.0):
					errors.append("capture_streams.streams[%d].max_bitrate_bps must be > 0" % index)
				if entry.has("eye") and not EYES.has(str(entry.get("eye"))):
					errors.append("capture_streams.streams[%d].eye must be left, mono or stereo" % index)
			index += 1
	var tasks_v: Variant = config.get("local_tasks", [])
	if not (tasks_v is Array):
		errors.append("'capture_streams.local_tasks' must be an array")
	else:
		var kinds: Dictionary = {}
		var task_index := 0
		for task_v in tasks_v as Array:
			if not (task_v is Dictionary):
				errors.append("capture_streams.local_tasks[%d] must be an object" % task_index)
			else:
				var task := task_v as Dictionary
				var kind := str(task.get("kind", ""))
				if not LOCAL_TASK_KINDS.has(kind):
					errors.append("capture_streams.local_tasks[%d].kind must be record or upload" % task_index)
				elif kinds.has(kind):
					# Status and planning are keyed by kind, so a second task of
					# the same kind would be silently dropped. Both the Rust and
					# the Python declaration validators reject it too.
					errors.append("capture_streams.local_tasks[%d] duplicates %s" % [task_index, kind])
				kinds[kind] = true
				if kind == "upload" and not EndpointRegistry.is_valid_name(str(task.get("endpoint_ref", ""))):
					errors.append("capture_streams.local_tasks[%d].endpoint_ref must name a local endpoint" % task_index)
			task_index += 1
	return {"config": config if errors.is_empty() else {}, "errors": errors}


## Parses the session-owned `media` block the session implementation (xr-bridge)
## adds to the descriptor it sends: where this session carries media_up
## (OLCP push) and media_down (OLCP results) on the connected peer, and the
## per-connection token. Host applications never author it. Returns {} when
## absent or invalid.
static func parse_media(value: Variant) -> Dictionary:
	if not (value is Dictionary):
		return {}
	var media := value as Dictionary
	if str(media.get("protocol", MEDIA_PROTOCOL)) != MEDIA_PROTOCOL:
		return {}
	var push_port := int(_number(media.get("push_port", 0)))
	var result_port := int(_number(media.get("result_port", 0)))
	var token := str(media.get("auth_token", ""))
	if push_port <= 0 or push_port > 65535 or result_port <= 0 or result_port > 65535 or token.is_empty():
		return {}
	return {"push_port": push_port, "result_port": result_port, "auth_token": token}


## Hash of what the user grants: the streams and local tasks.
static func declaration_hash(config: Dictionary) -> String:
	var granted := {
		"schema_version": config.get("schema_version", SCHEMA_VERSION),
		"streams": config.get("streams", []),
		"local_tasks": config.get("local_tasks", []),
	}
	return JSON.stringify(granted, "", true).sha256_text()


## Parses a StreamsControl payload. Returns {"control": Dictionary, "errors": Array[String]}.
static func parse_control(value: Variant) -> Dictionary:
	var errors: Array[String] = []
	if not (value is Dictionary):
		errors.append("StreamsControl must be an object")
		return {"control": {}, "errors": errors}
	var control := value as Dictionary
	if str(control.get("schema", "")) != CONTROL_SCHEMA:
		errors.append("StreamsControl schema must be %s" % CONTROL_SCHEMA)
	var streams_v: Variant = control.get("streams", {})
	if not (streams_v is Dictionary):
		errors.append("StreamsControl.streams must be an object")
	else:
		for stream_name_v in (streams_v as Dictionary).keys():
			var entry_v: Variant = (streams_v as Dictionary)[stream_name_v]
			if not (entry_v is Dictionary):
				errors.append("StreamsControl.streams.%s must be an object" % str(stream_name_v))
				continue
			var entry := entry_v as Dictionary
			for key in ["hz", "bitrate_bps"]:
				if entry.has(key) and not (_number(entry.get(key)) > 0.0):
					errors.append("StreamsControl.streams.%s.%s must be > 0" % [str(stream_name_v), key])
			if entry.has("paused") and not (entry.get("paused") is bool):
				errors.append("StreamsControl.streams.%s.paused must be a bool" % str(stream_name_v))
	var tasks_v: Variant = control.get("local_tasks", {})
	if not (tasks_v is Dictionary):
		errors.append("StreamsControl.local_tasks must be an object")
	else:
		for task_name_v in (tasks_v as Dictionary).keys():
			var task_name := str(task_name_v)
			if not LOCAL_TASK_KINDS.has(task_name):
				errors.append("StreamsControl.local_tasks.%s is not a local task" % task_name)
				continue
			var task_v: Variant = (tasks_v as Dictionary)[task_name_v]
			if not (task_v is Dictionary):
				errors.append("StreamsControl.local_tasks.%s must be an object" % task_name)
				continue
			var task := task_v as Dictionary
			if task.has("running") and not (task.get("running") is bool):
				errors.append("StreamsControl.local_tasks.%s.running must be a bool" % task_name)
	return {"control": control if errors.is_empty() else {}, "errors": errors}


static func _number(value: Variant) -> float:
	if value is int or value is float:
		var number := float(value)
		return number if is_finite(number) else 0.0
	return 0.0
