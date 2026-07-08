class_name TeleopVideoFeedManager
extends Node

const RobotViewScene = preload("res://scenes/robot_view/robot_view.tscn")

const DEFAULT_TCP_PORT: int = 12345
const DEFAULT_WIDTH: int = 1280
const DEFAULT_HEIGHT: int = 720
const DEFAULT_VIEW_SIZE := Vector2(3.2, 1.8)
const DEFAULT_VIEW_DISTANCE: float = 3.0
const VIDEO_RECV_BUFFER_BYTES: int = 32 * 1024 * 1024

var _origin: Node3D = null
var _primary_view: Node = null
var _xr_started: bool = false
var _video_face_locked: bool = true
var _show_video_panel: bool = false
var _host: String = ""
var _default_tcp_port: int = DEFAULT_TCP_PORT

var _feed_order: Array[String] = []
var _feeds: Dictionary = {}
var _views: Dictionary = {}
var _tcp_handlers: Dictionary = {}
var _udp_handlers: Dictionary = {}
var _enabled: Dictionary = {}


func setup(origin: Node3D, primary_view: Node) -> void:
	_origin = origin
	_primary_view = primary_view


func set_xr_started(value: bool) -> void:
	_xr_started = value
	if not _xr_started:
		return
	for feed_name in _feed_order:
		var view: Node = _views.get(feed_name, null)
		if view and view.has_method("initialize"):
			view.call("initialize")


func apply_preferences(video_face_locked: bool, show_video_panel: bool) -> void:
	_video_face_locked = video_face_locked
	_show_video_panel = show_video_panel
	for feed_name in _feed_order:
		_apply_view_preferences(feed_name)
	if _show_video_panel:
		connect_video_streams(_host, _default_tcp_port)
	else:
		disconnect_all()


func configure_feeds(descriptor: Dictionary) -> void:
	var incoming := _extract_video_feeds(descriptor)
	var wanted_names: Array[String] = []

	for i in range(incoming.size()):
		var feed := incoming[i] as Dictionary
		var base_name := _feed_name(feed, i)
		var feed_name := base_name
		var suffix := 2
		while wanted_names.has(feed_name):
			feed_name = "%s_%d" % [base_name, suffix]
			suffix += 1
		feed["name"] = feed_name
		wanted_names.append(feed_name)
		if not _enabled.has(feed_name):
			_enabled[feed_name] = bool(feed.get("enabled_by_default", true))
		_feeds[feed_name] = feed

	for existing in _feed_order.duplicate():
		if not wanted_names.has(existing):
			_remove_feed(existing)

	_feed_order = wanted_names
	for i in range(_feed_order.size()):
		_ensure_feed_view(_feed_order[i], i)
		_apply_view_preferences(_feed_order[i])
		_configure_view(_feed_order[i])

	if _show_video_panel and not _host.is_empty():
		connect_video_streams(_host, _default_tcp_port)


func configured_feeds() -> Array:
	var result: Array = []
	for feed_name in _feed_order:
		if _feeds.has(feed_name):
			var feed: Dictionary = (_feeds[feed_name] as Dictionary).duplicate(true)
			feed["visible"] = bool(_enabled.get(feed_name, true))
			result.append(feed)
	return result


func visibility_state() -> Dictionary:
	var state: Dictionary = {}
	for feed_name in _feed_order:
		state[feed_name] = bool(_enabled.get(feed_name, true))
	return state


func set_feed_visible(feed_name: String, visible: bool) -> void:
	if not _feeds.has(feed_name):
		return
	_enabled[feed_name] = visible
	_apply_view_preferences(feed_name)
	if visible and _show_video_panel:
		_connect_feed(feed_name)
	else:
		_disconnect_feed(feed_name, true)


func connect_video_streams(host: String, default_tcp_port: int = DEFAULT_TCP_PORT) -> void:
	if host.is_empty():
		return
	_host = host
	_default_tcp_port = default_tcp_port if default_tcp_port > 0 else DEFAULT_TCP_PORT
	if not _show_video_panel:
		disconnect_all()
		return
	for feed_name in _feed_order:
		if bool(_enabled.get(feed_name, true)):
			_connect_feed(feed_name)
		else:
			_disconnect_feed(feed_name, true)


func disconnect_all() -> void:
	for feed_name in _feed_order:
		_disconnect_feed(feed_name, true)


func disconnect_host(host: String) -> void:
	if host.is_empty() or host != _host:
		return
	disconnect_all()
	_host = ""


func clear_all() -> void:
	for feed_name in _feed_order:
		var view: Node = _views.get(feed_name, null)
		if view and view.has_method("clear_video_stream"):
			view.call("clear_video_stream")


