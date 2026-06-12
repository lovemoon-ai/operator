class_name OperatorTestAssertions
extends RefCounted
## v2 test harness (WP7): assertion context handed to each test script.
## Collects structured OperatorTestFailure entries instead of aborting,
## so a case reports every violation.

var _failures: Array = []
var _logs: Array = []


func failures() -> Array:
	return _failures


func logs() -> Array:
	return _logs


func passed() -> bool:
	return _failures.is_empty()


func log_line(message: String) -> void:
	_logs.append(message)


func fail(code: String, message: String, details: Dictionary = {}) -> void:
	_failures.append(OperatorTestFailure.create(code, message, details))


func is_true(condition: bool, message: String, details: Dictionary = {}) -> bool:
	if not condition:
		fail("assert_true", message, details)
	return condition


func is_false(condition: bool, message: String, details: Dictionary = {}) -> bool:
	return is_true(not condition, message, details)


func eq(actual: Variant, expected: Variant, message: String) -> bool:
	if not _variant_eq(actual, expected):
		fail("assert_eq", message, {"expected": expected, "actual": actual})
		return false
	return true


func ne(actual: Variant, unexpected: Variant, message: String) -> bool:
	if _variant_eq(actual, unexpected):
		fail("assert_ne", message, {"unexpected": unexpected})
		return false
	return true


func contains(collection: Variant, value: Variant, message: String) -> bool:
	var found := false
	if typeof(collection) == TYPE_ARRAY:
		found = (collection as Array).has(value)
	elif typeof(collection) == TYPE_DICTIONARY:
		found = (collection as Dictionary).has(value)
	elif typeof(collection) == TYPE_STRING:
		found = str(collection).contains(str(value))
	if not found:
		fail("assert_contains", message, {"value": value})
	return found


func almost_eq(actual: float, expected: float, tolerance: float, message: String) -> bool:
	if absf(actual - expected) > tolerance:
		fail("assert_almost_eq", message, {
			"expected": expected, "actual": actual, "tolerance": tolerance})
		return false
	return true


func merge_failures(extra_failures: Array) -> void:
	for failure in extra_failures:
		if failure is OperatorTestFailure:
			_failures.append(failure)
		else:
			fail("invariant", str(failure))


static func _variant_eq(a: Variant, b: Variant) -> bool:
	# Numeric ints/floats compare loosely so JSON-loaded numbers (always
	# floats) match GDScript ints.
	if (typeof(a) == TYPE_INT or typeof(a) == TYPE_FLOAT) \
			and (typeof(b) == TYPE_INT or typeof(b) == TYPE_FLOAT):
		return is_equal_approx(float(a), float(b))
	return a == b
