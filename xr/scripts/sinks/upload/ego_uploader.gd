extends Node
class_name EgoUploader

## Background uploader for finalized Ego sessions.
##
## Speaks TUS 1.0.0 (creation extension) so recordings >2 GB stream
## reliably over flaky Wi-Fi: each session artifact is split into
## ~8 MB PATCH chunks, and on any network blip the next attempt
## resumes from the last server-acknowledged Upload-Offset rather
## than retransmitting from byte 0.
##
## Design notes:
##   - One worker Thread drives the HTTPClient state machine. The
##     main thread only touches the queue under a Mutex.
##   - The queue is mirrored to `user://ego_upload_queue.json` on
##     every mutation so a crash / kill / reboot does not lose
##     pending sessions.
##   - The uploader pauses itself while a recording is active. The
##     Pico eMMC + Wi-Fi cannot sustain a 24 Mbps HEVC write AND a
##     TUS PATCH stream simultaneously without dropping recording
##     frames (see claw/issues/010-ego-data-upload.md, "Trip-wires").
##   - We upload `manifest.json`, optional legacy/debug calibration sidecars,
##     and `{session_id}.mp4`. Frame JSONL sidecar upload is deferred — the
##     muxed mp4 tracks (`mett:head`, `mett:hand`, etc.) carry the same data,
##     and those sidecars are documented as debug-only mirrors in
##     `session_spool_writer.gd`.
##
## Signals are emitted via call_deferred from the worker thread so
## listeners always see them on the main thread.

signal upload_started(session_id: String, artifact_kind: String)
signal upload_progress(session_id: String, artifact_kind: String, sent_bytes: int, total_bytes: int)
signal upload_finished(session_id: String, artifact_kind: String, response: Dictionary)
signal upload_failed(session_id: String, artifact_kind: String, error: String)
signal upload_cancelled(session_id: String, reason: String)
signal session_uploaded(session_id: String)
signal queue_changed(pending_count: int)

const QUEUE_PATH := "user://ego_upload_queue.json"
const TUS_VERSION := "1.0.0"
const SCHEMA_VERSION := "spatialmp4.quest_capture.spool.v3"
const CHUNK_SIZE := 8 * 1024 * 1024            # 8 MB
const MAX_BACKOFF_SECONDS := 30.0
const INITIAL_BACKOFF_SECONDS := 1.0
const HTTP_CONNECT_TIMEOUT_S := 15.0
const HTTP_POLL_TIMEOUT_S := 60.0
# Hard upper bound on transient retries per job. The TUS retry loop is meant
# to survive flaky Wi-Fi / brief server hiccups; without a ceiling a job whose
# failure mode is borderline-permanent (DNS that resolves but POST 502s, a
# tunnel that accepts the connect but drops PATCH, etc.) would otherwise block
# every later session forever — that is the "previous failed upload keeps
# retrying when I record a new file" bug. 20 attempts × up-to-30 s backoff
# gives us several minutes of resilience before we give up; permanent
# failures (4xx, missing local file) drop out much sooner via the
# permanent-failure path below.
const MAX_TRANSIENT_ATTEMPTS_PER_JOB := 20

# Artifact kinds — also written verbatim into Upload-Metadata so the
# server can route each artifact to the right slot.
const ARTIFACT_MANIFEST := "manifest"
const ARTIFACT_MEDIA := "media"
const ARTIFACT_LEFT_CAMERA_CHARACTERISTICS := "left_camera_characteristics"
const ARTIFACT_RIGHT_CAMERA_CHARACTERISTICS := "right_camera_characteristics"
const CAMERA_CHARACTERISTICS_UPLOADS := [
	{
		"kind": ARTIFACT_LEFT_CAMERA_CHARACTERISTICS,
		"filename": "left_camera_characteristics.json"
	},
	{
		"kind": ARTIFACT_RIGHT_CAMERA_CHARACTERISTICS,
		"filename": "right_camera_characteristics.json"
	},
]
const ARTIFACT_UPLOAD_ORDER := [
	ARTIFACT_MANIFEST,
	ARTIFACT_LEFT_CAMERA_CHARACTERISTICS,
	ARTIFACT_RIGHT_CAMERA_CHARACTERISTICS,
	ARTIFACT_MEDIA,
]

var _thread: Thread
var _mutex: Mutex
var _wake: Semaphore
var _exit_requested := false
var _paused := false
var _queue: Array = []                          # Array[Dictionary]
var _cancel_requested: Dictionary = {}           # session_id -> true


