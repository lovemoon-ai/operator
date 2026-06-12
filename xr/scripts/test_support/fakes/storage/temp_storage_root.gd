class_name TempStorageRoot
extends RefCounted
## v2 test harness (WP7): per-case temp storage under user://test_tmp/<case>.
## Created lazily, cleaned in teardown (teardown always runs).

const BASE_DIR := "user://test_tmp"

var _case_id := ""
var _created := false


func _init(case_id: String) -> void:
	_case_id = case_id.replace("/", "_").replace(":", "_")


func path() -> String:
	if not _created:
		DirAccess.make_dir_recursive_absolute(absolute_path())
		_created = true
	return "%s/%s" % [BASE_DIR, _case_id]


func absolute_path() -> String:
	return ProjectSettings.globalize_path("%s/%s" % [BASE_DIR, _case_id])


func cleanup() -> void:
	if not _created:
		return
	_remove_recursive(absolute_path())
	_created = false


static func _remove_recursive(absolute: String) -> void:
	var dir := DirAccess.open(absolute)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while not entry.is_empty():
		if entry != "." and entry != "..":
			var child := "%s/%s" % [absolute, entry]
			if dir.current_is_dir():
				_remove_recursive(child)
			else:
				DirAccess.remove_absolute(child)
		entry = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(absolute)
