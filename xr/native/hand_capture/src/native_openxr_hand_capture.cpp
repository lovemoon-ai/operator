#include "native_openxr_hand_capture.h"
#include "variant_json.h"

#include <android/log.h>
#include <dlfcn.h>
#include <pthread.h>

#include <godot_cpp/classes/open_xrapi_extension.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <array>
#include <chrono>
#include <cinttypes>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <ctime>

namespace godot {
namespace {

constexpr const char *kTag = "Operator-HandCapture";
constexpr int kTrackLeftHand = 3;
constexpr int kTrackRightHand = 4;
constexpr int64_t kSamplePeriodNs = 16'666'667;
constexpr int64_t kSampleDurationUs = 16'667;
constexpr int kPayloadBytes = 8 + XR_HAND_JOINT_COUNT_EXT * 36;

#define HC_LOGI(...) __android_log_print(ANDROID_LOG_INFO, kTag, __VA_ARGS__)
#define HC_LOGW(...) __android_log_print(ANDROID_LOG_WARN, kTag, __VA_ARGS__)
#define HC_LOGE(...) __android_log_print(ANDROID_LOG_ERROR, kTag, __VA_ARGS__)

int64_t timespec_ns(const timespec &p_value) {
	return static_cast<int64_t>(p_value.tv_sec) * 1'000'000'000LL + p_value.tv_nsec;
}

void encode_u16(uint8_t *p_dst, uint16_t p_value) {
	p_dst[0] = static_cast<uint8_t>(p_value);
	p_dst[1] = static_cast<uint8_t>(p_value >> 8);
}

void encode_u32(uint8_t *p_dst, uint32_t p_value) {
	p_dst[0] = static_cast<uint8_t>(p_value);
	p_dst[1] = static_cast<uint8_t>(p_value >> 8);
	p_dst[2] = static_cast<uint8_t>(p_value >> 16);
	p_dst[3] = static_cast<uint8_t>(p_value >> 24);
}

void encode_f32(uint8_t *p_dst, float p_value) {
	std::memcpy(p_dst, &p_value, sizeof(p_value));
}

XrQuaternionf multiply(const XrQuaternionf &p_a, const XrQuaternionf &p_b) {
	return {
		p_a.w * p_b.x + p_a.x * p_b.w + p_a.y * p_b.z - p_a.z * p_b.y,
		p_a.w * p_b.y - p_a.x * p_b.z + p_a.y * p_b.w + p_a.z * p_b.x,
		p_a.w * p_b.z + p_a.x * p_b.y - p_a.y * p_b.x + p_a.z * p_b.w,
		p_a.w * p_b.w - p_a.x * p_b.x - p_a.y * p_b.y - p_a.z * p_b.z,
	};
}

uint16_t godot_hand_flags(XrSpaceLocationFlags p_flags) {
	uint16_t flags = 0;
	if (p_flags & XR_SPACE_LOCATION_ORIENTATION_VALID_BIT) flags |= 1;
	if (p_flags & XR_SPACE_LOCATION_ORIENTATION_TRACKED_BIT) flags |= 2;
	if (p_flags & XR_SPACE_LOCATION_POSITION_VALID_BIT) flags |= 4;
	if (p_flags & XR_SPACE_LOCATION_POSITION_TRACKED_BIT) flags |= 8;
	return flags;
}

void pack_hand(const std::array<XrHandJointLocationEXT, XR_HAND_JOINT_COUNT_EXT> &p_joints,
		std::array<uint8_t, kPayloadBytes> &r_payload) {
	encode_u32(r_payload.data(), 0x544E4A48); // HJNT.
	encode_u16(r_payload.data() + 4, 1);
	encode_u16(r_payload.data() + 6, XR_HAND_JOINT_COUNT_EXT);
	constexpr float sqrt_half = 0.7071067811865475f;
	const XrQuaternionf bone_adjustment{ 0.f, -sqrt_half, sqrt_half, 0.f };
	uint8_t *dst = r_payload.data() + 8;
	for (uint16_t joint_index = 0; joint_index < XR_HAND_JOINT_COUNT_EXT; ++joint_index, dst += 36) {
		const XrHandJointLocationEXT &joint = p_joints[joint_index];
		const XrQuaternionf rotation = multiply(joint.pose.orientation, bone_adjustment);
		encode_u16(dst, joint_index);
		encode_u16(dst + 2, godot_hand_flags(joint.locationFlags));
		encode_f32(dst + 4, joint.radius);
		encode_f32(dst + 8, joint.pose.position.x);
		encode_f32(dst + 12, joint.pose.position.y);
		encode_f32(dst + 16, joint.pose.position.z);
		encode_f32(dst + 20, rotation.x);
		encode_f32(dst + 24, rotation.y);
		encode_f32(dst + 28, rotation.z);
		encode_f32(dst + 32, rotation.w);
	}
}

std::string build_hand_json_line(
		const std::array<XrHandJointLocationEXT, XR_HAND_JOINT_COUNT_EXT> &p_joints,
		int64_t p_timestamp_ns,
		const char *p_hand,
		const String &p_coordinate_space) {
	std::string line;
	line.reserve(8192);
	char head[128];
	std::snprintf(head, sizeof(head),
			"{\"timestamp_ns\":%" PRId64 ",\"hand\":\"%s\",\"coordinate_space\":",
			p_timestamp_ns, p_hand);
	line += head;
	append_json_string(line, p_coordinate_space);
	std::snprintf(head, sizeof(head), ",\"joint_count\":%d,\"joints\":[", XR_HAND_JOINT_COUNT_EXT);
	line += head;
	constexpr float sqrt_half = 0.7071067811865475f;
	const XrQuaternionf bone_adjustment{ 0.f, -sqrt_half, sqrt_half, 0.f };
	for (uint16_t joint_index = 0; joint_index < XR_HAND_JOINT_COUNT_EXT; ++joint_index) {
		if (joint_index > 0) line += ',';
		const XrHandJointLocationEXT &joint = p_joints[joint_index];
		const XrQuaternionf rotation = multiply(joint.pose.orientation, bone_adjustment);
		char prefix[80];
		std::snprintf(prefix, sizeof(prefix),
				"{\"joint\":%u,\"flags\":%u,\"radius_m\":",
				static_cast<unsigned>(joint_index),
				static_cast<unsigned>(godot_hand_flags(joint.locationFlags)));
		line += prefix;
		append_json_float(line, joint.radius);
		line += ",\"position\":{\"x\":";
		append_json_float(line, joint.pose.position.x);
		line += ",\"y\":";
		append_json_float(line, joint.pose.position.y);
		line += ",\"z\":";
		append_json_float(line, joint.pose.position.z);
		line += "},\"rotation\":{\"x\":";
		append_json_float(line, rotation.x);
		line += ",\"y\":";
		append_json_float(line, rotation.y);
		line += ",\"z\":";
		append_json_float(line, rotation.z);
		line += ",\"w\":";
		append_json_float(line, rotation.w);
		line += "}}";
	}
	line += "]}";
	return line;
}

} // namespace

NativeOpenXRHandCapture::NativeOpenXRHandCapture() : OpenXRExtensionWrapperExtension() {
	requested_extensions_[XR_EXT_HAND_TRACKING_EXTENSION_NAME] = &hand_tracking_ext_;
	requested_extensions_[XR_KHR_CONVERT_TIMESPEC_TIME_EXTENSION_NAME] = &convert_timespec_time_ext_;
}

NativeOpenXRHandCapture::~NativeOpenXRHandCapture() {
	stop_recording();
}

void NativeOpenXRHandCapture::_bind_methods() {
	ClassDB::bind_method(D_METHOD("start_recording", "xr_time_to_godot_ns", "hands_jsonl_path", "coordinate_space"),
			&NativeOpenXRHandCapture::start_recording, DEFVAL(0), DEFVAL(String()),
			DEFVAL(String("openxr_play_space")));
	ClassDB::bind_method(D_METHOD("stop_recording"), &NativeOpenXRHandCapture::stop_recording);
	ClassDB::bind_method(D_METHOD("is_recording"), &NativeOpenXRHandCapture::is_recording);
	ClassDB::bind_method(D_METHOD("pop_metrics"), &NativeOpenXRHandCapture::pop_metrics);
	ClassDB::bind_method(D_METHOD("get_last_error"), &NativeOpenXRHandCapture::get_last_error);
}

Dictionary NativeOpenXRHandCapture::_get_requested_extensions() {
	Dictionary extensions;
	for (auto extension : requested_extensions_) {
		extensions[extension.key] = Variant(reinterpret_cast<uint64_t>(extension.value));
	}
	return extensions;
}

void NativeOpenXRHandCapture::_on_instance_created(uint64_t p_instance) {
	instance_ = reinterpret_cast<XrInstance>(p_instance);
	resolve_openxr_functions();
	UtilityFunctions::print("NativeOpenXRHandCapture instance created; XR_EXT_hand_tracking=", hand_tracking_ext_,
			" XR_KHR_convert_timespec_time=", convert_timespec_time_ext_);
}

void NativeOpenXRHandCapture::_on_instance_destroyed() {
	stop_recording();
	instance_ = nullptr;
	session_ = nullptr;
	create_hand_tracker_ = nullptr;
	destroy_hand_tracker_ = nullptr;
	locate_hand_joints_ = nullptr;
	convert_timespec_time_ = nullptr;
}

void NativeOpenXRHandCapture::_on_session_created(uint64_t p_session) {
	session_ = reinterpret_cast<XrSession>(p_session);
}

void NativeOpenXRHandCapture::_on_session_destroyed() {
	stop_recording();
	session_ = nullptr;
}

bool NativeOpenXRHandCapture::resolve_openxr_functions() {
	Ref<OpenXRAPIExtension> api = get_openxr_api();
	if (api.is_null() || instance_ == nullptr || !hand_tracking_ext_ || !convert_timespec_time_ext_) {
		return false;
	}
	create_hand_tracker_ = reinterpret_cast<PFN_xrCreateHandTrackerEXT>(
			api->get_instance_proc_addr("xrCreateHandTrackerEXT"));
	destroy_hand_tracker_ = reinterpret_cast<PFN_xrDestroyHandTrackerEXT>(
			api->get_instance_proc_addr("xrDestroyHandTrackerEXT"));
	locate_hand_joints_ = reinterpret_cast<PFN_xrLocateHandJointsEXT>(
			api->get_instance_proc_addr("xrLocateHandJointsEXT"));
	convert_timespec_time_ = reinterpret_cast<PFN_xrConvertTimespecTimeToTimeKHR>(
			api->get_instance_proc_addr("xrConvertTimespecTimeToTimeKHR"));
	return create_hand_tracker_ && destroy_hand_tracker_ && locate_hand_joints_ && convert_timespec_time_;
}

bool NativeOpenXRHandCapture::resolve_muxer() {
	close_muxer();
	muxer_library_ = dlopen("libspatialmp4_writer.so", RTLD_NOW | RTLD_LOCAL);
	if (muxer_library_ == nullptr) {
		const char *error = dlerror();
		set_error(std::string("dlopen libspatialmp4_writer.so failed: ") + (error ? error : "unknown"));
		return false;
	}
	active_writer_ = reinterpret_cast<ActiveWriterFn>(dlsym(muxer_library_, "spatialmp4_active_writer_available"));
	write_metadata_ = reinterpret_cast<WriteMetadataFn>(dlsym(muxer_library_, "spatialmp4_write_timed_metadata_native"));
	if (!active_writer_ || !write_metadata_) {
		set_error("SpatialMP4 native hand-writer symbols are missing");
		close_muxer();
		return false;
	}
	return true;
}

void NativeOpenXRHandCapture::close_muxer() {
	active_writer_ = nullptr;
	write_metadata_ = nullptr;
	if (muxer_library_ != nullptr) {
		dlclose(muxer_library_);
		muxer_library_ = nullptr;
	}
}

bool NativeOpenXRHandCapture::start_recording(int64_t p_xr_time_to_godot_ns,
		const String &p_hands_jsonl_path,
		const String &p_coordinate_space) {
	stop_recording();
	(void)pop_metrics();
	set_error("");
	Ref<OpenXRAPIExtension> api = get_openxr_api();
	if (instance_ == nullptr || session_ == nullptr || api.is_null() ||
			!resolve_openxr_functions() || api->get_play_space() == 0) {
		set_error("OpenXR hand tracking, timespec conversion, session, or play space is unavailable");
		return false;
	}
	base_space_ = reinterpret_cast<XrSpace>(api->get_play_space());
	coordinate_space_ = p_coordinate_space.is_empty() ? String("openxr_play_space") : p_coordinate_space;
	if (!resolve_muxer() || !active_writer_()) {
		if (get_last_error().is_empty()) set_error("SpatialMP4 writer is not active");
		close_muxer();
		return false;
	}
	if (!p_hands_jsonl_path.is_empty() && !jsonl_.begin(p_hands_jsonl_path)) {
		set_error("failed to open the native hands.jsonl sidecar");
		close_muxer();
		return false;
	}

	for (int hand = 0; hand < 2; ++hand) {
		const XrHandTrackerCreateInfoEXT create_info{
			XR_TYPE_HAND_TRACKER_CREATE_INFO_EXT,
			nullptr,
			hand == 0 ? XR_HAND_LEFT_EXT : XR_HAND_RIGHT_EXT,
			XR_HAND_JOINT_SET_DEFAULT_EXT,
		};
		const XrResult result = create_hand_tracker_(session_, &create_info, &trackers_[hand]);
		if (XR_FAILED(result) || trackers_[hand] == XR_NULL_HAND_TRACKER_EXT) {
			set_error("xrCreateHandTrackerEXT failed for one or more hands");
			destroy_trackers();
			jsonl_.end();
			close_muxer();
			return false;
		}
	}

	xr_time_to_godot_ns_ = p_xr_time_to_godot_ns;
	stop_requested_.store(false, std::memory_order_release);
	running_.store(true, std::memory_order_release);
	worker_ = std::thread(&NativeOpenXRHandCapture::worker_loop, this);
	HC_LOGI("native OpenXR 60 Hz hand recorder started");
	return true;
}

void NativeOpenXRHandCapture::stop_recording() {
	stop_requested_.store(true, std::memory_order_release);
	if (worker_.joinable()) worker_.join();
	running_.store(false, std::memory_order_release);
	jsonl_.end();
	destroy_trackers();
	close_muxer();
	base_space_ = nullptr;
}

void NativeOpenXRHandCapture::destroy_trackers() {
	for (XrHandTrackerEXT &tracker : trackers_) {
		if (tracker != XR_NULL_HAND_TRACKER_EXT && destroy_hand_tracker_ != nullptr) {
			destroy_hand_tracker_(tracker);
		}
		tracker = XR_NULL_HAND_TRACKER_EXT;
	}
}

bool NativeOpenXRHandCapture::is_recording() const {
	return running_.load(std::memory_order_acquire) && !stop_requested_.load(std::memory_order_acquire);
}

Dictionary NativeOpenXRHandCapture::pop_metrics() {
	Dictionary metrics;
	metrics["native_hand_queries_left"] = metric_queries_left_.exchange(0);
	metrics["native_hand_queries_right"] = metric_queries_right_.exchange(0);
	metrics["native_hand_left"] = metric_writes_left_.exchange(0);
	metrics["native_hand_right"] = metric_writes_right_.exchange(0);
	metrics["native_hand_locate_failures"] = metric_locate_failures_.exchange(0);
	metrics["native_hand_inactive_samples"] = metric_inactive_samples_.exchange(0);
	metrics["native_hand_deadline_misses"] = metric_deadline_misses_.exchange(0);
	metrics["native_hand_jsonl_lines"] = static_cast<int64_t>(jsonl_.pop_lines());
	metrics["native_hand_jsonl_dropped"] = static_cast<int64_t>(jsonl_.pop_dropped());
	return metrics;
}

String NativeOpenXRHandCapture::get_last_error() const {
	std::lock_guard<std::mutex> lock(error_mutex_);
	return String::utf8(last_error_.c_str());
}

void NativeOpenXRHandCapture::set_error(const std::string &p_message) {
	std::lock_guard<std::mutex> lock(error_mutex_);
	last_error_ = p_message;
	if (!p_message.empty()) HC_LOGE("%s", p_message.c_str());
}

void NativeOpenXRHandCapture::worker_loop() {
	pthread_setname_np(pthread_self(), "HandCapture60Hz");
	std::array<std::array<XrHandJointLocationEXT, XR_HAND_JOINT_COUNT_EXT>, 2> joints{};
	std::array<std::array<uint8_t, kPayloadBytes>, 2> payloads{};
	auto next_sample = std::chrono::steady_clock::now();
	while (!stop_requested_.load(std::memory_order_acquire)) {
		next_sample += std::chrono::nanoseconds(kSamplePeriodNs);
		timespec sample_time{};
		clock_gettime(CLOCK_MONOTONIC, &sample_time);
		XrTime xr_time = 0;
		const XrResult converted = convert_timespec_time_(instance_, &sample_time, &xr_time);
		if (XR_FAILED(converted)) {
			metric_locate_failures_.fetch_add(1, std::memory_order_relaxed);
			std::this_thread::sleep_until(next_sample);
			continue;
		}
		if (!active_writer_ || !active_writer_()) {
			set_error("SpatialMP4 writer became inactive while recording hands");
			break;
		}
		const int64_t pts_us = (xr_time + xr_time_to_godot_ns_) / 1000;
		const int64_t timestamp_ns = xr_time + xr_time_to_godot_ns_;
		bool metadata_write_failed = false;
		for (int hand = 0; hand < 2; ++hand) {
			(hand == 0 ? metric_queries_left_ : metric_queries_right_).fetch_add(1, std::memory_order_relaxed);
			XrHandJointLocationsEXT locations{
				XR_TYPE_HAND_JOINT_LOCATIONS_EXT, nullptr, XR_FALSE,
				XR_HAND_JOINT_COUNT_EXT, joints[hand].data(),
			};
			const XrHandJointsLocateInfoEXT locate_info{
				XR_TYPE_HAND_JOINTS_LOCATE_INFO_EXT, nullptr, base_space_, xr_time,
			};
			const XrResult located = locate_hand_joints_(trackers_[hand], &locate_info, &locations);
			if (XR_FAILED(located)) {
				metric_locate_failures_.fetch_add(1, std::memory_order_relaxed);
				continue;
			}
			if (!locations.isActive) {
				metric_inactive_samples_.fetch_add(1, std::memory_order_relaxed);
				continue;
			}
			pack_hand(joints[hand], payloads[hand]);
			if (write_metadata_(hand == 0 ? kTrackLeftHand : kTrackRightHand,
					payloads[hand].data(), payloads[hand].size(), pts_us, kSampleDurationUs)) {
				(hand == 0 ? metric_writes_left_ : metric_writes_right_).fetch_add(1, std::memory_order_relaxed);
				if (jsonl_.active()) {
					jsonl_.enqueue(build_hand_json_line(
							joints[hand], timestamp_ns, hand == 0 ? "left" : "right", coordinate_space_));
				}
			} else {
				set_error("SpatialMP4 writer rejected a native hand metadata packet");
				metadata_write_failed = true;
				break;
			}
		}
		if (metadata_write_failed) break;
		std::this_thread::sleep_until(next_sample);
		const auto now = std::chrono::steady_clock::now();
		if (next_sample + std::chrono::milliseconds(50) < now) {
			metric_deadline_misses_.fetch_add(1, std::memory_order_relaxed);
			next_sample = now;
		}
	}
	running_.store(false, std::memory_order_release);
	HC_LOGI("native OpenXR 60 Hz hand recorder stopped");
}

} // namespace godot
