extends RefCounted
## Regression contract for the Pico Ego RGB picker. These values mirror the
## two eye-camera capability lists returned by XR_PICO_camera_image on-device.

const CASE_ID := "capture.pico_rgb_resolution_options"
const CapturePanelScript := preload("res://scripts/ui/view_locked_capture_panel.gd")
const EXPECTED_PICO_RESOLUTIONS := [
	Vector2i(2048, 1536),
	Vector2i(1920, 1440),
	Vector2i(1280, 960),
	Vector2i(1024, 768),
	Vector2i(640, 480),
]
const EXPECTED_STEREO_VIDEO_RESOLUTIONS := [
	Vector2i(4096, 1536),
	Vector2i(3840, 1440),
	Vector2i(2560, 960),
	Vector2i(2048, 768),
	Vector2i(1280, 480),
]


func run(_ctx: Dictionary, t: OperatorTestAssertions) -> void:
	var actual: Array = CapturePanelScript.RGB_RESOLUTIONS.get("pico", [])
	t.eq(actual, EXPECTED_PICO_RESOLUTIONS,
		"Pico Ego UI exposes exactly the runtime-supported per-eye resolutions")
	t.eq(actual.size(), 5, "Pico resolution picker contains five entries")
	t.contains(actual, CapturePanelScript.RGB_DEFAULT_RESOLUTION["pico"],
		"Pico default resolution remains one of the supported entries")
	for index in actual.size():
		var resolution_v: Variant = actual[index]
		var resolution := resolution_v as Vector2i
		t.is_true(resolution.x * 3 == resolution.y * 4,
			"Pico resolution is the expected 4:3 per-eye shape: %s" % resolution)
		t.eq(Vector2i(resolution.x * 2, resolution.y), EXPECTED_STEREO_VIDEO_RESOLUTIONS[index],
			"Pico stereo MP4 uses side-by-side width for %s" % resolution)
