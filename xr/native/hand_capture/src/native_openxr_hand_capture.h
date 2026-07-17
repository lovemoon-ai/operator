#pragma once

#include "openxr_hand_defs.h"

#include <godot_cpp/classes/open_xr_extension_wrapper_extension.hpp>
#include <godot_cpp/templates/hash_map.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>

#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <mutex>
#include <string>
#include <thread>

namespace godot {

// Runtime-independent 60 Hz hand recorder.  Unlike NativeHandSampler, this
// class samples XR_EXT_hand_tracking on its own worker clock, so rendering,
// camera acquisition and GDScript stalls cannot lower the MP4 hand rate.
class NativeOpenXRHandCapture : public OpenXRExtensionWrapperExtension {
	GDCLASS(NativeOpenXRHandCapture, OpenXRExtensionWrapperExtension)

public:
	NativeOpenXRHandCapture();
	~NativeOpenXRHandCapture() override;

	Dictionary _get_requested_extensions() override;
	void _on_instance_created(uint64_t p_instance) override;
	void _on_instance_destroyed() override;
	void _on_session_created(uint64_t p_session) override;
	void _on_session_destroyed() override;

		bool start_recording(int64_t p_xr_time_to_godot_ns = 0);
	void stop_recording();
	bool is_recording() const;
	Dictionary pop_metrics();
	String get_last_error() const;

protected:
	static void _bind_methods();

private:
	using ActiveWriterFn = bool (*)();
	using WriteMetadataFn = bool (*)(int, const uint8_t *, size_t, int64_t, int64_t);

	bool resolve_openxr_functions();
	bool resolve_muxer();
	void close_muxer();
	void destroy_trackers();
	void worker_loop();
	void set_error(const std::string &p_message);

	HashMap<String, bool *> requested_extensions_;
	bool hand_tracking_ext_ = false;
	bool convert_timespec_time_ext_ = false;

	XrInstance instance_ = nullptr;
	XrSession session_ = nullptr;
	XrSpace base_space_ = nullptr;
	PFN_xrCreateHandTrackerEXT create_hand_tracker_ = nullptr;
	PFN_xrDestroyHandTrackerEXT destroy_hand_tracker_ = nullptr;
	PFN_xrLocateHandJointsEXT locate_hand_joints_ = nullptr;
	PFN_xrConvertTimespecTimeToTimeKHR convert_timespec_time_ = nullptr;
	std::array<XrHandTrackerEXT, 2> trackers_{ XR_NULL_HAND_TRACKER_EXT, XR_NULL_HAND_TRACKER_EXT };

		void *muxer_library_ = nullptr;
		ActiveWriterFn active_writer_ = nullptr;
		WriteMetadataFn write_metadata_ = nullptr;
		int64_t xr_time_to_godot_ns_ = 0;
	std::atomic<bool> stop_requested_{ false };
	std::atomic<bool> running_{ false };
	std::thread worker_;

	std::atomic<int64_t> metric_queries_left_{ 0 };
	std::atomic<int64_t> metric_queries_right_{ 0 };
	std::atomic<int64_t> metric_writes_left_{ 0 };
	std::atomic<int64_t> metric_writes_right_{ 0 };
	std::atomic<int64_t> metric_locate_failures_{ 0 };
	std::atomic<int64_t> metric_inactive_samples_{ 0 };
	std::atomic<int64_t> metric_deadline_misses_{ 0 };

	mutable std::mutex error_mutex_;
	std::string last_error_;
};

} // namespace godot
