class_name PermissionTable
extends RefCounted
## Permission layer (components/permissions): which host may use which headset
## capability category. One data table instead of checks scattered through
## modes (claw/architecture/overview.md, "Principles"). System permissions
## (Android CAMERA / RECORD_AUDIO) are not here: source components handle them.
##
## Grants are remembered per (host address, capture declaration hash) for the
## process lifetime or until the user revokes them. The descriptor is resent
## after every Hello, so a reconnect with the same declaration never asks
## again; a changed declaration or address asks again. Remembering by host
## identity later only means changing the key.

const DECISION_ALLOW := "allow"
const DECISION_DENY := "deny"
const DECISION_ASK := "ask"
const DECISION_REVOKED := "revoked"

const CATEGORY_XR_STATE := "xr_state"
const CATEGORY_TRACKING := "tracking"
const CATEGORY_CAMERA := "camera"
const CATEGORY_AUDIO := "audio"

## Policy per capability category.
##   on_connect     — allowed by connecting (today's Teleop pose/controller/hand stream)
##   tracking_lease — body / external trackers: the tracking lease plus the
##                    system-settings calibration confirmation decide
##   confirm_once   — the user confirms the host's whole declaration once;
##                    revocable at any time
const POLICIES := {
	CATEGORY_XR_STATE: "on_connect",
	CATEGORY_TRACKING: "tracking_lease",
	CATEGORY_CAMERA: "confirm_once",
	CATEGORY_AUDIO: "confirm_once",
}

## "<host>|<hash>" -> {category: DECISION_ALLOW | DECISION_DENY | DECISION_REVOKED}
static var _grants: Dictionary = {}


static func policy(category: String) -> String:
	return str(POLICIES.get(category, "confirm_once"))


static func key(host: String, declaration_hash: String) -> String:
	return "%s|%s" % [host.strip_edges(), declaration_hash]


## Current decision for every requested category.
static func decisions(host: String, declaration_hash: String, categories: Array) -> Dictionary:
	var remembered: Dictionary = _grants.get(key(host, declaration_hash), {})
	var out: Dictionary = {}
	for category_v in categories:
		var category := str(category_v)
		match policy(category):
			"on_connect", "tracking_lease":
				out[category] = DECISION_ALLOW
			_:
				out[category] = str(remembered.get(category, DECISION_ASK))
	return out


## Records the user's answer for the confirm-once categories of a declaration.
static func remember(host: String, declaration_hash: String, categories: Array, allowed: bool) -> void:
	var grant_key := key(host, declaration_hash)
	var remembered: Dictionary = _grants.get(grant_key, {})
	for category_v in categories:
		var category := str(category_v)
		if policy(category) == "confirm_once":
			remembered[category] = DECISION_ALLOW if allowed else DECISION_DENY
	_grants[grant_key] = remembered


## Withdraws every confirm-once grant of a declaration. The host sees
## `denied: revoked` until it declares again (a new declaration asks again).
static func revoke(host: String, declaration_hash: String) -> void:
	var grant_key := key(host, declaration_hash)
	var remembered: Dictionary = _grants.get(grant_key, {})
	for category_v in POLICIES.keys():
		var category := str(category_v)
		if policy(category) == "confirm_once" and str(remembered.get(category, "")) == DECISION_ALLOW:
			remembered[category] = DECISION_REVOKED
	_grants[grant_key] = remembered


static func forget_all() -> void:
	_grants.clear()
