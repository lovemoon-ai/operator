extends Node

var bridge: Object


func _enter_tree() -> void:
	_ensure_bridge()


func get_bridge() -> Object:
	return _ensure_bridge()


func _ensure_bridge() -> Object:
	if bridge != null:
		return bridge
	# WP2: vendor singleton probing delegated to the platform layer.
	var adapter: Object = PlatformRegistry.shared().pico_adapter()
	bridge = adapter.openxr_bridge_native()
	if bridge != null:
		print("PicoOpenXRExtension bridge bound from native singleton")
		return bridge
	bridge = adapter.instantiate_openxr_bridge()
	if bridge != null:
		print("PicoOpenXRExtension bridge instantiated")
	return bridge
