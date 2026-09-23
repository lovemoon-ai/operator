class_name AudioSource
extends Node
## Capability layer (components/sources): microphone capture. The provider's
## Kotlin AudioCapture encodes AAC and hands it Kotlin-direct to the bound sink
## (timestamped `System.nanoTime() + clockMonotonicToGodotTicksOffsetNs`, see
## wire-protocol.md "Headset timebase"). This component owns the RECORD_AUDIO
## system permission flow and the per-session audio configuration.
##
## A denied or ignored permission prompt degrades the session to video-only
## after a grace period instead of failing it.

const AUDIO_PERMISSION_GRACE_US := 3000000

var _camera: CameraSource
var _wait_logged := false
var _degraded_logged := false
var _wait_started_ticks_us := 0
# One up-front RECORD_AUDIO prompt per app session. Audio defaults to ON, so
# the system prompt appears as soon as the provider binds -- otherwise the
# operator would not see it until Start, and a denied prompt would silently
# produce a video-only recording.
var _prompt_fired := false


func configure(camera: CameraSource) -> void:
	_camera = camera


## Mirrors com.spatialmp4.contract.AudioChannelLayout.code on the Kotlin side.
static func layout_code_for_label(label: String) -> int:
	match label:
		"mono":
			return 0
		"stereo":
			return 1
		"foa_acn_sn3d":
			return 2
		"raw_4ch":
			return 3
		_:
			return 1


## Provider session-config fields for this capture.
static func session_config(options: Dictionary) -> Dictionary:
	return {
		"record_audio": bool(options.get("record_audio", false)),
		"audio_channel_layout_code": layout_code_for_label(str(options.get("audio_channel_layout", "stereo"))),
		"audio_sample_rate_hz": int(options.get("audio_sample_rate_hz", 48000)),
		"audio_bitrate_bps": int(options.get("audio_bitrate_bps", 128000)),
	}


func reset_session() -> void:
	_wait_logged = false
	_degraded_logged = false
	_wait_started_ticks_us = 0


## Drops the once-per-app-session prompt latch (the operator re-enabled audio).
func rearm_prompt() -> void:
	_prompt_fired = false


func request_permission(wants_audio: bool) -> void:
	if wants_audio and _camera != null and _camera.plugin != null:
		_camera.plugin.call("requestAudioPermission")


## Idle-time up-front prompt. Idempotent: re-prompting every frame would spam
## the Android permission dialog.
func prompt_up_front(wants_audio: bool) -> void:
	if _prompt_fired or not wants_audio or _camera == null:
		return
	if not _camera.bind():
		return
	# Providers without audio capture never record it -- skip the prompt so
	# the operator isn't asked for a permission the session won't use.
	if not _camera.supports_audio():
		_prompt_fired = true
		return
	# Android plugin singletons do not always reflect @UsedByGodot methods
	# through has_method(), so call directly.
	if bool(_camera.plugin.call("hasAudioPermission")):
		_prompt_fired = true
		print("%s audio permission already granted" % _camera.label())
		return
	_camera.plugin.call("requestAudioPermission")
	_prompt_fired = true
	print("%s requested audio permission up front (record_audio=on)" % _camera.label())


## False while the session should keep waiting for RECORD_AUDIO; true once it
## is granted, not wanted, or the grace period expired (video-only).
func ready_to_start(wants_audio: bool) -> bool:
	if not wants_audio or _camera == null or _camera.plugin == null:
		return true
	if bool(_camera.plugin.call("hasAudioPermission")):
		return true
	var now_us := Time.get_ticks_usec()
	if not _wait_logged:
		_wait_logged = true
		_wait_started_ticks_us = now_us
		print("%s waiting for audio permission" % _camera.label())
	_camera.plugin.call("requestAudioPermission")
	if now_us - _wait_started_ticks_us < AUDIO_PERMISSION_GRACE_US:
		return false
	if not _degraded_logged:
		_degraded_logged = true
		print("%s audio permission missing; starting without audio" % _camera.label())
	return true
