#pragma once

#include "pico_openxr_defs.h"

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <mutex>
#include <string>
#include <thread>

// Android-only native recording hot path used by XR_PICO_camera_image.
//
// Camera thread:
//   OpenXR raw RGBA pointer -> GLES texture -> NDK MediaCodec input Surface.
// The worker never calls Godot Object/Variant APIs.  The only raw-image copy is
// a reusable fallback staging buffer for a non-RGBA/non-contiguous runtime
// layout; the normal RGBA8888 path uploads the runtime pointer directly.
class NativeRecordingPipeline {
public:
	struct Config {
		XrSession session = nullptr;
		XrCameraCaptureSessionPICO left_camera = XR_NULL_CAMERA_CAPTURE_SESSION_PICO;
		XrCameraCaptureSessionPICO right_camera = XR_NULL_CAMERA_CAPTURE_SESSION_PICO;
		bool stereo = true;
		int eye_width = 0;
		int eye_height = 0;
		int fps = 30;
		int bitrate = 8'000'000;
		std::string codec = "hevc";
		int64_t xr_time_to_godot_ns = 0;
		std::string left_frame_index_path;
		std::string right_frame_index_path;

		PFN_xrAcquireCameraImagePICO acquire_camera = nullptr;
		PFN_xrGetCameraImageDataPICO get_camera_data = nullptr;
		PFN_xrReleaseCameraImagePICO release_camera = nullptr;
	};

	struct Metrics {
		int64_t camera_left = 0;
		int64_t camera_right = 0;
		int64_t camera_dropped = 0;
		int64_t staging_copies = 0;
		int64_t encoded_frames = 0;
		int64_t encoded_packets = 0;
	};

	NativeRecordingPipeline() = default;
	~NativeRecordingPipeline();

	bool start(const Config &config);
	void stop();
	bool is_running() const;
	Metrics pop_metrics();
	std::string get_last_error() const;

private:
	void camera_loop();
	void complete_startup(bool success, const std::string &error);
	void fail_runtime(const std::string &error);

	Config config_;
	std::atomic<bool> stop_requested_{ false };
	std::atomic<bool> running_{ false };
	std::thread camera_thread_;
	mutable std::mutex state_mutex_;
	std::condition_variable startup_cv_;
	bool startup_complete_ = false;
	bool startup_success_ = false;
	std::string last_error_;

	std::atomic<int64_t> metric_camera_left_{ 0 };
	std::atomic<int64_t> metric_camera_right_{ 0 };
	std::atomic<int64_t> metric_camera_dropped_{ 0 };
	std::atomic<int64_t> metric_staging_copies_{ 0 };
	std::atomic<int64_t> metric_encoded_frames_{ 0 };
	std::atomic<int64_t> metric_encoded_packets_{ 0 };
};
