#include "pico_openxr_extension.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/quaternion.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <algorithm>
#include <chrono>
#include <cstring>
#include <cmath>
#include <limits>
#include <thread>
#include <vector>

using namespace godot;

namespace {

bool dict_bool(const Dictionary &dict, const String &key, bool fallback = false) {
	return dict.has(key) ? bool(dict[key]) : fallback;
}

float dict_float(const Dictionary &dict, const String &key, float fallback = 0.0f) {
	return dict.has(key) ? float(dict[key]) : fallback;
}

int64_t tracker_id_to_variant(XrMotionTrackerIdPICO tracker_id) {
	return static_cast<int64_t>(tracker_id);
}

Quaternion quaternion_from_xr(const XrQuaternionf &value) {
	const double length_sq =
			double(value.x) * double(value.x) +
			double(value.y) * double(value.y) +
			double(value.z) * double(value.z) +
			double(value.w) * double(value.w);
	if (!std::isfinite(length_sq) || length_sq <= 1e-8) {
		return Quaternion(0.0, 0.0, 0.0, 1.0);
	}
	const double inv_length = 1.0 / std::sqrt(length_sq);
	return Quaternion(
			real_t(double(value.x) * inv_length),
			real_t(double(value.y) * inv_length),
			real_t(double(value.z) * inv_length),
			real_t(double(value.w) * inv_length));
}

template <typename T>
bool contains_value(const std::vector<T> &values, T target) {
	return std::find(values.begin(), values.end(), target) != values.end();
}

int camera_fps_to_int(XrCameraImageFpsPICO fps) {
	return fps == XR_CAMERA_IMAGE_FPS_60_PICO ? 60 : 30;
}

} // namespace

PicoOpenXRExtension::PicoOpenXRExtension() :
		OpenXRExtensionWrapperExtension() {
	request_extensions[XR_EXT_FUTURE_EXTENSION_NAME] = &future_ext;
	request_extensions[XR_PICO_CAMERA_IMAGE_EXTENSION_NAME] = &camera_image_ext;
	request_extensions[XR_PICO_MOTION_TRACKING_EXTENSION_NAME] = &motion_tracking_ext;
	request_extensions[XR_PICO_BODY_TRACKING2_EXTENSION_NAME] = &pico_body_tracking2_ext;
	request_extensions[XR_BD_BODY_TRACKING_EXTENSION_NAME] = &bd_body_tracking_ext;
}

PicoOpenXRExtension::~PicoOpenXRExtension() {
	stop_camera_image_capture();
	destroy_body_tracker();
}

void PicoOpenXRExtension::_bind_methods() {
	ClassDB::bind_method(D_METHOD("get_status"), &PicoOpenXRExtension::get_status);
	ClassDB::bind_method(D_METHOD("get_external_camera_info"), &PicoOpenXRExtension::get_external_camera_info);
	ClassDB::bind_method(D_METHOD("start_camera_image_capture", "stereo", "width", "height", "fps"), &PicoOpenXRExtension::start_camera_image_capture, DEFVAL(true), DEFVAL(640), DEFVAL(480), DEFVAL(30));
	ClassDB::bind_method(D_METHOD("poll_camera_image_frames"), &PicoOpenXRExtension::poll_camera_image_frames);
	ClassDB::bind_method(D_METHOD("stop_camera_image_capture"), &PicoOpenXRExtension::stop_camera_image_capture);
	ClassDB::bind_method(D_METHOD("get_camera_image_info"), &PicoOpenXRExtension::get_camera_image_info);
	ClassDB::bind_method(D_METHOD("request_motion_trackers", "count"), &PicoOpenXRExtension::request_motion_trackers);
	ClassDB::bind_method(D_METHOD("sample_motion_trackers", "max_count"), &PicoOpenXRExtension::sample_motion_trackers);
	ClassDB::bind_method(D_METHOD("start_body_tracking", "bone_lengths"), &PicoOpenXRExtension::start_body_tracking, DEFVAL(Dictionary()));
	ClassDB::bind_method(D_METHOD("stop_body_tracking"), &PicoOpenXRExtension::stop_body_tracking);
	ClassDB::bind_method(D_METHOD("start_body_tracking_calibration_app"), &PicoOpenXRExtension::start_body_tracking_calibration_app);
	ClassDB::bind_method(D_METHOD("sample_body_joints"), &PicoOpenXRExtension::sample_body_joints);
}

Dictionary PicoOpenXRExtension::_get_requested_extensions() {
	Dictionary result;
	for (auto ext : request_extensions) {
		result[ext.key] = Variant(reinterpret_cast<uint64_t>(ext.value));
	}
	UtilityFunctions::print("PicoOpenXRExtension requested OpenXR extensions: ", result.keys());
	return result;
}

uint64_t PicoOpenXRExtension::_set_system_properties_and_get_next_pointer(void *next_pointer) {
	if (bd_body_tracking_ext) {
		system_body_tracking_properties.next = next_pointer;
		next_pointer = &system_body_tracking_properties;
	}
	return reinterpret_cast<uint64_t>(next_pointer);
}

void PicoOpenXRExtension::_on_instance_created(uint64_t p_instance) {
	instance = reinterpret_cast<XrInstance>(p_instance);
	function_resolution_attempted = false;
	resolve_functions();
	UtilityFunctions::print("PicoOpenXRExtension instance created; XR_EXT_future=", future_ext,
			" XR_PICO_camera_image=", camera_image_ext,
			" XR_PICO_motion_tracking=", motion_tracking_ext,
			" XR_PICO_body_tracking2=", pico_body_tracking2_ext,
			" XR_BD_body_tracking=", bd_body_tracking_ext);
}

void PicoOpenXRExtension::_on_instance_destroyed() {
	stop_camera_image_capture();
	destroy_body_tracker();
	instance = nullptr;
	session = nullptr;
	function_resolution_attempted = false;
	xrGetExternalCameraInfoPICO_ptr = nullptr;
	xrPollFutureEXT_ptr = nullptr;
	xrEnumerateAvailableCamerasPICO_ptr = nullptr;
	xrEnumerateCameraPropertyTypesPICO_ptr = nullptr;
	xrGetCameraPropertiesPICO_ptr = nullptr;
	xrEnumerateCameraCapabilityTypesPICO_ptr = nullptr;
	xrGetCameraSupportedCapabilitiesPICO_ptr = nullptr;
	xrCreateCameraDeviceAsyncPICO_ptr = nullptr;
	xrCreateCameraDeviceCompletePICO_ptr = nullptr;
	xrDestroyCameraDevicePICO_ptr = nullptr;
	xrCreateCameraCaptureSessionAsyncPICO_ptr = nullptr;
	xrCreateCameraCaptureSessionCompletePICO_ptr = nullptr;
	xrDestroyCameraCaptureSessionPICO_ptr = nullptr;
	xrGetCameraIntrinsicsPICO_ptr = nullptr;
	xrGetCameraExtrinsicsPICO_ptr = nullptr;
	xrBeginCameraCapturePICO_ptr = nullptr;
	xrEndCameraCapturePICO_ptr = nullptr;
	xrAcquireCameraImagePICO_ptr = nullptr;
	xrGetCameraImageDataPICO_ptr = nullptr;
	xrReleaseCameraImagePICO_ptr = nullptr;
	xrRequestMotionTrackerDevicePICO_ptr = nullptr;
	xrGetMotionTrackerBatteryStatePICO_ptr = nullptr;
	xrLocateMotionTrackerPICO_ptr = nullptr;
	xrCreateBodyTrackerBD_ptr = nullptr;
	xrDestroyBodyTrackerBD_ptr = nullptr;
	xrLocateBodyJointsBD_ptr = nullptr;
	xrStartBodyTrackingCalibrationAppPICO_ptr = nullptr;
	xrGetBodyTrackingStatePICO_ptr = nullptr;
}

void PicoOpenXRExtension::_on_session_created(uint64_t p_session) {
	session = reinterpret_cast<XrSession>(p_session);
	UtilityFunctions::print("PicoOpenXRExtension session created");
	refresh_external_camera_info();
	if (motion_tracking_ext && requested_motion_tracker_count > 0) {
		request_motion_trackers(requested_motion_tracker_count);
	}
}

void PicoOpenXRExtension::_on_session_destroyed() {
	stop_camera_image_capture();
	destroy_body_tracker();
	session = nullptr;
	motion_tracker_ids.clear();
	motion_request_sent = false;
}

bool PicoOpenXRExtension::_on_event_polled(const void *event) {
	if (!event || !motion_tracking_ext) {
		return false;
	}
	const XrStructureType type = *reinterpret_cast<const XrStructureType *>(event);
	if (type == XR_TYPE_EVENT_DATA_REQUEST_MOTION_TRACKER_COMPLETE_PICO) {
		const auto *complete = reinterpret_cast<const XrEventDataRequestMotionTrackerCompletePICO *>(event);
		last_motion_request_result = complete->result;
		if (XR_SUCCEEDED(complete->result)) {
			motion_tracker_ids.clear();
			const uint32_t count = std::min<uint32_t>(complete->trackerCount, XR_MOTION_TRACKER_MAX_SIZE_PICO);
			for (uint32_t i = 0; i < count; ++i) {
				add_motion_tracker_id(complete->trackerIds[i]);
			}
		}
		return true;
	}
	if (type == XR_TYPE_EVENT_DATA_MOTION_TRACKER_CONNECTION_STATE_CHANGED_PICO) {
		const auto *changed = reinterpret_cast<const XrEventDataMotionTrackerConnectionStateChangedPICO *>(event);
		if (changed->state == XR_MOTION_TRACKER_CONNECTION_STATE_CONNECTED_PICO) {
			add_motion_tracker_id(changed->trackerId);
		} else {
			remove_motion_tracker_id(changed->trackerId);
		}
		return true;
	}
	if (type == XR_TYPE_EVENT_DATA_MOTION_TRACKER_POWER_KEY_EVENT_PICO) {
		const auto *power_key = reinterpret_cast<const XrEventDataMotionTrackerPowerKeyEventPICO *>(event);
		Dictionary record;
		record["id"] = tracker_id_to_variant(power_key->trackerId);
		record["is_long_click"] = power_key->isLongClick == XR_TRUE;
		last_motion_power_key_event = record;
		return true;
	}
	return false;
}

