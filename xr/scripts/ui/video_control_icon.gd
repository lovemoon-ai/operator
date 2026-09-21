extends Control
class_name VideoControlIcon

enum Kind { MORE, LOCKED, UNLOCKED }

const COLOR := Color("fff4e6")
const STROKE := 5.0
var _kind: int = Kind.MORE


func set_kind(value: int) -> void:
	_kind = value
	queue_redraw()


func _draw() -> void:
	var center := size * 0.5
	match _kind:
		Kind.MORE:
			for offset in [-18.0, 0.0, 18.0]:
				draw_circle(center + Vector2(offset, 0.0), 5.0, COLOR)
		Kind.LOCKED, Kind.UNLOCKED:
			var body := Rect2(center + Vector2(-20.0, -2.0), Vector2(40.0, 31.0))
			draw_style_box(_lock_body_style(), body)
			var shackle := PackedVector2Array()
			if _kind == Kind.LOCKED:
				shackle = PackedVector2Array([
					center + Vector2(-11.0, -2.0),
					center + Vector2(-11.0, -13.0),
					center + Vector2(-8.0, -21.0),
					center + Vector2(0.0, -25.0),
					center + Vector2(8.0, -21.0),
					center + Vector2(11.0, -13.0),
					center + Vector2(11.0, -2.0),
				])
			else:
				shackle = PackedVector2Array([
					center + Vector2(11.0, -2.0),
					center + Vector2(11.0, -13.0),
					center + Vector2(8.0, -21.0),
					center + Vector2(0.0, -25.0),
					center + Vector2(-8.0, -21.0),
					center + Vector2(-11.0, -15.0),
				])
			draw_polyline(shackle, COLOR, STROKE, true)
			draw_circle(center + Vector2(0.0, 13.0), 3.5, COLOR)


func _lock_body_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color.TRANSPARENT
	style.border_color = COLOR
	style.set_border_width_all(int(STROKE))
	style.set_corner_radius_all(7)
	return style