func _extract_video_feeds(descriptor: Dictionary) -> Array:
	var feeds: Array = []
	for feed_variant in descriptor.get("video_feeds", []):
		if feed_variant is Dictionary:
			var feed: Dictionary = (feed_variant as Dictionary).duplicate(true)
			if int(feed.get("port", 0)) > 0 or int(feed.get("udp_port", 0)) > 0:
				feeds.append(feed)

	if feeds.is_empty():
		feeds.append({
			"name": "primary",
			"display": "Video",
			"port": DEFAULT_TCP_PORT,
			"width": DEFAULT_WIDTH,
			"height": DEFAULT_HEIGHT,
			"stereo": false,
			"transport": "tcp",
			"codec": "h264",
			"enabled_by_default": true,
			"view_size_m": [DEFAULT_VIEW_SIZE.x, DEFAULT_VIEW_SIZE.y],
			"view_offset_m": [0.0, 0.0, 0.0],
			"view_distance_m": DEFAULT_VIEW_DISTANCE,
		})

	return feeds


func _feed_name(feed: Dictionary, index: int) -> String:
	var base := String(feed.get("name", ""))
	if base.is_empty():
		base = String(feed.get("display", ""))
	if base.is_empty():
		base = "feed_%d" % index
	return base


func _ensure_feed_view(feed_name: String, index: int) -> void:
	if _views.has(feed_name):
		return

	var view: Node = null
	if index == 0 and _primary_view != null:
		view = _primary_view
	else:
		view = RobotViewScene.instantiate()
		view.name = "RobotView_%s" % feed_name
		if _origin:
			_origin.add_child(view)

	_views[feed_name] = view
	if view and view.has_method("set_decoder_stream_id"):
		view.call("set_decoder_stream_id", feed_name)
	if _xr_started and view and view.has_method("initialize"):
		view.call("initialize")


func _remove_feed(feed_name: String) -> void:
	_disconnect_feed(feed_name, true)
	_feeds.erase(feed_name)
	_enabled.erase(feed_name)

	if _tcp_handlers.has(feed_name):
		var tcp: Node = _tcp_handlers[feed_name]
		if tcp:
			tcp.queue_free()
		_tcp_handlers.erase(feed_name)

	if _udp_handlers.has(feed_name):
		var udp: Node = _udp_handlers[feed_name]
		if udp:
			udp.queue_free()
		_udp_handlers.erase(feed_name)

	if _views.has(feed_name):
		var view: Node = _views[feed_name]
		if view != null and view != _primary_view:
			view.queue_free()
		elif view != null and view.has_method("clear_video_stream"):
			view.call("clear_video_stream")
		_views.erase(feed_name)


func _apply_view_preferences(feed_name: String) -> void:
	var view: Node = _views.get(feed_name, null)
	if view == null:
		return
	view.set("follow_camera", _video_face_locked)
	if view.has_method("set_show_video_panel"):
		view.call("set_show_video_panel", _show_video_panel and bool(_enabled.get(feed_name, true)))


func _configure_view(feed_name: String) -> void:
	var view: Node = _views.get(feed_name, null)
	if view == null:
		return
	var feed := _feeds.get(feed_name, {}) as Dictionary
	if view.has_method("set_decoder_stream_id"):
		view.call("set_decoder_stream_id", feed_name)
	if view.has_method("set_display_size"):
		view.call("set_display_size", _feed_view_size(feed))
	view.set("follow_offset", _feed_view_offset(feed))
	view.set("follow_distance", float(feed.get("view_distance_m", DEFAULT_VIEW_DISTANCE)))
	if view.has_method("configure_video_stream"):
		view.call("configure_video_stream", feed)


func _connect_feed(feed_name: String) -> void:
	if _host.is_empty() or not _feeds.has(feed_name):
		return

	var feed := _feeds[feed_name] as Dictionary
	var transport := _select_video_transport(feed)
	var port := int(feed.get("udp_port", 0)) if transport == "udp" else _feed_tcp_port(feed)
	if port <= 0:
		return

	_configure_view(feed_name)

	if transport == "udp":
		var udp := _ensure_udp_handler(feed_name)
		var tcp := _tcp_handlers.get(feed_name, null) as TcpHandler
		if tcp:
			tcp.disconnect_from_robot()
		if udp.is_connected_to_robot() and udp.get_host() == _host and udp.get_port() == port:
			_set_packet_source(feed_name, udp)
			return
		udp.disconnect_from_robot()
		print("[VideoFeedManager] Connecting %s (UDP) to %s:%d" % [feed_name, _host, port])
		udp.connect_to_video_stream(_host, port)
		_set_packet_source(feed_name, udp)
	else:
		var tcp_handler := _ensure_tcp_handler(feed_name)
		var udp_handler := _udp_handlers.get(feed_name, null) as UdpVideoHandler
		if udp_handler:
			udp_handler.disconnect_from_robot()
		if tcp_handler.is_connected_to_robot() and tcp_handler.get_host() == _host and tcp_handler.get_port() == port:
			_set_packet_source(feed_name, tcp_handler)
			return
		tcp_handler.disconnect_from_robot()
		print("[VideoFeedManager] Connecting %s (TCP) to %s:%d" % [feed_name, _host, port])
		tcp_handler.connect_to_video_stream(_host, port)
		_set_packet_source(feed_name, tcp_handler)