Dictionary PicoOpenXRExtension::get_status() const {
	Dictionary status;
	status["external_camera_extension"] = external_camera_ext;
	status["future_extension"] = future_ext;
	status["camera_image_extension"] = camera_image_ext;
	status["motion_tracking_extension"] = motion_tracking_ext;
	status["pico_body_tracking2_extension"] = pico_body_tracking2_ext;
	status["bd_body_tracking_extension"] = bd_body_tracking_ext;
	status["bd_body_tracking_supported"] = system_body_tracking_properties.supportsBodyTracking == XR_TRUE;
	status["session_created"] = session != nullptr;
	status["camera_image_active"] = camera_image_capture_active;
	status["camera_image_stereo"] = camera_image_stereo;
	status["camera_image_width"] = camera_image_width;
	status["camera_image_height"] = camera_image_height;
	status["camera_image_fps"] = camera_image_fps;
	status["body_tracker_created"] = body_tracker != XR_NULL_BODY_TRACKER_BD;
	status["motion_tracker_count"] = motion_tracker_ids.size();
	status["motion_request_sent"] = motion_request_sent;
	status["requested_motion_tracker_count"] = requested_motion_tracker_count;
	status["last_external_camera_result"] = last_external_camera_result;
	status["last_camera_image_result"] = last_camera_image_result;
	status["last_motion_request_result"] = last_motion_request_result;
	status["last_body_create_result"] = last_body_create_result;
	status["last_body_state_result"] = last_body_state_result;
	status["last_body_locate_result"] = last_body_locate_result;
	status["last_motion_power_key_event"] = last_motion_power_key_event;
	return status;
}

Dictionary PicoOpenXRExtension::get_external_camera_info() {
	if (cached_external_camera_info.is_empty()) {
		refresh_external_camera_info();
	}
	return cached_external_camera_info.duplicate(true);
}

Dictionary PicoOpenXRExtension::start_camera_image_capture(bool stereo, int width, int height, int fps) {
	stop_camera_image_capture();
	last_camera_image_result = XR_SUCCESS;
	cached_camera_image_info.clear();
	camera_image_stereo = stereo;
	const int preferred_width = width > 0 ? std::clamp(width, 2, 4096) : 0;
	const int preferred_height = height > 0 ? std::clamp(height, 2, 4096) : 0;
	const int preferred_fps = fps >= 60 ? 60 : 30;
	camera_image_width = preferred_width;
	camera_image_height = preferred_height;
	camera_image_fps = preferred_fps;

	Dictionary result;
	result["extension"] = XR_PICO_CAMERA_IMAGE_EXTENSION_NAME;
	result["supported"] = camera_image_ext;
	result["future_supported"] = future_ext;
	result["session_created"] = current_session() != nullptr;
	result["active"] = false;
	result["requested_width"] = preferred_width;
	result["requested_height"] = preferred_height;
	result["requested_fps"] = preferred_fps;
	result["stereo"] = camera_image_stereo;

	if (!resolve_functions() || !current_session() || !instance || !has_camera_image_functions()) {
		last_camera_image_result = XR_ERROR_HANDLE_INVALID;
		result["result"] = last_camera_image_result;
		cached_camera_image_info = result;
		return result;
	}
	refresh_camera_image_camera_ids();

	CameraImageCaptureConfig left_config;
	if (!select_camera_image_config(camera_left.camera_id, preferred_width, preferred_height, preferred_fps, left_config)) {
		result["result"] = last_camera_image_result;
		cached_camera_image_info = result;
		return result;
	}
	camera_image_width = left_config.resolution.width;
	camera_image_height = left_config.resolution.height;
	camera_image_fps = camera_fps_to_int(left_config.fps);
	result["width"] = camera_image_width;
	result["height"] = camera_image_height;
	result["fps"] = camera_image_fps;

	if (!start_camera_image_eye(camera_left, left_config)) {
		stop_camera_image_capture();
		result["result"] = last_camera_image_result;
		cached_camera_image_info = result;
		return result;
	}
	if (camera_image_stereo) {
		CameraImageCaptureConfig right_config;
		if (!select_camera_image_config(camera_right.camera_id, camera_image_width, camera_image_height, camera_image_fps, right_config)) {
			stop_camera_image_capture();
			result["result"] = last_camera_image_result;
			cached_camera_image_info = result;
			return result;
		}
		if (right_config.resolution.width != camera_image_width || right_config.resolution.height != camera_image_height) {
			last_camera_image_result = XR_ERROR_VALIDATION_FAILURE;
			stop_camera_image_capture();
			result["result"] = last_camera_image_result;
			cached_camera_image_info = result;
			return result;
		}
		if (!start_camera_image_eye(camera_right, right_config)) {
			stop_camera_image_capture();
			result["result"] = last_camera_image_result;
			cached_camera_image_info = result;
			return result;
		}
	}

	camera_image_capture_active = true;
	refresh_camera_image_info();
	return cached_camera_image_info.duplicate(true);
}

Array PicoOpenXRExtension::poll_camera_image_frames() {
	Array frames;
	if (!camera_image_capture_active || !resolve_functions() || !has_camera_image_functions()) {
		return frames;
	}

	CameraImageEyeState *eyes[] = { &camera_left, &camera_right };
	for (CameraImageEyeState *eye_state : eyes) {
		if (!eye_state->active || !eye_state->capture_session) {
			continue;
		}

		XrCameraImageAcquireInfoPICO acquire_info{
			XR_TYPE_CAMERA_IMAGE_ACQUIRE_INFO_PICO,
			nullptr,
			eye_state->last_capture_time,
		};
		XrCameraImagePICO image{
			XR_TYPE_CAMERA_IMAGE_PICO,
			nullptr,
			0,
			0,
		};
		const XrResult acquire_result = xrAcquireCameraImagePICO_ptr(eye_state->capture_session, &acquire_info, &image);
		eye_state->last_result = acquire_result;
		last_camera_image_result = acquire_result;
		if (acquire_result == XR_CAMERA_IMAGE_NO_UPDATE_PICO) {
			continue;
		}
		if (XR_FAILED(acquire_result)) {
			continue;
		}

		XrCameraImageDataRawBufferPICO raw_buffer{
			XR_TYPE_CAMERA_IMAGE_DATA_RAW_BUFFER_PICO,
			nullptr,
			0,
			0,
			0,
			0,
			0,
			0,
			nullptr,
		};
		auto *base = reinterpret_cast<XrCameraImageDataBaseHeaderPICO *>(&raw_buffer);
		const XrResult data_result = xrGetCameraImageDataPICO_ptr(eye_state->capture_session, image.imageId, base);
		eye_state->last_result = data_result;
		last_camera_image_result = data_result;
		if (XR_SUCCEEDED(data_result) && raw_buffer.buffer && raw_buffer.bufferSize > 0) {
			uint32_t pixel_stride = raw_buffer.pixelStride > 0 ? raw_buffer.pixelStride : raw_buffer.bytesPerPixel;
			if (pixel_stride == 0) {
				pixel_stride = 4;
			}
			uint32_t source_bytes_per_pixel = raw_buffer.bytesPerPixel > 0 ? raw_buffer.bytesPerPixel : std::min(pixel_stride, 4u);
			uint32_t row_stride = raw_buffer.stride > 0 ? raw_buffer.stride : raw_buffer.width * pixel_stride;
			const uint64_t min_row_stride = static_cast<uint64_t>(raw_buffer.width) * pixel_stride;
			if (row_stride < min_row_stride) {
				row_stride = static_cast<uint32_t>(min_row_stride);
			}
			uint64_t required_size = 0;
			if (raw_buffer.width > 0 && raw_buffer.height > 0) {
				required_size = (static_cast<uint64_t>(raw_buffer.height) - 1) * row_stride +
						(static_cast<uint64_t>(raw_buffer.width) - 1) * pixel_stride +
						std::min(source_bytes_per_pixel, 4u);
			}
			if (required_size > raw_buffer.bufferSize) {
				const uint32_t compact_stride = raw_buffer.width * source_bytes_per_pixel;
				const uint64_t compact_required_size = raw_buffer.width > 0 && raw_buffer.height > 0 ?
						(static_cast<uint64_t>(raw_buffer.height) - 1) * compact_stride +
								(static_cast<uint64_t>(raw_buffer.width) - 1) * source_bytes_per_pixel +
								std::min(source_bytes_per_pixel, 4u) :
						0;
				if (compact_required_size <= raw_buffer.bufferSize) {
					row_stride = compact_stride;
					pixel_stride = source_bytes_per_pixel;
				} else {
					xrReleaseCameraImagePICO_ptr(eye_state->capture_session, image.imageId);
					continue;
				}
			}

			PackedByteArray bytes;
			bytes.resize(raw_buffer.bufferSize);
			uint8_t *dst = bytes.ptrw();
			if (dst) {
				std::memcpy(dst, raw_buffer.buffer, raw_buffer.bufferSize);
				Dictionary frame;
				frame["eye"] = String(eye_state->eye);
				frame["camera_id"] = static_cast<int64_t>(eye_state->camera_id);
				frame["xr_time_ns"] = static_cast<int64_t>(image.captureTime);
				frame["width"] = static_cast<int>(raw_buffer.width);
				frame["height"] = static_cast<int>(raw_buffer.height);
				frame["stride"] = static_cast<int>(row_stride);
				frame["bytes_per_pixel"] = static_cast<int>(source_bytes_per_pixel);
				frame["pixel_stride"] = static_cast<int>(raw_buffer.pixelStride);
				frame["effective_pixel_stride"] = static_cast<int>(pixel_stride);
				frame["source_stride"] = static_cast<int>(raw_buffer.stride);
				frame["buffer_size"] = static_cast<int>(raw_buffer.bufferSize);
				frame["format"] = "rgba8888";
				frame["data"] = bytes;
				frames.append(frame);
				eye_state->last_capture_time = image.captureTime;
			}
		}
		xrReleaseCameraImagePICO_ptr(eye_state->capture_session, image.imageId);
	}
	return frames;
}

