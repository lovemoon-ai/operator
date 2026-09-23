class_name EndpointRegistry
extends RefCounted
## Permission layer (components/permissions): the ingest endpoints the user
## configured and verified on this headset (QR -> ack -> Save), persisted by
## name. Hosts may reference an endpoint only by that name
## (`capture_streams.local_tasks[].endpoint_ref`); they can never supply a URL,
## host or token. Tightening what hosts may orchestrate is a matter of
## shrinking what resolve() returns.

const SETTINGS_PATH := "user://ingest_endpoints.cfg"
const KIND_UPLOAD := "upload"
const KIND_LIVE := "live"

static var _shared: EndpointRegistry = null

## name -> {kind, verified, updated_unix, url, token | host, push_port, result_port, token}
var _endpoints: Dictionary = {}
var _path := SETTINGS_PATH


static func shared() -> EndpointRegistry:
	if _shared == null:
		_shared = EndpointRegistry.new()
		_shared.load_from_disk()
	return _shared


func _init(path: String = SETTINGS_PATH) -> void:
	_path = path


## An endpoint name is a bare identifier: never a URL, path or host:port.
static func is_valid_name(endpoint_name: String) -> bool:
	return not endpoint_name.is_empty() \
			and not endpoint_name.contains("://") \
			and not endpoint_name.contains("/") \
			and not endpoint_name.contains(":")


## Default name for an endpoint: its host, with IPv6 separators replaced.
static func name_for_host(host: String) -> String:
	var trimmed := host.strip_edges().trim_prefix("[").trim_suffix("]")
	return trimmed.replace(":", "-").to_lower()


static func host_of_url(url: String) -> String:
	var rest := url.strip_edges()
	var scheme_end := rest.find("://")
	if scheme_end >= 0:
		rest = rest.substr(scheme_end + 3)
	for separator in ["/", "?", "#"]:
		var index := rest.find(separator)
		if index >= 0:
			rest = rest.substr(0, index)
	var at := rest.rfind("@")
	if at >= 0:
		rest = rest.substr(at + 1)
	if rest.begins_with("["):
		var close := rest.find("]")
		return rest.substr(1, close - 1) if close > 0 else rest
	var colon := rest.rfind(":")
	return rest.substr(0, colon) if colon >= 0 else rest


func load_from_disk() -> void:
	_endpoints = {}
	var config := ConfigFile.new()
	if config.load(_path) != OK:
		return
	for section in config.get_sections():
		var entry: Dictionary = {}
		for key in config.get_section_keys(section):
			entry[key] = config.get_value(section, key)
		if is_valid_name(section):
			_endpoints[section] = entry


func save() -> Error:
	var config := ConfigFile.new()
	for endpoint_name_v in _endpoints.keys():
		var entry: Dictionary = _endpoints[endpoint_name_v]
		for key in entry.keys():
			config.set_value(str(endpoint_name_v), str(key), entry[key])
	return config.save(_path)


## Records an upload (TUS) endpoint. Returns its name.
func register_upload(url: String, token: String, verified: bool, endpoint_name: String = "") -> String:
	var resolved_name := endpoint_name if is_valid_name(endpoint_name) else name_for_host(host_of_url(url))
	if not is_valid_name(resolved_name):
		return ""
	_endpoints[resolved_name] = {
		"kind": KIND_UPLOAD,
		"url": url.strip_edges(),
		"token": token,
		"verified": verified,
		"updated_unix": int(Time.get_unix_time_from_system()),
	}
	save()
	print("[EndpointRegistry] %s endpoint %s (%s)" % [KIND_UPLOAD, resolved_name, "verified" if verified else "unverified"])
	return resolved_name


## Records a live (OLCP) ingest server. Returns its name.
func register_live(host: String, push_port: int, result_port: int, token: String, verified: bool, endpoint_name: String = "") -> String:
	var resolved_name := endpoint_name if is_valid_name(endpoint_name) else name_for_host(host)
	if not is_valid_name(resolved_name):
		return ""
	_endpoints[resolved_name] = {
		"kind": KIND_LIVE,
		"host": host.strip_edges(),
		"push_port": push_port,
		"result_port": result_port,
		"token": token,
		"verified": verified,
		"updated_unix": int(Time.get_unix_time_from_system()),
	}
	save()
	print("[EndpointRegistry] %s endpoint %s (%s)" % [KIND_LIVE, resolved_name, "verified" if verified else "unverified"])
	return resolved_name


## A verified endpoint by name, optionally restricted to one kind; {} when
## unknown, unverified, or of another kind.
func resolve(endpoint_name: String, kind: String = "") -> Dictionary:
	var entry: Dictionary = _endpoints.get(endpoint_name, {})
	if entry.is_empty() or not bool(entry.get("verified", false)):
		return {}
	if not kind.is_empty() and str(entry.get("kind", "")) != kind:
		return {}
	return entry.duplicate(true)


func names(kind: String = "") -> Array:
	var out: Array = []
	for endpoint_name_v in _endpoints.keys():
		if kind.is_empty() or str((_endpoints[endpoint_name_v] as Dictionary).get("kind", "")) == kind:
			out.append(str(endpoint_name_v))
	out.sort()
	return out


func forget(endpoint_name: String) -> void:
	if _endpoints.erase(endpoint_name):
		save()
