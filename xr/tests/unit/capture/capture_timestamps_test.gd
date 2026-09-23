extends RefCounted
## First timestamp gate (claw/architecture/wire-protocol.md, "Headset
## timebase"). Deterministic, runs on every test APK:
##  - a SensorFrame with a fixed timestamp, fed through the StreamBinding of
##    every capture Output wiring (local / ingest / both), reaches every
##    mounted sink's writer with exactly that timestamp, in order;
##  - sinks that are not mounted for an Output receive nothing;
##  - XrStateSink on the same binding assembles each tick at exactly the
##    frames' timestamp;
##  - the timebase contract (android_timebase key set, PTS domain/clock
##    names) is unchanged.

const CASE_ID := "capture.timestamps"

## Deliberately not a multiple of 1000: any us<->ns rounding would show.
const TIMESTAMPS := [1_000_000_123, 1_011_111_457, 1_022_222_791, 1_033_333_001]
const FROZEN_ANDROID_TIMEBASE_KEYS := [
	"session_start_unix_us",
	"session_start_godot_ticks_us",
	"configure_godot_ticks_us",
	"configure_clock_monotonic_ns",
	"configure_elapsed_realtime_ns",
	"configure_unix_time_ms",
	"rgb_timestamp_domain",
	"godot_ticks_clock",
	"clock_monotonic_to_godot_ticks_ns_offset",
	"clock_boottime_to_godot_ticks_ns_offset",
	"openxr_xr_time_domain",
	"openxr_xr_time_to_godot_ticks_ns_offset",
	"rgb_sensor_timestamp_sources",
]


func run(_ctx: Dictionary, t: OperatorTestAssertions) -> void:
	for output_v in EgoCaptureComposition.OUTPUTS:
		_check_output(str(output_v), t)
	_check_timebase_contract(t)


func _check_output(output: String, t: OperatorTestAssertions) -> void:
	var spool := RecordingWriter.new()
	var push := RecordingWriter.new()
	var uploader := Node.new()
	var io := {
		"spatialmp4_sink": SpatialMp4Sink.new(spool),
		"live_push_sink": LivePushSink.new(push),
		"upload_sink": UploadQueueSink.new(uploader),
	}
	var wiring := EgoCaptureComposition.wire(io, output)
	var binding := wiring.get("frame_sink") as StreamBinding
	var observer := RecordingSink.new()
	binding.add_sink(observer)
	var xr_state := XrStateSink.new()
	binding.add_sink(xr_state)

	var sent: Array = []
	for timestamp_v in TIMESTAMPS:
		for frame in _frames_at(int(timestamp_v)):
			sent.append(frame)
			binding.on_frame(frame)
		binding.end_of_tick()
		var snapshot := xr_state.take_snapshot()
		t.eq(snapshot.get("timestamp_ns"), timestamp_v, "%s: XrStateFrame carries the tick timestamp" % output)
		t.eq(snapshot.get("head", {}).get("sample_timestamp_ns"), timestamp_v,
			"%s: XrStateFrame head sample timestamp unchanged" % output)
		t.eq(snapshot.get("controllers", {}).get("left", {}).get("pose", {}).get("sample_timestamp_ns"),
			timestamp_v, "%s: XrStateFrame controller sample timestamp unchanged" % output)

	# The observer received the very same frame objects, timestamps untouched.
	t.eq(observer.frames.size(), sent.size(), "%s: every frame reaches the binding's sinks" % output)
	for index in mini(observer.frames.size(), sent.size()):
		var received := observer.frames[index] as SensorFrame
		var original := sent[index] as SensorFrame
		t.is_true(received == original, "%s: sinks receive the same SensorFrame object" % output)
		t.eq(received.timestamp_ns, original.timestamp_ns, "%s: timestamp unchanged" % output)

	var expected_writer_timestamps: Array = []
	for frame_v in sent:
		expected_writer_timestamps.append((frame_v as SensorFrame).timestamp_ns)
	var local := EgoCaptureComposition.records_locally(output)
	var ingest := EgoCaptureComposition.streams_to_ingest(output)
	t.eq(bool(wiring.get("local")), local, "%s: wiring reports local recording" % output)
	t.eq(bool(wiring.get("ingest")), ingest, "%s: wiring reports ingest push" % output)
	t.eq(spool.timestamps(), expected_writer_timestamps if local else [],
		"%s: SpatialMP4 writer receives exactly the sampled timestamps" % output)
	t.eq(push.timestamps(), expected_writer_timestamps if ingest else [],
		"%s: live push writer receives exactly the sampled timestamps" % output)
	uploader.free()


## One frame of every type the capture sinks accept, all at `timestamp_ns`.
func _frames_at(timestamp_ns: int) -> Array:
	var head := _frame(SensorFrameType.POSE, timestamp_ns, "head")
	head.payload = {"transform": Transform3D.IDENTITY, "tracking_valid": true}
	var controller := _frame(SensorFrameType.CONTROLLER, timestamp_ns, "left_controller")
	controller.payload = {"transform": Transform3D.IDENTITY, "tracking_valid": true}
	var input := _frame(SensorFrameType.INPUT_EVENT, timestamp_ns, "right_controller")
	input.payload = {"packet_type": 1, "available_mask": 3, "pressed_mask": 1}
	var depth := _frame(SensorFrameType.DEPTH, timestamp_ns, "left")
	depth.payload = {
		"eye": "left",
		"width": 2,
		"height": 1,
		"metadata": {},
		"depth_u16_mm": PackedByteArray([1, 0, 2, 0]),
	}
	return [head, controller, input, depth]


func _frame(frame_type: int, timestamp_ns: int, source_id: String) -> SensorFrame:
	var frame := SensorFrame.new()
	frame.frame_type = frame_type
	frame.timestamp_ns = timestamp_ns
	frame.source_id = source_id
	frame.coordinate_space = "openxr_stage"
	return frame


func _check_timebase_contract(t: OperatorTestAssertions) -> void:
	var keys: Array = Timebase.new().to_android_timebase_dict().keys()
	keys.sort()
	var frozen := FROZEN_ANDROID_TIMEBASE_KEYS.duplicate()
	frozen.sort()
	t.eq(keys, frozen, "android_timebase key set is frozen")
	t.eq(Timebase.PTS_DOMAIN, "godot_ticks_ns", "single sampling timebase is godot_ticks_ns")
	t.eq(Timebase.PTS_CLOCK, "clock_monotonic_ns", "godot ticks clock is CLOCK_MONOTONIC")
	t.eq(SpatialMp4ManifestContract.MEDIA_PTS_DOMAIN, Timebase.PTS_DOMAIN,
		"SpatialMP4 manifest media_pts_domain matches the timebase")
	t.eq(SpatialMp4ManifestContract.MEDIA_PTS_CLOCK, Timebase.PTS_CLOCK,
		"SpatialMP4 manifest media_pts_clock matches the timebase")
