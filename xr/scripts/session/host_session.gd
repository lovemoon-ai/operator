class_name HostSession
extends Node
## Session layer (1:1): the headset's session with one host — a robot computer
## (`xr-bridge` / adapter) or a GPU service (`operator_xr` program). A newer
## connection replaces the older one on the host side.
##
## This node is the single place ctrl commands are sent and received
## (Hello · DeviceDescriptor · Blueprint · BlueprintState · BlueprintEvent ·
## StreamsStatus · StreamsControl) and it owns the session's media_down
## channels: telemetry and timed video. Robot commands and XR state keep using
## the ctrl transport through their own senders (sinks). The host session's
## media_up (OLCP push) is mounted by a host capture composition and targets
## this session's peer address.

signal connected()
signal disconnected()
signal connection_failed(reason: String)
signal descriptor_received(descriptor: Dictionary)
signal descriptor_cleared()
signal telemetry_received(data: Dictionary)
signal telemetry_link_lost()
signal blueprint_received(blueprint: Dictionary)
signal blueprint_cleared()
signal blueprint_state_received(state: Dictionary)
signal streams_control_received(control: Dictionary)
signal video_packet_received(packet: Dictionary)
signal video_connected()
signal video_disconnected(retrying: bool)
signal video_connection_failed(reason: String)

const DEFAULT_TELEMETRY_PORT := 63903
const TELEMETRY_PORT_OFFSET := 2
const TELEMETRY_RETRY_DELAY_SEC := 1.0
const VIDEO_RECONNECT_DELAY_SEC := 0.5
const DEFAULT_VIDEO_PORT := 12345

## ctrl transport (the scene-owned TcpHandler; typed as Node like the mode's
## own reference so tests can inject a transport double).
var tcp_handler: Node
var session: Session
var telemetry_tcp_handler: TcpHandler
## Video transports (TcpHandler / UdpVideoHandler; Node-typed for doubles).
var video_tcp_handler: Node
var video_udp_handler: Node
var clock_sync: RobotClockSync
## View that decodes media_down video (configure_video_stream,
## set_packet_source, clear_video_stream).
var video_view: Node
## True while the Operator outside target owns this session; telemetry and
## video reconnection only run then.
var active := false
## (ip: String, pose_port: int) -> Dictionary of discovery info
## ({telemetry_port, video_port, ...}) or {} when unknown.
var endpoint_lookup := Callable()
var active_telemetry_port := DEFAULT_TELEMETRY_PORT
var active_video_transport := "tcp"
## () -> bool. When set and it returns true, the mode connected a video
## endpoint pinned in settings ("Connect video") and the descriptor feed is
## not used.
var video_override := Callable()

var _last_video_feed: Dictionary = {}
var _telemetry_retry_remaining := 0.0
var _video_retry_remaining := -1.0


