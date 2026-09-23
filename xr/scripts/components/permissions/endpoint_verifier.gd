class_name EndpointVerifier
extends Node
## Permission layer (components/permissions): verifies an upload endpoint the
## user scanned. A signed ack QR (`/ack?...exp=...&sig=...`) is fetched and its
## returned upload URL/token are trusted as verified; a plain http(s) URL is
## accepted but stays unverified until the user confirms it. Verified results
## are recorded in the EndpointRegistry so hosts can reference them by name.

signal checking()
signal resolved(upload_url: String, upload_token: String, verified: bool)
signal failed(message: String)

const ACK_TIMEOUT_SECONDS := 8.0

var registry: EndpointRegistry
var _request: HTTPRequest


func _ready() -> void:
	if registry == null:
		registry = EndpointRegistry.shared()
	_request = HTTPRequest.new()
	_request.name = "UploadAckRequest"
	_request.timeout = ACK_TIMEOUT_SECONDS
	_request.request_completed.connect(_on_request_completed)
	add_child(_request)


func verify(payload: String) -> void:
	var trimmed := payload.strip_edges()
	if trimmed.is_empty():
		return
	# A QR carrying a plain ingest URL (no signed-ack challenge) is common for
	# self-hosted setups. Apply it directly, unverified; the signed ack stays
	# the secure default for servers that hand out per-session credentials.
	if not is_signed_ack_payload(trimmed):
		if looks_like_http_url(trimmed):
			print("[UploadAck] applying plain URL from QR %s" % trimmed)
			resolved.emit(trimmed, "", false)
			return
		failed.emit(tr("UI_UPLOAD_ACK_INVALID_QR"))
		return
	checking.emit()
	print("[UploadAck] checking ack %s" % trimmed)
	if _request == null:
		failed.emit(tr("UI_UPLOAD_ACK_UNAVAILABLE"))
		return
	if _request.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED:
		_request.cancel_request()
	var err := _request.request(trimmed, PackedStringArray(["User-Agent: ego-uploader/1.0 (godot)"]), HTTPClient.METHOD_GET)
	if err != OK:
		failed.emit(tr("UI_UPLOAD_ACK_REQUEST_FAILED") % err)


static func is_signed_ack_payload(payload: String) -> bool:
	return payload.find("/ack") >= 0 and payload.find("exp=") >= 0 and payload.find("sig=") >= 0


## http/https only, with a host after the scheme.
static func looks_like_http_url(payload: String) -> bool:
	var lower := payload.to_lower()
	if not (lower.begins_with("http://") or lower.begins_with("https://")):
		return false
	var after_scheme := payload.substr(payload.find("://") + 3).strip_edges()
	return not after_scheme.is_empty()


func _on_request_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS:
		failed.emit(tr("UI_UPLOAD_ACK_NETWORK_FAILED") % result)
		return
	var text := body.get_string_from_utf8()
	if response_code < 200 or response_code >= 300:
		failed.emit(tr("UI_UPLOAD_ACK_HTTP_FAILED") % [response_code, text.substr(0, 80)])
		return
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		failed.emit(tr("UI_UPLOAD_ACK_BAD_RESPONSE"))
		return
	var response := parsed as Dictionary
	if not bool(response.get("ok", false)):
		failed.emit(str(response.get("error", tr("UI_UPLOAD_ACK_BAD_RESPONSE"))))
		return
	var upload_url := str(response.get("uploadUrl", response.get("upload_url", ""))).strip_edges()
	if upload_url.is_empty():
		failed.emit(tr("UI_UPLOAD_ACK_BAD_RESPONSE"))
		return
	var upload_token := str(response.get("uploadToken", response.get("upload_token", "")))
	var endpoint_name := str(response.get("endpointName", response.get("endpoint_name", "")))
	registry.register_upload(upload_url, upload_token, true, endpoint_name)
	print("[UploadAck] ready upload_url=%s auth=%s" % [upload_url, "yes" if not upload_token.is_empty() else "no"])
	resolved.emit(upload_url, upload_token, true)
