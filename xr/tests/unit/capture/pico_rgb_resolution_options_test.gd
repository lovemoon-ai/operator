extends RefCounted
## Regression contract for capability-driven PICO Ego RGB choices. The two
## fixtures intentionally describe capability shapes rather than products or
## models so future devices exercise the same path without source changes.

const CASE_ID := "capture.pico_rgb_resolution_options"
const CapturePanelScript := preload("res://scripts/ui/view_locked_capture_panel.gd")

const RECTANGULAR_CAPABILITIES := {
	"available": true,
	"stereo_available": true,
	"mono_resolutions": [
		{"width": 2048, "height": 1536},
		{"width": 1280, "height": 960},
		{"width": 640, "height": 480},
	],
	"stereo_resolutions": [
		{"width": 2048, "height": 1536},
		{"width": 1280, "height": 960},
		{"width": 640, "height": 480},
	],
	"fps": [30, 60],
}
const SQUARE_CAPABILITIES := {
	"available": true,
	"stereo_available": true,
	"mono_resolutions": [
		{"width": 1920, "height": 1920},
		{"width": 1280, "height": 1280},
		{"width": 640, "height": 640},
	],
	"stereo_resolutions": [
		{"width": 1920, "height": 1920},
		{"width": 1280, "height": 1280},
		{"width": 640, "height": 640},
	],
	"fps": [30],
}


func run(_ctx: Dictionary, t: OperatorTestAssertions) -> void:
	var panel: Object = CapturePanelScript.new(false)
	panel.set_capture_provider_name("pico")
	var pending_options: Dictionary = CapturePanelScript._default_options()
	pending_options["rgb_width"] = 1280
	pending_options["rgb_height"] = 1280
	pending_options["rgb_resolution"] = "1280x1280"
	panel.set_options(pending_options)
	var pending_normalized: Dictionary = panel.get_options()
	t.eq(str(pending_normalized.get("rgb_resolution", "")), "1280x1280",
		"explicit selection survives until runtime capabilities arrive")

	panel.set_rgb_capabilities(RECTANGULAR_CAPABILITIES)
	t.eq(
		panel._rgb_resolution_choices(),
		[Vector2i(2048, 1536), Vector2i(1280, 960), Vector2i(640, 480)],
		"runtime rectangular capability list is exposed verbatim")

	panel.set_rgb_capabilities(SQUARE_CAPABILITIES)
	t.eq(
		panel._rgb_resolution_choices(),
		[Vector2i(1920, 1920), Vector2i(1280, 1280), Vector2i(640, 640)],
		"runtime square capability list replaces the previous device shape")
	var default_options: Dictionary = CapturePanelScript._default_options()
	panel.set_options(default_options)
	var default_normalized: Dictionary = panel.get_options()
	t.eq(str(default_normalized.get("rgb_resolution", "")), "1920x1920",
		"empty PICO selection defaults to the first runtime resolution")

	var options: Dictionary = CapturePanelScript._default_options()
	options["rgb_width"] = 2048
	options["rgb_height"] = 1536
	options["rgb_resolution"] = "2048x1536"
	panel.set_options(options)
	var normalized: Dictionary = panel.get_options()
	t.eq(int(normalized.get("rgb_width", -1)), 1920,
		"stale unsupported width is reset to the first runtime resolution")
	t.eq(int(normalized.get("rgb_height", -1)), 1920,
		"stale unsupported height is reset to the first runtime resolution")
	t.eq(str(normalized.get("rgb_resolution", "invalid")), "1920x1920",
		"fallback remains capability-driven without a model-specific resolution")

	panel.queue_free()