func _ready() -> void:
	_mutex = Mutex.new()
	_wake = Semaphore.new()
	_load_queue_from_disk()
	_thread = Thread.new()
	_thread.start(Callable(self, "_worker_loop"))
	# Kick the worker once in case the queue had pending jobs from
	# a previous app launch.
	_wake.post()


func _exit_tree() -> void:
	_mutex.lock()
	_exit_requested = true
	_mutex.unlock()
	_wake.post()
	if _thread and _thread.is_started():
		_thread.wait_to_finish()


## Pause the worker while recording is active. The current PATCH (if any)
## runs to completion, then the worker parks until resume() is called.
func pause() -> void:
	_mutex.lock()
	_paused = true
	_mutex.unlock()


func resume() -> void:
	_mutex.lock()
	_paused = false
	_mutex.unlock()
	_wake.post()


## Enqueue a finalized session for upload. Called from capture_app.gd
## right after SessionSpoolWriter::close().
##
## `options` is the same `capture_options` dict the writer used so we
## pick up `upload_url`, `upload_token`, `keep_local_after_upload`,
## etc. in one shot.
func enqueue(session_dir: String, mp4_path: String, options: Dictionary) -> bool:
	var url := str(options.get("upload_url", "")).strip_edges()
	if url.is_empty():
		return false
	if not bool(options.get("upload_on_finalize", false)):
		return false

	var manifest_path := session_dir.path_join("manifest.json")
	if not FileAccess.file_exists(manifest_path):
		push_warning("[EgoUploader] manifest missing for session %s; refusing to enqueue" % session_dir)
		return false
	if not FileAccess.file_exists(mp4_path):
		push_warning("[EgoUploader] mp4 missing at %s; refusing to enqueue" % mp4_path)
		return false

	var session_id := mp4_path.get_file().get_basename()
	var artifacts := {
		ARTIFACT_MANIFEST: {"path": manifest_path, "tus_location": "", "offset": 0, "done": false},
		ARTIFACT_MEDIA:    {"path": mp4_path,      "tus_location": "", "offset": 0, "done": false},
	}
	for sidecar in CAMERA_CHARACTERISTICS_UPLOADS:
		var filename := str(sidecar.get("filename", ""))
		var path := session_dir.path_join(filename)
		if filename.is_empty() or not FileAccess.file_exists(path):
			continue
		artifacts[str(sidecar.get("kind", filename.get_basename()))] = {
			"path": path,
			"tus_location": "",
			"offset": 0,
			"done": false
		}
	var job := {
		"session_id": session_id,
		"session_dir": session_dir,
		"manifest_path": manifest_path,
		"mp4_path": mp4_path,
		"upload_url": url,
		"upload_token": str(options.get("upload_token", "")),
		"keep_local_after_upload": bool(options.get("keep_local_after_upload", true)),
		"allow_metered_upload": bool(options.get("allow_metered_upload", false)),
		"artifacts": artifacts,
		"attempt": 0,
	}

	_mutex.lock()
	_queue.append(job)
	var pending: int = _queue.size()
	_save_queue_locked()
	_mutex.unlock()

	call_deferred("emit_signal", "queue_changed", pending)
	_wake.post()
	return true


## Snapshot of the queue for UI/debug callers. Safe to call from main thread.
func pending_jobs() -> Array:
	_mutex.lock()
	var snapshot := _queue.duplicate(true)
	_mutex.unlock()
	return snapshot


## Move a queued job to the front so a freshly-finalized recording uploads
## before stale retry jobs recovered from a previous app run.
func prioritize(session_id: String) -> bool:
	var found := false
	_mutex.lock()
	for i in range(_queue.size()):
		if str(_queue[i].get("session_id", "")) != session_id:
			continue
		found = true
		if i > 0:
			var job: Dictionary = _queue[i]
			_queue.remove_at(i)
			_queue.push_front(job)
			_save_queue_locked()
		break
	_mutex.unlock()
	if found:
		_wake.post()
	return found


## Drop every queued job that is currently in the "permanent failure" state.
## Useful as a manual escape hatch (settings panel "Clear failed uploads")
## when, say, a user mass-deleted local recordings while the queue still
## referenced them. Active uploads in progress are NOT touched — those are
## still in the worker thread's `job` local and will go through the normal
## permanent-failure exit path on the next attempt.
func clear_failed() -> int:
	var removed := 0
	_mutex.lock()
	for i in range(_queue.size() - 1, -1, -1):
		if bool(_queue[i].get("_permanent_failure", false)):
			_queue.remove_at(i)
			removed += 1
	if removed > 0:
		_save_queue_locked()
	var pending: int = _queue.size()
	_mutex.unlock()
	if removed > 0:
		call_deferred("emit_signal", "queue_changed", pending)
	return removed


