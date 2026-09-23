class_name HostDiscovery
extends Node
## Session layer: the hosts announcing themselves on the LAN. Merges
## Operator's own beacon (UDP 63900, the scene's Discovery node) with the
## XRoboToolkit robot beacon (UDP 29888, Pico builds only) into one
## protocol-aware endpoint map. Identity includes the protocol and command
## port, so an Operator service and an XRoboToolkit service can share one IP.
## The mode reads this map for its settings dropdown and launch decision; the
## host session follows it for telemetry/video endpoints.

signal changed()
signal endpoint_found(ip: String, pose_port: int, telemetry_port: int)
signal endpoint_lost(ip: String, pose_port: int)

const XROBOT_TOOLKIT_DISCOVERY_PATH := "res://scripts/compat/xrobot_toolkit/xrt_discovery.gd"
const XROBOT_TOOLKIT_DEVICE_TYPE := "xrobot_toolkit"
const DEFAULT_TELEMETRY_PORT := 63903
const TELEMETRY_PORT_OFFSET := 2

## Discovery identity -> endpoint metadata.
var known: Dictionary = {}
var _operator_discovery: Node
var _xrt_discovery: Node = null


func setup(operator_discovery: Node) -> void:
	_operator_discovery = operator_discovery
	if _operator_discovery != null:
		_operator_discovery.connect("robot_found", _on_robot_found)
		_operator_discovery.connect("robot_lost", _on_robot_lost)
	_start_xrt_discovery()


func start_scan() -> void:
	if _operator_discovery != null and _operator_discovery.has_method("start_scan"):
		_operator_discovery.call("start_scan")


func stop_scan() -> void:
	if _operator_discovery != null and _operator_discovery.has_method("stop_scan"):
		_operator_discovery.call("stop_scan")
	if _xrt_discovery != null and _xrt_discovery.has_method("stop_scan"):
		_xrt_discovery.call("stop_scan")


static func operator_key(ip: String, pose_port: int) -> String:
	return "operator|%s|%d" % [ip, pose_port]


static func xrt_key(ip: String, port: int) -> String:
	return "xrobot_toolkit_v1|%s|%d" % [ip, port]


static func endpoint_ip(key: Variant, info: Dictionary) -> String:
	var ip := str(info.get("ip", "")).strip_edges()
	if ip.is_empty() and str(key).is_valid_ip_address():
		ip = str(key)
	return ip


static func matches_options(info: Dictionary, options: Dictionary) -> bool:
	return (
		str(info.get("ip", "")).strip_edges() == str(options.get("ip", "")).strip_edges()
		and int(info.get("pose_port", 0)) == int(options.get("port", 0))
		and str(info.get("protocol", "operator")) == str(options.get("protocol", "operator"))
	)


## Silent auto-connect is allowed only for an endpoint the operator previously
## confirmed and saved.
static func can_auto_connect(info: Dictionary, options: Dictionary) -> bool:
	return bool(options.get("loaded", false)) and matches_options(info, options)


static func is_loopback_host(host: String) -> bool:
	var trimmed := host.strip_edges().to_lower()
	return (
		trimmed == ""
		or trimmed == "localhost"
		or trimmed == "::1"
		or trimmed == "0:0:0:0:0:0:0:1"
		or trimmed.begins_with("127.")
	)


## Launch decision once the discovery window closes. Returns either
## {"action": "auto_connect", "options": Dictionary} or
## {"action": "show", "status": String}:
##   show_on_launch            -> show the settings page
##   no hosts                  -> show (manual fallback)
##   one host == saved endpoint -> auto-connect
##   one other host            -> show it for confirmation
##   several hosts             -> show the populated dropdown
## Silent auto-connect is allowed only for an endpoint the operator previously
## confirmed: a fresh install's loopback default must never hand ownership to
## whichever unrelated debug service happens to be the sole broadcaster.
func launch_decision(persisted: Dictionary) -> Dictionary:
	var show_on_launch := bool(persisted.get("show_on_launch", false))
	print("[Operator] Launch decision: known=%d show_on_launch=%s last_ip=%s" % [
		count(), show_on_launch, str(persisted.get("ip", ""))])
	if show_on_launch:
		return {"action": "show", "status": tr("UI_SHOW_ON_LAUNCH_ENABLED")}
	if count() == 0:
		return {"action": "show", "status": tr("UI_NO_ROBOTS_DISCOVERED")}
	if count() > 1:
		# The dropdown preselects the saved endpoint when it is among them.
		return {"action": "show", "status": tr("UI_ROBOTS_FOUND_PICK") % count()}
	var only_key: Variant = known.keys()[0]
	var only_info: Dictionary = known[only_key]
	var only_ip := endpoint_ip(only_key, only_info)
	if not can_auto_connect(only_info, persisted):
		return {"action": "show", "status": tr("UI_FOUND_ROBOT_CONFIRM") % only_ip}
	var options := persisted.duplicate(true)
	options["target_scope"] = "outside"
	options["protocol"] = str(only_info.get("protocol", "operator"))
	options["ip"] = only_ip
	options["port"] = int(only_info.get("pose_port", 63901))
	return {"action": "auto_connect", "options": options}


