# Live Video

`addons/live_video` is a reusable Godot plugin for showing low-latency H.264 live video on a 3D quad.

## What It Provides

- `LiveVideoView` custom node and `live_video_view.tscn`.
- Annex-B H.264 access-unit submission via `submit_h264_access_unit()`.
- Operator packet compatibility via `report_video_packet()`.
- Android MediaCodec integration through the `KotlinVideoDecoderPlugin` singleton.
- AHB, YUV-plane, and RGBA presentation paths using `stereo_display.gdshader`.
- A bounded compressed-frame queue plus a latest-frame mailbox. Queue overflow
  flushes stale decoder work and resumes from the next random-access frame,
  while the render thread uploads at most one newest decoded frame per tick.
- Stage telemetry for received, decoded, uploaded, and actually drawn frames,
  including rendered-frame interval P50/P95 and decoder input queue depth.

## Basic Use

Enable `res://addons/live_video/plugin.cfg`, instance `res://addons/live_video/live_video_view.tscn`, then configure and feed H.264:

```gdscript
var view: LiveVideoView = $LiveVideoView

func _ready() -> void:
	view.initialize()
	view.configure_h264_stream(1280, 720, false)

func _on_access_unit(access_unit: PackedByteArray) -> void:
	view.submit_h264_access_unit(access_unit)
```

`configure_video_stream()` also accepts `color_standard` (`auto`, `bt601`, or
`bt709`) and `color_range` (`limited` or `full`). `auto` selects BT.709 at 720p
and above, otherwise BT.601. The default range is limited. YUV output is
converted from gamma-encoded video RGB into Godot's linear lighting space
before being written to `ALBEDO`.

For Operator receivers, keep sending packet dictionaries to `report_video_packet(packet)`.

## RTSP

The Godot plugin does not open RTSP URLs directly. It expects Annex-B H.264 access units. RTSP is supported through the existing `robot/crates/xr-bridge` relay: RTSP input is pulled by ffmpeg, converted to Annex-B H.264, and republished over the existing TCP/UDP XR video protocol that `LiveVideoView.report_video_packet()` consumes.

Direct RTSP inside this plugin would require a new source adapter, likely an Android native/Kotlin RTSP client or an ffmpeg/GStreamer integration that emits Annex-B H.264 access units into `submit_h264_access_unit()`.
