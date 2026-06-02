shader_type spatial;
render_mode unshaded, cull_disabled;

// Plan B: YUV path. When `use_yuv` is true the fragment shader samples
// three single-channel textures (Y full size, U/V at half size) and does
// the BT.601 limited-range YUV->RGB conversion on the GPU. When false we
// fall back to the legacy single RGBA texture path used by the placeholder
// and any pre-decoded frames.

uniform bool use_yuv = false;
uniform sampler2D video_texture : source_color, filter_linear;
uniform sampler2D y_texture : hint_default_white, filter_linear;
uniform sampler2D u_texture : hint_default_white, filter_linear;
uniform sampler2D v_texture : hint_default_white, filter_linear;

// How much of the texture width each eye uses (0.5 = side-by-side stereo).
uniform float content_ratio : hint_range(0.0, 1.0) = 0.5;
// Visible portion of each eye's content (for cropping borders).
uniform float visible_ratio : hint_range(0.0, 1.0) = 1.0;
// Whether the input texture is stereo side-by-side or a mono frame.
uniform bool stereo_layout = true;
// Opacity for blending with passthrough.
uniform float opacity : hint_range(0.0, 1.0) = 1.0;


vec3 yuv_to_rgb_bt601(vec3 yuv) {
	// BT.601 limited-range, matching the integer coefficients in the
	// Kotlin CPU path: 298, 409, -100, -208, 516 scaled by 1/256.
	float y = (yuv.x * 255.0 - 16.0) * (298.0 / 256.0);
	float u = yuv.y * 255.0 - 128.0;
	float v = yuv.z * 255.0 - 128.0;
	float r = y + 1.5979 * v;
	float g = y - 0.3917 * u - 0.8129 * v;
	float b = y + 2.0156 * u;
	return clamp(vec3(r, g, b) / 255.0, vec3(0.0), vec3(1.0));
}


void fragment() {
	vec2 uv = UV;

	if (stereo_layout) {
		// VIEW_INDEX: 0 = left eye, 1 = right eye (Godot OpenXR multiview).
		float eye = float(VIEW_INDEX);
		uv.x = uv.x * content_ratio + eye * content_ratio;
	}

	// Apply visible ratio cropping (center crop).
	float margin = (1.0 - visible_ratio) * 0.5;
	uv = uv * visible_ratio + vec2(margin);

	vec3 color;
	if (use_yuv) {
		// Y at full resolution, U/V at half resolution but normalized UVs
		// are the same — bilinear filter on chroma upsamples for free.
		float y_sample = texture(y_texture, uv).r;
		float u_sample = texture(u_texture, uv).r;
		float v_sample = texture(v_texture, uv).r;
		color = yuv_to_rgb_bt601(vec3(y_sample, u_sample, v_sample));
	} else {
		color = texture(video_texture, uv).rgb;
	}

	ALBEDO = color;
	ALPHA = opacity;
}
