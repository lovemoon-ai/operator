shader_type spatial;
render_mode unshaded, cull_disabled, shadows_disabled, depth_draw_never;

uniform float grid_size = 8.0;
uniform float spacing = 0.5;
uniform float major_every = 5.0;
uniform float line_width = 0.01;
uniform vec4 line_color : source_color = vec4(0.5, 0.58, 0.67, 0.4);
uniform vec4 major_color : source_color = vec4(0.72, 0.81, 0.88, 0.6);
varying vec2 ground_position;

void vertex() {
	ground_position = VERTEX.xz;
}

float grid_lines(vec2 position, float cell_size, float width) {
	vec2 distance_to_line = abs(fract(position / cell_size + 0.5) - 0.5) * cell_size;
	vec2 footprint = max(fwidth(position), vec2(0.00001));
	vec2 coverage = 1.0 - smoothstep(vec2(width * 0.5), vec2(width * 0.5) + footprint, distance_to_line);
	// Subpixel grids fade rather than shimmering into a solid floor at grazing angles.
	coverage *= clamp(vec2(cell_size) / (footprint * 2.0), vec2(0.0), vec2(1.0));
	return max(coverage.x, coverage.y);
}

void fragment() {
	float minor = grid_lines(ground_position, spacing, line_width);
	float major = grid_lines(ground_position, spacing * major_every, line_width * 1.6);
	float edge = max(abs(ground_position.x), abs(ground_position.y)) / (grid_size * 0.5);
	float fade = 1.0 - smoothstep(0.75, 1.0, edge);
	vec4 color = mix(line_color, major_color, major);
	ALBEDO = color.rgb;
	ALPHA = max(minor * line_color.a, major * major_color.a) * fade;
}
