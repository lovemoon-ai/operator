class_name EgoCaptureComposition
extends RefCounted
## v2 app/composition (WP6): composition root for the ego-capture mode.
##
## Given the mode's writer engine, samplers, and scene-owned callables it
## builds the v2 capture stack (sinks + StreamBinding fanout + writer
## adapter + CaptureSessionController) exactly as capture_app.gd wired it
## inline before WP6. capture_app.gd remains the scene-lifecycle script
## (its path is load-bearing for tests/02_ego_record.sh); this class owns
## the "what gets composed" decisions so they can be exercised by the WP7
## harness with fake platforms/sinks.
##
## Behavior note: depth/body/motion-tracker availability is still gated at
## the capture-options level via the capture provider's reported support
## (see effective_capture_options) — identical to pre-v2 behavior. A
## missing capability degrades the option set; the manifest records the
## stream as absent with today's reasons text.

const SessionSpoolWriterScript := preload("res://scripts/core/capture/session_spool_writer.gd")
const CaptureProviderRegistryScript := preload("res://scripts/xr/capture_provider_registry.gd")


## Phase 1: writer engine + sinks + canonical-frame fanout.
## Returns {writer, frame_sink, spatialmp4_sink, upload_sink}.
## The samplers are configured against `writer` by the scene before phase 2.
static func build_io() -> Dictionary:
	var writer: Object = SessionSpoolWriterScript.new()
	var spatialmp4_sink := SpatialMp4Sink.new(writer)
	var binding := StreamBinding.new()
	binding.add_sink(spatialmp4_sink)
	return {
		"writer": writer,
		"frame_sink": binding,
		"spatialmp4_sink": spatialmp4_sink,
		# EgoUploader drains user://ego_upload_queue.json for ego capture
		# only. The sink owns the uploader instance (same queue file / TUS
		# behavior / signals); the scene keeps node lifecycle + UI glue.
		"upload_sink": UploadQueueSink.new(),
	}


## Phase 2: capture lifecycle controller over the phase-1 stack.
## deps:
##   pose_sampler / depth_sampler / body_motion_sampler: configured Nodes
##   permission_check: Callable -> bool (storage readiness)
##   stop_live_pull: Callable (live-pull disconnect, ego mode only)
static func build_controller(io: Dictionary, deps: Dictionary) -> CaptureSessionController:
	var writer_adapter := SpoolWriterAdapter.new(io.get("writer"))
	# Legacy stop order, preserved exactly: body_motion.stop -> live-pull
	# disconnect -> depth.stop -> writer.close (inside the controller).
	var stop_chain: Array = [deps.get("body_motion_sampler")]
	if deps.has("stop_live_pull"):
		stop_chain.append(deps.get("stop_live_pull"))
	stop_chain.append(deps.get("depth_sampler"))
	var controller := CaptureSessionController.new()
	controller.configure({
		"writer_adapter": writer_adapter,
		"permission_check": deps.get("permission_check"),
		"option_samplers": [deps.get("pose_sampler"), deps.get("body_motion_sampler")],
		"stop_chain": stop_chain,
		"live_mode": false,
	})
	return controller


## Provider-capability gating of the requested capture options (moved
## verbatim from capture_app.gd in WP6). Shared by the live-feed mode.
## Vendor-name decisions live behind CaptureProviderRegistry helpers so no
## device-name strings appear at the app layer.
static func effective_capture_options(options: Dictionary, camera_plugin: Object) -> Dictionary:
	var effective := options.duplicate(true)
	if camera_plugin != null:
		var provider_name := CaptureProviderRegistryScript.provider_name(camera_plugin)
		if not provider_name.is_empty():
			effective["capture_provider"] = provider_name
		if not CaptureProviderRegistryScript.supports_depth(camera_plugin):
			effective["record_depth"] = false
		if not CaptureProviderRegistryScript.supports_body_motion(camera_plugin):
			effective["record_body_tracking"] = false
			effective["record_motion_trackers"] = false
		# Motion trackers (PICO XR_PICO_motion_tracking) are PICO-only even
		# when the provider reports body-motion support — Quest's body data
		# comes purely from the Meta vendor AAR's XR_FB_body_tracking +
		# XR_META_body_tracking_full_body extensions, no external trackers.
		if not CaptureProviderRegistryScript.supports_motion_trackers(camera_plugin):
			effective["record_motion_trackers"] = false
		if CaptureProviderRegistryScript.provider_uses_pico_bridge(provider_name) \
				and bool(effective.get("record_body_tracking", false)):
			# PICO full-body capture and independent tracker capture are separate
			# runtime modes. Keep the manifest aligned with the sampler, which
			# must not request independent trackers while body tracking is active.
			effective["record_motion_trackers"] = false
		if not CaptureProviderRegistryScript.provider_supports_audio_capture(provider_name):
			effective["record_audio"] = false
	return effective