## Builds the session's channel nodes. `ctrl` is the scene's command
## TcpHandler (robot command and XR-state senders share it).
func setup(ctrl: TcpHandler) -> void:
	tcp_handler = ctrl
	session = Session.new()
	session.name = "Session"
	session.tcp_handler = ctrl
	add_child(session)
	session.device_connected.connect(func(descriptor: Dictionary) -> void: descriptor_received.emit(descriptor))
	session.device_disconnected.connect(func() -> void: descriptor_cleared.emit())
	session.telemetry_received.connect(func(data: Dictionary) -> void: telemetry_received.emit(data))
	session.blueprint_received.connect(func(blueprint: Dictionary) -> void: blueprint_received.emit(blueprint))
	session.blueprint_cleared.connect(func() -> void: blueprint_cleared.emit())
	session.blueprint_state_received.connect(func(state: Dictionary) -> void: blueprint_state_received.emit(state))
	session.streams_control_received.connect(func(control: Dictionary) -> void: streams_control_received.emit(control))

	telemetry_tcp_handler = TcpHandler.new()
	telemetry_tcp_handler.name = "TelemetryTcpHandler"
	add_child(telemetry_tcp_handler)
	# [issue 005 / item 6] 32 MiB so a freshly connected client surviving a
	# brief Wi-Fi stall doesn't trip the overflow-disconnect cycle on the next IDR.
	var video_tcp := TcpHandler.new()
	video_tcp.name = "VideoTcpHandler"
	video_tcp.set_max_recv_buffer(32 * 1024 * 1024)
	add_child(video_tcp)
	video_tcp_handler = video_tcp
	# [issue 005 / item 1] Same API surface as the TCP handler; idle until the
	# descriptor asks for UDP.
	var video_udp := UdpVideoHandler.new()
	video_udp.name = "VideoUdpHandler"
	add_child(video_udp)
	video_udp_handler = video_udp
	# [opt 5] ClockPing on the ctrl channel every second; the learned offset
	# makes the video latency tracker's `tx=` honest.
	clock_sync = RobotClockSync.new()
	clock_sync.name = "ClockSync"
	clock_sync.tcp_handler = ctrl
	add_child(clock_sync)

	ctrl.connected_to_server.connect(_on_connected)
	ctrl.disconnected_from_server.connect(_on_disconnected)
	ctrl.connection_failed.connect(_on_connection_failed)
	ctrl.command_received.connect(_on_command_received)
	telemetry_tcp_handler.connected_to_server.connect(_on_telemetry_connected)
	telemetry_tcp_handler.disconnected_from_server.connect(_on_telemetry_disconnected)
	telemetry_tcp_handler.connection_failed.connect(_on_telemetry_connection_failed)
	telemetry_tcp_handler.command_received.connect(_on_telemetry_command_received)
	for handler_v in [video_tcp_handler, video_udp_handler]:
		var handler: Node = handler_v
		handler.connect("connected_to_server", _on_video_connected)
		handler.connect("disconnected_from_server", _on_video_disconnected)
		handler.connect("connection_failed", _on_video_connection_failed)
		handler.connect("video_frame_received", func(packet: Dictionary) -> void: video_packet_received.emit(packet))


func _process(delta: float) -> void:
	_tick_telemetry_reconnect(delta)
	_tick_video_reconnect(delta)


func host() -> String:
	return str(tcp_handler.call("get_host")) if tcp_handler != null else ""


func port() -> int:
	return int(tcp_handler.call("get_port")) if tcp_handler != null else 0


func is_connected_to_host() -> bool:
	return tcp_handler != null and bool(tcp_handler.call("is_connected_to_robot"))


## The headset capabilities this build adds to Hello (capture streams).
func set_extra_capabilities(capabilities: Array) -> void:
	if session != null:
		session.extra_capabilities = capabilities.duplicate()


## Called before the ctrl transport connects to (ip, pose_port).
func prepare_endpoint(ip: String, pose_port: int) -> void:
	active_telemetry_port = telemetry_port_for(ip, pose_port)


func telemetry_port_for(ip: String, pose_port: int) -> int:
	var info := _lookup(ip, pose_port)
	var discovered_port := int(info.get("telemetry_port", 0))
	if discovered_port > 0 and discovered_port <= 65535:
		return discovered_port
	var derived := pose_port + TELEMETRY_PORT_OFFSET
	return derived if derived > 0 and derived <= 65535 else DEFAULT_TELEMETRY_PORT


func send_blueprint_event(event: Dictionary) -> Error:
	if session == null:
		return ERR_UNAVAILABLE
	return session.send_blueprint_event(event)


func send_streams_status(status: Dictionary) -> Error:
	if session == null:
		return ERR_UNAVAILABLE
	return session.send_streams_status(status)


## Discovery saw (ip, pose_port) again; when it is this session's peer, follow
## a changed telemetry port and re-establish media.
func on_endpoint_discovered(ip: String, pose_port: int, telemetry_port: int) -> void:
	if not is_connected_to_host() or host() != ip or port() != pose_port:
		return
	active_telemetry_port = telemetry_port
	connect_telemetry(ip)
	connect_video(ip, pose_port)


