class_name IngestSession
extends RefCounted
## Session layer (N:1): the headset-initiated OLCP session to a live server
## that the user configured (QR / manual entry) and verified on the headset.
##
## Unlike a host session it never receives declarations: the server's
## `capture_request` can only narrow what the headset captures (StreamPlanner),
## and the user's scan + Start is the authorization. The session injects its
## endpoint into the LivePushSink (`media_up`) and drives the result channel
## (`media_down`) rendered by the DenseMapView.

signal connectivity_changed(text: String, level: String)
signal capture_request_received(request: Dictionary)

const DEFAULT_HOST := "127.0.0.1"
const DEFAULT_PUSH_PORT := 63910
const DEFAULT_RESULT_PORT := 63912

var host := DEFAULT_HOST
var push_port := DEFAULT_PUSH_PORT
var result_port := DEFAULT_RESULT_PORT
var auth_token := ""
var planner := StreamPlanner.new()

var _push_sink: LivePushSink
var _results: DenseMapView


func _init(push_sink: LivePushSink = null, results: DenseMapView = null) -> void:
	_push_sink = push_sink
	_results = results
	if _results != null:
		_results.connected_to_server.connect(_on_results_connected)
		_results.disconnected_from_server.connect(_on_results_disconnected)
		_results.connection_failed.connect(_on_results_connection_failed)
		_results.capture_request_received.connect(_on_capture_request_received)


## Applies the endpoint fields of the capture options
## (server_host / server_port / server_result_port / server_auth_token).
func configure(options: Dictionary) -> void:
	var next_host := str(options.get("server_host", host)).strip_edges()
	host = next_host if not next_host.is_empty() else DEFAULT_HOST
	# `capture_options` declares the ports as 0 when unset, and 0 must mean
	# "keep the default endpoint", not port 1.
	push_port = _port(options.get("server_port", push_port), push_port)
	result_port = _port(options.get("server_result_port", result_port), result_port)
	auth_token = str(options.get("server_auth_token", auth_token))
	if _push_sink != null:
		_push_sink.set_target(host, push_port, auth_token)


static func _port(value: Variant, fallback: int) -> int:
	var port := int(value)
	return clampi(port, 1, 65535) if port > 0 else fallback


func results_view() -> DenseMapView:
	return _results


func connect_results() -> void:
	if _results == null:
		return
	connectivity_changed.emit(tr("UI_LIVE_SERVER_CONNECTING") % [host, result_port], "normal")
	print("Live feed pull connecting: %s:%d" % [host, result_port])
	_results.connect_to_server(host, result_port, auth_token)


func disconnect_results() -> void:
	if _results == null:
		return
	print("Live feed pull disconnecting")
	_results.disconnect_from_server()


func _on_results_connected(result_host: String, port: int) -> void:
	connectivity_changed.emit(tr("UI_LIVE_SERVER_CONNECTED") % [result_host, port], "success")


func _on_results_disconnected(result_host: String, port: int) -> void:
	connectivity_changed.emit(tr("UI_LIVE_SERVER_DISCONNECTED") % [result_host, port], "warning")


func _on_results_connection_failed(_result_host: String, _port: int, reason: String) -> void:
	connectivity_changed.emit(tr("UI_LIVE_SERVER_CONNECTION_FAILED") % reason, "error")


func _on_capture_request_received(request: Dictionary) -> void:
	capture_request_received.emit(request)
