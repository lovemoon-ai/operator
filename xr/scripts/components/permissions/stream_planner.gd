class_name StreamPlanner
extends RefCounted
## Permission layer (components/permissions): merges one stream request with
## local limits, the user's permissions and what this APK can produce, and
## outputs the effective composition as capture-option updates plus a
## StreamsStatus report. It decides only *what is wired*; it never touches
## frames or timestamps.
##
## Two request shapes feed it:
## - ingest sessions: the server's OLCP `capture_request`, which can only
##   narrow what the headset captures (apply_ingest_request);
## - host sessions: the descriptor's `capture_streams` envelope, gated by the
##   PermissionTable and adjusted within the envelope by `StreamsControl`
##   (plan_host / apply_control).

## OLCP stream name -> the capture_options flag that produces it.
## controller_input has no independent flag: it is derived from
## record_controller_pose, so both OLCP streams map onto the same switch.
const STREAM_TO_OPTION := {
	"depth.u16": "record_depth",
	"head_pose.json": "record_head_pose",
	"controller_pose.json": "record_controller_pose",
	"controller_input.json": "record_controller_pose",
	"hand_joints.json": "record_hand_data",
}
## Every OLCP media_up stream this client knows how to produce.
const KNOWN_STREAMS := [
	"rgb.hevc",
	"depth.u16",
	"head_pose.json",
	"controller_pose.json",
	"controller_input.json",
	"hand_joints.json",
]
const RGB_STREAM := "rgb.hevc"
## Permission categories (claw/architecture/overview.md, permission layer).
const CATEGORY_CAMERA := "camera"
const CATEGORY_XR_STATE := "xr_state"

const MIN_RGB_BITRATE := 500000
const MAX_RGB_BITRATE := 24000000
const MIN_RGB_FPS := 1
const MAX_RGB_FPS := 60
const DEFAULT_RGB_FPS := 30
const DEFAULT_RGB_BITRATE := 24000000
const EYES := ["left", "mono", "stereo"]

const STATE_PENDING := "pending"
const STATE_ACTIVE := "active"
const STATE_PAUSED := "paused"
const STATE_DENIED := "denied"
const REASON_PERMISSION_DENIED := "permission_denied"
const REASON_REVOKED := "revoked"
const REASON_UNSUPPORTED := "unsupported"
const REASON_LIMIT := "limit"
const REASON_UNKNOWN_ENDPOINT := "unknown_endpoint"
const STATUS_SCHEMA := "operator.streams_status.v1"

## Ingest: the OLCP stream names the server last asked for.
var _requested_streams: Array = []
var _algorithm := ""

## Host: stream name -> declared envelope {required, max_hz, max_bitrate_bps, eye}.
var _envelope: Dictionary = {}
## Host: stream name -> effective state {state, reason, hz, bitrate_bps, eye}
## plus planner bookkeeping (granted, clipped) stripped from status().
var _effective: Dictionary = {}
## Host: stream name -> true while a StreamsControl paused it.
var _host_paused: Dictionary = {}


static func category_for_stream(stream_name: String) -> String:
	if stream_name == RGB_STREAM or stream_name == "depth.u16":
		return CATEGORY_CAMERA
	if stream_name.begins_with("audio."):
		return "audio"
	return CATEGORY_XR_STATE


# ---------------------------------------------------------------------------
# Ingest session: capture_request narrowing
# ---------------------------------------------------------------------------

func clear() -> void:
	_requested_streams = []
	_algorithm = ""
	_envelope = {}
	_effective = {}
	_host_paused = {}


func has_request() -> bool:
	return not _requested_streams.is_empty()


func requested_streams() -> Array:
	return _requested_streams.duplicate()


func algorithm() -> String:
	return _algorithm


