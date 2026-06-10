extends RefCounted
class_name CaptureProviderRegistry

const PROVIDER_SINGLETONS := ["QuestCapturePlugin", "PicoCapturePlugin"]


static func bind() -> Object:
	var best_plugin: Object
	var best_score := -1000000
	for singleton_name in PROVIDER_SINGLETONS:
		if not Engine.has_singleton(singleton_name):
			continue
		var plugin := Engine.get_singleton(singleton_name)
		if plugin == null:
			continue
		var score := _provider_score(plugin, singleton_name)
		if best_plugin == null or score > best_score:
			best_plugin = plugin
			best_score = score
	return best_plugin


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


static func _provider_score(plugin: Object, singleton_name: String) -> int:
	var raw: Variant = _call_or_null(plugin, "getCaptureProviderDeviceScore")
	if raw != null:
		return int(raw)
	return 10 if singleton_name == "PicoCapturePlugin" else 5


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
