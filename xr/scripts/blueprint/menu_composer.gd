extends RefCounted
## Ownership is attached by the caller, never taken from robot properties.
static func compose(system_rows: Array[Dictionary], robot_rows: Array[Dictionary]) -> Dictionary:
	var groups := {"system": [], "robot": []}
	for owner in groups:
		var rows: Array[Dictionary] = system_rows if owner == "system" else robot_rows
		for row in rows:
			if not bool(row.get("visible", false)):
				continue
			var item := row.duplicate(true)
			item["owner"] = owner
			groups[owner].append(item)
	return groups
