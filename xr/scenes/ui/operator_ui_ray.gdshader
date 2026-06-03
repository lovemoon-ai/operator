shader_type spatial;

render_mode unshaded, blend_mix, depth_prepass_alpha, cull_disabled;

uniform vec4 core_color : source_color = vec4(0.34, 0.88, 1.0, 0.48);
uniform vec4 tip_color : source_color = vec4(0.78, 0.98, 1.0, 0.10);
uniform float laser_length_m = 1.0;
uniform float fade_start = 0.58;
uniform float alpha_multiplier = 1.0;

varying float ray_along;

void vertex() {
	float length_m = max(laser_length_m, 0.001);
	ray_along = clamp(((length_m * 0.5) - VERTEX.z) / length_m, 0.0, 1.0);
}

void fragment() {
	float origin_fade = smoothstep(0.0, 0.10, ray_along);
	float tip_fade = 1.0 - smoothstep(fade_start, 1.0, ray_along);
	float color_mix = smoothstep(0.0, fade_start, ray_along);
	vec3 color = mix(core_color.rgb, tip_color.rgb, color_mix);

	ALBEDO = color;
	EMISSION = color * 0.22;
	ALPHA = core_color.a * origin_fade * tip_fade * alpha_multiplier;
}