void PicoOpenXRExtension::stop_camera_image_capture() {
	stop_camera_image_eye(camera_right);
	stop_camera_image_eye(camera_left);
	reset_camera_image_state();
	refresh_camera_image_info();
}

Dictionary PicoOpenXRExtension::get_camera_image_info() const {
	return cached_camera_image_info.duplicate(true);
}

bool PicoOpenXRExtension::request_motion_trackers(int count) {
	requested_motion_tracker_count = std::clamp(count, 0, static_cast<int>(XR_MOTION_TRACKER_MAX_SIZE_PICO));
	if (requested_motion_tracker_count <= 0) {
		return true;
	}
	if (!resolve_functions() || !motion_tracking_ext || !xrRequestMotionTrackerDevicePICO_ptr || !current_session()) {
		return false;
	}
	last_motion_request_result = xrRequestMotionTrackerDevicePICO_ptr(current_session(), static_cast<uint32_t>(requested_motion_tracker_count));
	motion_request_sent = XR_SUCCEEDED(last_motion_request_result);
	return motion_request_sent;
}

Array PicoOpenXRExtension::sample_motion_trackers(int max_count) {
	Array records;
	if (!resolve_functions() || !motion_tracking_ext || !xrLocateMotionTrackerPICO_ptr || !current_session()) {
		return records;
	}
	const int requested_count = std::clamp(max_count, 0, static_cast<int>(XR_MOTION_TRACKER_MAX_SIZE_PICO));
	if (requested_count > 0 && motion_tracker_ids.is_empty() && !motion_request_sent) {
		request_motion_trackers(requested_count);
	}
	const XrSpace base_space = current_play_space();
	const XrTime display_time = current_display_time();
	if (!base_space || display_time == 0) {
		return records;
	}
	const int sample_count = std::min<int>(requested_count > 0 ? requested_count : motion_tracker_ids.size(), motion_tracker_ids.size());
	for (int i = 0; i < sample_count; ++i) {
		const XrMotionTrackerIdPICO tracker_id = static_cast<XrMotionTrackerIdPICO>(int64_t(motion_tracker_ids[i]));
		XrMotionTrackerLocationInfoPICO locate_info{
			XR_TYPE_MOTION_TRACKER_LOCATION_INFO_PICO,
			nullptr,
			base_space,
			display_time,
		};
		XrMotionTrackerSpaceVelocityPICO velocity{
			XR_TYPE_MOTION_TRACKER_SPACE_VELOCITY_PICO,
			nullptr,
			0,
			{},
			{},
			{},
			{},
		};
		XrMotionTrackerSpaceLocationPICO location{
			XR_TYPE_MOTION_TRACKER_SPACE_LOCATION_PICO,
			&velocity,
			0,
			{},
		};
		const XrResult locate_result = xrLocateMotionTrackerPICO_ptr(current_session(), tracker_id, &locate_info, &location);
		Dictionary record;
		record["tracker_index"] = i;
		record["id"] = tracker_id_to_variant(tracker_id);
		record["result"] = locate_result;
		record["location_flags"] = static_cast<int64_t>(location.locationFlags);
		record["tracking_valid"] = XR_SUCCEEDED(locate_result) &&
				(location.locationFlags & XR_SPACE_LOCATION_POSITION_VALID_BIT) &&
				(location.locationFlags & XR_SPACE_LOCATION_ORIENTATION_VALID_BIT);
		const Transform3D transform = transform_from_pose(location.pose);
		record["transform"] = transform;
		record["position"] = vector3_record(transform.origin);
		record["rotation"] = quaternion_record(quaternion_from_xr(location.pose.orientation));
		record["velocity_flags"] = static_cast<int64_t>(velocity.velocityFlags);
		record["linear_velocity"] = xr_vector3_record(velocity.linearVelocity);
		record["angular_velocity"] = xr_vector3_record(velocity.angularVelocity);
		record["linear_acceleration"] = xr_vector3_record(velocity.linearAcceleration);
		record["angular_acceleration"] = xr_vector3_record(velocity.angularAcceleration);
		if (xrGetMotionTrackerBatteryStatePICO_ptr) {
			XrMotionTrackerBatteryStatePICO battery{
				XR_TYPE_MOTION_TRACKER_BATTERY_STATE_PICO,
				nullptr,
				0.0f,
				XR_MOTION_TRACKER_CHARGING_STATE_UNCHARGED_PICO,
			};
			const XrResult battery_result = xrGetMotionTrackerBatteryStatePICO_ptr(current_session(), tracker_id, &battery);
			record["battery_result"] = battery_result;
			if (XR_SUCCEEDED(battery_result)) {
				record["battery_level"] = battery.batteryLevel;
				record["charging_state"] = static_cast<int>(battery.chargingState);
			}
		}
		records.append(record);
	}
	return records;
}

bool PicoOpenXRExtension::start_body_tracking(Dictionary bone_lengths) {
	return ensure_body_tracker(bone_lengths);
}

void PicoOpenXRExtension::stop_body_tracking() {
	destroy_body_tracker();
}

bool PicoOpenXRExtension::start_body_tracking_calibration_app() {
	if (!resolve_functions() || !pico_body_tracking2_ext || !xrStartBodyTrackingCalibrationAppPICO_ptr || !current_session()) {
		return false;
	}
	const XrResult result = xrStartBodyTrackingCalibrationAppPICO_ptr(current_session());
	return XR_SUCCEEDED(result);
}

