class_name RobotClockSync
extends Node
## NTP-style clock synchronisation between the XR headset and the
## robot, piggy-backed on the existing command TCP channel.
##
## The XR side sends a `ClockPing` frame periodically; the robot
## responds immediately with a `ClockPong` containing
##   { t_xr_send, t_robot_recv, t_robot_send }
## We compute
##   offset_ns = ((t_robot_recv - t_xr_send) + (t_robot_send - t_xr_recv)) / 2
##   rtt_ns   = (t_xr_recv - t_xr_send) - (t_robot_send - t_robot_recv)
## offset is "robot wall-clock minus XR wall-clock", so to convert a
## robot-stamped timestamp to the XR clock we subtract `offset_ns`:
##   t_xr_equiv = t_robot - offset_ns
## VideoLatencyTracker uses this to make `tx=` an honest number
## (`receive_ns - (send_ns - offset_ns)`).
##
## The offset is exponentially smoothed (alpha=0.3). When RTT spikes
## (e.g. one TCP retransmit) we down-weight that sample by feeding the
## average of the last few RTTs instead of the raw single sample. After
## ~5 successful round-trips the offset is stable to within a few ms.

const PING_INTERVAL_SEC: float = 1.0
const EWMA_ALPHA: float = 0.3
const RTT_WINDOW: int = 5

## Globally readable offset; VideoLatencyTracker references this.
## Zero means "we don't have a measurement yet, treat tx as
## un-correctable" — matches the previous `tx=--` behaviour.
static var offset_ns: int = 0
static var rtt_ns: int = 0
static var samples: int = 0
static var last_ping_ns: int = 0

## Reference to the command tcp_handler so we can send pings.
var tcp_handler: Node = null
var _timer: Timer
var _recent_rtts: Array[int] = []


func _ready() -> void:
	_timer = Timer.new()
	_timer.wait_time = PING_INTERVAL_SEC
	_timer.one_shot = false
	_timer.autostart = false
	_timer.timeout.connect(_send_ping)
	add_child(_timer)


## Begin pinging once the command channel is connected.
func start() -> void:
	if _timer == null:
		return
	if not _timer.is_stopped():
		return
	_timer.start()
	# Don't fire the first ClockPing immediately — back-to-back sends
	# right after STATUS_CONNECTED were racing Godot's StreamPeerTCP
	# state on swan and dropping the command socket. The Timer fires
	# its first event PING_INTERVAL_SEC after start(); we let that be
	# the first ping. Initial offset just shows up one second late.


## Stop pinging when the command channel disconnects.
func stop() -> void:
	if _timer:
		_timer.stop()


## Called by the parent teleop controller for every command frame received.
## Returns true when we consumed a ClockPong (so caller can short-circuit
## any further dispatch).
func handle_command(command: String, data: PackedByteArray) -> bool:
	if command != "ClockPong":
		return false
	var t_xr_recv := RobotClockSync.now_ns()
	var payload := data.get_string_from_utf8()
	var t_xr_send := _parse_field(payload, "t_xr_send")
	var t_robot_recv := _parse_field(payload, "t_robot_recv")
	var t_robot_send := _parse_field(payload, "t_robot_send")
	if t_xr_send <= 0 or t_robot_recv <= 0 or t_robot_send <= 0:
		print("[ClockSync] Bad ClockPong payload: %s" % payload)
		return true

	var rtt: int = (t_xr_recv - t_xr_send) - (t_robot_send - t_robot_recv)
	if rtt < 0:
		# Clock jumped or the robot's frame got delayed in our outbound
		# queue; drop.
		return true

	# Reject samples whose RTT is way above our recent window — they
	# bias the offset toward a phantom value. Skip until we have a few
	# samples to compare against.
	_recent_rtts.append(rtt)
	if _recent_rtts.size() > RTT_WINDOW:
		_recent_rtts.pop_front()
	var median_rtt := _median(_recent_rtts)
	if _recent_rtts.size() >= 3 and rtt > median_rtt * 3:
		return true

	var sample_offset: int = ((t_robot_recv - t_xr_send) + (t_robot_send - t_xr_recv)) / 2
	if RobotClockSync.samples == 0:
		RobotClockSync.offset_ns = sample_offset
	else:
		RobotClockSync.offset_ns = int(
			float(RobotClockSync.offset_ns) * (1.0 - EWMA_ALPHA)
			+ float(sample_offset) * EWMA_ALPHA
		)
	RobotClockSync.rtt_ns = rtt
	RobotClockSync.samples += 1

	# Log first sample and then every 30 to keep the log sparse.
	if RobotClockSync.samples == 1 or RobotClockSync.samples % 30 == 0:
		print("[ClockSync] sample #%d offset=%.2f ms rtt=%.2f ms" % [
			RobotClockSync.samples,
			float(RobotClockSync.offset_ns) / 1_000_000.0,
			float(rtt) / 1_000_000.0,
		])
	return true


func _send_ping() -> void:
	if tcp_handler == null:
		return
	if not tcp_handler.has_method("send_command"):
		return
	if not tcp_handler.is_connected_to_robot():
		return
	var t_xr_send := RobotClockSync.now_ns()
	RobotClockSync.last_ping_ns = t_xr_send
	var payload := "{\"t_xr_send\":%d}" % t_xr_send
	# Untyped tcp_handler => `:=` can't infer Error; cast through int.
	var _err: int = int(tcp_handler.send_command("ClockPing", payload.to_utf8_buffer()))


## XR-side wall-clock nanoseconds. Independent of VideoLatencyTracker
## so the two can't accidentally pick different epochs.
static func now_ns() -> int:
	# Use the same calibrated unix-epoch offset that VideoLatencyTracker
	# uses, so latency math stays consistent.
	return VideoLatencyTracker.now_ns()


static func _parse_field(json: String, key: String) -> int:
	# Hand-rolled mini-parser — payload is fixed shape {"a":N,"b":N,...}.
	var needle := "\"%s\":" % key
	var start := json.find(needle)
	if start < 0:
		return 0
	var num_start := start + needle.length()
	var num_end := num_start
	while num_end < json.length():
		var ch := json[num_end]
		if ch.is_valid_int() or ch == "-":
			num_end += 1
		else:
			break
	if num_end == num_start:
		return 0
	return int(json.substr(num_start, num_end - num_start))


static func _median(values: Array[int]) -> int:
	if values.is_empty():
		return 0
	var sorted := values.duplicate()
	sorted.sort()
	return sorted[sorted.size() / 2]