## Cancel a job by session_id. The job stays queued until the worker deletes
## any remote TUS resources it already created, then the worker removes it.
func cancel(session_id: String) -> bool:
	var found := false
	_mutex.lock()
	for i in range(_queue.size() - 1, -1, -1):
		if str(_queue[i].get("session_id", "")) == session_id:
			found = true
			break
	if found:
		_cancel_requested[session_id] = true
	var pending: int = _queue.size()
	_mutex.unlock()
	if found:
		call_deferred("emit_signal", "queue_changed", pending)
		_wake.post()
	return found


# --- Worker thread -----------------------------------------------------------

func _worker_loop() -> void:
	while true:
		_mutex.lock()
		var exit_now := _exit_requested
		var paused := _paused
		var has_job := not _queue.is_empty()
		var job: Dictionary = _queue[0].duplicate(true) if has_job else {}
		_mutex.unlock()

		if exit_now:
			return
		if paused or not has_job:
			_wake.wait()
			continue

		var ok := _process_job(job)
		_mutex.lock()
		# Only merge our worker-side mutations (offsets, tus_location) back
		# into the queue head if it is still the same job we picked up at
		# the top of the loop. cancel() can remove [0] while we were
		# mid-upload, in which case [0] is now a different session and
		# writing our local `job` over it would corrupt the queue.
		var head_matches := not _queue.is_empty() and str(_queue[0].get("session_id", "")) == str(job.get("session_id", ""))
		if head_matches:
			_queue[0] = job
		var cancelled := bool(job.get("_cancelled", false))
		if cancelled and head_matches:
			_queue.pop_front()
			_save_queue_locked()
			var cancelled_sid := str(job.get("session_id", ""))
			_mutex.unlock()
			call_deferred("emit_signal", "queue_changed", _queue_size())
			call_deferred("emit_signal", "upload_cancelled", cancelled_sid, "cancelled")
			continue
		if ok and head_matches:
			var finished_job: Dictionary = _queue.pop_front()
			_save_queue_locked()
			var sid := str(finished_job.get("session_id", ""))
			var keep_local := bool(finished_job.get("keep_local_after_upload", true))
			var session_dir_finished := str(finished_job.get("session_dir", ""))
			var mp4_finished := str(finished_job.get("mp4_path", ""))
			_mutex.unlock()
			if not keep_local:
				_cleanup_local_artifacts(session_dir_finished, mp4_finished)
			call_deferred("emit_signal", "session_uploaded", sid)
			call_deferred("emit_signal", "queue_changed", _queue_size())
			continue
		# Failure path. Decide whether to retry the same job (transient) or
		# drop it from the queue (permanent, or transient-with-budget-exhausted)
		# so that a poison job does not block every later session forever.
		var permanent := head_matches and bool(job.get("_permanent_failure", false))
		var attempt: int = int(job.get("attempt", 0))
		var exhausted := head_matches and attempt >= MAX_TRANSIENT_ATTEMPTS_PER_JOB
		if permanent or exhausted:
			# Pop FIRST, release the mutex, THEN do the best-effort remote
			# TUS DELETE. Earlier revisions kept the cleanup inside the lock,
			# which meant a wedged server blocked main-thread enqueue() /
			# cancel() / clear_failed() / pending_jobs() / get_options() polls
			# for up to MAX_DELETE_TIME_S × N artifacts — i.e. the same
			# "cancel button frozen" symptom the popup-routing fix was
			# supposed to kill. The job is already poison; if cleanup also
			# fails we just leak the TUS resource at the server and log it.
			var dropped_job: Dictionary = {}
			var dropped_sid := str(job.get("session_id", ""))
			var drop_reason := str(job.get("_failure_message", "transient failure budget exhausted")) if permanent else ("transient failure budget exhausted after %d attempts" % attempt)
			if head_matches:
				dropped_job = _queue.pop_front()
			_save_queue_locked()
			_mutex.unlock()
			if not dropped_job.is_empty():
				if not _cleanup_cancelled_job(dropped_job):
					push_warning("[EgoUploader] dropping job %s but remote TUS cleanup failed; resources may linger at the server until GC" % dropped_sid)
			push_warning("[EgoUploader] dropping job %s after permanent/exhausted failure: %s" % [dropped_sid, drop_reason])
			call_deferred("emit_signal", "queue_changed", _queue_size())
			# upload_failed was already emitted from _fail(); add a terminal
			# upload_cancelled to clearly signal "this session will not retry"
			# so the status popup can move on instead of staying spinning.
			call_deferred("emit_signal", "upload_cancelled", dropped_sid, drop_reason)
			continue
		_save_queue_locked()
		_mutex.unlock()

		# Transient failure — TUS resume on the next attempt. Exponential
		# back-off so we don't spin against a wedged server.
		var backoff: float = minf(INITIAL_BACKOFF_SECONDS * pow(2.0, attempt - 1), MAX_BACKOFF_SECONDS)
		var deadline_ms: int = Time.get_ticks_msec() + int(backoff * 1000.0)
		while Time.get_ticks_msec() < deadline_ms:
			_mutex.lock()
			var bail := _exit_requested
			_mutex.unlock()
			if bail:
				return
			if _is_cancel_requested(str(job.get("session_id", ""))) and not bool(job.get("_cancel_cleanup_failed", false)):
				break
			OS.delay_msec(200)