## Discovery lost (ip, pose_port): drop this session's media if it was ours.
func on_endpoint_lost(ip: String, pose_port: int) -> void:
	if not is_connected_to_host() or host() != ip or port() != pose_port:
		return
	if video_tcp_handler.is_connected_to_robot():
		video_tcp_handler.disconnect_from_robot()
	if video_udp_handler.is_connected_to_robot():
		video_udp_handler.disconnect_from_robot()
	if telemetry_tcp_handler.is_connected_to_robot():
		telemetry_tcp_handler.disconnect_from_robot()


## Tears down every channel (ctrl, telemetry, video).
func disconnect_all() -> void:
	if tcp_handler:
		tcp_handler.call("disconnect_from_robot")
	disconnect_media()
	if clock_sync:
		clock_sync.stop()


func disconnect_media() -> void:
	if video_tcp_handler:
		video_tcp_handler.disconnect_from_robot()
	if video_udp_handler:
		video_udp_handler.disconnect_from_robot()
	if telemetry_tcp_handler:
		telemetry_tcp_handler.disconnect_from_robot()
	if video_view and video_view.has_method("clear_video_stream"):
		video_view.clear_video_stream()


## Total bytes moved over the session's channels (settings network rate).
func network_byte_total(method_name: String) -> int:
	var total := 0
	for handler_value: Variant in [tcp_handler, telemetry_tcp_handler, video_tcp_handler, video_udp_handler]:
		var handler := handler_value as Node
		if handler != null and handler.has_method(method_name):
			total += int(handler.call(method_name))
	return total


# --- ctrl channel -------------------------------------------------------------

func _on_connected() -> void:
	session.on_connected()
	connected.emit()
	connect_telemetry(host())
	connect_video(host(), port())
	if clock_sync:
		clock_sync.start()


func _on_disconnected() -> void:
	disconnect_media()
	session.on_disconnected()
	if clock_sync:
		clock_sync.stop()
	disconnected.emit()


func _on_connection_failed(reason: String) -> void:
	telemetry_tcp_handler.disconnect_from_robot()
	connection_failed.emit(reason)


func _on_command_received(command: String, data: PackedByteArray) -> void:
	if clock_sync and clock_sync.handle_command(command, data):
		return
	if session.handle_command(command, data):
		return
	match command:
		"VideoFrame":
			pass
		_:
			print("[Operator] Unknown command: %s" % command)


# --- telemetry (media_down) ----------------------------------------------------

func connect_telemetry(ip: String) -> void:
	if ip.is_empty() or active_telemetry_port <= 0 or active_telemetry_port > 65535:
		return
	if (
		telemetry_tcp_handler.is_connected_to_robot()
		and telemetry_tcp_handler.get_host() == ip
		and telemetry_tcp_handler.get_port() == active_telemetry_port
	):
		return
	telemetry_tcp_handler.disconnect_from_robot()
	_telemetry_retry_remaining = TELEMETRY_RETRY_DELAY_SEC
	print("[Operator] Connecting telemetry stream to %s:%d" % [ip, active_telemetry_port])
	telemetry_tcp_handler.connect_to_robot(ip, active_telemetry_port)


func _on_telemetry_connected() -> void:
	_telemetry_retry_remaining = 0.0
	print("[Operator] Telemetry stream connected")


func _on_telemetry_disconnected() -> void:
	_telemetry_retry_remaining = TELEMETRY_RETRY_DELAY_SEC
	print("[Operator] Telemetry stream disconnected")
	telemetry_link_lost.emit()


func _on_telemetry_connection_failed(reason: String) -> void:
	_telemetry_retry_remaining = TELEMETRY_RETRY_DELAY_SEC
	print("[Operator] Telemetry connection failed: %s" % reason)


