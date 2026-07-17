class_name Timebase
extends RefCounted
## v2 core/time (WP4): timestamp-domain conversion helper.
##
## All capture timestamps live in the Godot-ticks-ns domain, which is
## CLOCK_MONOTONIC ns offset to process start. The Android capture plugins
## embed the anchors in MP4 `operator_static`; this class mirrors those offsets
## on the GDScript side so core/ code can convert without touching vendor
## singletons (platform adapters from WP2 feed the offsets in).
##
## Keys emitted by to_android_timebase_dict() exactly match the embedded
## `android_timebase` record written by QuestCapturePlugin/PicoCapturePlugin.

const PTS_DOMAIN := "godot_ticks_ns"
const PTS_CLOCK := "clock_monotonic_ns"

var session_start_unix_us := 0
var session_start_godot_ticks_us := 0
var configure_godot_ticks_us := 0
var configure_clock_monotonic_ns := 0
var configure_elapsed_realtime_ns := 0
var configure_unix_time_ms := 0
## CLOCK_MONOTONIC ns -> Godot ticks ns. Also the OpenXR XrTime offset
## (XrTime is CLOCK_MONOTONIC ns since boot on the supported runtimes).
var clock_monotonic_to_godot_ticks_ns_offset := 0
var clock_boottime_to_godot_ticks_ns_offset := 0
var openxr_xr_time_to_godot_ticks_ns_offset := 0
## Per-eye camera sensor timestamp source info, e.g.
## {"left": "...", "left_code": N, "right": "...", "right_code": N}.
var rgb_sensor_timestamp_sources: Dictionary = {}


## Current time in the Godot-ticks-ns domain. Overridable (WP7 TestClock
## subclasses this to provide a deterministic manual-advance clock).
func now_ticks_ns() -> int:
	return Time.get_ticks_usec() * 1000


## OpenXR XrTime ns -> Godot ticks ns.
func xr_to_ticks_ns(xr_time_ns: int) -> int:
	return xr_time_ns + openxr_xr_time_to_godot_ticks_ns_offset


## CLOCK_MONOTONIC ns -> Godot ticks ns.
func monotonic_to_ticks_ns(monotonic_ns: int) -> int:
	return monotonic_ns + clock_monotonic_to_godot_ticks_ns_offset


func set_xr_time_offset_ns(offset_ns: int) -> void:
	openxr_xr_time_to_godot_ticks_ns_offset = offset_ns
	if clock_monotonic_to_godot_ticks_ns_offset == 0:
		clock_monotonic_to_godot_ticks_ns_offset = offset_ns


## Produces exactly the key set of the embedded `android_timebase` record.
func to_android_timebase_dict() -> Dictionary:
	return {
		"session_start_unix_us": session_start_unix_us,
		"session_start_godot_ticks_us": session_start_godot_ticks_us,
		"configure_godot_ticks_us": configure_godot_ticks_us,
		"configure_clock_monotonic_ns": configure_clock_monotonic_ns,
		"configure_elapsed_realtime_ns": configure_elapsed_realtime_ns,
		"configure_unix_time_ms": configure_unix_time_ms,
		"rgb_timestamp_domain": PTS_DOMAIN,
		"godot_ticks_clock": PTS_CLOCK,
		"clock_monotonic_to_godot_ticks_ns_offset": clock_monotonic_to_godot_ticks_ns_offset,
		"clock_boottime_to_godot_ticks_ns_offset": clock_boottime_to_godot_ticks_ns_offset,
		"openxr_xr_time_domain": PTS_CLOCK,
		"openxr_xr_time_to_godot_ticks_ns_offset": openxr_xr_time_to_godot_ticks_ns_offset,
		"rgb_sensor_timestamp_sources": rgb_sensor_timestamp_sources.duplicate(true),
	}