func _disconnect_feed(feed_name: String, clear_view: bool) -> void:
	var tcp := _tcp_handlers.get(feed_name, null) as TcpHandler
	if tcp:
		tcp.disconnect_from_robot()
	var udp := _udp_handlers.get(feed_name, null) as UdpVideoHandler
	if udp:
		udp.disconnect_from_robot()
	if clear_view:
		var view: Node = _views.get(feed_name, null)
		if view and view.has_method("clear_video_stream"):
			view.call("clear_video_stream")


func _ensure_tcp_handler(feed_name: String) -> TcpHandler:
	if _tcp_handlers.has(feed_name):
		return _tcp_handlers[feed_name] as TcpHandler
	var handler := TcpHandler.new()
	handler.name = "VideoTcp_%s" % feed_name
	handler.set_max_recv_buffer(VIDEO_RECV_BUFFER_BYTES)
	handler.connected_to_server.connect(_on_feed_connected.bind(feed_name, "TCP"))
	handler.disconnected_from_server.connect(_on_feed_disconnected.bind(feed_name, "TCP"))
	handler.connection_failed.connect(_on_feed_connection_failed.bind(feed_name, "TCP"))
	handler.video_frame_received.connect(_on_video_frame_received.bind(feed_name))
	add_child(handler)
	_tcp_handlers[feed_name] = handler
	return handler


func _ensure_udp_handler(feed_name: String) -> UdpVideoHandler:
	if _udp_handlers.has(feed_name):
		return _udp_handlers[feed_name] as UdpVideoHandler
	var handler := UdpVideoHandler.new()
	handler.name = "VideoUdp_%s" % feed_name
	handler.connected_to_server.connect(_on_feed_connected.bind(feed_name, "UDP"))
	handler.disconnected_from_server.connect(_on_feed_disconnected.bind(feed_name, "UDP"))
	handler.connection_failed.connect(_on_feed_connection_failed.bind(feed_name, "UDP"))
	handler.video_frame_received.connect(_on_video_frame_received.bind(feed_name))
	add_child(handler)
	_udp_handlers[feed_name] = handler
	return handler


func _set_packet_source(feed_name: String, handler: Node) -> void:
	var view: Node = _views.get(feed_name, null)
	if view and view.has_method("set_packet_source"):
		view.call("set_packet_source", handler)


func _on_feed_connected(feed_name: String, transport: String) -> void:
	print("[VideoFeedManager] %s video stream connected (%s)" % [feed_name, transport])


func _on_feed_disconnected(feed_name: String, transport: String) -> void:
	print("[VideoFeedManager] %s video stream disconnected (%s)" % [feed_name, transport])


func _on_feed_connection_failed(reason: String, feed_name: String, transport: String) -> void:
	print("[VideoFeedManager] %s video connection failed (%s): %s" % [feed_name, transport, reason])


func _on_video_frame_received(packet: Dictionary, feed_name: String) -> void:
	var view: Node = _views.get(feed_name, null)
	if view == null:
		return
	if view.has_method("set_clock_offset"):
		view.call("set_clock_offset", RobotClockSync.offset_ns, RobotClockSync.samples)
	if view.has_method("report_video_packet"):
		view.call("report_video_packet", packet)
	elif view.has_method("report_video_frame"):
		view.call("report_video_frame", packet)


func _select_video_transport(feed: Dictionary) -> String:
	var transport := String(feed.get("transport", "tcp")).to_lower()
	var udp_port := int(feed.get("udp_port", 0))
	if transport == "udp" and udp_port > 0:
		return "udp"
	if transport == "auto" and udp_port > 0:
		return "udp"
	return "tcp"


func _feed_tcp_port(feed: Dictionary) -> int:
	var port := int(feed.get("port", 0))
	if port > 0:
		return port
	return _default_tcp_port


func _feed_view_size(feed: Dictionary) -> Vector2:
	var raw: Variant = feed.get("view_size_m", [])
	if raw is Array and raw.size() >= 2:
		return Vector2(float(raw[0]), float(raw[1]))
	return DEFAULT_VIEW_SIZE


func _feed_view_offset(feed: Dictionary) -> Vector3:
	var raw: Variant = feed.get("view_offset_m", [])
	if raw is Array and raw.size() >= 3:
		return Vector3(float(raw[0]), float(raw[1]), float(raw[2]))
	return Vector3.ZERO