func _queue_size() -> int:
	_mutex.lock()
	var n: int = _queue.size()
	_mutex.unlock()
	return n


# Process a single session. Mutates `job` in place so partial progress
# (per-artifact offset, tus_location) survives across retries.
# Returns true iff every artifact finished.
func _process_job(job: Dictionary) -> bool:
	job["attempt"] = int(job.get("attempt", 0)) + 1
	# Wipe the per-attempt failure flags so a transient retry can't inherit
	# a stale "permanent" marker from a previous attempt. _fail() will set
	# them again if this attempt also fails.
	job.erase("_permanent_failure")
	job.erase("_failure_message")
	job.erase("_failure_kind")
	var session_id := str(job.get("session_id", ""))
	if _is_cancel_requested(session_id):
		_cleanup_cancelled_job(job)
		return false
	var artifacts: Dictionary = job.get("artifacts", {})
	# Manifest first so the server can allocate the session record before
	# optional legacy sidecars and the much larger mp4 arrive. Keep sidecars
	# ahead of media so older ingest workers that still consult them have the
	# fallback files before media completion starts preview/Rerun work.
	for kind in _artifact_upload_order(artifacts):
		if not artifacts.has(kind):
			continue
		var artifact: Dictionary = artifacts[kind]
		if bool(artifact.get("done", false)):
			continue
		call_deferred("emit_signal", "upload_started", session_id, kind)
		var ok := _upload_artifact(job, kind, artifact)
		artifacts[kind] = artifact
		if not ok:
			if _is_cancel_requested(session_id):
				_cleanup_cancelled_job(job)
			return false
		artifact["done"] = true
		artifacts[kind] = artifact
		call_deferred("emit_signal", "upload_finished", session_id, kind, {"offset": artifact.get("offset", 0)})
	job["artifacts"] = artifacts
	return true


func _artifact_upload_order(artifacts: Dictionary) -> Array:
	var ordered: Array = []
	for kind in ARTIFACT_UPLOAD_ORDER:
		if artifacts.has(kind):
			ordered.append(kind)
	for kind in artifacts.keys():
		if not ordered.has(kind):
			ordered.append(kind)
	return ordered


func _upload_artifact(job: Dictionary, kind: String, artifact: Dictionary) -> bool:
	var session_id := str(job.get("session_id", ""))
	if _is_cancel_requested(session_id):
		return false
	var path := str(artifact.get("path", ""))
	if not FileAccess.file_exists(path):
		# Local file disappeared (user deleted the session via Storage panel,
		# DCIM was cleared, sdcard yanked). Retrying will never resurrect it.
		_fail(job, kind, "local file missing: %s" % path, true)
		return false
	var total: int = int(FileAccess.get_file_as_bytes(path).size()) if kind == ARTIFACT_MANIFEST else int(_file_size(path))
	if total <= 0:
		_fail(job, kind, "empty artifact: %s" % path, true)
		return false

	var http := _connect_to(job)
	if http == null:
		_fail(job, kind, "failed to connect to %s" % job.get("upload_url", ""))
		return false

	var endpoint_path := _path_of_url(str(job.get("upload_url", "")))
	var tus_location := str(artifact.get("tus_location", ""))
	var offset := int(artifact.get("offset", 0))

	# Create the TUS resource if we don't already have a Location header
	# from a prior partial attempt.
	if tus_location.is_empty():
		var creation := _tus_create(http, endpoint_path, job, kind, path, total)
		if creation.is_empty():
			return false
		tus_location = creation
		artifact["tus_location"] = tus_location
		if _is_cancel_requested(session_id):
			return false
	else:
		# Resume path: HEAD the existing resource so we believe the server
		# about how many bytes it actually persisted.
		var server_offset := _tus_head(http, tus_location, job)
		if server_offset < 0:
			# Resource gone (410) or unrecoverable — recreate.
			artifact["tus_location"] = ""
			artifact["offset"] = 0
			var creation2 := _tus_create(http, endpoint_path, job, kind, path, total)
			if creation2.is_empty():
				return false
			tus_location = creation2
			artifact["tus_location"] = tus_location
			offset = 0
			if _is_cancel_requested(session_id):
				return false
		else:
			offset = server_offset
			artifact["offset"] = offset

	call_deferred("emit_signal", "upload_progress", session_id, kind, offset, total)

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		_fail(job, kind, "cannot read %s" % path, true)
		return false
	file.seek(offset)
	while offset < total:
		_mutex.lock()
		var should_stop := _exit_requested or _paused or _cancel_requested.has(session_id)
		_mutex.unlock()
		if should_stop:
			file.close()
			return false

		var chunk_size := mini(CHUNK_SIZE, total - offset)
		var chunk: PackedByteArray = file.get_buffer(chunk_size)
		if chunk.size() != chunk_size:
			# File truncated under us — same logic as "local file missing".
			_fail(job, kind, "short read from %s at offset %d" % [path, offset], true)
			file.close()
			return false

		var new_offset := _tus_patch(http, tus_location, offset, chunk, job, kind)
		if new_offset < 0:
			file.close()
			return false
		offset = new_offset
		artifact["offset"] = offset
		call_deferred("emit_signal", "upload_progress", session_id, kind, offset, total)

	file.close()
	return true