Dictionary PicoOpenXRExtension::sample_body_joints() {
	Dictionary result;
	result["supported"] = bd_body_tracking_ext && system_body_tracking_properties.supportsBodyTracking == XR_TRUE;
	result["active"] = false;
	result["status"] = int(XR_BODY_TRACKING_STATUS_INVALID_PICO);
	result["message"] = int(XR_BODY_TRACKING_MESSAGE_NO_ERROR_PICO);
	result["all_tracked"] = false;
	result["joints"] = Array();

	if (!ensure_body_tracker(Dictionary())) {
		return result;
	}

	XrBodyTrackingStatePICO tracking_state{
		XR_TYPE_BODY_TRACKING_STATE_PICO,
		nullptr,
		XR_BODY_TRACKING_STATUS_INVALID_PICO,
		XR_BODY_TRACKING_MESSAGE_NO_ERROR_PICO,
	};
	if (pico_body_tracking2_ext && xrGetBodyTrackingStatePICO_ptr) {
		last_body_state_result = xrGetBodyTrackingStatePICO_ptr(current_session(), &tracking_state);
	}

	XrBodyJointLocationBD locations_storage[XR_BODY_JOINT_COUNT_BD] = {};
	XrBodyTrackingPosturePICO posture_storage[XR_BODY_JOINT_COUNT_BD] = {};
	XrBodyJointVelocityPICO velocities_storage[XR_BODY_JOINT_COUNT_BD] = {};
	XrBodyJointAccelerationPICO accelerations_storage[XR_BODY_JOINT_COUNT_BD] = {};
	XrBodyJointAccelerationsPICO accelerations{
		XR_TYPE_BODY_JOINT_ACCELERATIONS_PICO,
		nullptr,
		XR_BODY_JOINT_COUNT_BD,
		accelerations_storage,
	};
	XrBodyJointVelocitiesPICO velocities{
		XR_TYPE_BODY_JOINT_VELOCITIES_PICO,
		&accelerations,
		XR_BODY_JOINT_COUNT_BD,
		velocities_storage,
	};
	XrBodyTrackingPostureFlagsDataPICO posture_flags{
		XR_TYPE_BODY_TRACKING_POSTURE_FLAGS_DATA_PICO,
		&velocities,
		XR_BODY_JOINT_COUNT_BD,
		posture_storage,
	};
	XrBodyJointLocationsBD locations{
		XR_TYPE_BODY_JOINT_LOCATIONS_BD,
		pico_body_tracking2_ext ? static_cast<void *>(&posture_flags) : nullptr,
		XR_FALSE,
		XR_BODY_JOINT_COUNT_BD,
		locations_storage,
	};
	XrBodyJointsLocateInfoBD locate_info{
		XR_TYPE_BODY_JOINTS_LOCATE_INFO_BD,
		nullptr,
		current_play_space(),
		current_display_time(),
	};
	if (!locate_info.baseSpace || locate_info.time == 0) {
		return result;
	}

	last_body_locate_result = xrLocateBodyJointsBD_ptr(body_tracker, &locate_info, &locations);
	result["active"] = XR_SUCCEEDED(last_body_locate_result);
	result["status"] = int(tracking_state.status);
	result["message"] = int(tracking_state.message);
	result["all_tracked"] = locations.allJointPosesTracked == XR_TRUE;
	result["locate_result"] = last_body_locate_result;
	result["state_result"] = last_body_state_result;
	result["body_flags"] = int(tracking_state.status) | (int(tracking_state.message) << 8) | ((locations.allJointPosesTracked == XR_TRUE ? 1 : 0) << 16);

	if (XR_FAILED(last_body_locate_result)) {
		return result;
	}

	Array joints;
	const uint32_t joint_count = std::min<uint32_t>(locations.jointLocationCount, XR_BODY_JOINT_COUNT_BD);
	for (uint32_t joint = 0; joint < joint_count; ++joint) {
		const XrBodyJointLocationBD &joint_location = locations_storage[joint];
		if (joint_location.locationFlags == 0) {
			continue;
		}
		Dictionary joint_record = pose_record(joint_location.pose);
		joint_record["joint"] = static_cast<int>(joint);
		joint_record["flags"] = static_cast<int64_t>(joint_location.locationFlags);
		joint_record["radius_m"] = 0.0;
		if (pico_body_tracking2_ext) {
			joint_record["posture"] = static_cast<int>(posture_storage[joint]);
			const XrBodyJointVelocityPICO &velocity = velocities_storage[joint];
			joint_record["velocity_flags"] = static_cast<int64_t>(velocity.velocityFlags);
			joint_record["linear_velocity"] = xr_vector3_record(velocity.linearVelocity);
			joint_record["angular_velocity"] = xr_vector3_record(velocity.angularVelocity);
			const XrBodyJointAccelerationPICO &acceleration = accelerations_storage[joint];
			joint_record["acceleration_flags"] = static_cast<int64_t>(acceleration.accelerationFlags);
			joint_record["linear_acceleration"] = xr_vector3_record(acceleration.linearAcceleration);
			joint_record["angular_acceleration"] = xr_vector3_record(acceleration.angularAcceleration);
		}
		joints.append(joint_record);
	}
	result["joints"] = joints;
	return result;
}

bool PicoOpenXRExtension::resolve_functions() {
	if (function_resolution_attempted) {
		return true;
	}
	function_resolution_attempted = true;
	Ref<OpenXRAPIExtension> api = get_openxr_api();
	if (api.is_null()) {
		return false;
	}
	if (external_camera_ext) {
		xrGetExternalCameraInfoPICO_ptr = reinterpret_cast<PFN_xrGetExternalCameraInfoPICO>(api->get_instance_proc_addr("xrGetExternalCameraInfoPICO"));
	}
	if (future_ext) {
		xrPollFutureEXT_ptr = reinterpret_cast<PFN_xrPollFutureEXT>(api->get_instance_proc_addr("xrPollFutureEXT"));
	}
	if (camera_image_ext) {
		xrEnumerateAvailableCamerasPICO_ptr = reinterpret_cast<PFN_xrEnumerateAvailableCamerasPICO>(api->get_instance_proc_addr("xrEnumerateAvailableCamerasPICO"));
		xrEnumerateCameraPropertyTypesPICO_ptr = reinterpret_cast<PFN_xrEnumerateCameraPropertyTypesPICO>(api->get_instance_proc_addr("xrEnumerateCameraPropertyTypesPICO"));
		xrGetCameraPropertiesPICO_ptr = reinterpret_cast<PFN_xrGetCameraPropertiesPICO>(api->get_instance_proc_addr("xrGetCameraPropertiesPICO"));
		xrEnumerateCameraCapabilityTypesPICO_ptr = reinterpret_cast<PFN_xrEnumerateCameraCapabilityTypesPICO>(api->get_instance_proc_addr("xrEnumerateCameraCapabilityTypesPICO"));
		xrGetCameraSupportedCapabilitiesPICO_ptr = reinterpret_cast<PFN_xrGetCameraSupportedCapabilitiesPICO>(api->get_instance_proc_addr("xrGetCameraSupportedCapabilitiesPICO"));
		xrCreateCameraDeviceAsyncPICO_ptr = reinterpret_cast<PFN_xrCreateCameraDeviceAsyncPICO>(api->get_instance_proc_addr("xrCreateCameraDeviceAsyncPICO"));
		xrCreateCameraDeviceCompletePICO_ptr = reinterpret_cast<PFN_xrCreateCameraDeviceCompletePICO>(api->get_instance_proc_addr("xrCreateCameraDeviceCompletePICO"));
		xrDestroyCameraDevicePICO_ptr = reinterpret_cast<PFN_xrDestroyCameraDevicePICO>(api->get_instance_proc_addr("xrDestroyCameraDevicePICO"));
		xrCreateCameraCaptureSessionAsyncPICO_ptr = reinterpret_cast<PFN_xrCreateCameraCaptureSessionAsyncPICO>(api->get_instance_proc_addr("xrCreateCameraCaptureSessionAsyncPICO"));
		xrCreateCameraCaptureSessionCompletePICO_ptr = reinterpret_cast<PFN_xrCreateCameraCaptureSessionCompletePICO>(api->get_instance_proc_addr("xrCreateCameraCaptureSessionCompletePICO"));
		xrDestroyCameraCaptureSessionPICO_ptr = reinterpret_cast<PFN_xrDestroyCameraCaptureSessionPICO>(api->get_instance_proc_addr("xrDestroyCameraCaptureSessionPICO"));
		xrGetCameraIntrinsicsPICO_ptr = reinterpret_cast<PFN_xrGetCameraIntrinsicsPICO>(api->get_instance_proc_addr("xrGetCameraIntrinsicsPICO"));
		xrGetCameraExtrinsicsPICO_ptr = reinterpret_cast<PFN_xrGetCameraExtrinsicsPICO>(api->get_instance_proc_addr("xrGetCameraExtrinsicsPICO"));
		xrBeginCameraCapturePICO_ptr = reinterpret_cast<PFN_xrBeginCameraCapturePICO>(api->get_instance_proc_addr("xrBeginCameraCapturePICO"));
		xrEndCameraCapturePICO_ptr = reinterpret_cast<PFN_xrEndCameraCapturePICO>(api->get_instance_proc_addr("xrEndCameraCapturePICO"));
		xrAcquireCameraImagePICO_ptr = reinterpret_cast<PFN_xrAcquireCameraImagePICO>(api->get_instance_proc_addr("xrAcquireCameraImagePICO"));
		xrGetCameraImageDataPICO_ptr = reinterpret_cast<PFN_xrGetCameraImageDataPICO>(api->get_instance_proc_addr("xrGetCameraImageDataPICO"));
		xrReleaseCameraImagePICO_ptr = reinterpret_cast<PFN_xrReleaseCameraImagePICO>(api->get_instance_proc_addr("xrReleaseCameraImagePICO"));
	}
	if (motion_tracking_ext) {
		xrRequestMotionTrackerDevicePICO_ptr = reinterpret_cast<PFN_xrRequestMotionTrackerDevicePICO>(api->get_instance_proc_addr("xrRequestMotionTrackerDevicePICO"));
		xrGetMotionTrackerBatteryStatePICO_ptr = reinterpret_cast<PFN_xrGetMotionTrackerBatteryStatePICO>(api->get_instance_proc_addr("xrGetMotionTrackerBatteryStatePICO"));
		xrLocateMotionTrackerPICO_ptr = reinterpret_cast<PFN_xrLocateMotionTrackerPICO>(api->get_instance_proc_addr("xrLocateMotionTrackerPICO"));
	}
	if (bd_body_tracking_ext) {
		xrCreateBodyTrackerBD_ptr = reinterpret_cast<PFN_xrCreateBodyTrackerBD>(api->get_instance_proc_addr("xrCreateBodyTrackerBD"));
		xrDestroyBodyTrackerBD_ptr = reinterpret_cast<PFN_xrDestroyBodyTrackerBD>(api->get_instance_proc_addr("xrDestroyBodyTrackerBD"));
		xrLocateBodyJointsBD_ptr = reinterpret_cast<PFN_xrLocateBodyJointsBD>(api->get_instance_proc_addr("xrLocateBodyJointsBD"));
	}
	if (pico_body_tracking2_ext) {
		xrStartBodyTrackingCalibrationAppPICO_ptr = reinterpret_cast<PFN_xrStartBodyTrackingCalibrationAppPICO>(api->get_instance_proc_addr("xrStartBodyTrackingCalibrationAppPICO"));
		xrGetBodyTrackingStatePICO_ptr = reinterpret_cast<PFN_xrGetBodyTrackingStatePICO>(api->get_instance_proc_addr("xrGetBodyTrackingStatePICO"));
	}
	return true;
}

