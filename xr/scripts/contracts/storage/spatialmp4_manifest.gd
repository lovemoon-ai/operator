class_name SpatialMp4ManifestContract
extends RefCounted
## v2 contracts: schema id + key-name constants for the SpatialMP4 spool
## manifest. WP2 uses this only as a constants source; the writer migrates to
## it in WP5. Values are copied verbatim from session_spool_writer.gd — the
## on-disk manifest must stay byte-compatible.

const SCHEMA := "spatialmp4.quest_capture.spool.v3"

const KEY_SCHEMA := "schema"
const KEY_SESSION_ID := "session_id"
const KEY_CAPTURE_OPTIONS := "capture_options"
const KEY_MEDIA_PTS_DOMAIN := "media_pts_domain"
const KEY_MEDIA_PTS_CLOCK := "media_pts_clock"
const KEY_SOURCES := "sources"
const KEY_ARTIFACTS := "artifacts"
const KEY_BODY_TRACKING := "body_tracking"

const MEDIA_PTS_DOMAIN := "godot_ticks_ns"
const MEDIA_PTS_CLOCK := "clock_monotonic_ns"

## Body runtime detection values surfaced in the manifest.
const BODY_RUNTIME_GODOT := "godot_xr_body_tracker"
const BODY_RUNTIME_PICO_BD := "pico_bd"


## Manifest `sources.rgb` description text, keyed by the capture provider
## (WP6: moved from session_spool_writer.gd so vendor-name comparisons stay
## out of the writer engine). Strings are byte-identical to the historical
## manifest output — offline tooling matches on them.
static func rgb_source_description(capture_provider: String, stereo_rgb: bool) -> String:
	if capture_provider == "pico":
		if stereo_rgb:
			return "PICO OpenXR XR_PICO_camera_image stereo side-by-side raw RGBA + HEVC MediaCodec"
		return "PICO OpenXR XR_PICO_camera_image left camera raw RGBA + HEVC MediaCodec"
	if stereo_rgb:
		return "Android Camera2 stereo side-by-side + HEVC MediaCodec"
	return "Android Camera2 left camera + HEVC MediaCodec"


static func validate(manifest: Dictionary) -> Array[String]:
	var errors: Array[String] = []
	if str(manifest.get(KEY_SCHEMA, "")) != SCHEMA:
		errors.append("manifest schema must be '%s'" % SCHEMA)
	if manifest.has(KEY_MEDIA_PTS_DOMAIN) and str(manifest.get(KEY_MEDIA_PTS_DOMAIN)) != MEDIA_PTS_DOMAIN:
		errors.append("media_pts_domain must be '%s'" % MEDIA_PTS_DOMAIN)
	if manifest.has(KEY_MEDIA_PTS_CLOCK) and str(manifest.get(KEY_MEDIA_PTS_CLOCK)) != MEDIA_PTS_CLOCK:
		errors.append("media_pts_clock must be '%s'" % MEDIA_PTS_CLOCK)
	if not manifest.has(KEY_SESSION_ID) or str(manifest.get(KEY_SESSION_ID, "")).is_empty():
		errors.append("manifest missing session_id")
	return errors