## The server owns the stream selection for an ingest session: it tells us what
## its algorithm needs and we capture exactly that. Returns the capture-option
## updates to merge. `interaction_mode` is the live input source ("hands" or
## "controllers"); the request cannot switch the physical source by itself.
func apply_ingest_request(request: Dictionary, interaction_mode: String) -> Dictionary:
	var selected: Array = []
	var raw_selected: Variant = request.get("selected_streams", [])
	if raw_selected is Array:
		selected = raw_selected
	_requested_streams = selected.duplicate()
	_algorithm = str(request.get("algorithm", ""))

	# Enable exactly what was asked for, nothing more.
	var requested := requested_options()
	var updates: Dictionary = {}
	for option_v in STREAM_TO_OPTION.values():
		var option := str(option_v)
		updates[option] = bool(requested.get(option, false))
	# RGB is a single OLCP stream, but the camera provider can encode either
	# left-only mono or side-by-side stereo. The server selects that shape via
	# limits.rgb_eye; absent/unknown values keep the protocol's stereo default.
	var limits: Dictionary = {}
	var raw_limits: Variant = request.get("limits", {})
	if raw_limits is Dictionary:
		limits = raw_limits
	var rgb_eye := str(limits.get("rgb_eye", "stereo")).strip_edges().to_lower()
	updates["stereo_rgb"] = rgb_eye != "left" and rgb_eye != "mono"
	# Recording-quality defaults are intentionally high. Live algorithms can
	# cap their HEVC budget independently without reducing Ego Record quality.
	# Reset on every request so limits from a previous server do not leak into
	# a reconnect or a later algorithm that omits them.
	updates["rgb_fps"] = DEFAULT_RGB_FPS
	updates["rgb_bitrate"] = DEFAULT_RGB_BITRATE
	if limits.has("rgb_max_hz"):
		var requested_rgb_fps := _positive_limit(limits, "rgb_max_hz")
		if requested_rgb_fps > 0:
			updates["rgb_fps"] = clampi(requested_rgb_fps, MIN_RGB_FPS, MAX_RGB_FPS)
	if limits.has("rgb_bitrate_bps"):
		var requested_rgb_bitrate := _positive_limit(limits, "rgb_bitrate_bps")
		if requested_rgb_bitrate > 0:
			updates["rgb_bitrate"] = clampi(requested_rgb_bitrate, MIN_RGB_BITRATE, MAX_RGB_BITRATE)
	_disable_untransmittable(updates, interaction_mode)
	print("[Operator] Capture streams set by server: %s" % JSON.stringify(selected))
	return updates


## capture_options keys the server's current request maps to.
func requested_options() -> Dictionary:
	var requested: Dictionary = {}
	for stream_v in _requested_streams:
		var option := str(STREAM_TO_OPTION.get(str(stream_v), ""))
		if not option.is_empty():
			requested[option] = true
	return requested


## Runtime input detection writes the same flags as the request. Re-applying
## the request afterwards lets detection *narrow* the set (there genuinely is
## no controller data while the user is bare-handed) without ever widening it
## past what the algorithm asked for.
func narrow(options: Dictionary) -> void:
	if not has_request():
		return
	var requested := requested_options()
	for option_v in STREAM_TO_OPTION.values():
		var option := str(option_v)
		if not bool(requested.get(option, false)):
			options[option] = false


## Hand tracking and controller tracking are mutually exclusive at the provider
## level, and which one is live is a physical fact. When the algorithm wants
## the source the operator is not holding, return the localisation key asking
## them to switch ("" when there is nothing to say).
func input_source_notice_key(interaction_mode: String) -> String:
	if not has_request():
		return ""
	var requested := requested_options()
	var wants_hands := bool(requested.get("record_hand_data", false))
	var wants_controllers := bool(requested.get("record_controller_pose", false))
	if wants_hands and not wants_controllers and interaction_mode == "controllers":
		return "UI_SERVER_WANTS_HANDS"
	if wants_controllers and not wants_hands and interaction_mode == "hands":
		return "UI_SERVER_WANTS_CONTROLLERS"
	return ""


# ---------------------------------------------------------------------------
# Host session: capture_streams envelope
# ---------------------------------------------------------------------------

## Plans a host declaration. `advertised` lists the stream names this APK can
## produce on this device; `decisions` maps permission category -> one of
## PermissionTable decisions ("allow", "deny", "ask", "revoked").
## Returns {"updates": capture-option updates, "status": StreamsStatus dict,
## "media_up": bool (true when the OLCP push pipeline must run)}.
## Parameters and pauses already applied by StreamsControl survive a re-plan
## (for example after the user answers the permission prompt).
func plan_host(declaration: Dictionary, advertised: Array, decisions: Dictionary, interaction_mode: String) -> Dictionary:
	var previous := _effective
	_envelope = {}
	_effective = {}
	var streams: Variant = declaration.get("streams", [])
	if streams is Array:
		for entry_v in streams:
			if not (entry_v is Dictionary):
				continue
			var entry: Dictionary = entry_v
			var stream_name := str(entry.get("name", "")).strip_edges()
			if stream_name.is_empty() or _envelope.has(stream_name):
				continue
			_envelope[stream_name] = entry.duplicate(true)
	for paused_name_v in _host_paused.keys():
		if not _envelope.has(paused_name_v):
			_host_paused.erase(paused_name_v)
	for stream_name_v in _envelope.keys():
		var stream_name := str(stream_name_v)
		_effective[stream_name] = _plan_stream(
			stream_name, _envelope[stream_name] as Dictionary, advertised, decisions,
			previous.get(stream_name, {}) as Dictionary)
	_resolve_states()
	return {
		"updates": host_capture_updates(interaction_mode),
		"status": status(),
		"media_up": media_up_running(),
	}