bool PicoOpenXRExtension::has_camera_image_functions() const {
	return future_ext &&
			camera_image_ext &&
			xrPollFutureEXT_ptr &&
			xrEnumerateAvailableCamerasPICO_ptr &&
			xrEnumerateCameraPropertyTypesPICO_ptr &&
			xrGetCameraPropertiesPICO_ptr &&
			xrEnumerateCameraCapabilityTypesPICO_ptr &&
			xrGetCameraSupportedCapabilitiesPICO_ptr &&
			xrCreateCameraDeviceAsyncPICO_ptr &&
			xrCreateCameraDeviceCompletePICO_ptr &&
			xrDestroyCameraDevicePICO_ptr &&
			xrCreateCameraCaptureSessionAsyncPICO_ptr &&
			xrCreateCameraCaptureSessionCompletePICO_ptr &&
			xrDestroyCameraCaptureSessionPICO_ptr &&
			xrGetCameraIntrinsicsPICO_ptr &&
			xrGetCameraExtrinsicsPICO_ptr &&
			xrBeginCameraCapturePICO_ptr &&
			xrEndCameraCapturePICO_ptr &&
			xrAcquireCameraImagePICO_ptr &&
			xrGetCameraImageDataPICO_ptr &&
			xrReleaseCameraImagePICO_ptr;
}

bool PicoOpenXRExtension::wait_future_until_ready(XrFutureEXT future, XrResult &poll_result, int timeout_ms) {
	if (!instance || !xrPollFutureEXT_ptr || future == XR_NULL_FUTURE_EXT) {
		poll_result = XR_ERROR_HANDLE_INVALID;
		return false;
	}
	XrFuturePollInfoEXT poll_info{
		XR_TYPE_FUTURE_POLL_INFO_EXT,
		nullptr,
		future,
	};
	XrFuturePollResultEXT poll_state{
		XR_TYPE_FUTURE_POLL_RESULT_EXT,
		nullptr,
		XR_FUTURE_STATE_PENDING_EXT,
	};
	const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout_ms);
	do {
		poll_result = xrPollFutureEXT_ptr(instance, &poll_info, &poll_state);
		if (XR_FAILED(poll_result)) {
			return false;
		}
		if (poll_state.state == XR_FUTURE_STATE_READY_EXT) {
			return true;
		}
		std::this_thread::sleep_for(std::chrono::milliseconds(1));
	} while (std::chrono::steady_clock::now() < deadline);
	poll_result = XR_ERROR_VALIDATION_FAILURE;
	return false;
}

bool PicoOpenXRExtension::refresh_camera_image_camera_ids() {
	if (!instance || !xrEnumerateAvailableCamerasPICO_ptr || !xrEnumerateCameraPropertyTypesPICO_ptr || !xrGetCameraPropertiesPICO_ptr) {
		last_camera_image_result = XR_ERROR_HANDLE_INVALID;
		return false;
	}

	XrCameraPropertiesPICO camera_properties{
		XR_TYPE_CAMERA_PROPERTIES_PICO,
		nullptr,
		0,
		nullptr,
	};
	XrCameraCapabilitiesPICO camera_capabilities{
		XR_TYPE_CAMERA_CAPABILITIES_PICO,
		nullptr,
		0,
		nullptr,
	};
	XrAvailableCamerasEnumerateInfoPICO enumerate_info{
		XR_TYPE_AVAILABLE_CAMERAS_ENUMERATE_INFO_PICO,
		nullptr,
		&camera_properties,
		&camera_capabilities,
	};

	uint32_t camera_count = 0;
	last_camera_image_result = xrEnumerateAvailableCamerasPICO_ptr(instance, &enumerate_info, 0, &camera_count, nullptr);
	if (XR_FAILED(last_camera_image_result) || camera_count == 0) {
		UtilityFunctions::print("PicoOpenXRExtension camera enumeration failed; using fallback ids left=",
				static_cast<int64_t>(camera_left.camera_id), " right=", static_cast<int64_t>(camera_right.camera_id),
				" result=", last_camera_image_result, " count=", static_cast<int64_t>(camera_count));
		return false;
	}

	std::vector<XrCameraIdPICO> camera_ids(camera_count);
	last_camera_image_result = xrEnumerateAvailableCamerasPICO_ptr(instance, &enumerate_info, camera_count, &camera_count, camera_ids.data());
	if (XR_FAILED(last_camera_image_result) || camera_count == 0) {
		UtilityFunctions::print("PicoOpenXRExtension camera enumeration read failed; using fallback ids left=",
				static_cast<int64_t>(camera_left.camera_id), " right=", static_cast<int64_t>(camera_right.camera_id),
				" result=", last_camera_image_result);
		return false;
	}
	camera_ids.resize(camera_count);

	XrCameraIdPICO left_id = 0;
	XrCameraIdPICO right_id = 0;
	std::vector<XrCameraIdPICO> color_world_ids;
	color_world_ids.reserve(camera_ids.size());

	for (XrCameraIdPICO camera_id : camera_ids) {
		uint32_t property_type_count = 0;
		XrResult result = xrEnumerateCameraPropertyTypesPICO_ptr(instance, camera_id, 0, &property_type_count, nullptr);
		if (XR_FAILED(result) || property_type_count == 0) {
			color_world_ids.push_back(camera_id);
			continue;
		}

		std::vector<XrCameraPropertyTypePICO> property_types(property_type_count);
		result = xrEnumerateCameraPropertyTypesPICO_ptr(instance, camera_id, property_type_count, &property_type_count, property_types.data());
		if (XR_FAILED(result)) {
			color_world_ids.push_back(camera_id);
			continue;
		}
		property_types.resize(property_type_count);

		XrCameraPropertyFacingPICO facing{
			XR_TYPE_CAMERA_PROPERTY_FACING_PICO,
			nullptr,
			XR_CAMERA_FACING_WORLD_PICO,
		};
		XrCameraPropertyPositionPICO position{
			XR_TYPE_CAMERA_PROPERTY_POSITION_PICO,
			nullptr,
			XR_CAMERA_POSITION_UNSPECIFIED_PICO,
		};
		XrCameraPropertyCameraTypePICO camera_type{
			XR_TYPE_CAMERA_PROPERTY_CAMERA_TYPE_PICO,
			nullptr,
			XR_CAMERA_TYPE_PASSTHROUGH_COLOR_PICO,
		};

		bool has_facing = false;
		bool has_position = false;
		bool has_camera_type = false;
		std::vector<XrCameraPropertyBaseHeaderPICO *> property_headers;
		property_headers.reserve(property_types.size());
		for (XrCameraPropertyTypePICO property_type : property_types) {
			switch (property_type) {
				case XR_CAMERA_PROPERTY_TYPE_FACING_PICO:
					has_facing = true;
					property_headers.push_back(reinterpret_cast<XrCameraPropertyBaseHeaderPICO *>(&facing));
					break;
				case XR_CAMERA_PROPERTY_TYPE_POSITION_PICO:
					has_position = true;
					property_headers.push_back(reinterpret_cast<XrCameraPropertyBaseHeaderPICO *>(&position));
					break;
				case XR_CAMERA_PROPERTY_TYPE_CAMERA_TYPE_PICO:
					has_camera_type = true;
					property_headers.push_back(reinterpret_cast<XrCameraPropertyBaseHeaderPICO *>(&camera_type));
					break;
				default:
					break;
			}
		}

		if (!property_headers.empty()) {
			XrCameraPropertiesGetInfoPICO get_info{
				XR_TYPE_CAMERA_PROPERTIES_GET_INFO_PICO,
				nullptr,
				camera_id,
			};
			XrCameraPropertiesPICO properties{
				XR_TYPE_CAMERA_PROPERTIES_PICO,
				nullptr,
				static_cast<uint32_t>(property_headers.size()),
				property_headers.data(),
			};
			result = xrGetCameraPropertiesPICO_ptr(instance, &get_info, &properties);
			if (XR_FAILED(result)) {
				color_world_ids.push_back(camera_id);
				continue;
			}
		}

		const bool world_facing = !has_facing || facing.facing == XR_CAMERA_FACING_WORLD_PICO;
		const bool passthrough_color = !has_camera_type || camera_type.cameraType == XR_CAMERA_TYPE_PASSTHROUGH_COLOR_PICO;
		UtilityFunctions::print("PicoOpenXRExtension camera property id=", static_cast<int64_t>(camera_id),
				" facing=", static_cast<int>(facing.facing),
				" position=", static_cast<int>(position.position),
				" type=", static_cast<int>(camera_type.cameraType));
		if (!world_facing || !passthrough_color) {
			continue;
		}

		color_world_ids.push_back(camera_id);
		if (has_position && position.position == XR_CAMERA_POSITION_LEFT_PICO) {
			left_id = camera_id;
		} else if (has_position && position.position == XR_CAMERA_POSITION_RIGHT_PICO) {
			right_id = camera_id;
		}
	}

	if (left_id == 0 && !color_world_ids.empty()) {
		left_id = color_world_ids[0];
	}
	if (right_id == 0) {
		if (color_world_ids.size() > 1) {
			right_id = color_world_ids[1];
		} else if (camera_ids.size() > 1 && camera_ids[1] != left_id) {
			right_id = camera_ids[1];
		}
	}
	if (left_id != 0) {
		camera_left.camera_id = left_id;
	}
	if (right_id != 0) {
		camera_right.camera_id = right_id;
	}

	UtilityFunctions::print("PicoOpenXRExtension camera ids available=", static_cast<int64_t>(camera_ids.size()),
			" selected left=", static_cast<int64_t>(camera_left.camera_id),
			" right=", static_cast<int64_t>(camera_right.camera_id));
	last_camera_image_result = XR_SUCCESS;
	return true;
}

