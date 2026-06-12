extends RefCounted
class_name CaptureProviderRegistry
## WP2: compat shim. Provider selection (vendor singleton probing + device
## scoring) lives in PlatformRegistry under xr/scripts/platform/; this file
## keeps the legacy API surface for existing callers.


static func bind() -> Object:
	return PlatformRegistry.shared().bind_camera_provider()


static func provider_name(plugin: Object) -> String:
	if plugin == null:
		return ""
	var raw: Variant = _call_or_null(plugin, "getCaptureProviderName")
	if raw != null and not str(raw).is_empty():
		return str(raw)
	var text := str(plugin)
	if text.contains("PicoCapturePlugin"):
		return "pico"
	return "quest"


static func supports_depth(plugin: Object) -> bool:
	if plugin == null:
		return false
	var raw: Variant = _call_or_null(plugin, "isDepthCaptureSupported")
	if raw != null:
		return bool(raw)
	return provider_name(plugin) == "quest"


static func supports_body_motion(plugin: Object) -> bool:
	if plugin == null:
		return false
	var raw: Variant = _call_or_null(plugin, "isBodyMotionCaptureSupported")
	if raw != null:
		return bool(raw)
	return provider_name(plugin) == "pico"


# External motion trackers (waist / feet pucks) are PICO-only — the OpenXR
# extension that drives them is XR_PICO_motion_tracking, with no counterpart
# on Quest. We deliberately key off provider_name rather than a per-provider
# capability call: even if a future provider adds tracker support, the panel
# wiring (PICO connect button, request flow, battery status) is hard-tied to
# the Pico bridge, so flipping this on for another provider would surface a
# broken UI. Quest, GlassXR, etc. just hide the toggle entirely.
static func supports_motion_trackers(plugin: Object) -> bool:
	if plugin == null:
		return false
	return provider_name(plugin) == "pico"


# WP6 sweep: vendor-name comparisons moved out of app scripts. This shim is
# the sanctioned home for provider-name semantics (alongside platform/);
# capture_app.gd asks these questions instead of comparing "pico" inline.

## True when the provider sources camera frames through the PICO OpenXR
## bridge (XR_PICO_camera_image): the GDScript pump, the bridge-tied
## configure/stop RPC variants, motion-tracker setup, and the QR scanner's
## exclusive-stream handoff all key off this.
static func provider_uses_pico_bridge(provider: String) -> bool:
	return provider == "pico"


## PICO capture disables the MP4 audio track today (see
## EgoCaptureComposition.effective_capture_options) — also used to skip the
## RECORD_AUDIO permission prompt the session would not use.
static func provider_supports_audio_capture(provider: String) -> bool:
	return provider != "pico"


static func _call_or_null(plugin: Object, method: String) -> Variant:
	if plugin == null:
		return null
	if plugin.has_method(method):
		return plugin.call(method)
	# Android plugin singletons sometimes do not reflect @UsedByGodot methods
	# through has_method(). Only direct-call known provider methods that every
	# current provider implements, otherwise fall back silently.
	if method in ["getCaptureProviderName", "getCaptureProviderDeviceScore", "isDepthCaptureSupported", "isBodyMotionCaptureSupported"]:
		return plugin.call(method)
	return null
