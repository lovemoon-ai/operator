class_name DepthSource
extends DepthSampler
## Capability layer (components/sources): OpenXR environment depth. The frozen
## DepthSampler owns sampling and timestamping
## (`depth_timestamp_source_priority`); this component adds only the lifecycle
## rule a composition needs: depth may start once the OpenXR session is running
## and the provider has confirmed its permissions, and stops with the session.

var xr_session_active := false


## Starts depth when the OpenXR session is running. Returns false when the
## session is not up yet (the caller retries on session_begun).
func start_when_xr_ready() -> bool:
	if not xr_session_active:
		return false
	start()
	return true


func on_xr_session_begun(should_run: bool) -> void:
	xr_session_active = true
	if should_run:
		start()


func on_xr_session_stopping(should_run: bool) -> void:
	xr_session_active = false
	if should_run:
		stop()
