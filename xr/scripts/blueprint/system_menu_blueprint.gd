extends RefCounted
## Local system Blueprint: its lifetime does not depend on a robot session.
## The two actions are dispatched only by the local owner of this runtime.
const ID := "system.teleop.menu"


static func definition() -> Dictionary:
	var components: Array = [{
		"id": "connection", "type": "menu_item", "user_overridable": false,
		"properties": {
			"title": "",
			"action": "connection.toggle",
			"locked_text": str(TranslationServer.translate("UI_CONNECT_ROBOT")),
			"unlocked_text": str(TranslationServer.translate("UI_DISCONNECT")),
			"unavailable_text": str(TranslationServer.translate("UI_SELECT_ROBOT_FIRST")),
		},
		"bindings": {
			"value": "local.connection_active", "available": "local.connection_available",
		},
	}, {
		"id": "recenter", "type": "menu_item", "user_overridable": false,
		"properties": {"title": "", "action": "view.recenter",
			"locked_text": str(TranslationServer.translate("UI_RECENTER_ROBOT")),
			"unlocked_text": str(TranslationServer.translate("UI_RECENTER_ROBOT")),
			"unavailable_text": str(TranslationServer.translate("UI_RECENTER_ROBOT"))},
		"bindings": {"value": "local.recenter_value", "available": "local.can_recenter"},
	}]
	for hand in ["left", "right"]:
		components.append({
			"id": hand + "_lamp", "type": "status_lamp", "anchor": hand + "_controller",
			"user_overridable": false,
			"transform": {"position": [0.0, 0.05, 0.0]},
			"properties": {
				"text": "", "radius": 0.008,
				"colors": {"disconnected": "#666666", "busy": "#269cff", "needs_reset": "#ffaa22", "ready": "#20d477"},
				"pulse_states": ["busy"], "pulse_hz": 2,
			},
			"bindings": {"state": "local.state", "visible": "local." + hand + "_tracked"},
		})
	return {"schema": BlueprintContract.BLUEPRINT_SCHEMA, "blueprint_id": ID, "revision": 1, "components": components}