func _tick_telemetry_reconnect(delta: float) -> void:
	if telemetry_tcp_handler == null or tcp_handler == null:
		return
	if not active or not is_connected_to_host():
		return
	if telemetry_tcp_handler.get_state() != TcpHandler.State.DISCONNECTED:
		return
	_telemetry_retry_remaining = maxf(_telemetry_retry_remaining - maxf(delta, 0.0), 0.0)
	if _telemetry_retry_remaining > 0.0:
		return
	connect_telemetry(host())


func _on_telemetry_command_received(command: String, data: PackedByteArray) -> void:
	if session.handle_command(command, data):
		return
	print("[Operator] Unknown telemetry command: %s" % command)


# --- video (media_down) --------------------------------------------------------

## Adopts the descriptor's primary video feed for the decoder.
func configure_video_from_descriptor(descriptor: Dictionary) -> void:
	if not video_view or not video_view.has_method("configure_video_stream"):
		return
	var feed := extract_primary_video_feed(descriptor)
	if feed.is_empty():
		feed = {
			"width": 1280,
			"height": 720,
			"stereo": false,
		}
	_last_video_feed = feed
	video_view.configure_video_stream(feed)


static func extract_primary_video_feed(descriptor: Dictionary) -> Dictionary:
	var feeds: Array = descriptor.get("video_feeds", [])
	for feed_variant in feeds:
		if feed_variant is Dictionary:
			var feed: Dictionary = feed_variant
			if int(feed.get("port", 0)) > 0:
				return feed
	return {}


## [issue 005 / item 1+2] Transport for the negotiated video feed.
static func select_video_transport(feed: Dictionary) -> String:
	var transport := str(feed.get("transport", "tcp")).to_lower()
	var udp_port := int(feed.get("udp_port", 0))
	if transport == "udp" and udp_port > 0:
		return "udp"
	if transport == "auto" and udp_port > 0:
		return "udp"
	return "tcp"


## Connects the operator timed-video stream for (ip, pose_port): a pinned
## manual endpoint wins, else the descriptor feed, else discovery's port.
func connect_video(ip: String, pose_port: int = 0) -> void:
	if video_override.is_valid() and bool(video_override.call()):
		return
	if ip.is_empty():
		return
	# Resolve the TCP port: prefer the descriptor's primary feed, then the
	# discovery announcement, then the legacy default.
	var tcp_port := DEFAULT_VIDEO_PORT
	var info := _lookup(ip, pose_port)
	if not info.is_empty():
		tcp_port = int(info.get("video_port", tcp_port))
	if int(_last_video_feed.get("port", 0)) > 0:
		tcp_port = int(_last_video_feed["port"])
	var transport := select_video_transport(_last_video_feed)
	var udp_port := int(_last_video_feed.get("udp_port", 0))

	# Already pointed at the right host+port: don't churn the connection —
	# that flushes decoder state.
	if transport == "tcp":
		if (
			video_tcp_handler.is_connected_to_robot()
			and video_tcp_handler.get_host() == ip
			and video_tcp_handler.get_port() == tcp_port
		):
			video_udp_handler.disconnect_from_robot()
			active_video_transport = "tcp"
			return
	else:
		if (
			video_udp_handler.is_connected_to_robot()
			and video_udp_handler.get_host() == ip
			and video_udp_handler.get_port() == udp_port
		):
			video_tcp_handler.disconnect_from_robot()
			active_video_transport = "udp"
			return

	# Never run both transports at once or we'd see duplicate frames.
	video_tcp_handler.disconnect_from_robot()
	video_udp_handler.disconnect_from_robot()

	# Reconfigure the decoder for the new transport. Never pass an empty
	# descriptor: its 1280x720 fallback feed has no `codec` and would reset the
	# decoder MIME from `video/hevc` back to `video/avc`. Wrap the cached feed
	# so the same feed is re-extracted unchanged.
	var configure_arg: Dictionary = {}
	if not _last_video_feed.is_empty():
		configure_arg = {"video_feeds": [_last_video_feed]}
	if transport == "udp":
		print("[Operator] Connecting video stream (UDP) to %s:%d" % [ip, udp_port])
		active_video_transport = "udp"
		configure_video_from_descriptor(configure_arg)
		video_udp_handler.connect_to_video_stream(ip, udp_port)
		if video_view and video_view.has_method("set_packet_source"):
			video_view.set_packet_source(video_udp_handler)
	else:
		print("[Operator] Connecting video stream (TCP) to %s:%d" % [ip, tcp_port])
		active_video_transport = "tcp"
		configure_video_from_descriptor(configure_arg)
		video_tcp_handler.connect_to_video_stream(ip, tcp_port)
		if video_view and video_view.has_method("set_packet_source"):
			video_view.set_packet_source(video_tcp_handler)