# --- TUS state machine -------------------------------------------------------

func _tus_create(http: HTTPClient, endpoint_path: String, job: Dictionary, kind: String, local_path: String, total_bytes: int) -> String:
	var headers := _common_headers(job)
	headers.append("Upload-Length: %d" % total_bytes)
	headers.append("Content-Length: 0")
	headers.append("Upload-Metadata: %s" % _build_upload_metadata(job, kind, local_path))
	var err := http.request(HTTPClient.METHOD_POST, endpoint_path, headers)
	if err != OK:
		_fail(job, kind, "POST request() failed: %d" % err)
		return ""
	var status := _drive_http(http)
	if status < 0:
		_fail(job, kind, "POST drive_http error")
		return ""
	if status != 201:
		# 401 deserves a targeted hint: the panel's connectivity probe is an
		# unauthenticated OPTIONS (TUS discovery), so "endpoint OK" + 401 here
		# almost always means the Bearer token is missing (URL was typed or
		# came from a plain-URL QR) or no longer matches the server's user
		# table — re-scanning the signed connect QR refreshes both.
		if status == 401:
			_drain_body(http)
			var token_hint := "no upload token configured" if str(job.get("upload_token", "")).is_empty() else "upload token rejected by server"
			_fail(job, kind, "POST got 401 (%s) — re-scan the connect QR to refresh credentials" % token_hint, true)
			return ""
		_fail(job, kind, "POST expected 201, got %d (%s)" % [status, _body_text(http)], _is_permanent_http_status(status))
		return ""
	var location := _response_header(http, "location")
	if location.is_empty():
		_fail(job, kind, "POST 201 missing Location header")
		return ""
	# Drain any body that came with the 201 response.
	_drain_body(http)
	return _normalize_tus_location(str(job.get("upload_url", "")), location)


func _tus_head(http: HTTPClient, tus_location: String, job: Dictionary) -> int:
	var headers := _common_headers(job)
	var path := _path_of_url(tus_location)
	var err := http.request(HTTPClient.METHOD_HEAD, path, headers)
	if err != OK:
		return -1
	var status := _drive_http(http)
	_drain_body(http)
	if status == 200 or status == 204:
		var off := _response_header(http, "upload-offset")
		if off.is_empty():
			return 0
		return int(off)
	# 404/410 → server forgot the resource; caller will recreate.
	return -1


func _tus_patch(http: HTTPClient, tus_location: String, offset: int, chunk: PackedByteArray, job: Dictionary, kind: String) -> int:
	var headers := _common_headers(job)
	headers.append("Content-Type: application/offset+octet-stream")
	headers.append("Upload-Offset: %d" % offset)
	headers.append("Content-Length: %d" % chunk.size())
	var path := _path_of_url(tus_location)
	var err := http.request_raw(HTTPClient.METHOD_PATCH, path, headers, chunk)
	if err != OK:
		_fail(job, kind, "PATCH request_raw failed: %d" % err)
		return -1
	var status := _drive_http(http)
	if status < 0:
		_fail(job, kind, "PATCH drive_http error")
		return -1
	if status != 204 and status != 200:
		# 401 here almost certainly means the operator rotated their upload
		# token mid-upload (or the server restarted with a fresh secret).
		# Either way the in-flight TUS resource is now stranded — re-scan.
		if status == 401:
			_drain_body(http)
			_fail(job, kind, "PATCH got 401 — upload token rejected mid-stream; re-scan the connect QR", true)
			return -1
		_fail(job, kind, "PATCH expected 204, got %d (%s)" % [status, _body_text(http)], _is_permanent_http_status(status))
		return -1
	var new_off := _response_header(http, "upload-offset")
	_drain_body(http)
	if new_off.is_empty():
		return offset + chunk.size()
	return int(new_off)


