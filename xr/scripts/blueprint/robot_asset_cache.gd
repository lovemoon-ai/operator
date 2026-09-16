extends Node
## Static asset transfer from the selected robot only, separate from pose TCP.
signal loaded(bytes: PackedByteArray, from_cache: bool)
signal failed(message: String)

const CACHE_DIR := "user://blueprint_robot_assets"
const MAX_ASSET_BYTES := 64 * 1024 * 1024
const MAX_CACHE_BYTES := 256 * 1024 * 1024
var _request: HTTPRequest
var _sha := ""
var _size := 0


static func valid_hash(value: String) -> bool:
	if value.length() != 64:
		return false
	for character in value:
		if character not in "0123456789abcdef":
			return false
	return true


static func digest(bytes: PackedByteArray) -> String:
	var hashing := HashingContext.new()
	hashing.start(HashingContext.HASH_SHA256)
	hashing.update(bytes)
	return hashing.finish().hex_encode()


static func cache_path(sha: String) -> String:
	return CACHE_DIR.path_join(sha + ".glb") if valid_hash(sha) else ""


func fetch(host: String, port: int, sha: String, size: int) -> void:
	if not valid_hash(sha) or size < 20 or size > MAX_ASSET_BYTES or port < 1 or port > 65535:
		failed.emit("Invalid robot asset hash, size, or port")
		return
	var pattern := RegEx.new()
	pattern.compile("^[A-Za-z0-9._:-]+$")
	if host.is_empty() or pattern.search(host) == null:
		failed.emit("Robot asset requires a connected robot host")
		return
	_sha = sha
	_size = size
	var path := cache_path(sha)
	var cached := FileAccess.open(path, FileAccess.READ)
	if cached != null:
		var bytes := cached.get_buffer(size) if cached.get_length() == size else PackedByteArray()
		cached.close()
		if bytes.size() == size and digest(bytes) == sha:
			loaded.emit(bytes, true)
			return
		DirAccess.remove_absolute(path) # Only this validated content-hash entry.
	_request = HTTPRequest.new()
	_request.use_threads = true
	_request.timeout = 30.0
	_request.body_size_limit = size
	_request.accept_gzip = false
	_request.max_redirects = 0
	add_child(_request)
	_request.request_completed.connect(_on_completed)
	var address := "[%s]" % host if host.contains(":") else host
	var error := _request.request("http://%s:%d/blueprint-assets/%s.glb" % [address, port, sha])
	if error != OK:
		failed.emit("Robot asset request could not start: %s" % error_string(error))


func _on_completed(result: int, code: int, _headers: PackedStringArray, bytes: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		failed.emit("Robot asset download failed (result=%d HTTP=%d)" % [result, code])
		return
	if bytes.size() != _size or digest(bytes) != _sha:
		failed.emit("Robot asset size/SHA-256 verification failed")
		return
	_store(bytes)
	loaded.emit(bytes, false)


func _store(bytes: PackedByteArray) -> void:
	if DirAccess.make_dir_recursive_absolute(CACHE_DIR) != OK:
		return # Rendering can still proceed without a writable cache.
	var entries: Array[Dictionary] = []
	var total := 0
	for file in DirAccess.get_files_at(CACHE_DIR):
		if not file.ends_with(".glb") or not valid_hash(file.trim_suffix(".glb")):
			continue
		var path := CACHE_DIR.path_join(file)
		var handle := FileAccess.open(path, FileAccess.READ)
		if handle == null:
			continue
		var size := handle.get_length()
		handle.close()
		total += size
		entries.append({"path": path, "size": size, "time": FileAccess.get_modified_time(path)})
	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a["time"]) < int(b["time"]))
	for entry in entries:
		if total + bytes.size() <= MAX_CACHE_BYTES:
			break
		if DirAccess.remove_absolute(str(entry["path"])) == OK:
			total -= int(entry["size"])
	if total + bytes.size() > MAX_CACHE_BYTES:
		return
	var target := cache_path(_sha)
	var temporary := target + ".%d.part" % get_instance_id()
	var handle := FileAccess.open(temporary, FileAccess.WRITE)
	if handle == null:
		return
	handle.store_buffer(bytes)
	var ok := handle.get_error() == OK
	handle.close()
	if not ok or DirAccess.rename_absolute(temporary, target) != OK:
		DirAccess.remove_absolute(temporary)


func _exit_tree() -> void:
	if is_instance_valid(_request):
		_request.cancel_request()
