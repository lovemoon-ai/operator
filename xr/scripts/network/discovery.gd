class_name RobotDiscovery
extends Node
## UDP broadcast listener for robot discovery.
## Listens on DISCOVERY_PORT for JSON robot announcements.
##
## Expected JSON format:
## {
##   "service": "xrobo-agent",
##   "name": "Robot-1",
##   "tcp_port": 63901,
##   "video_port": 12345
## }

signal robot_found(name: String, ip: String, pose_port: int, video_port: int, device_type: String, device_name: String)
signal robot_lost(name: String)

const DISCOVERY_PORT: int = 63900
## How long before a robot is considered lost (seconds)
const ROBOT_TIMEOUT: float = 10.0

## UDP peer for receiving broadcasts
var _udp_peer: PacketPeerUDP = null
## Known robots: name -> { ip, pose_port, video_port, last_seen }
var _known_robots: Dictionary = {}
## Whether scanning is active
var _scanning: bool = false


func _process(delta: float) -> void:
	if not _scanning or not _udp_peer:
		return

	# Process incoming packets
	while _udp_peer.get_available_packet_count() > 0:
		var packet := _udp_peer.get_packet()
		var sender_ip := _udp_peer.get_packet_ip()
		var sender_port := _udp_peer.get_packet_port()

		if packet.size() == 0:
			continue

		var text := packet.get_string_from_utf8()
		_process_announcement(text, sender_ip)

	# Check for timed-out robots
	_check_timeouts()


func _process_announcement(text: String, sender_ip: String) -> void:
	var json = JSON.parse_string(text)
	if json == null or not (json is Dictionary):
		return

	var service: String = json.get("service", "")
	if service != "xrobo-agent":
		return

	var robot_name: String = json.get("name", "Unknown Robot")
	var tcp_port: int = json.get("tcp_port", 0)
	var video_port: int = json.get("video_port", 0)
	var device_type: String = json.get("device_type", "")
	var device_name: String = json.get("device_name", "")

	if tcp_port <= 0:
		return

	var is_new := not _known_robots.has(robot_name)

	_known_robots[robot_name] = {
		"ip": sender_ip,
		"pose_port": tcp_port,
		"video_port": video_port,
		"device_type": device_type,
		"device_name": device_name,
		"last_seen": Time.get_ticks_msec() / 1000.0,
	}

	if is_new:
		print("[Discovery] Robot found: %s at %s:%d (type: %s)" % [robot_name, sender_ip, tcp_port, device_type])
		robot_found.emit(robot_name, sender_ip, tcp_port, video_port, device_type, device_name)


func _check_timeouts() -> void:
	var now: float = Time.get_ticks_msec() / 1000.0
	var to_remove: Array[String] = []

	for robot_name in _known_robots:
		var info: Dictionary = _known_robots[robot_name]
		if now - info["last_seen"] > ROBOT_TIMEOUT:
			to_remove.append(robot_name)

	for robot_name in to_remove:
		_known_robots.erase(robot_name)
		print("[Discovery] Robot lost: %s" % robot_name)
		robot_lost.emit(robot_name)


## Start scanning for robot broadcasts.
func start_scan() -> void:
	if _scanning:
		return

	_udp_peer = PacketPeerUDP.new()

	var err := _udp_peer.bind(DISCOVERY_PORT)
	if err != OK:
		print("[Discovery] Failed to bind UDP port %d: error %d" % [DISCOVERY_PORT, err])
		# Try with SO_REUSEADDR by using a different approach
		_udp_peer = null
		return

	_udp_peer.set_broadcast_enabled(true)
	_scanning = true
	print("[Discovery] Started scanning on port %d" % DISCOVERY_PORT)


## Stop scanning.
func stop_scan() -> void:
	if not _scanning:
		return

	if _udp_peer:
		_udp_peer.close()
		_udp_peer = null

	_scanning = false
	_known_robots.clear()
	print("[Discovery] Stopped scanning")


## Get all currently known robots.
func get_known_robots() -> Dictionary:
	return _known_robots.duplicate()


## Check if scanning is active.
func is_scanning() -> bool:
	return _scanning


func _exit_tree() -> void:
	stop_scan()