func _cleanup_cancelled_job(job: Dictionary) -> bool:
	var session_id := str(job.get("session_id", ""))
	if session_id.is_empty():
		return false
	if bool(job.get("_cancelled", false)):
		return true
	job["_cancel_cleanup_failed"] = false
	var cleaned := true
	var artifacts: Dictionary = job.get("artifacts", {})
	for kind in artifacts.keys():
		var artifact: Dictionary = artifacts[kind]
		var location := str(artifact.get("tus_location", ""))
		if not location.is_empty():
			cleaned = _tus_delete_location(job, location) and cleaned
	cleaned = _delete_remote_session(job) and cleaned
	if not cleaned:
		job["_cancel_cleanup_failed"] = true
		_fail(job, "cancel", "remote cleanup failed; will retry")
		return false
	_clear_cancel_requested(session_id)
	job["_cancelled"] = true
	return true


func _tus_delete_location(job: Dictionary, tus_location: String) -> bool:
	var base_url := str(job.get("upload_url", ""))
	var target_url := _normalize_tus_location(base_url, tus_location)
	return _delete_url(job, target_url)


func _delete_remote_session(job: Dictionary) -> bool:
	var session_id := str(job.get("session_id", ""))
	var upload_url := str(job.get("upload_url", ""))
	var target_url := _session_cleanup_url(upload_url, session_id)
	if target_url.is_empty():
		return false
	return _delete_url(job, target_url)


func _delete_url(job: Dictionary, url: String) -> bool:
	var http := _connect_to_url(url)
	if http == null:
		return false
	var err := http.request(HTTPClient.METHOD_DELETE, _path_of_url(url), _common_headers(job))
	if err != OK:
		return false
	var status := _drive_http(http)
	_drain_body(http)
	return status == 204 or status == 404 or status == 410


func _is_cancel_requested(session_id: String) -> bool:
	_mutex.lock()
	var requested := _cancel_requested.has(session_id)
	_mutex.unlock()
	return requested


func _clear_cancel_requested(session_id: String) -> void:
	_mutex.lock()
	_cancel_requested.erase(session_id)
	_mutex.unlock()


# --- HTTP helpers ------------------------------------------------------------

func _connect_to(job: Dictionary) -> HTTPClient:
	return _connect_to_url(str(job.get("upload_url", "")))


func _connect_to_url(url: String) -> HTTPClient:
	var parsed := _parse_url(url)
	if parsed.is_empty():
		return null
	var http := HTTPClient.new()
	var use_tls: bool = parsed["scheme"] == "https"
	var tls := TLSOptions.client() if use_tls else null
	var err := http.connect_to_host(parsed["host"], int(parsed["port"]), tls)
	if err != OK:
		return null

	var deadline_ms: int = Time.get_ticks_msec() + int(HTTP_CONNECT_TIMEOUT_S * 1000.0)
	while true:
		var status := http.get_status()
		if status == HTTPClient.STATUS_CONNECTED:
			return http
		if status == HTTPClient.STATUS_CANT_CONNECT or status == HTTPClient.STATUS_CANT_RESOLVE or status == HTTPClient.STATUS_DISCONNECTED or status == HTTPClient.STATUS_TLS_HANDSHAKE_ERROR:
			return null
		if Time.get_ticks_msec() > deadline_ms:
			return null
		http.poll()
		OS.delay_msec(20)
	return null


# Drive HTTPClient through request → response. Returns HTTP status code,
# or -1 on protocol error / timeout.
func _drive_http(http: HTTPClient) -> int:
	var deadline_ms: int = Time.get_ticks_msec() + int(HTTP_POLL_TIMEOUT_S * 1000.0)
	while true:
		var status := http.get_status()
		if status == HTTPClient.STATUS_BODY or status == HTTPClient.STATUS_CONNECTED:
			return int(http.get_response_code())
		if status == HTTPClient.STATUS_DISCONNECTED or status == HTTPClient.STATUS_CONNECTION_ERROR or status == HTTPClient.STATUS_CANT_RESOLVE or status == HTTPClient.STATUS_CANT_CONNECT or status == HTTPClient.STATUS_TLS_HANDSHAKE_ERROR:
			return -1
		if Time.get_ticks_msec() > deadline_ms:
			return -1
		http.poll()
		OS.delay_msec(5)
	return -1


