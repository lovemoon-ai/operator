class_name OperatorTestFailure
extends RefCounted
## v2 test harness (WP7): structured test failure. Failures are data, not
## just log strings, so reporters/CI can aggregate them.

var code := ""
var message := ""
var details: Dictionary = {}


static func create(p_code: String, p_message: String, p_details: Dictionary = {}) -> OperatorTestFailure:
	var failure := OperatorTestFailure.new()
	failure.code = p_code
	failure.message = p_message
	failure.details = p_details
	return failure


func to_dict() -> Dictionary:
	return {
		"code": code,
		"message": message,
		"details": details,
	}
