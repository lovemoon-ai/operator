class_name XrtDiscovery
extends Node
## Listener for the XRoboToolkit robot beacon.
##
## The robot-side service broadcasts its own address once a second and the
## headset app listens; there is no query/response. Operator's native discovery
## (`scripts/network/discovery.gd`) speaks a different JSON format on a different
## port, so without this a user running the compatibility protocol has to type
## the robot's IP by hand while the stock app finds it on its own.
##
## Wire layout, 15 + ip_len bytes, all integers little-endian:
##
##     0   u8    0xCF          magic
##     1   u8    0x7E          magic
##     2   i32   ip_len        length of the ASCII address that follows
##     6   ...   ip_ascii      e.g. "192.168.124.169"
##     ..  i64   unix_ms       robot wall clock when the beacon was sent
##     ..  u8    0xA5          trailer
##
## The beacon carries no port, so peers are reported on the protocol's fixed
## service port.

signal host_found(ip: String, port: int, timestamp_ms: int)
signal host_lost(ip: String)

const DISCOVERY_PORT := 29888
## The compatibility service port. The beacon never carries one.
const SERVICE_PORT := 63901
const MAGIC_0 := 0xCF
const MAGIC_1 := 0x7E
const TRAILER := 0xA5
const HEADER_SIZE := 6
const FOOTER_SIZE := 9
const OVERHEAD_SIZE := HEADER_SIZE + FOOTER_SIZE
## Longest textual IPv6 address, including an IPv4-mapped tail and a zone id.
const MAX_IP_LENGTH := 64
## Beacons arrive at 1 Hz. Ten missed in a row is a robot that went away, not a
## dropped datagram.
const HOST_TIMEOUT_SEC := 10.0
## One beacon is 30-odd bytes and arrives once a second per robot. Anything past
## this in a single poll is a flood, not discovery.
const MAX_PACKETS_PER_POLL := 64

var _udp: PacketPeerUDP = null
var _scanning := false
## ip -> { "port": int, "timestamp_ms": int, "last_seen": float }
var _known_hosts: Dictionary = {}


## Decodes one beacon. Returns an empty dictionary for anything that is not a
## well-formed beacon, so an unrelated broadcaster sharing the port cannot
## inject a peer. Static and socket-free so the format can be tested directly.
static func parse_beacon(packet: PackedByteArray) -> Dictionary:
	if packet.size() < OVERHEAD_SIZE + 1:
		return {}
	if packet[0] != MAGIC_0 or packet[1] != MAGIC_1:
		return {}
	var ip_length := packet.decode_s32(2)
	if ip_length <= 0 or ip_length > MAX_IP_LENGTH:
		return {}
	# Exact, not "at least": a length field that disagrees with the datagram is a
	# different protocol that happens to start with the same two bytes.
	if packet.size() != OVERHEAD_SIZE + ip_length:
		return {}
	if packet[packet.size() - 1] != TRAILER:
		return {}
	var ip := packet.slice(HEADER_SIZE, HEADER_SIZE + ip_length).get_string_from_ascii()
	if not ip.is_valid_ip_address():
		return {}
	var timestamp_ms := packet.decode_s64(HEADER_SIZE + ip_length)
	if timestamp_ms < 0:
		return {}
	return {"ip": ip, "timestamp_ms": timestamp_ms}


## Builds a beacon. Only the tests and the on-robot checker need this, but it
## lives beside the parser so the two cannot drift apart.
static func build_beacon(ip: String, timestamp_ms: int) -> PackedByteArray:
	var ip_bytes := ip.to_ascii_buffer()
	var packet := PackedByteArray()
	packet.resize(OVERHEAD_SIZE + ip_bytes.size())
	packet[0] = MAGIC_0
	packet[1] = MAGIC_1
	packet.encode_s32(2, ip_bytes.size())
	for index in range(ip_bytes.size()):
		packet[HEADER_SIZE + index] = ip_bytes[index]
	packet.encode_s64(HEADER_SIZE + ip_bytes.size(), timestamp_ms)
	packet[packet.size() - 1] = TRAILER
	return packet


func start_scan() -> void:
	if _scanning:
		return
	_udp = PacketPeerUDP.new()
	var error := _udp.bind(DISCOVERY_PORT)
	if error != OK:
		push_warning(
			"[XrtDiscovery] Cannot bind UDP %d: error %d" % [DISCOVERY_PORT, error]
		)
		_udp = null
		return
	_udp.set_broadcast_enabled(true)
	_scanning = true
	print("[XrtDiscovery] Listening for XRoboToolkit beacons on %d" % DISCOVERY_PORT)


func stop_scan() -> void:
	if not _scanning:
		return
	if _udp != null:
		_udp.close()
		_udp = null
	_scanning = false
	_known_hosts.clear()


func is_scanning() -> bool:
	return _scanning


func get_known_hosts() -> Dictionary:
	return _known_hosts.duplicate(true)


func _process(_delta: float) -> void:
	if not _scanning or _udp == null:
		return
	var budget := MAX_PACKETS_PER_POLL
	while _udp.get_available_packet_count() > 0 and budget > 0:
		budget -= 1
		var packet := _udp.get_packet()
		var sender_ip := _udp.get_packet_ip()
		var beacon := parse_beacon(packet)
		if beacon.is_empty():
			continue
		# The robot advertises the address it wants to be reached on, which on a
		# multi-homed host is not necessarily the interface the datagram left
		# from. Trust the payload, and fall back to the sender only if the
		# payload is unusable.
		var ip := str(beacon.get("ip", ""))
		if ip.is_empty() or ip == "0.0.0.0":
			ip = sender_ip
		if ip.is_empty():
			continue
		_record_host(ip, int(beacon.get("timestamp_ms", 0)))
	_expire_hosts()


func _record_host(ip: String, timestamp_ms: int) -> void:
	var is_new := not _known_hosts.has(ip)
	_known_hosts[ip] = {
		"port": SERVICE_PORT,
		"timestamp_ms": timestamp_ms,
		"last_seen": _now_sec(),
	}
	if is_new:
		print("[XrtDiscovery] XRoboToolkit host found: %s:%d" % [ip, SERVICE_PORT])
		host_found.emit(ip, SERVICE_PORT, timestamp_ms)


func _expire_hosts() -> void:
	var now := _now_sec()
	var expired: Array[String] = []
	for ip in _known_hosts:
		var info: Dictionary = _known_hosts[ip]
		if now - float(info.get("last_seen", 0.0)) > HOST_TIMEOUT_SEC:
			expired.append(str(ip))
	for ip in expired:
		_known_hosts.erase(ip)
		print("[XrtDiscovery] XRoboToolkit host lost: %s" % ip)
		host_lost.emit(ip)


func _now_sec() -> float:
	return float(Time.get_ticks_msec()) / 1000.0


func _exit_tree() -> void:
	stop_scan()
