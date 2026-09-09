shader_type spatial;
render_mode unshaded, cull_disabled;

// Plan B: YUV path. When `use_yuv` is true the fragment shader samples
// three single-channel textures (Y full size, U/V at half size) and does
// the configured YUV->RGB conversion on the GPU. When false we
// fall back to the legacy single RGBA texture path used by the placeholder
// and any pre-decoded frames.

uniform bool use_yuv = false;
uniform sampler2D video_texture : source_color, filter_linear;
uniform sampler2D y_texture : hint_default_white, filter_linear;
uniform sampler2D u_texture : hint_default_white, filter_linear;
uniform sampler2D v_texture : hint_default_white, filter_linear;

// 0 = BT.601, 1 = BT.709. Video at 720p and above defaults to BT.709 in
// LiveVideoView; feeds can override this through their descriptor.
uniform int yuv_color_standard = 1;
// false = studio/limited range (Y 16..235, Cb/Cr 16..240), true = full range.
uniform bool yuv_full_range = false;

// How much of the texture width each eye uses (0.5 = side-by-side stereo).
uniform float content_ratio : hint_range(0.0, 1.0) = 0.5;
// Visible portion of each eye's content (for cropping borders).
uniform float visible_ratio : hint_range(0.0, 1.0) = 1.0;
// Whether the input texture is stereo side-by-side or a mono frame.
uniform bool stereo_layout = true;
// Opacity for blending with passthrough.
uniform float opacity : hint_range(0.0, 1.0) = 1.0;


vec3 srgb_to_linear(vec3 color) {
	vec3 low = color / 12.92;
	vec3 high = pow((color + vec3(0.055)) / 1.055, vec3(2.4));
	return mix(high, low, lessThanEqual(color, vec3(0.04045)));
}


vec3 yuv_to_srgb(vec3 yuv) {
	float cb = yuv.y - (128.0 / 255.0);
	float cr = yuv.z - (128.0 / 255.0);
	float y;
	vec3 color;

	if (yuv_full_range) {
		y = yuv.x;
		if (yuv_color_standard == 1) {
			color = vec3(
				y + 1.5748 * cr,
				y - 0.187324 * cb - 0.468124 * cr,
				y + 1.8556 * cb
			);
		} else {
			color = vec3(
				y + 1.402 * cr,
				y - 0.344136 * cb - 0.714136 * cr,
				y + 1.772 * cb
			);
		}
	} else {
		y = (yuv.x - (16.0 / 255.0)) * (255.0 / 219.0);
		if (yuv_color_standard == 1) {
			color = vec3(
				y + 1.792741 * cr,
				y - 0.213249 * cb - 0.532909 * cr,
				y + 2.112402 * cb
			);
		} else {
			color = vec3(
				y + 1.596027 * cr,
				y - 0.391762 * cb - 0.812968 * cr,
				y + 2.017232 * cb
			);
		}
	}

	return clamp(color, vec3(0.0), vec3(1.0));
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
		// YUV matrices produce gamma-encoded RGB. Godot spatial ALBEDO is
		// linear, so convert exactly once here; omitting this conversion makes
		// the renderer encode the signal a second time and visibly washes out
		// mid-tones on PICO.
		color = srgb_to_linear(yuv_to_srgb(vec3(y_sample, u_sample, v_sample)));
	} else {
		color = texture(video_texture, uv).rgb;
	}

	ALBEDO = color;
	ALPHA = opacity;
}