func find(ip: String, protocol := "", pose_port := 0) -> Dictionary:
	for key in known:
		var info_v: Variant = known[key]
		if not info_v is Dictionary:
			continue
		var info := info_v as Dictionary
		if endpoint_ip(key, info) != ip:
			continue
		if not protocol.is_empty() and str(info.get("protocol", "operator")) != protocol:
			continue
		if pose_port > 0 and int(info.get("pose_port", 0)) != pose_port:
			continue
		return info
	return {}


func count() -> int:
	return known.size()


## The name-keyed structure the settings dropdown expects.
func settings_state() -> Dictionary:
	var by_endpoint: Dictionary = {}
	for key in known:
		var raw: Dictionary = known[key]
		var ip := endpoint_ip(key, raw)
		by_endpoint[str(key)] = {
			"name": raw.get("name", ip),
			"ip": ip,
			"pose_port": raw.get("pose_port", 63901),
			"video_port": raw.get("video_port", 0),
			"telemetry_port": raw.get("telemetry_port", DEFAULT_TELEMETRY_PORT),
			"device_type": raw.get("device_type", ""),
			"device_name": raw.get("device_name", ""),
			"protocol": raw.get("protocol", "operator"),
		}
	return by_endpoint


func _on_robot_found(
	robot_name: String,
	ip: String,
	pose_port: int,
	video_port: int,
	telemetry_port: int,
	device_type: String,
	device_name: String
) -> void:
	if telemetry_port <= 0:
		telemetry_port = pose_port + TELEMETRY_PORT_OFFSET
	known[operator_key(ip, pose_port)] = {
		"name": robot_name,
		"ip": ip,
		"pose_port": pose_port,
		"video_port": video_port,
		"telemetry_port": telemetry_port,
		"device_type": device_type,
		"device_name": device_name,
		"protocol": "operator",
		# Which listener owns this entry. The XRoboToolkit beacon defers to
		# native announcements only for metadata, not for endpoint identity.
		"source": "operator",
	}
	changed.emit()
	endpoint_found.emit(ip, pose_port, telemetry_port)


func _on_robot_lost(_robot_name: String, ip: String, pose_port: int) -> void:
	if not known.erase(operator_key(ip, pose_port)):
		return
	endpoint_lost.emit(ip, pose_port)
	changed.emit()


## XRoboToolkit's beacon carries only an address and a clock reading — no name,
## no ports, no device type. Everything else is filled from the protocol's
## fixed service port so the entry can sit in the same dropdown as native hosts.
## Pico-only: other platforms never listen for it.
func _start_xrt_discovery() -> void:
	if not PicoPlatformAdapter.is_pico_build():
		return
	var script: Variant = load(XROBOT_TOOLKIT_DISCOVERY_PATH)
	if script == null:
		push_warning("[Operator] Cannot load the XRoboToolkit discovery listener")
		return
	var instance: Variant = script.new()
	if not (instance is Node):
		push_warning("[Operator] Cannot instantiate the XRoboToolkit discovery listener")
		return
	_xrt_discovery = instance
	_xrt_discovery.name = "XRobotToolkitDiscovery"
	_xrt_discovery.connect("host_found", _on_xrt_host_found)
	_xrt_discovery.connect("host_lost", _on_xrt_host_lost)
	add_child(_xrt_discovery)
	_xrt_discovery.call("start_scan")


func _on_xrt_host_found(ip: String, port: int, _timestamp_ms: int) -> void:
	known[xrt_key(ip, port)] = {
		"name": "XRoboToolkit %s" % ip,
		"ip": ip,
		"pose_port": port,
		"video_port": 0,
		"telemetry_port": 0,
		"device_type": XROBOT_TOOLKIT_DEVICE_TYPE,
		"device_name": "",
		"source": XROBOT_TOOLKIT_DEVICE_TYPE,
		# Lets the settings panel preselect the matching protocol, so picking a
		# beacon connects without a second manual choice.
		"protocol": "xrobot_toolkit_v1",
	}
	changed.emit()


func _on_xrt_host_lost(ip: String) -> void:
	var removed := false
	for key in known.keys():
		var existing: Dictionary = known[key]
		if (
			str(existing.get("source", "")) == XROBOT_TOOLKIT_DEVICE_TYPE
			and endpoint_ip(key, existing) == ip
		):
			known.erase(key)
			removed = true
	if removed:
		changed.emit()
