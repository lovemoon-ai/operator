#include "native_recording_pipeline.h"

#include <android/log.h>
#include <android/native_window.h>
#include <dlfcn.h>
#include <media/NdkMediaCodec.h>
#include <media/NdkMediaFormat.h>

#define EGL_EGLEXT_PROTOTYPES 1
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <ctime>
#include <cstring>
#include <deque>
#include <string>
#include <thread>
#include <vector>

namespace {

constexpr const char *kTag = "Operator-NativeCapture";
constexpr int kColorFormatSurface = 0x7F000789;
constexpr int kAvPacketFlagKey = 0x0001;
// The NDK header in r26c omits the Java MediaCodec key-frame alias.  Bit 0 is
// the stable sync/key-frame flag used by MediaCodec.BufferInfo.
constexpr uint32_t kMediaCodecBufferFlagKeyFrame = 0x0001;
constexpr int kTrackRgbFrameIndexLeft = 9;
constexpr int kTrackRgbFrameIndexRight = 10;
constexpr int64_t kMaxStereoDeltaNs = 20'000'000;
constexpr auto kStartupTimeout = std::chrono::seconds(5);
constexpr auto kRuntimeCameraIdleTimeout = std::chrono::seconds(2);
constexpr auto kRuntimeEncoderIdleTimeout = std::chrono::seconds(2);

#define NC_LOGI(...) __android_log_print(ANDROID_LOG_INFO, kTag, __VA_ARGS__)
#define NC_LOGW(...) __android_log_print(ANDROID_LOG_WARN, kTag, __VA_ARGS__)
#define NC_LOGE(...) __android_log_print(ANDROID_LOG_ERROR, kTag, __VA_ARGS__)

using ActiveWriterFn = bool (*)();
using ConfigureRgbFn = bool (*)(const char *, const uint8_t *, size_t);
using WriteRgbFn = bool (*)(const uint8_t *, size_t, int64_t, int64_t, int);
using WriteMetadataFn = bool (*)(int, const uint8_t *, size_t, int64_t, int64_t);

struct EncodedPacketEvent {
	int64_t pts_us = 0;
};

class NativeMuxerApi {
public:
	~NativeMuxerApi() {
		if (library_) {
			dlclose(library_);
		}
	}

	bool resolve() {
		if (library_) {
			return available_ && configure_rgb_ && write_rgb_ && write_metadata_;
		}
		library_ = dlopen("libspatialmp4_writer.so", RTLD_NOW | RTLD_LOCAL);
		if (!library_) {
			NC_LOGE("dlopen libspatialmp4_writer.so failed: %s", dlerror());
			return false;
		}
		available_ = reinterpret_cast<ActiveWriterFn>(dlsym(library_, "spatialmp4_active_writer_available"));
		configure_rgb_ = reinterpret_cast<ConfigureRgbFn>(dlsym(library_, "spatialmp4_configure_rgb_native"));
		write_rgb_ = reinterpret_cast<WriteRgbFn>(dlsym(library_, "spatialmp4_write_rgb_native"));
		write_metadata_ = reinterpret_cast<WriteMetadataFn>(dlsym(library_, "spatialmp4_write_timed_metadata_native"));
		return available_ && configure_rgb_ && write_rgb_ && write_metadata_;
	}

	bool active() const { return available_ && available_(); }
	bool configure_rgb(const char *codec, const uint8_t *data, size_t size) const {
		return configure_rgb_ && configure_rgb_(codec, data, size);
	}
	bool write_rgb(const uint8_t *data, size_t size, int64_t pts_us, int64_t duration_us, int flags) const {
		return write_rgb_ && write_rgb_(data, size, pts_us, duration_us, flags);
	}
	bool write_metadata(int track, const uint8_t *data, size_t size, int64_t pts_us, int64_t duration_us) const {
		return write_metadata_ && write_metadata_(track, data, size, pts_us, duration_us);
	}

private:
	void *library_ = nullptr;
	ActiveWriterFn available_ = nullptr;
	ConfigureRgbFn configure_rgb_ = nullptr;
	WriteRgbFn write_rgb_ = nullptr;
	WriteMetadataFn write_metadata_ = nullptr;
};

GLuint compile_shader(GLenum type, const char *source) {
	const GLuint shader = glCreateShader(type);
	glShaderSource(shader, 1, &source, nullptr);
	glCompileShader(shader);
	GLint ok = GL_FALSE;
	glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
	if (ok != GL_TRUE) {
		char log[1024]{};
		glGetShaderInfoLog(shader, sizeof(log), nullptr, log);
		NC_LOGE("shader compile failed: %s", log);
		glDeleteShader(shader);
		return 0;
	}
	return shader;
}

GLuint create_program() {
	static constexpr const char *vertex_source = R"(
attribute vec2 aPosition;
attribute vec2 aTexCoord;
varying vec2 vTexCoord;
void main() {
    gl_Position = vec4(aPosition, 0.0, 1.0);
    vTexCoord = aTexCoord;
})";
	static constexpr const char *fragment_source = R"(
precision mediump float;
uniform sampler2D uTexture;
varying vec2 vTexCoord;
void main() {
    gl_FragColor = texture2D(uTexture, vTexCoord);
})";
	const GLuint vs = compile_shader(GL_VERTEX_SHADER, vertex_source);
	const GLuint fs = compile_shader(GL_FRAGMENT_SHADER, fragment_source);
	if (!vs || !fs) {
		if (vs) glDeleteShader(vs);
		if (fs) glDeleteShader(fs);
		return 0;
	}
	const GLuint program = glCreateProgram();
	glAttachShader(program, vs);
	glAttachShader(program, fs);
	glBindAttribLocation(program, 0, "aPosition");
	glBindAttribLocation(program, 1, "aTexCoord");
	glLinkProgram(program);
	glDeleteShader(vs);
	glDeleteShader(fs);
	GLint ok = GL_FALSE;
	glGetProgramiv(program, GL_LINK_STATUS, &ok);
	if (ok != GL_TRUE) {
		char log[1024]{};
		glGetProgramInfoLog(program, sizeof(log), nullptr, log);
		NC_LOGE("program link failed: %s", log);
		glDeleteProgram(program);
		return 0;
	}
	return program;
}

