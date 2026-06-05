extends Node

var bridge: Object


func _enter_tree() -> void:
	_ensure_bridge()


func get_bridge() -> Object:
	return _ensure_bridge()


func _ensure_bridge() -> Object:
	if bridge != null:
		return bridge
	if Engine.has_singleton("PicoOpenXRBridgeNative"):
		bridge = Engine.get_singleton("PicoOpenXRBridgeNative")
		if bridge != null:
			print("PicoOpenXRExtension bridge bound from native singleton")
			return bridge
	if not ClassDB.class_exists("PicoOpenXRExtension"):
		return null
	bridge = ClassDB.instantiate("PicoOpenXRExtension")
	if bridge != null:
		print("PicoOpenXRExtension bridge instantiated")
	return bridge
