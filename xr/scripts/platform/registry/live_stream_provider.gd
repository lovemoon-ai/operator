class_name LiveStreamProvider
extends RefCounted
## LIVE_STREAM_SERVER provider: wraps the live-push plugin singletons. Probe
## order preserves legacy capture_app behavior (LivePushPlugin first, then the
## older server plugin names exported by previous APKs).

const SINGLETONS := [
	"LivePushPlugin",
	"LiveFeedServerPlugin",
	"LiveCaptureServerPlugin",
]


static func bind() -> Object:
	for singleton_name in SINGLETONS:
		if Engine.has_singleton(singleton_name):
			var plugin := Engine.get_singleton(singleton_name)
			if plugin != null:
				return plugin
	return null


static func is_available() -> bool:
	return bind() != null