class NativeSurfaceEncoder {
public:
	~NativeSurfaceEncoder() { release(); }

	bool start(int width, int height, int eye_width, int fps, int bitrate, const std::string &codec_name, NativeMuxerApi *muxer) {
		failed_ = false;
		last_error_.clear();
		width_ = width;
		height_ = height;
		eye_width_ = eye_width;
		fps_ = std::max(fps, 1);
		codec_name_ = codec_name == "h264" ? "h264" : "hevc";
		muxer_ = muxer;
		const char *mime = codec_name_ == "h264" ? "video/avc" : "video/hevc";
		codec_ = AMediaCodec_createEncoderByType(mime);
		if (!codec_) {
			NC_LOGE("no NDK MediaCodec encoder for %s", mime);
			return false;
		}
		AMediaFormat *format = AMediaFormat_new();
		AMediaFormat_setString(format, AMEDIAFORMAT_KEY_MIME, mime);
		AMediaFormat_setInt32(format, AMEDIAFORMAT_KEY_WIDTH, width_);
		AMediaFormat_setInt32(format, AMEDIAFORMAT_KEY_HEIGHT, height_);
		AMediaFormat_setInt32(format, AMEDIAFORMAT_KEY_COLOR_FORMAT, kColorFormatSurface);
		AMediaFormat_setInt32(format, AMEDIAFORMAT_KEY_BIT_RATE, std::max(bitrate, 1'000'000));
		AMediaFormat_setInt32(format, AMEDIAFORMAT_KEY_FRAME_RATE, fps_);
		AMediaFormat_setInt32(format, AMEDIAFORMAT_KEY_I_FRAME_INTERVAL, 1);
		AMediaFormat_setInt32(format, AMEDIAFORMAT_KEY_BITRATE_MODE, 1); // VBR.
		AMediaFormat_setInt32(format, AMEDIAFORMAT_KEY_COLOR_STANDARD, 1); // BT.709.
		AMediaFormat_setInt32(format, AMEDIAFORMAT_KEY_COLOR_TRANSFER, 3); // SDR video.
		AMediaFormat_setInt32(format, AMEDIAFORMAT_KEY_COLOR_RANGE, 2); // Limited.
		const media_status_t configured = AMediaCodec_configure(
				codec_, format, nullptr, nullptr, AMEDIACODEC_CONFIGURE_FLAG_ENCODE);
		AMediaFormat_delete(format);
		if (configured != AMEDIA_OK || AMediaCodec_createInputSurface(codec_, &window_) != AMEDIA_OK || !window_) {
			NC_LOGE("NDK MediaCodec configure/input Surface failed status=%d", configured);
			return false;
		}
		if (!setup_egl() || !setup_gl()) {
			return false;
		}
		if (AMediaCodec_start(codec_) != AMEDIA_OK) {
			NC_LOGE("AMediaCodec_start failed");
			return false;
		}
		codec_started_ = true;
		NC_LOGI("native %s Surface encoder started %dx%d@%d bitrate=%d",
				codec_name_.c_str(), width_, height_, fps_, bitrate);
		return true;
	}

	GLuint texture(int eye) const { return textures_[eye == 0 ? 0 : 1]; }

	bool present(bool stereo, int64_t pts_ns) {
		if (!codec_started_ || display_ == EGL_NO_DISPLAY || surface_ == EGL_NO_SURFACE) return false;
		drain(false);
		if (failed_) return false;
		glViewport(0, 0, width_, height_);
		glClearColor(0.f, 0.f, 0.f, 1.f);
		glClear(GL_COLOR_BUFFER_BIT);
		draw_texture(textures_[0], 0, 0, stereo ? width_ / 2 : width_, height_);
		if (stereo) draw_texture(textures_[1], width_ / 2, 0, width_ / 2, height_);
		// Qualcomm's Surface encoder does not reliably preserve very large
		// absolute monotonic timestamps.  Present a session-relative timestamp
		// to EGL, then restore the absolute clock when draining MediaCodec.
		if (source_origin_ns_ < 0) source_origin_ns_ = pts_ns;
		int64_t relative_pts_ns = std::max<int64_t>(0, pts_ns - source_origin_ns_);
		if (relative_pts_ns <= last_relative_pts_ns_) relative_pts_ns = last_relative_pts_ns_ + 1'000;
		last_relative_pts_ns_ = relative_pts_ns;
		eglPresentationTimeANDROID(display_, surface_, relative_pts_ns);
		if (eglSwapBuffers(display_, surface_) != EGL_TRUE) {
			NC_LOGE("eglSwapBuffers failed 0x%x", eglGetError());
			return false;
		}
		drain(false);
		return !failed_;
	}

