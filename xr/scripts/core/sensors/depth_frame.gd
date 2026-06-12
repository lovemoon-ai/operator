class_name DepthFrame
extends RefCounted
## v2 core/sensors (WP4): environment-depth SensorFrame builder.
## Payload shape: {eye, image_path, width, height, metadata, depth_u16_mm}.
## `metadata` is the depth_sampler metadata dict, unchanged; `depth_u16_mm`
## is a PackedByteArray passed by reference (no copy).


static func build(
	timestamp_ns: int,
	eye: String,
	width: int,
	height: int,
	metadata: Dictionary,
	depth_u16_mm: PackedByteArray,
	image_path: String = ""
) -> SensorFrame:
	var frame := SensorFrame.new()
	frame.frame_type = SensorFrameType.DEPTH
	frame.timestamp_ns = timestamp_ns
	frame.source_id = eye
	frame.payload = {
		"eye": eye,
		"image_path": image_path,
		"width": width,
		"height": height,
		"metadata": metadata,
		"depth_u16_mm": depth_u16_mm,
	}
	return frame
