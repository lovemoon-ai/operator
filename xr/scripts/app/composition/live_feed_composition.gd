class_name LiveFeedComposition
extends RefCounted
## v2 app/composition (WP6): composition root for the live-feed mode.
##
## Camera + pose (+ optional depth, gated by provider support at the
## options level) routed into LiveStreamSink over the LivePushWriter
## engine. Low-latency options (`Live feed push connected:` markers, ack
## behavior) stay inside the wrapped writer/plugin unchanged.

const LivePushWriterScript := preload("res://addons/live-push/live_push_writer.gd")


## Phase 1: writer engine + sink + canonical-frame fanout.
## Returns {writer, frame_sink, live_stream_sink}.
static func build_io(server_host: String, server_port: int, auth_token: String) -> Dictionary:
	var writer: Object = LivePushWriterScript.new()
	writer.configure_server(server_host, server_port, auth_token)
	var live_sink := LiveStreamSink.new(writer)
	var binding := StreamBinding.new()
	binding.add_sink(live_sink)
	return {
		"writer": writer,
		"frame_sink": binding,
		"live_stream_sink": live_sink,
	}


## Phase 2: capture lifecycle controller. Live mode has no local
## live-pull disconnect step in the stop chain.
static func build_controller(io: Dictionary, deps: Dictionary) -> CaptureSessionController:
	var writer_adapter := LiveWriterAdapter.new(io.get("writer"))
	var stop_chain: Array = [deps.get("body_motion_sampler"), deps.get("depth_sampler")]
	var controller := CaptureSessionController.new()
	controller.configure({
		"writer_adapter": writer_adapter,
		"permission_check": deps.get("permission_check"),
		"option_samplers": [deps.get("pose_sampler"), deps.get("body_motion_sampler")],
		"stop_chain": stop_chain,
		"live_mode": true,
	})
	return controller
