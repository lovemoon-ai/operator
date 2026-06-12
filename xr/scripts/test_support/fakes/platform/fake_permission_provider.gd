class_name FakePermissionProvider
extends RefCounted
## v2 test harness (WP7): scripted permission provider. The check Callable
## plugs into CaptureSessionController's permission_check dep.

var _granted := true
var check_count := 0


func grant() -> void:
	_granted = true


func deny() -> void:
	_granted = false


func is_granted() -> bool:
	return _granted


## Matches the controller's permission_check Callable contract.
func check() -> bool:
	check_count += 1
	return _granted


func as_callable() -> Callable:
	return Callable(self, "check")