## Applies a host `StreamsControl` inside the declared envelope. Values beyond
## the envelope or local limits are clipped and reported with reason `limit`;
## streams outside the granted set are ignored. Returns true when the effective
## capture parameters changed (the capture pipeline must be re-planned).
func apply_control(control: Dictionary) -> bool:
	var streams_v: Variant = control.get("streams", {})
	if not (streams_v is Dictionary):
		return false
	var before := status()
	for stream_name_v in (streams_v as Dictionary).keys():
		var stream_name := str(stream_name_v)
		var request_v: Variant = (streams_v as Dictionary)[stream_name_v]
		if not (request_v is Dictionary) or not _effective.has(stream_name):
			continue
		var effective: Dictionary = _effective[stream_name]
		if not effective.has("granted"):
			continue
		var request: Dictionary = request_v
		var envelope: Dictionary = _envelope.get(stream_name, {})
		if request.has("hz") and effective.has("hz"):
			var requested_hz := _number(request.get("hz"))
			effective["requested_hz"] = requested_hz
			effective["hz"] = int(_clip_hz(stream_name, requested_hz, envelope).get("value", 0))
		if request.has("bitrate_bps") and effective.has("bitrate_bps"):
			var requested_bitrate := _number(request.get("bitrate_bps"))
			effective["requested_bitrate_bps"] = requested_bitrate
			effective["bitrate_bps"] = int(_clip_bitrate(requested_bitrate, envelope).get("value", 0))
		if request.has("paused"):
			_host_paused[stream_name] = bool(request.get("paused"))
		# Derived from every field the host has asked for, not just the ones in
		# this request: a later `{"paused": true}` must not erase the `limit`
		# reason of an earlier clipped rate.
		_refresh_clipped(stream_name, effective, envelope)
		_effective[stream_name] = effective
	_resolve_states()
	return status() != before


## The current StreamsStatus payload (schema operator.streams_status.v1).
func status(local_tasks: Dictionary = {}) -> Dictionary:
	var streams: Dictionary = {}
	for stream_name_v in _effective.keys():
		streams[str(stream_name_v)] = _public_state(_effective[stream_name_v] as Dictionary)
	return {
		"schema": STATUS_SCHEMA,
		"streams": streams,
		"local_tasks": local_tasks.duplicate(true),
	}


func effective(stream_name: String) -> Dictionary:
	return _public_state(_effective.get(stream_name, {}) as Dictionary)


func declared_streams() -> Array:
	return _envelope.keys()


## Streams whose permission category is still undecided.
func pending_streams() -> Array:
	var pending: Array = []
	for stream_name_v in _effective.keys():
		if str((_effective[stream_name_v] as Dictionary).get("state", "")) == STATE_PENDING:
			pending.append(str(stream_name_v))
	return pending


func media_up_running() -> bool:
	return str(effective(RGB_STREAM).get("state", "")) == STATE_ACTIVE


## The rgb stream's granted upper limits. A provider that sets the delivered
## rate in place captures at these, so StreamsControl never restarts it.
func rgb_capture_ceiling() -> Dictionary:
	var envelope: Dictionary = _envelope.get(RGB_STREAM, {})
	return {
		"rgb_fps": int(_clip_hz(RGB_STREAM, _default_hz(envelope), envelope).get("value", DEFAULT_RGB_FPS)),
		"rgb_bitrate": int(_clip_bitrate(_default_bitrate(envelope), envelope).get("value", DEFAULT_RGB_BITRATE)),
	}