bool PicoOpenXRExtension::select_camera_image_config(XrCameraIdPICO camera_id, int preferred_width, int preferred_height, int preferred_fps, CameraImageCaptureConfig &config) {
	if (!instance || !xrEnumerateCameraCapabilityTypesPICO_ptr || !xrGetCameraSupportedCapabilitiesPICO_ptr) {
		last_camera_image_result = XR_ERROR_HANDLE_INVALID;
		return false;
	}

	uint32_t type_count = 0;
	last_camera_image_result = xrEnumerateCameraCapabilityTypesPICO_ptr(instance, camera_id, 0, &type_count, nullptr);
	if (XR_FAILED(last_camera_image_result) || type_count == 0) {
		return false;
	}
	std::vector<XrCameraCapabilityTypePICO> capability_types(type_count);
	last_camera_image_result = xrEnumerateCameraCapabilityTypesPICO_ptr(instance, camera_id, type_count, &type_count, capability_types.data());
	if (XR_FAILED(last_camera_image_result)) {
		return false;
	}
	capability_types.resize(type_count);

	XrCameraSupportedCapabilityImageResolutionPICO resolution{
		XR_TYPE_CAMERA_SUPPORTED_CAPABILITY_IMAGE_RESOLUTION_PICO,
		nullptr,
		0,
		0,
		nullptr,
	};
	XrCameraSupportedCapabilityImageFormatPICO format{
		XR_TYPE_CAMERA_SUPPORTED_CAPABILITY_IMAGE_FORMAT_PICO,
		nullptr,
		0,
		0,
		nullptr,
	};
	XrCameraSupportedCapabilityDataTransferTypePICO transfer_type{
		XR_TYPE_CAMERA_SUPPORTED_CAPABILITY_DATA_TRANSFER_TYPE_PICO,
		nullptr,
		0,
		0,
		nullptr,
	};
	XrCameraSupportedCapabilityCameraModelPICO model{
		XR_TYPE_CAMERA_SUPPORTED_CAPABILITY_CAMERA_MODEL_PICO,
		nullptr,
		0,
		0,
		nullptr,
	};
	XrCameraSupportedCapabilityImageFpsPICO fps{
		XR_TYPE_CAMERA_SUPPORTED_CAPABILITY_IMAGE_FPS_PICO,
		nullptr,
		0,
		0,
		nullptr,
	};
	std::vector<XrCameraSupportedCapabilityBaseHeaderPICO *> capability_headers;
	capability_headers.reserve(capability_types.size());
	for (XrCameraCapabilityTypePICO type : capability_types) {
		switch (type) {
			case XR_CAMERA_CAPABILITY_TYPE_IMAGE_RESOLUTION_PICO:
				capability_headers.push_back(reinterpret_cast<XrCameraSupportedCapabilityBaseHeaderPICO *>(&resolution));
				break;
			case XR_CAMERA_CAPABILITY_TYPE_IMAGE_FORMAT_PICO:
				capability_headers.push_back(reinterpret_cast<XrCameraSupportedCapabilityBaseHeaderPICO *>(&format));
				break;
			case XR_CAMERA_CAPABILITY_TYPE_DATA_TRANSFER_TYPE_PICO:
				capability_headers.push_back(reinterpret_cast<XrCameraSupportedCapabilityBaseHeaderPICO *>(&transfer_type));
				break;
			case XR_CAMERA_CAPABILITY_TYPE_CAMERA_MODEL_PICO:
				capability_headers.push_back(reinterpret_cast<XrCameraSupportedCapabilityBaseHeaderPICO *>(&model));
				break;
			case XR_CAMERA_CAPABILITY_TYPE_IMAGE_FPS_PICO:
				capability_headers.push_back(reinterpret_cast<XrCameraSupportedCapabilityBaseHeaderPICO *>(&fps));
				break;
			default:
				break;
		}
	}
	if (capability_headers.empty()) {
		last_camera_image_result = XR_ERROR_VALIDATION_FAILURE;
		return false;
	}

	XrCameraSupportedCapabilitiesGetInfoPICO get_info{
		XR_TYPE_CAMERA_SUPPORTED_CAPABILITIES_GET_INFO_PICO,
		nullptr,
		camera_id,
	};
	XrCameraSupportedCapabilitiesPICO supported{
		XR_TYPE_CAMERA_SUPPORTED_CAPABILITIES_PICO,
		nullptr,
		static_cast<uint32_t>(capability_headers.size()),
		capability_headers.data(),
	};
	last_camera_image_result = xrGetCameraSupportedCapabilitiesPICO_ptr(instance, &get_info, &supported);
	if (XR_FAILED(last_camera_image_result)) {
		return false;
	}

	std::vector<XrExtent2Di> resolutions(resolution.resolutionCountOutput);
	std::vector<XrCameraImageFormatPICO> formats(format.formatCountOutput);
	std::vector<XrCameraDataTransferTypePICO> transfer_types(transfer_type.typeCountOutput);
	std::vector<XrCameraModelPICO> models(model.modelCountOutput);
	std::vector<XrCameraImageFpsPICO> fps_values(fps.fpsCountOutput);
	resolution.resolutionCapacityInput = static_cast<uint32_t>(resolutions.size());
	resolution.resolutions = resolutions.empty() ? nullptr : resolutions.data();
	format.formatCapacityInput = static_cast<uint32_t>(formats.size());
	format.formats = formats.empty() ? nullptr : formats.data();
	transfer_type.typeCapacityInput = static_cast<uint32_t>(transfer_types.size());
	transfer_type.types = transfer_types.empty() ? nullptr : transfer_types.data();
	model.modelCapacityInput = static_cast<uint32_t>(models.size());
	model.models = models.empty() ? nullptr : models.data();
	fps.fpsCapacityInput = static_cast<uint32_t>(fps_values.size());
	fps.fps = fps_values.empty() ? nullptr : fps_values.data();

	last_camera_image_result = xrGetCameraSupportedCapabilitiesPICO_ptr(instance, &get_info, &supported);
	if (XR_FAILED(last_camera_image_result)) {
		return false;
	}

	bool have_resolution = false;
	uint64_t best_score = std::numeric_limits<uint64_t>::max();
	const uint64_t preferred_area = preferred_width > 0 && preferred_height > 0 ?
			static_cast<uint64_t>(preferred_width) * static_cast<uint64_t>(preferred_height) : 0;
	for (const XrExtent2Di &candidate : resolutions) {
		if (candidate.width <= 0 || candidate.height <= 0) {
			continue;
		}
		uint64_t score = static_cast<uint64_t>(candidate.width) * static_cast<uint64_t>(candidate.height);
		if (preferred_width > 0 && preferred_height > 0) {
			const int64_t width_delta = static_cast<int64_t>(candidate.width) - preferred_width;
			const int64_t height_delta = static_cast<int64_t>(candidate.height) - preferred_height;
			const uint64_t abs_width = width_delta < 0 ? static_cast<uint64_t>(-width_delta) : static_cast<uint64_t>(width_delta);
			const uint64_t abs_height = height_delta < 0 ? static_cast<uint64_t>(-height_delta) : static_cast<uint64_t>(height_delta);
			const uint64_t area = static_cast<uint64_t>(candidate.width) * static_cast<uint64_t>(candidate.height);
			const uint64_t area_delta = area > preferred_area ? area - preferred_area : preferred_area - area;
			score = abs_width * 1000000ULL + abs_height * 1000ULL + area_delta;
		}
		if (!have_resolution || score < best_score) {
			config.resolution = candidate;
			best_score = score;
			have_resolution = true;
		}
	}
	if (!have_resolution) {
		last_camera_image_result = XR_ERROR_VALIDATION_FAILURE;
		return false;
	}

	if (!formats.empty() && !contains_value(formats, XR_CAMERA_IMAGE_FORMAT_RGBA_8888_PICO)) {
		last_camera_image_result = XR_ERROR_VALIDATION_FAILURE;
		return false;
	}
	if (!transfer_types.empty() && !contains_value(transfer_types, XR_CAMERA_DATA_TRANSFER_TYPE_RAW_BUFFER_PICO)) {
		last_camera_image_result = XR_ERROR_VALIDATION_FAILURE;
		return false;
	}
	config.format = XR_CAMERA_IMAGE_FORMAT_RGBA_8888_PICO;
	config.transfer_type = XR_CAMERA_DATA_TRANSFER_TYPE_RAW_BUFFER_PICO;
	if (!models.empty()) {
		config.model = contains_value(models, XR_CAMERA_MODEL_PINHOLE_PICO) ? XR_CAMERA_MODEL_PINHOLE_PICO : models.front();
	}
	if (!fps_values.empty()) {
		const XrCameraImageFpsPICO preferred = preferred_fps >= 60 ? XR_CAMERA_IMAGE_FPS_60_PICO : XR_CAMERA_IMAGE_FPS_30_PICO;
		if (contains_value(fps_values, preferred)) {
			config.fps = preferred;
		} else if (contains_value(fps_values, XR_CAMERA_IMAGE_FPS_30_PICO)) {
			config.fps = XR_CAMERA_IMAGE_FPS_30_PICO;
		} else {
			config.fps = fps_values.front();
		}
	}

	UtilityFunctions::print("PicoOpenXRExtension camera config camera=", static_cast<int64_t>(camera_id),
			" requested=", preferred_width, "x", preferred_height, "@", preferred_fps,
			" selected=", config.resolution.width, "x", config.resolution.height, "@", camera_fps_to_int(config.fps),
			" caps=", static_cast<int64_t>(resolutions.size()), "/", static_cast<int64_t>(formats.size()), "/",
			static_cast<int64_t>(transfer_types.size()), "/", static_cast<int64_t>(models.size()), "/", static_cast<int64_t>(fps_values.size()));
	last_camera_image_result = XR_SUCCESS;
	return true;
}