	bool poll() {
		drain(false);
		return !failed_;
	}

	bool finish() {
		if (!codec_started_) return !failed_;
		drain(false);
		if (failed_) return false;
		if (AMediaCodec_signalEndOfInputStream(codec_) != AMEDIA_OK) {
			failed_ = true;
			last_error_ = "AMediaCodec failed to signal end of input stream";
			return false;
		}
		for (int tries = 0; tries < 100 && !saw_eos_; ++tries) drain(true);
		if (!failed_ && !saw_eos_) {
			failed_ = true;
			last_error_ = "timed out draining the native RGB encoder";
		}
		return !failed_;
	}

	int64_t packets_written() const { return packets_written_; }
	const std::string &last_error() const { return last_error_; }
	bool pop_encoded_packet(EncodedPacketEvent &out) {
		if (encoded_packets_.empty()) return false;
		out = encoded_packets_.front();
		encoded_packets_.pop_front();
		return true;
	}

private:
	bool setup_egl() {
		display_ = eglGetDisplay(EGL_DEFAULT_DISPLAY);
		if (display_ == EGL_NO_DISPLAY || eglInitialize(display_, nullptr, nullptr) != EGL_TRUE) {
			NC_LOGE("eglInitialize failed 0x%x", eglGetError());
			return false;
		}
		const EGLint attrs[] = {
			EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
			EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT_KHR,
			EGL_SURFACE_TYPE, EGL_WINDOW_BIT, EGL_NONE
		};
		EGLint count = 0;
		if (eglChooseConfig(display_, attrs, &egl_config_, 1, &count) != EGL_TRUE || count < 1) {
			NC_LOGE("eglChooseConfig failed 0x%x", eglGetError());
			return false;
		}
		const EGLint context_attrs[] = { EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE };
		context_ = eglCreateContext(display_, egl_config_, EGL_NO_CONTEXT, context_attrs);
		surface_ = eglCreateWindowSurface(display_, egl_config_, window_, nullptr);
		if (context_ == EGL_NO_CONTEXT || surface_ == EGL_NO_SURFACE ||
				eglMakeCurrent(display_, surface_, surface_, context_) != EGL_TRUE) {
			NC_LOGE("EGL context/surface creation failed 0x%x", eglGetError());
			return false;
		}
		return true;
	}

	bool setup_gl() {
		program_ = create_program();
		if (!program_) return false;
		sampler_ = glGetUniformLocation(program_, "uTexture");
		glGenTextures(2, textures_.data());
		for (GLuint texture : textures_) {
			glBindTexture(GL_TEXTURE_2D, texture);
			glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
			glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
			glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
			glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
			glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, eye_width_, height_, 0, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
		}
		glBindTexture(GL_TEXTURE_2D, 0);
		return glGetError() == GL_NO_ERROR;
	}