## Capture-option updates for the current host plan. Streams OLCP cannot carry
## (audio, body, motion trackers) are always off in a host session.
func host_capture_updates(interaction_mode: String) -> Dictionary:
	var updates: Dictionary = {}
	for option_v in STREAM_TO_OPTION.values():
		updates[str(option_v)] = false
	for stream_name_v in _effective.keys():
		var stream_name := str(stream_name_v)
		if not _is_running(stream_name):
			continue
		var option := str(STREAM_TO_OPTION.get(stream_name, ""))
		if not option.is_empty():
			updates[option] = true
	var rgb := effective(RGB_STREAM)
	updates["rgb_fps"] = int(rgb.get("hz", DEFAULT_RGB_FPS))
	updates["rgb_bitrate"] = int(rgb.get("bitrate_bps", DEFAULT_RGB_BITRATE))
	var eye := str(rgb.get("eye", "stereo"))
	updates["stereo_rgb"] = eye == "stereo"
	_disable_untransmittable(updates, interaction_mode)
	return updates


func _plan_stream(
		stream_name: String,
		envelope: Dictionary,
		advertised: Array,
		decisions: Dictionary,
		previous: Dictionary) -> Dictionary:
	if not KNOWN_STREAMS.has(stream_name) or not advertised.has(stream_name):
		return {"state": STATE_DENIED, "reason": REASON_UNSUPPORTED}
	var decision := str(decisions.get(category_for_stream(stream_name), "ask"))
	match decision:
		"ask":
			return {"state": STATE_PENDING}
		"deny":
			return {"state": STATE_DENIED, "reason": REASON_PERMISSION_DENIED}
		"revoked":
			return {"state": STATE_DENIED, "reason": REASON_REVOKED}
	var planned: Dictionary = {"state": STATE_ACTIVE, "granted": true, "clipped": false}
	if stream_name == RGB_STREAM:
		var eye := str(envelope.get("eye", "stereo")).strip_edges().to_lower()
		if not EYES.has(eye):
			eye = "stereo"
		planned["eye"] = eye
		# What the host last asked for survives a re-plan, so a value clipped
		# to the envelope is still reported as clipped afterwards.
		planned["requested_hz"] = float(
			previous.get("requested_hz", previous.get("hz", _default_hz(envelope))))
		planned["requested_bitrate_bps"] = float(
			previous.get("requested_bitrate_bps", previous.get("bitrate_bps", _default_bitrate(envelope))))
		planned["hz"] = int(_clip_hz(
			stream_name, float(planned["requested_hz"]), envelope).get("value", DEFAULT_RGB_FPS))
		planned["bitrate_bps"] = int(_clip_bitrate(
			float(planned["requested_bitrate_bps"]), envelope).get("value", DEFAULT_RGB_BITRATE))
		_refresh_clipped(stream_name, planned, envelope)
	return planned


## `clipped` for a stream: whether the host's last requested rate or bitrate
## still does not survive the envelope and the local limits.
func _refresh_clipped(stream_name: String, planned: Dictionary, envelope: Dictionary) -> void:
	var clipped := false
	if planned.has("hz"):
		var requested_hz := float(planned.get("requested_hz", planned.get("hz", 0)))
		clipped = bool(_clip_hz(stream_name, requested_hz, envelope).get("clipped", false))
	if planned.has("bitrate_bps"):
		var requested_bitrate := float(planned.get("requested_bitrate_bps", planned.get("bitrate_bps", 0)))
		clipped = clipped or bool(_clip_bitrate(requested_bitrate, envelope).get("clipped", false))
	planned["clipped"] = clipped


func _default_hz(envelope: Dictionary) -> float:
	var max_hz := _number(envelope.get("max_hz", 0.0))
	return max_hz if max_hz > 0.0 else float(DEFAULT_RGB_FPS)


func _default_bitrate(envelope: Dictionary) -> float:
	var max_bitrate := _number(envelope.get("max_bitrate_bps", 0.0))
	return max_bitrate if max_bitrate > 0.0 else float(DEFAULT_RGB_BITRATE)


## `clipped` compares the value actually used — an integer — with the request,
## so a fractional rate the capture pipeline cannot honour (`hz` and
## `bitrate_bps` are floats on the wire) is reported as `limit` too.
func _clip_hz(stream_name: String, requested: float, envelope: Dictionary) -> Dictionary:
	if stream_name != RGB_STREAM:
		var rounded := int(round(requested))
		return {"value": rounded, "clipped": not is_equal_approx(float(rounded), requested)}
	var upper := float(MAX_RGB_FPS)
	var max_hz := _number(envelope.get("max_hz", 0.0))
	if max_hz > 0.0:
		upper = minf(upper, max_hz)
	var value := int(floor(clampf(requested, float(MIN_RGB_FPS), maxf(upper, float(MIN_RGB_FPS)))))
	return {"value": value, "clipped": not is_equal_approx(float(value), requested)}