bool PicoOpenXRExtension::start_camera_image_eye(CameraImageEyeState &eye_state, const CameraImageCaptureConfig &config) {
	XrCameraDeviceCreateInfoPICO device_info{
		XR_TYPE_CAMERA_DEVICE_CREATE_INFO_PICO,
		nullptr,
		eye_state.camera_id,
	};
	XrFutureEXT future = XR_NULL_FUTURE_EXT;
	last_camera_image_result = xrCreateCameraDeviceAsyncPICO_ptr(instance, &device_info, &future);
	if (XR_FAILED(last_camera_image_result)) {
		eye_state.last_result = last_camera_image_result;
		return false;
	}
	if (!wait_future_until_ready(future, last_camera_image_result)) {
		eye_state.last_result = last_camera_image_result;
		return false;
	}
	XrCreateCameraDeviceCompletionPICO device_completion{
		XR_TYPE_CREATE_CAMERA_DEVICE_COMPLETION_PICO,
		nullptr,
		XR_ERROR_VALIDATION_FAILURE,
		XR_NULL_CAMERA_DEVICE_PICO,
	};
	last_camera_image_result = xrCreateCameraDeviceCompletePICO_ptr(instance, future, &device_completion);
	if (XR_FAILED(last_camera_image_result) || XR_FAILED(device_completion.futureResult) || !device_completion.device) {
		eye_state.last_result = XR_FAILED(last_camera_image_result) ? last_camera_image_result : device_completion.futureResult;
		last_camera_image_result = eye_state.last_result;
		return false;
	}
	eye_state.device = device_completion.device;

	XrCameraCapabilityImageResolutionPICO resolution{
		XR_TYPE_CAMERA_CAPABILITY_IMAGE_RESOLUTION_PICO,
		nullptr,
		config.resolution,
	};
	XrCameraCapabilityImageFormatPICO format{
		XR_TYPE_CAMERA_CAPABILITY_IMAGE_FORMAT_PICO,
		nullptr,
		config.format,
	};
	XrCameraCapabilityDataTransferTypePICO transfer{
		XR_TYPE_CAMERA_CAPABILITY_DATA_TRANSFER_TYPE_PICO,
		nullptr,
		config.transfer_type,
	};
	XrCameraCapabilityCameraModelPICO model{
		XR_TYPE_CAMERA_CAPABILITY_CAMERA_MODEL_PICO,
		nullptr,
		config.model,
	};
	XrCameraCapabilityImageFpsPICO capture_fps{
		XR_TYPE_CAMERA_CAPABILITY_IMAGE_FPS_PICO,
		nullptr,
		config.fps,
	};
	std::vector<const XrCameraCapabilityBaseHeaderPICO *> configs{
		reinterpret_cast<const XrCameraCapabilityBaseHeaderPICO *>(&resolution),
		reinterpret_cast<const XrCameraCapabilityBaseHeaderPICO *>(&format),
		reinterpret_cast<const XrCameraCapabilityBaseHeaderPICO *>(&transfer),
		reinterpret_cast<const XrCameraCapabilityBaseHeaderPICO *>(&model),
		reinterpret_cast<const XrCameraCapabilityBaseHeaderPICO *>(&capture_fps),
	};
	XrCameraCaptureSessionCreateInfoPICO session_info{
		XR_TYPE_CAMERA_CAPTURE_SESSION_CREATE_INFO_PICO,
		nullptr,
		eye_state.device,
		static_cast<uint32_t>(configs.size()),
		configs.data(),
	};
	future = XR_NULL_FUTURE_EXT;
	last_camera_image_result = xrCreateCameraCaptureSessionAsyncPICO_ptr(current_session(), &session_info, &future);
	if (XR_FAILED(last_camera_image_result)) {
		eye_state.last_result = last_camera_image_result;
		return false;
	}
	if (!wait_future_until_ready(future, last_camera_image_result)) {
		eye_state.last_result = last_camera_image_result;
		return false;
	}
	XrCreateCameraCaptureSessionCompletionPICO session_completion{
		XR_TYPE_CREATE_CAMERA_CAPTURE_SESSION_COMPLETION_PICO,
		nullptr,
		XR_ERROR_VALIDATION_FAILURE,
		XR_NULL_CAMERA_CAPTURE_SESSION_PICO,
	};
	last_camera_image_result = xrCreateCameraCaptureSessionCompletePICO_ptr(current_session(), future, &session_completion);
	if (XR_FAILED(last_camera_image_result) || XR_FAILED(session_completion.futureResult) || !session_completion.captureSession) {
		eye_state.last_result = XR_FAILED(last_camera_image_result) ? last_camera_image_result : session_completion.futureResult;
		last_camera_image_result = eye_state.last_result;
		return false;
	}
	eye_state.capture_session = session_completion.captureSession;
	eye_state.width = config.resolution.width;
	eye_state.height = config.resolution.height;
	eye_state.fps = camera_fps_to_int(config.fps);

	XrCameraIntrinsicsPICO intrinsics{
		XR_TYPE_CAMERA_INTRINSICS_PICO,
		nullptr,
		{},
		{},
		{},
	};
	const XrResult intrinsics_result = xrGetCameraIntrinsicsPICO_ptr(eye_state.capture_session, &intrinsics);
	XrCameraExtrinsicsPICO extrinsics{
		XR_TYPE_CAMERA_EXTRINSICS_PICO,
		nullptr,
		{ { 0.0f, 0.0f, 0.0f, 1.0f }, { 0.0f, 0.0f, 0.0f } },
	};
	const XrResult extrinsics_result = xrGetCameraExtrinsicsPICO_ptr(eye_state.capture_session, &extrinsics);
	eye_state.metadata = camera_metadata_from_session(eye_state, intrinsics_result, intrinsics, extrinsics_result, extrinsics);

	XrCameraCaptureBeginInfoPICO begin_info{
		XR_TYPE_CAMERA_CAPTURE_BEGIN_INFO_PICO,
		nullptr,
	};
	last_camera_image_result = xrBeginCameraCapturePICO_ptr(eye_state.capture_session, &begin_info);
	eye_state.last_result = last_camera_image_result;
	if (XR_FAILED(last_camera_image_result)) {
		return false;
	}
	eye_state.active = true;
	eye_state.last_capture_time = 0;
	return true;
}

void PicoOpenXRExtension::stop_camera_image_eye(CameraImageEyeState &eye_state) {
	if (eye_state.capture_session && xrEndCameraCapturePICO_ptr && eye_state.active) {
		xrEndCameraCapturePICO_ptr(eye_state.capture_session);
	}
	if (eye_state.capture_session && xrDestroyCameraCaptureSessionPICO_ptr) {
		xrDestroyCameraCaptureSessionPICO_ptr(eye_state.capture_session);
	}
	if (eye_state.device && xrDestroyCameraDevicePICO_ptr) {
		xrDestroyCameraDevicePICO_ptr(eye_state.device);
	}
	eye_state.device = XR_NULL_CAMERA_DEVICE_PICO;
	eye_state.capture_session = XR_NULL_CAMERA_CAPTURE_SESSION_PICO;
	eye_state.last_capture_time = 0;
	eye_state.width = 0;
	eye_state.height = 0;
	eye_state.fps = 0;
	eye_state.active = false;
	eye_state.metadata.clear();
}

Dictionary PicoOpenXRExtension::camera_metadata_from_session(const CameraImageEyeState &eye_state, XrResult intrinsics_result, const XrCameraIntrinsicsPICO &intrinsics, XrResult extrinsics_result, const XrCameraExtrinsicsPICO &extrinsics) const {
	Dictionary metadata;
	metadata["source"] = XR_PICO_CAMERA_IMAGE_EXTENSION_NAME;
	metadata["camera_id"] = static_cast<int64_t>(eye_state.camera_id);
	metadata["eye"] = String(eye_state.eye);
	metadata["width"] = eye_state.width;
	metadata["height"] = eye_state.height;
	metadata["fps"] = eye_state.fps;
	metadata["image_format"] = "rgba8888";
	metadata["transfer_type"] = "raw_buffer";
	metadata["camera_model"] = "pinhole";
	metadata["sensor_timestamp_source"] = "openxr_xr_time";

	Array intrinsics_array;
	intrinsics_array.append(intrinsics.focalLength.x);
	intrinsics_array.append(intrinsics.focalLength.y);
	intrinsics_array.append(intrinsics.principalPoint.x);
	intrinsics_array.append(intrinsics.principalPoint.y);
	metadata["lens_intrinsic_calibration"] = intrinsics_array;
	metadata["lens_distortion"] = Array();

	Array rotation;
	rotation.append(extrinsics.pose.orientation.x);
	rotation.append(extrinsics.pose.orientation.y);
	rotation.append(extrinsics.pose.orientation.z);
	rotation.append(extrinsics.pose.orientation.w);
	metadata["lens_pose_rotation"] = rotation;
	Array translation;
	translation.append(extrinsics.pose.position.x);
	translation.append(extrinsics.pose.position.y);
	translation.append(extrinsics.pose.position.z);
	metadata["lens_pose_translation"] = translation;

	Dictionary openxr;
	openxr["intrinsics_result"] = intrinsics_result;
	openxr["extrinsics_result"] = extrinsics_result;
	openxr["fov_x"] = intrinsics.fov.x;
	openxr["fov_y"] = intrinsics.fov.y;
	openxr["focal_length_x"] = intrinsics.focalLength.x;
	openxr["focal_length_y"] = intrinsics.focalLength.y;
	openxr["principal_point_x"] = intrinsics.principalPoint.x;
	openxr["principal_point_y"] = intrinsics.principalPoint.y;
	metadata["openxr_camera_image"] = openxr;
	return metadata;
}