func _drain_body(http: HTTPClient) -> void:
	if not http.has_response():
		return
	var deadline_ms: int = Time.get_ticks_msec() + int(HTTP_POLL_TIMEOUT_S * 1000.0)
	while http.get_status() == HTTPClient.STATUS_BODY:
		http.poll()
		var _chunk: PackedByteArray = http.read_response_body_chunk()
		if Time.get_ticks_msec() > deadline_ms:
			return


func _body_text(http: HTTPClient) -> String:
	var buf := PackedByteArray()
	var deadline_ms: int = Time.get_ticks_msec() + int(HTTP_POLL_TIMEOUT_S * 1000.0)
	while http.get_status() == HTTPClient.STATUS_BODY:
		http.poll()
		var chunk: PackedByteArray = http.read_response_body_chunk()
		if chunk.size() > 0:
			buf.append_array(chunk)
		if Time.get_ticks_msec() > deadline_ms:
			break
	return buf.get_string_from_utf8().substr(0, 200)


func _response_header(http: HTTPClient, name_lower: String) -> String:
	for h in http.get_response_headers():
		var line := str(h)
		var colon := line.find(":")
		if colon <= 0:
			continue
		var key := line.substr(0, colon).strip_edges().to_lower()
		if key == name_lower:
			return line.substr(colon + 1).strip_edges()
	return ""


func _common_headers(job: Dictionary) -> PackedStringArray:
	var headers := PackedStringArray()
	headers.append("Tus-Resumable: %s" % TUS_VERSION)
	headers.append("X-Ego-Schema-Version: %s" % SCHEMA_VERSION)
	var token := str(job.get("upload_token", ""))
	if not token.is_empty():
		headers.append("Authorization: Bearer %s" % token)
	headers.append("User-Agent: ego-uploader/1.0 (godot)")
	return headers


func _build_upload_metadata(job: Dictionary, kind: String, local_path: String) -> String:
	# TUS Upload-Metadata is a comma-separated list of
	# "<key> <base64 value>" pairs.
	var pairs := [
		"session_id %s" % Marshalls.utf8_to_base64(str(job.get("session_id", ""))),
		"artifact_kind %s" % Marshalls.utf8_to_base64(kind),
		"filename %s" % Marshalls.utf8_to_base64(local_path.get_file()),
		"schema %s" % Marshalls.utf8_to_base64(SCHEMA_VERSION),
	]
	return ",".join(pairs)


# --- URL utils ---------------------------------------------------------------

func _parse_url(url: String) -> Dictionary:
	# Minimal parser: scheme://host[:port][/path]
	var scheme := ""
	var rest := ""
	if url.begins_with("https://"):
		scheme = "https"
		rest = url.substr(8)
	elif url.begins_with("http://"):
		scheme = "http"
		rest = url.substr(7)
	else:
		return {}
	var slash := rest.find("/")
	var authority := rest if slash < 0 else rest.substr(0, slash)
	var path := "/" if slash < 0 else rest.substr(slash)
	var host := authority
	var port := 443 if scheme == "https" else 80
	var colon := authority.find(":")
	if colon > 0:
		host = authority.substr(0, colon)
		port = authority.substr(colon + 1).to_int()
	return {"scheme": scheme, "host": host, "port": port, "path": path}


func _path_of_url(url: String) -> String:
	if url.begins_with("http://") or url.begins_with("https://"):
		var parsed := _parse_url(url)
		if parsed.is_empty():
			return "/"
		return str(parsed.get("path", "/"))
	# Already a relative path (typical for TUS Location headers).
	return url if url.begins_with("/") else "/" + url


# tus-node-server returns Location as either an absolute URL or a
# server-relative path. Normalize to absolute so subsequent resumes
# survive a reconnect to the same host.
func _normalize_tus_location(base_url: String, location: String) -> String:
	if location.begins_with("http://") or location.begins_with("https://"):
		return location
	var parsed := _parse_url(base_url)
	if parsed.is_empty():
		return location
	var authority := "%s://%s" % [parsed["scheme"], parsed["host"]]
	var port := int(parsed["port"])
	var default_port := 443 if parsed["scheme"] == "https" else 80
	if port != default_port:
		authority += ":%d" % port
	if not location.begins_with("/"):
		location = "/" + location
	return authority + location