## Connects operator timed video to an endpoint from settings
## ({video_ip, video_port, video_sbs}).
func connect_manual_video(options: Dictionary) -> void:
	var host_name := str(options.get("video_ip", "")).strip_edges()
	var video_port := int(options.get("video_port", 0))
	var feed := {
		"width": 1280,
		"height": 720,
		"codec": "h264",
		"stereo": bool(options.get("video_sbs", false)),
	}
	video_udp_handler.disconnect_from_robot()
	# Disconnect before configuring: disconnect_from_robot() emits
	# disconnected_from_server synchronously, and a disconnect handler clears
	# the decoder, so configuring first would stop the decoder just started.
	video_tcp_handler.disconnect_from_robot()
	if video_view and video_view.has_method("configure_video_stream"):
		video_view.configure_video_stream(feed)
	active_video_transport = "tcp"
	if video_view and video_view.has_method("set_packet_source"):
		video_view.set_packet_source(video_tcp_handler)
	video_tcp_handler.connect_to_video_stream(host_name, video_port)


## Stops operator timed video (another transport, e.g. XRoboToolkit FPV,
## takes the decoder over).
func release_video() -> void:
	video_tcp_handler.disconnect_from_robot()
	video_udp_handler.disconnect_from_robot()
	active_video_transport = ""


func _on_video_connected() -> void:
	_video_retry_remaining = -1.0
	print("[Operator] Video stream connected")
	video_connected.emit()


func _on_video_disconnected() -> void:
	print("[Operator] Video stream disconnected")
	var retrying := _schedule_video_reconnect()
	# Keep the last decoded texture and decoder alive across a transient video
	# reconnect. Clearing here hides the Blueprint-owned panel and makes every
	# brief Wi-Fi stall rebuild MediaCodec on the render thread.
	if not retrying and video_view and video_view.has_method("clear_video_stream"):
		video_view.clear_video_stream()
	video_disconnected.emit(retrying)


func _on_video_connection_failed(reason: String) -> void:
	print("[Operator] Video connection failed: %s" % reason)
	_schedule_video_reconnect()
	video_connection_failed.emit(reason)


func _schedule_video_reconnect() -> bool:
	if active_video_transport == "tcp" and active and is_connected_to_host():
		_video_retry_remaining = VIDEO_RECONNECT_DELAY_SEC
		return true
	return false


func _tick_video_reconnect(delta: float) -> void:
	if _video_retry_remaining < 0.0:
		return
	if (
		active_video_transport != "tcp"
		or not active
		or not is_connected_to_host()
		or video_tcp_handler == null
	):
		_video_retry_remaining = -1.0
		return
	if int(video_tcp_handler.call("get_state")) != TcpHandler.State.DISCONNECTED:
		_video_retry_remaining = -1.0
		return
	_video_retry_remaining -= maxf(delta, 0.0)
	if _video_retry_remaining > 0.0:
		return
	_video_retry_remaining = -1.0
	print("[Operator] Reconnecting latest-frame video stream")
	connect_video(host(), port())


func _lookup(ip: String, pose_port: int) -> Dictionary:
	if not endpoint_lookup.is_valid():
		return {}
	var info: Variant = endpoint_lookup.call(ip, pose_port)
	return info if info is Dictionary else {}