void PicoOpenXRExtension::refresh_camera_image_info() {
	Dictionary info;
	info["extension"] = XR_PICO_CAMERA_IMAGE_EXTENSION_NAME;
	info["supported"] = camera_image_ext;
	info["future_supported"] = future_ext;
	info["session_created"] = current_session() != nullptr;
	info["active"] = camera_image_capture_active;
	info["stereo"] = camera_image_stereo;
	info["width"] = camera_image_width;
	info["height"] = camera_image_height;
	info["fps"] = camera_image_fps;
	info["result"] = last_camera_image_result;
	info["left"] = camera_left.metadata.duplicate(true);
	info["right"] = camera_right.metadata.duplicate(true);
	cached_camera_image_info = info;
}

void PicoOpenXRExtension::reset_camera_image_state() {
	camera_image_capture_active = false;
	camera_left.active = false;
	camera_right.active = false;
	camera_left.last_capture_time = 0;
	camera_right.last_capture_time = 0;
}

bool PicoOpenXRExtension::ensure_body_tracker(const Dictionary &bone_lengths) {
	if (body_tracker != XR_NULL_BODY_TRACKER_BD) {
		return true;
	}
	if (!resolve_functions() || !bd_body_tracking_ext || !xrCreateBodyTrackerBD_ptr || !xrLocateBodyJointsBD_ptr || !current_session()) {
		return false;
	}
	if (system_body_tracking_properties.supportsBodyTracking != XR_TRUE) {
		return false;
	}
	XrBodyBoneLengthPICO bone_length = body_bone_length_from_dict(bone_lengths);
	XrBodyTrackerCreateInfoBD create_info{
		XR_TYPE_BODY_TRACKER_CREATE_INFO_BD,
		has_nonzero_bone_length(bone_length) ? static_cast<const void *>(&bone_length) : nullptr,
		XR_BODY_JOINT_SET_FULL_BODY_JOINTS_BD,
	};
	last_body_create_result = xrCreateBodyTrackerBD_ptr(current_session(), &create_info, &body_tracker);
	if (XR_FAILED(last_body_create_result)) {
		body_tracker = XR_NULL_BODY_TRACKER_BD;
		return false;
	}
	return true;
}

void PicoOpenXRExtension::destroy_body_tracker() {
	if (body_tracker != XR_NULL_BODY_TRACKER_BD && xrDestroyBodyTrackerBD_ptr) {
		xrDestroyBodyTrackerBD_ptr(body_tracker);
	}
	body_tracker = XR_NULL_BODY_TRACKER_BD;
}

bool PicoOpenXRExtension::refresh_external_camera_info() {
	Dictionary info;
	info["extension"] = XR_PICO_EXTERNAL_CAMERA_EXTENSION_NAME;
	info["supported"] = external_camera_ext;
	info["session_created"] = current_session() != nullptr;
	info["result"] = XR_ERROR_HANDLE_INVALID;
	if (!resolve_functions() || !external_camera_ext || !xrGetExternalCameraInfoPICO_ptr || !current_session()) {
		cached_external_camera_info = info;
		return false;
	}
	XrExternalCameraParameterPICO camera_info{
		XR_TYPE_EXTERNAL_CAMERA_PARAMETER_PICO,
		nullptr,
		0,
		0,
		0.0f,
	};
	last_external_camera_result = xrGetExternalCameraInfoPICO_ptr(current_session(), &camera_info);
	info["result"] = last_external_camera_result;
	info["width"] = camera_info.width;
	info["height"] = camera_info.height;
	info["fov"] = camera_info.fov;
	info["available"] = XR_SUCCEEDED(last_external_camera_result);
	cached_external_camera_info = info;
	return XR_SUCCEEDED(last_external_camera_result);
}

XrSession PicoOpenXRExtension::current_session() const {
	return session;
}

XrSpace PicoOpenXRExtension::current_play_space() const {
	Ref<OpenXRAPIExtension> api = const_cast<PicoOpenXRExtension *>(this)->get_openxr_api();
	if (api.is_null()) {
		return nullptr;
	}
	return reinterpret_cast<XrSpace>(api->get_play_space());
}

XrTime PicoOpenXRExtension::current_display_time() const {
	Ref<OpenXRAPIExtension> api = const_cast<PicoOpenXRExtension *>(this)->get_openxr_api();
	if (api.is_null()) {
		return 0;
	}
	return static_cast<XrTime>(api->get_predicted_display_time());
}

Transform3D PicoOpenXRExtension::transform_from_pose(const XrPosef &pose) const {
	const Quaternion q = quaternion_from_xr(pose.orientation);
	const Basis basis(q);
	const Vector3 origin(pose.position.x, pose.position.y, pose.position.z);
	return Transform3D(basis, origin);
}

Dictionary PicoOpenXRExtension::pose_record(const XrPosef &pose) const {
	const Transform3D transform = transform_from_pose(pose);
	Dictionary record;
	record["position"] = vector3_record(transform.origin);
	record["rotation"] = quaternion_record(quaternion_from_xr(pose.orientation));
	record["transform"] = transform;
	return record;
}

Dictionary PicoOpenXRExtension::vector3_record(const Vector3 &value) const {
	Dictionary record;
	record["x"] = value.x;
	record["y"] = value.y;
	record["z"] = value.z;
	return record;
}

Dictionary PicoOpenXRExtension::xr_vector3_record(const XrVector3f &value) const {
	Dictionary record;
	record["x"] = value.x;
	record["y"] = value.y;
	record["z"] = value.z;
	return record;
}

Dictionary PicoOpenXRExtension::quaternion_record(const Quaternion &value) const {
	Dictionary record;
	record["x"] = value.x;
	record["y"] = value.y;
	record["z"] = value.z;
	record["w"] = value.w;
	return record;
}

void PicoOpenXRExtension::add_motion_tracker_id(XrMotionTrackerIdPICO tracker_id) {
	if (tracker_id == 0 || has_motion_tracker_id(tracker_id)) {
		return;
	}
	motion_tracker_ids.append(tracker_id_to_variant(tracker_id));
}

void PicoOpenXRExtension::remove_motion_tracker_id(XrMotionTrackerIdPICO tracker_id) {
	for (int i = motion_tracker_ids.size() - 1; i >= 0; --i) {
		if (static_cast<XrMotionTrackerIdPICO>(int64_t(motion_tracker_ids[i])) == tracker_id) {
			motion_tracker_ids.remove_at(i);
		}
	}
}

bool PicoOpenXRExtension::has_motion_tracker_id(XrMotionTrackerIdPICO tracker_id) const {
	for (int i = 0; i < motion_tracker_ids.size(); ++i) {
		if (static_cast<XrMotionTrackerIdPICO>(int64_t(motion_tracker_ids[i])) == tracker_id) {
			return true;
		}
	}
	return false;
}

XrBodyBoneLengthPICO PicoOpenXRExtension::body_bone_length_from_dict(const Dictionary &bone_lengths) const {
	XrBodyBoneLengthPICO bone_length{
		XR_TYPE_BODY_BONE_LENGTH_PICO,
		nullptr,
		dict_float(bone_lengths, "head"),
		dict_float(bone_lengths, "neck"),
		dict_float(bone_lengths, "torso"),
		dict_float(bone_lengths, "hip"),
		dict_float(bone_lengths, "upper_leg"),
		dict_float(bone_lengths, "lower_leg"),
		dict_float(bone_lengths, "foot"),
		dict_float(bone_lengths, "shoulder"),
		dict_float(bone_lengths, "upper_arm"),
		dict_float(bone_lengths, "lower_arm"),
		dict_float(bone_lengths, "hand"),
	};
	return bone_length;
}

bool PicoOpenXRExtension::has_nonzero_bone_length(const XrBodyBoneLengthPICO &bone_length) const {
	return bone_length.headBoneLength > 0.0f ||
			bone_length.neckBoneLength > 0.0f ||
			bone_length.torsoBoneLength > 0.0f ||
			bone_length.hipBoneLength > 0.0f ||
			bone_length.upperBoneLength > 0.0f ||
			bone_length.lowerBoneLength > 0.0f ||
			bone_length.footBoneLength > 0.0f ||
			bone_length.shoulderBoneLength > 0.0f ||
			bone_length.upperArmBoneLength > 0.0f ||
			bone_length.lowerArmBoneLength > 0.0f ||
			bone_length.handBoneLength > 0.0f;
}