	void draw_texture(GLuint texture, int x, int y, int width, int height) {
		static constexpr GLfloat vertices[] = { -1.f, -1.f, 1.f, -1.f, -1.f, 1.f, 1.f, 1.f };
		// Vertical flip matches the previous Kotlin GLES encoder and camera metadata.
		static constexpr GLfloat texcoords[] = { 0.f, 1.f, 1.f, 1.f, 0.f, 0.f, 1.f, 0.f };
		glViewport(x, y, width, height);
		glUseProgram(program_);
		glActiveTexture(GL_TEXTURE0);
		glBindTexture(GL_TEXTURE_2D, texture);
		glUniform1i(sampler_, 0);
		glEnableVertexAttribArray(0);
		glEnableVertexAttribArray(1);
		glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, vertices);
		glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 0, texcoords);
		glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
		glDisableVertexAttribArray(0);
		glDisableVertexAttribArray(1);
	}

	void configure_with_csd(const uint8_t *data, size_t size, const char *source) {
		if (rgb_configured_ || failed_ || !muxer_ || !data || size == 0) return;
		rgb_configured_ = muxer_->configure_rgb(codec_name_.c_str(), data, size);
		if (!rgb_configured_) {
			failed_ = true;
			last_error_ = "native muxer rejected " + codec_name_ + " codec configuration from " + source;
			NC_LOGE("native muxer rejected %s CSD from %s (%zu bytes)", codec_name_.c_str(), source, size);
		}
	}

	void configure_from_output_format() {
		if (rgb_configured_ || !codec_ || !muxer_) return;
		AMediaFormat *format = AMediaCodec_getOutputFormat(codec_);
		if (!format) return;
		std::vector<uint8_t> csd;
		for (const char *key : { "csd-0", "csd-1", "csd-2" }) {
			void *data = nullptr;
			size_t size = 0;
			if (AMediaFormat_getBuffer(format, key, &data, &size) && data && size > 0) {
				const auto *bytes = static_cast<const uint8_t *>(data);
				csd.insert(csd.end(), bytes, bytes + size);
			}
		}
		AMediaFormat_delete(format);
		if (!csd.empty()) configure_with_csd(csd.data(), csd.size(), "output format");
	}

	void drain(bool wait) {
		if (!codec_started_ || !codec_) return;
		for (;;) {
			AMediaCodecBufferInfo info{};
			const ssize_t index = AMediaCodec_dequeueOutputBuffer(codec_, &info, wait ? 20'000 : 0);
			if (index == AMEDIACODEC_INFO_TRY_AGAIN_LATER) return;
			if (index == AMEDIACODEC_INFO_OUTPUT_FORMAT_CHANGED) {
				configure_from_output_format();
				continue;
			}
			if (index < 0) continue;
			size_t capacity = 0;
			uint8_t *buffer = AMediaCodec_getOutputBuffer(codec_, static_cast<size_t>(index), &capacity);
			size_t offset = info.offset >= 0 ? static_cast<size_t>(info.offset) : 0;
			const size_t output_size = info.size > 0 ? static_cast<size_t>(info.size) : 0;
			if (offset > capacity || output_size > capacity - offset) {
				failed_ = true;
				last_error_ = "MediaCodec returned an invalid native RGB output buffer range";
			} else if (!buffer && output_size > 0) {
				failed_ = true;
				last_error_ = "MediaCodec returned a null native RGB output buffer";
			} else if (buffer && output_size > 0 && (info.flags & AMEDIACODEC_BUFFER_FLAG_CODEC_CONFIG)) {
				// Some vendor encoders do not expose csd-* on the output format and
				// instead return the complete codec setup as a flagged output buffer.
				configure_with_csd(buffer + offset, output_size, "codec-config buffer");
			} else if (buffer && output_size > 0) {
				if (!rgb_configured_) configure_from_output_format();
				if (!rgb_configured_ && !failed_) {
					failed_ = true;
					last_error_ = "native RGB encoder produced media before codec configuration";
				}
				if (failed_) {
					AMediaCodec_releaseOutputBuffer(codec_, static_cast<size_t>(index), false);
					return;
				}
				const int flags = (info.flags & kMediaCodecBufferFlagKeyFrame) ? kAvPacketFlagKey : 0;
				// Some encoders add a fixed offset to the first output PTS.  Remove it
				// and map the relative codec clock back onto the OpenXR/Godot clock.
				if (codec_output_origin_us_ < 0) codec_output_origin_us_ = info.presentationTimeUs;
				const int64_t relative_pts_us = std::max<int64_t>(0, info.presentationTimeUs - codec_output_origin_us_);
				const int64_t absolute_pts_us = source_origin_ns_ / 1'000 + relative_pts_us;
				if (source_origin_ns_ < 0) {
					failed_ = true;
					last_error_ = "native RGB encoder returned media before the first submitted frame";
				} else if (muxer_->write_rgb(buffer + offset, output_size, absolute_pts_us,
						1'000'000LL / fps_, flags)) {
					packets_written_++;
					encoded_packets_.push_back({ absolute_pts_us });
				} else {
					failed_ = true;
					last_error_ = "native muxer rejected an encoded RGB packet";
				}
			}
			if (info.flags & AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM) saw_eos_ = true;
			AMediaCodec_releaseOutputBuffer(codec_, static_cast<size_t>(index), false);
			if (failed_ || saw_eos_) return;
		}
	}

	void release() {
		if (display_ != EGL_NO_DISPLAY) {
			if (context_ != EGL_NO_CONTEXT && surface_ != EGL_NO_SURFACE) {
				eglMakeCurrent(display_, surface_, surface_, context_);
				if (textures_[0] || textures_[1]) glDeleteTextures(2, textures_.data());
				if (program_) glDeleteProgram(program_);
			}
			eglMakeCurrent(display_, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
			if (surface_ != EGL_NO_SURFACE) eglDestroySurface(display_, surface_);
			if (context_ != EGL_NO_CONTEXT) eglDestroyContext(display_, context_);
			eglReleaseThread();
			eglTerminate(display_);
		}
		if (codec_) {
			if (codec_started_) AMediaCodec_stop(codec_);
			AMediaCodec_delete(codec_);
		}
		if (window_) ANativeWindow_release(window_);
		codec_ = nullptr;
		window_ = nullptr;
		codec_started_ = false;
		display_ = EGL_NO_DISPLAY;
		context_ = EGL_NO_CONTEXT;
		surface_ = EGL_NO_SURFACE;
	}

	AMediaCodec *codec_ = nullptr;
	ANativeWindow *window_ = nullptr;
	bool codec_started_ = false;
	bool rgb_configured_ = false;
	bool saw_eos_ = false;
	bool failed_ = false;
	int width_ = 0;
	int height_ = 0;
	int eye_width_ = 0;
	int fps_ = 30;
	int64_t source_origin_ns_ = -1;
	int64_t last_relative_pts_ns_ = -1;
	int64_t codec_output_origin_us_ = -1;
	int64_t packets_written_ = 0;
	std::deque<EncodedPacketEvent> encoded_packets_;
	std::string codec_name_;
	std::string last_error_;
	NativeMuxerApi *muxer_ = nullptr;
	EGLDisplay display_ = EGL_NO_DISPLAY;
	EGLConfig egl_config_ = nullptr;
	EGLContext context_ = EGL_NO_CONTEXT;
	EGLSurface surface_ = EGL_NO_SURFACE;
	GLuint program_ = 0;
	GLint sampler_ = -1;
	std::array<GLuint, 2> textures_{ 0, 0 };
};

struct UploadedFrame {
	bool updated = false;
	XrTime capture_time = 0;
};

enum class UploadResult { None, Uploaded, Dropped };

class FrameIndexFiles {
public:
	~FrameIndexFiles() { close(); }

	bool open(const NativeRecordingPipeline::Config &config, std::string &error) {
		close();
		if (!config.left_frame_index_path.empty()) {
			left_ = std::fopen(config.left_frame_index_path.c_str(), "w");
			if (!left_) {
				error = "failed to open left camera frame-index sidecar: " + config.left_frame_index_path;
				return false;
			}
		}
		if (config.stereo && !config.right_frame_index_path.empty()) {
			right_ = std::fopen(config.right_frame_index_path.c_str(), "w");
			if (!right_) {
				error = "failed to open right camera frame-index sidecar: " + config.right_frame_index_path;
				close();
				return false;
			}
		}
		return true;
	}

	FILE *for_eye(int eye) const { return eye == 0 ? left_ : right_; }

private:
	void close() {
		if (left_) std::fclose(left_);
		if (right_) std::fclose(right_);
		left_ = nullptr;
		right_ = nullptr;
	}

	FILE *left_ = nullptr;
	FILE *right_ = nullptr;
};

UploadResult acquire_and_upload(
		const NativeRecordingPipeline::Config &config,
		XrCameraCaptureSessionPICO camera,
		XrTime &last_capture_time,
		GLuint texture,
		std::vector<uint8_t> &staging,
		std::atomic<int64_t> &staging_metric,
		UploadedFrame &out) {
	if (!camera) return UploadResult::None;
	XrCameraImageAcquireInfoPICO acquire_info{ XR_TYPE_CAMERA_IMAGE_ACQUIRE_INFO_PICO, nullptr, last_capture_time };
	XrCameraImagePICO image{ XR_TYPE_CAMERA_IMAGE_PICO, nullptr, 0, 0 };
	const XrResult acquired = config.acquire_camera(camera, &acquire_info, &image);
	if (acquired == XR_CAMERA_IMAGE_NO_UPDATE_PICO || XR_FAILED(acquired)) return UploadResult::None;

	XrCameraImageDataRawBufferPICO raw{
		XR_TYPE_CAMERA_IMAGE_DATA_RAW_BUFFER_PICO, nullptr, 0, 0, 0, 0, 0, 0, nullptr
	};
	const XrResult got = config.get_camera_data(
			camera, image.imageId, reinterpret_cast<XrCameraImageDataBaseHeaderPICO *>(&raw));
	UploadResult result = UploadResult::Dropped;
	if (XR_SUCCEEDED(got) && raw.buffer && raw.width == static_cast<uint32_t>(config.eye_width) &&
			raw.height == static_cast<uint32_t>(config.eye_height)) {
		uint32_t pixel_stride = raw.pixelStride ? raw.pixelStride : raw.bytesPerPixel;
		if (!pixel_stride) pixel_stride = 4;
		uint32_t row_stride = raw.stride ? raw.stride : raw.width * pixel_stride;
		const uint64_t required = static_cast<uint64_t>(row_stride) * (raw.height - 1) +
				static_cast<uint64_t>(pixel_stride) * (raw.width - 1) + std::min<uint32_t>(4, raw.bytesPerPixel ? raw.bytesPerPixel : 4);
		if (required <= raw.bufferSize) {
			const uint8_t *pixels = raw.buffer;
			if (pixel_stride != 4 || row_stride % 4 != 0) {
				staging.resize(static_cast<size_t>(raw.width) * raw.height * 4);
				for (uint32_t y = 0; y < raw.height; ++y) {
					for (uint32_t x = 0; x < raw.width; ++x) {
						const uint8_t *src = raw.buffer + static_cast<size_t>(y) * row_stride + static_cast<size_t>(x) * pixel_stride;
						uint8_t *dst = staging.data() + (static_cast<size_t>(y) * raw.width + x) * 4;
						dst[0] = src[0]; dst[1] = src[1]; dst[2] = src[2]; dst[3] = pixel_stride > 3 ? src[3] : 0xff;
					}
				}
				pixels = staging.data();
				row_stride = raw.width * 4;
				staging_metric.fetch_add(1, std::memory_order_relaxed);
			}
			glBindTexture(GL_TEXTURE_2D, texture);
			glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
			glPixelStorei(GL_UNPACK_ROW_LENGTH, static_cast<GLint>(row_stride / 4));
			glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, raw.width, raw.height, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
			glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
			glBindTexture(GL_TEXTURE_2D, 0);
			if (glGetError() == GL_NO_ERROR) {
				last_capture_time = image.captureTime;
				out.updated = true;
				out.capture_time = image.captureTime;
				result = UploadResult::Uploaded;
			}
		}
	}
	// glTexSubImage2D consumes client memory before returning, so the runtime
	// buffer can be released here without a CPU-side PackedByteArray copy.
	config.release_camera(camera, image.imageId);
	return result;
}

bool write_frame_index(NativeMuxerApi &muxer, FILE *sidecar, int eye, int64_t index, XrTime xr_time,
		int64_t godot_time_ns, int64_t encoded_pts_us, int width, int height, int64_t duration_us) {
	char json[512];
	const char *eye_name = eye == 0 ? "left" : "right";
	const int length = std::snprintf(json, sizeof(json),
			"{\"frame_index\":%lld,\"eye\":\"%s\",\"timestamp_ns\":%lld,"
			"\"camera_sensor_timestamp_ns\":%lld,\"sensor_timestamp_source\":\"openxr_clock_monotonic\","
			"\"camera_id\":\"openxr:%s\",\"width\":%d,\"height\":%d,\"raw_path\":\"\",\"planes\":[]}",
			static_cast<long long>(index), eye_name, static_cast<long long>(godot_time_ns),
			static_cast<long long>(xr_time), eye_name, width, height);
	if (length > 0 && static_cast<size_t>(length) < sizeof(json)) {
		const bool muxer_written = muxer.write_metadata(eye == 0 ? kTrackRgbFrameIndexLeft : kTrackRgbFrameIndexRight,
				reinterpret_cast<const uint8_t *>(json), static_cast<size_t>(length), encoded_pts_us, duration_us);
		bool sidecar_written = true;
		if (sidecar) {
			sidecar_written = std::fwrite(json, 1, static_cast<size_t>(length), sidecar) == static_cast<size_t>(length) &&
					std::fputc('\n', sidecar) != EOF && std::fflush(sidecar) == 0;
		}
		return muxer_written && sidecar_written;
	}
	return false;
}

struct PendingFrameIndex {
	bool stereo = false;
	XrTime left_capture_time = 0;
	XrTime right_capture_time = 0;
	int64_t submitted_pts_us = 0;
};

bool flush_encoded_frame_indices(
		NativeSurfaceEncoder &encoder,
		NativeMuxerApi &muxer,
		FrameIndexFiles &files,
		std::deque<PendingFrameIndex> &pending,
		int64_t xr_time_to_godot_ns,
		int width,
		int height,
		int64_t duration_us,
		int64_t &left_index,
		int64_t &right_index,
		int64_t &dropped_submissions,
		int64_t &written_packets,
		std::string &error) {
	EncodedPacketEvent packet;
	while (encoder.pop_encoded_packet(packet)) {
		if (pending.empty()) {
			error = "native RGB encoder produced a packet without a submitted camera frame";
			return false;
		}

		// MediaCodec output PTS is the authoritative link between an accepted
		// input Surface frame and the encoded access unit. Skip any submitted
		// frames the encoder dropped instead of inventing frame-index entries.
		size_t best_index = 0;
		int64_t best_delta = std::llabs(pending.front().submitted_pts_us - packet.pts_us);
		for (size_t i = 1; i < pending.size(); ++i) {
			const int64_t delta = std::llabs(pending[i].submitted_pts_us - packet.pts_us);
			if (delta < best_delta) {
				best_delta = delta;
				best_index = i;
			}
			if (pending[i].submitted_pts_us > packet.pts_us && delta > best_delta) break;
		}
		const int64_t match_tolerance_us = std::max<int64_t>(duration_us * 2, 5'000);
		if (best_delta > match_tolerance_us) {
			error = "native RGB encoded PTS did not match a submitted camera frame";
			return false;
		}
		for (size_t i = 0; i < best_index; ++i) pending.pop_front();
		dropped_submissions += static_cast<int64_t>(best_index);
		const PendingFrameIndex frame = pending.front();
		pending.pop_front();

		const int64_t left_godot_time_ns = frame.left_capture_time + xr_time_to_godot_ns;
		if (!write_frame_index(muxer, files.for_eye(0), 0, left_index, frame.left_capture_time,
				left_godot_time_ns, packet.pts_us, width, height, duration_us)) {
			error = "failed to write native left RGB frame-index metadata or sidecar";
			return false;
		}
		left_index++;
		if (frame.stereo) {
			const int64_t right_godot_time_ns = frame.right_capture_time + xr_time_to_godot_ns;
			if (!write_frame_index(muxer, files.for_eye(1), 1, right_index, frame.right_capture_time,
					right_godot_time_ns, packet.pts_us, width, height, duration_us)) {
				error = "failed to write native right RGB frame-index metadata or sidecar";
				return false;
			}
			right_index++;
		}
		written_packets++;
	}
	return true;
}

} // namespace

NativeRecordingPipeline::~NativeRecordingPipeline() {
	stop();
}

bool NativeRecordingPipeline::start(const Config &config) {
	stop();
	// A stopped worker can leave a final partial metrics interval behind.
	// Do not attribute it to the next recording session.
	(void)pop_metrics();
	if (!config.session || !config.left_camera || config.eye_width <= 0 ||
			config.eye_height <= 0 || !config.acquire_camera || !config.get_camera_data || !config.release_camera ||
			config.left_frame_index_path.empty() || (config.stereo && config.right_frame_index_path.empty())) {
		NC_LOGE("native pipeline rejected incomplete camera/OpenXR config");
		std::lock_guard<std::mutex> lock(state_mutex_);
		last_error_ = "native pipeline rejected incomplete camera/OpenXR config";
		return false;
	}
	config_ = config;
	{
		std::lock_guard<std::mutex> lock(state_mutex_);
		startup_complete_ = false;
		startup_success_ = false;
		last_error_.clear();
	}
	stop_requested_.store(false, std::memory_order_release);
	running_.store(false, std::memory_order_release);
	camera_thread_ = std::thread(&NativeRecordingPipeline::camera_loop, this);
	std::unique_lock<std::mutex> lock(state_mutex_);
	if (!startup_cv_.wait_for(lock, kStartupTimeout, [this]() { return startup_complete_; })) {
		last_error_ = "timed out waiting for native camera encoder startup";
		startup_complete_ = true;
		startup_success_ = false;
		lock.unlock();
		stop_requested_.store(true, std::memory_order_release);
		if (camera_thread_.joinable()) camera_thread_.join();
		NC_LOGE("%s", get_last_error().c_str());
		return false;
	}
	const bool success = startup_success_;
	lock.unlock();
	if (!success && camera_thread_.joinable()) camera_thread_.join();
	return success;
}

void NativeRecordingPipeline::stop() {
	stop_requested_.store(true, std::memory_order_release);
	if (camera_thread_.joinable()) camera_thread_.join();
	running_.store(false, std::memory_order_release);
}

bool NativeRecordingPipeline::is_running() const {
	return running_.load(std::memory_order_acquire) && !stop_requested_.load(std::memory_order_acquire);
}

NativeRecordingPipeline::Metrics NativeRecordingPipeline::pop_metrics() {
	Metrics out;
	out.camera_left = metric_camera_left_.exchange(0);
	out.camera_right = metric_camera_right_.exchange(0);
	out.camera_dropped = metric_camera_dropped_.exchange(0);
	out.staging_copies = metric_staging_copies_.exchange(0);
	out.encoded_frames = metric_encoded_frames_.exchange(0);
	out.encoded_packets = metric_encoded_packets_.exchange(0);
	return out;
}

std::string NativeRecordingPipeline::get_last_error() const {
	std::lock_guard<std::mutex> lock(state_mutex_);
	return last_error_;
}

void NativeRecordingPipeline::complete_startup(bool success, const std::string &error) {
	{
		std::lock_guard<std::mutex> lock(state_mutex_);
		if (startup_complete_) return;
		startup_success_ = success;
		startup_complete_ = true;
		if (!error.empty()) last_error_ = error;
	}
	startup_cv_.notify_all();
}

void NativeRecordingPipeline::fail_runtime(const std::string &error) {
	{
		std::lock_guard<std::mutex> lock(state_mutex_);
		last_error_ = error;
	}
	running_.store(false, std::memory_order_release);
	NC_LOGE("%s", error.c_str());
}

void NativeRecordingPipeline::camera_loop() {
	NativeMuxerApi muxer;
	if (!muxer.resolve() || !muxer.active()) {
		complete_startup(false, "native camera worker started without an active SpatialMP4 writer");
		return;
	}
	NativeSurfaceEncoder encoder;
	const int encoded_width = config_.stereo ? config_.eye_width * 2 : config_.eye_width;
	if (!encoder.start(encoded_width, config_.eye_height, config_.eye_width, config_.fps, config_.bitrate, config_.codec, &muxer)) {
		complete_startup(false, "native camera encoder initialization failed");
		return;
	}
	FrameIndexFiles frame_index_files;
	std::string sidecar_error;
	if (!frame_index_files.open(config_, sidecar_error)) {
		complete_startup(false, sidecar_error);
		return;
	}
	running_.store(true, std::memory_order_release);

	XrTime left_last = 0;
	XrTime right_last = 0;
	UploadedFrame left;
	UploadedFrame right;
	std::vector<uint8_t> left_staging;
	std::vector<uint8_t> right_staging;
	int64_t left_index = 0;
	int64_t right_index = 0;
	const int64_t duration_us = 1'000'000LL / std::max(config_.fps, 1);
	int64_t reported_packets = 0;
	std::deque<PendingFrameIndex> pending_indices;
	bool startup_signaled = false;
	bool pipeline_failed = false;
	auto last_camera_activity = std::chrono::steady_clock::now();
	auto last_packet_activity = last_camera_activity;

	auto report_failure = [&](const std::string &error) {
		pipeline_failed = true;
		if (!startup_signaled) {
			complete_startup(false, error);
		} else {
			fail_runtime(error);
		}
	};
	auto process_encoded_packets = [&]() -> bool {
		int64_t dropped_submissions = 0;
		int64_t written_packets = 0;
		std::string error;
		if (!flush_encoded_frame_indices(encoder, muxer, frame_index_files, pending_indices,
				config_.xr_time_to_godot_ns, config_.eye_width, config_.eye_height, duration_us,
				left_index, right_index, dropped_submissions, written_packets, error)) {
			report_failure(error);
			return false;
		}
		if (dropped_submissions > 0) {
			metric_camera_dropped_.fetch_add(dropped_submissions, std::memory_order_relaxed);
		}
		const int64_t packets = encoder.packets_written();
		if (packets > reported_packets) {
			metric_encoded_packets_.fetch_add(packets - reported_packets, std::memory_order_relaxed);
			reported_packets = packets;
		}
		if (written_packets > 0) {
			last_packet_activity = std::chrono::steady_clock::now();
			if (!startup_signaled) {
				startup_signaled = true;
				complete_startup(true, "");
				NC_LOGI("native camera startup confirmed after first encoded RGB packet and frame index");
			}
		}
		return true;
	};

	while (!stop_requested_.load(std::memory_order_acquire)) {
		if (!muxer.active()) {
			report_failure("SpatialMP4 writer became inactive while native camera recording was running");
			break;
		}
		bool did_work = false;
		const UploadResult left_result = acquire_and_upload(config_, config_.left_camera, left_last,
				encoder.texture(0), left_staging, metric_staging_copies_, left);
		if (left_result == UploadResult::Uploaded) {
			did_work = true;
			last_camera_activity = std::chrono::steady_clock::now();
			metric_camera_left_.fetch_add(1, std::memory_order_relaxed);
		} else if (left_result == UploadResult::Dropped) {
			metric_camera_dropped_.fetch_add(1, std::memory_order_relaxed);
		}

		if (config_.stereo) {
			const UploadResult right_result = acquire_and_upload(config_, config_.right_camera, right_last,
					encoder.texture(1), right_staging, metric_staging_copies_, right);
			if (right_result == UploadResult::Uploaded) {
				did_work = true;
				last_camera_activity = std::chrono::steady_clock::now();
				metric_camera_right_.fetch_add(1, std::memory_order_relaxed);
			} else if (right_result == UploadResult::Dropped) {
				metric_camera_dropped_.fetch_add(1, std::memory_order_relaxed);
			}
			if (left.updated && right.updated) {
				const int64_t delta = std::llabs(left.capture_time - right.capture_time);
				if (delta <= kMaxStereoDeltaNs) {
					const int64_t pts = std::min(left.capture_time, right.capture_time) + config_.xr_time_to_godot_ns;
					if (!encoder.present(true, pts)) {
						report_failure(encoder.last_error().empty()
								? "native camera encoder failed to present a stereo frame"
								: encoder.last_error());
						break;
					}
					metric_encoded_frames_.fetch_add(1, std::memory_order_relaxed);
					pending_indices.push_back({ true, left.capture_time, right.capture_time, pts / 1'000 });
					left.updated = false;
					right.updated = false;
					if (!process_encoded_packets()) break;
				} else if (left.capture_time < right.capture_time) {
					left.updated = false;
					metric_camera_dropped_.fetch_add(1, std::memory_order_relaxed);
				} else {
					right.updated = false;
					metric_camera_dropped_.fetch_add(1, std::memory_order_relaxed);
				}
			}
		} else if (left.updated) {
			const int64_t pts = left.capture_time + config_.xr_time_to_godot_ns;
			if (!encoder.present(false, pts)) {
				report_failure(encoder.last_error().empty()
						? "native camera encoder failed to present a mono frame"
						: encoder.last_error());
				break;
			}
			metric_encoded_frames_.fetch_add(1, std::memory_order_relaxed);
			pending_indices.push_back({ false, left.capture_time, 0, pts / 1'000 });
			left.updated = false;
			if (!process_encoded_packets()) break;
		}
		if (!encoder.poll()) {
			report_failure(encoder.last_error().empty()
					? "native RGB encoder failed while draining output"
					: encoder.last_error());
			break;
		}
		if (!process_encoded_packets()) break;
		const auto now = std::chrono::steady_clock::now();
		if (startup_signaled && now - last_camera_activity > kRuntimeCameraIdleTimeout) {
			report_failure("native OpenXR camera produced no frames for 2 seconds");
			break;
		}
		if (startup_signaled && now - last_packet_activity > kRuntimeEncoderIdleTimeout) {
			report_failure("native RGB encoder produced no packets for 2 seconds");
			break;
		}
		if (!did_work) std::this_thread::sleep_for(std::chrono::milliseconds(1));
	}
	const bool finish_ok = encoder.finish();
	if (finish_ok || encoder.packets_written() > reported_packets) {
		(void)process_encoded_packets();
	}
	if (!finish_ok && !pipeline_failed) {
		report_failure(encoder.last_error().empty()
				? "native RGB encoder failed while finalizing"
				: encoder.last_error());
	}
	if (!pending_indices.empty()) {
		metric_camera_dropped_.fetch_add(static_cast<int64_t>(pending_indices.size()), std::memory_order_relaxed);
	}
	if (!startup_signaled && !pipeline_failed) {
		const std::string existing_error = get_last_error();
		complete_startup(false, existing_error.empty()
				? "native camera stopped before its first encoded RGB packet"
				: existing_error);
	}
	running_.store(false, std::memory_order_release);
	NC_LOGI("native camera worker stopped");
}