func _clip_bitrate(requested: float, envelope: Dictionary) -> Dictionary:
	var upper := float(MAX_RGB_BITRATE)
	var max_bitrate := _number(envelope.get("max_bitrate_bps", 0.0))
	if max_bitrate > 0.0:
		upper = minf(upper, max_bitrate)
	var value := int(floor(clampf(requested, float(MIN_RGB_BITRATE), maxf(upper, float(MIN_RGB_BITRATE)))))
	return {"value": value, "clipped": not is_equal_approx(float(value), requested)}


## Recomputes each granted stream's state from host pauses. media_up is
## carried by the camera provider's session in v1, so the other OLCP streams
## cannot flow before, or without, an active RGB stream: they follow the RGB
## state (pending / paused) or become unsupported without it.
func _resolve_states() -> void:
	var rgb: Dictionary = _effective.get(RGB_STREAM, {})
	var rgb_granted := rgb.has("granted")
	if rgb_granted:
		rgb["state"] = STATE_PAUSED if bool(_host_paused.get(RGB_STREAM, false)) else STATE_ACTIVE
		_set_limit_reason(rgb)
	var rgb_state := str(rgb.get("state", ""))
	for stream_name_v in _effective.keys():
		var stream_name := str(stream_name_v)
		if stream_name == RGB_STREAM:
			continue
		var planned: Dictionary = _effective[stream_name]
		if not planned.has("granted"):
			continue
		if not rgb_granted and rgb_state != STATE_PENDING:
			planned["state"] = STATE_DENIED
			planned["reason"] = REASON_UNSUPPORTED
		elif rgb_state == STATE_PENDING:
			planned["state"] = STATE_PENDING
			planned.erase("reason")
		elif rgb_state == STATE_PAUSED or bool(_host_paused.get(stream_name, false)):
			planned["state"] = STATE_PAUSED
			_set_limit_reason(planned)
		else:
			planned["state"] = STATE_ACTIVE
			_set_limit_reason(planned)
		_effective[stream_name] = planned


static func _set_limit_reason(planned: Dictionary) -> void:
	if bool(planned.get("clipped", false)):
		planned["reason"] = REASON_LIMIT
	else:
		planned.erase("reason")


## Status view of one planned stream, without planner bookkeeping.
static func _public_state(planned: Dictionary) -> Dictionary:
	var out := planned.duplicate(true)
	out.erase("granted")
	out.erase("clipped")
	out.erase("requested_hz")
	out.erase("requested_bitrate_bps")
	return out


func _is_running(stream_name: String) -> bool:
	var state := str((_effective.get(stream_name, {}) as Dictionary).get("state", ""))
	return state == STATE_ACTIVE


## Capture paths with no OLCP stream: disable their producers so a narrow
## request does not spend device CPU on data that can never be transmitted.
## Hands and controllers are mutually exclusive and the live one is a physical
## fact, so drop the source that is not in use.
func _disable_untransmittable(updates: Dictionary, interaction_mode: String) -> void:
	updates["record_audio"] = false
	updates["record_body_tracking"] = false
	updates["record_motion_trackers"] = false
	if interaction_mode == "hands":
		updates["record_controller_pose"] = false
	elif interaction_mode == "controllers":
		updates["record_hand_data"] = false


static func _number(value: Variant) -> float:
	if value is int or value is float:
		var number := float(value)
		return number if is_finite(number) else 0.0
	if value is String and str(value).is_valid_float():
		return str(value).to_float()
	return 0.0


func _positive_limit(limits: Dictionary, key: String) -> int:
	var raw_value: Variant = limits.get(key)
	var parsed_value := -1
	if raw_value is int or raw_value is float:
		parsed_value = int(raw_value)
	elif raw_value is String and str(raw_value).is_valid_int():
		parsed_value = str(raw_value).to_int()
	if parsed_value <= 0:
		push_warning("Ignoring invalid capture limit %s=%s" % [key, raw_value])
		return -1
	return parsed_value