func _session_cleanup_url(upload_url: String, session_id: String) -> String:
	var parsed := _parse_url(upload_url)
	if parsed.is_empty() or session_id.is_empty():
		return ""
	var authority := "%s://%s" % [parsed["scheme"], parsed["host"]]
	var port := int(parsed["port"])
	var default_port := 443 if parsed["scheme"] == "https" else 80
	if port != default_port:
		authority += ":%d" % port
	var path := str(parsed.get("path", "/"))
	while path.ends_with("/") and path.length() > 1:
		path = path.substr(0, path.length() - 1)
	return "%s%s/sessions/%s" % [authority, path, session_id]


# --- Queue persistence -------------------------------------------------------

func _save_queue_locked() -> void:
	# Caller holds _mutex.
	var tmp := QUEUE_PATH + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(_queue))
	f.close()
	DirAccess.rename_absolute(ProjectSettings.globalize_path(tmp), ProjectSettings.globalize_path(QUEUE_PATH))


func _load_queue_from_disk() -> void:
	if not FileAccess.file_exists(QUEUE_PATH):
		return
	var f := FileAccess.open(QUEUE_PATH, FileAccess.READ)
	if f == null:
		return
	var text := f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_ARRAY:
		return
	# Reset transient state — the worker will HEAD each resource to
	# rediscover the real Upload-Offset before resuming. Also drop any
	# entries that were already marked as a permanent failure on a
	# previous run: keeping them would just have the worker re-emit the
	# same upload_failed signal at startup and then sit on them, which is
	# the bug we're fixing here.
	var cleaned: Array = []
	var dropped := 0
	for entry in parsed:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		if bool(entry.get("_permanent_failure", false)):
			dropped += 1
			continue
		entry["attempt"] = 0
		cleaned.append(entry)
	_queue = cleaned
	if dropped > 0:
		_save_queue_locked()
		print("[EgoUploader] dropped %d permanently-failed job(s) at load" % dropped)
	print("[EgoUploader] loaded %d pending job(s) from %s" % [_queue.size(), QUEUE_PATH])


# --- Misc helpers ------------------------------------------------------------

func _file_size(path: String) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return 0
	var sz := int(f.get_length())
	f.close()
	return sz


func _cleanup_local_artifacts(session_dir: String, mp4_path: String) -> void:
	# Only used when keep_local_after_upload=false. Remove the mp4 first
	# so the user gets storage back fast; the session_dir (manifest +
	# sidecars) is a separate pass.
	if FileAccess.file_exists(mp4_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(mp4_path))
	if not session_dir.is_empty():
		_recursive_delete(session_dir)


func _recursive_delete(dir_path: String) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	while true:
		var entry := dir.get_next()
		if entry.is_empty():
			break
		if entry == "." or entry == "..":
			continue
		var full := dir_path.path_join(entry)
		if dir.current_is_dir():
			_recursive_delete(full)
		else:
			DirAccess.remove_absolute(ProjectSettings.globalize_path(full))
	dir.list_dir_end()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(dir_path))


## Mark `job` as failed. `permanent=true` flips a sticky flag the worker
## checks AFTER _process_job returns so the job leaves the queue instead of
## getting retried forever (which is what the pre-fix behaviour did to e.g.
## 401-Authorization failures, blocking every subsequent recording from ever
## uploading until the user manually wiped user://ego_upload_queue.json).
func _fail(job: Dictionary, kind: String, message: String, permanent: bool = false) -> void:
	push_warning("[EgoUploader] %s/%s: %s%s" % [
		str(job.get("session_id", "?")),
		kind,
		message,
		" (permanent)" if permanent else "",
	])
	if permanent:
		job["_permanent_failure"] = true
		job["_failure_message"] = message
		job["_failure_kind"] = kind
	call_deferred("emit_signal", "upload_failed", str(job.get("session_id", "")), kind, message)


# TUS / HTTP statuses that should NOT be retried — the next attempt would just
# produce the same error. We treat the standard 4xx client errors as
# permanent (bad token, missing resource, conflict, payload too big, …) while
# leaving 408 / 425 / 429 + everything ≥500 + raw connection failures on the
# transient retry path. Anything outside the documented HTTP space (status < 0
# from drive_http(), 0 from a torn-down poll) is transient by definition: we
# never actually got a response, so the next attempt might.
func _is_permanent_http_status(status: int) -> bool:
	if status < 400 or status >= 500:
		return false
	if status == 408 or status == 425 or status == 429:
		return false
	return true
