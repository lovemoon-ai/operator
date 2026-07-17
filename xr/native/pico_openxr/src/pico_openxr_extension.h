#pragma once

#include "pico_openxr_defs.h"
#include "native_recording_pipeline.h"

#include <godot_cpp/classes/open_xr_extension_wrapper_extension.hpp>
#include <godot_cpp/classes/open_xrapi_extension.hpp>
#include <godot_cpp/templates/hash_map.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/transform3d.hpp>

using namespace godot;

class PicoOpenXRExtension : public OpenXRExtensionWrapperExtension {
	GDCLASS(PicoOpenXRExtension, OpenXRExtensionWrapperExtension);

public:
	PicoOpenXRExtension();
	~PicoOpenXRExtension() override;

	Dictionary _get_requested_extensions() override;
	uint64_t _set_system_properties_and_get_next_pointer(void *next_pointer) override;
	void _on_instance_created(uint64_t instance) override;
	void _on_instance_destroyed() override;
	void _on_session_created(uint64_t session) override;
	void _on_session_destroyed() override;
	bool _on_event_polled(const void *event) override;

	Dictionary get_status() const;
	Dictionary get_external_camera_info();
	Dictionary start_camera_image_capture(bool stereo = true, int width = 640, int height = 480, int fps = 30);
	Array poll_camera_image_frames();
	// Kotlin-direct camera pump: binds the capture plugin (JNISingleton) so
	// at most one pending eye frame is submitted via submitOpenXrRgbaFrame
	// straight from C++ — no per-frame GDScript Dictionary/Array marshalling.
	// Stereo calls alternate eyes to spread the two large RGBA copies across
	// separate render ticks. Returns
	// [ok_left, ok_right, fail_left, fail_right, skipped, acquire_us,
	// submit_us] per pump call
	// (skipped = frames dropped before submit: zero-dim or unusable layout,
	// the same class the legacy GDScript pump counted as skip).
	void bind_camera_frame_sink(Object *p_sink);
	PackedInt32Array pump_camera_frames_to_sink();
	bool start_native_recording_pipeline(String codec = "hevc", int bitrate = 8000000,
			int64_t xr_time_to_godot_ns = 0, bool rgb_tracking_sample_metadata = true,
			bool rgb_tracking_sample_head = true,
			bool rgb_tracking_sample_hands = true, String tracking_coordinate_space = "openxr_play_space");
	bool is_native_recording_pipeline_running() const;
	String get_native_recording_pipeline_error() const;
	Dictionary pop_native_recording_metrics();
	void stop_camera_image_capture();
	Dictionary get_camera_image_info() const;
	bool request_motion_trackers(int count);
	Array sample_motion_trackers(int max_count);
	bool start_body_tracking(Dictionary bone_lengths = Dictionary());
	void stop_body_tracking();
	bool start_body_tracking_calibration_app();
	Dictionary sample_body_joints();

	// Ad-hoc probe: returns the raw XR_REFERENCE_SPACE_TYPE_VIEW pose in
	// the OpenXR runtime's play (LOCAL/STAGE) space, expressed as a Godot
	// Transform3D. Used to verify whether Godot's XRCamera3D.global_transform
	// matches what xrLocateSpace(view, play) reports. Empty dictionary when
	// the probe can't run (no session yet, or function resolution failed).
	// Also __android_log_print's the pose to the "Operator-PROBE" tag so the
	// result is visible via logcat without relying on Godot's stdout being
	// captured (it isn't, on Pico).
	Dictionary probe_view_space_pose();

	// Companion logger: emits the godot-side head pose alongside the latest
	// xrLocateSpace VIEW pose so the two are timeline-adjacent in logcat and
	// the delta (godot - openxr) is printed on a single line.
	void log_head_pose_comparison(const Transform3D &godot_head_transform);

protected:
	static void _bind_methods();

private:
	struct CameraImageEyeState {
		const char *eye = "";
		XrCameraIdPICO camera_id = 0;
		XrCameraDevicePICO device = XR_NULL_CAMERA_DEVICE_PICO;
		XrCameraCaptureSessionPICO capture_session = XR_NULL_CAMERA_CAPTURE_SESSION_PICO;
		XrTime last_capture_time = 0;
		int width = 0;
		int height = 0;
		int fps = 0;
		bool active = false;
		XrResult last_result = XR_SUCCESS;
		Dictionary metadata;
		bool calibration_valid = false;
		XrCameraIntrinsicsPICO intrinsics{};
		XrCameraExtrinsicsPICO extrinsics{};
	};

	struct CameraImageCaptureConfig {
		XrExtent2Di resolution{ 0, 0 };
		XrCameraImageFormatPICO format = XR_CAMERA_IMAGE_FORMAT_RGBA_8888_PICO;
		XrCameraDataTransferTypePICO transfer_type = XR_CAMERA_DATA_TRANSFER_TYPE_RAW_BUFFER_PICO;
		XrCameraModelPICO model = XR_CAMERA_MODEL_PINHOLE_PICO;
		XrCameraImageFpsPICO fps = XR_CAMERA_IMAGE_FPS_30_PICO;
	};

	// One normalized camera frame pulled from the PICO runtime (shared by
	// the legacy Dictionary poll and the Kotlin-direct pump).
	struct AcquiredCameraFrame {
		PackedByteArray bytes;
		int64_t capture_time = 0;
		int64_t camera_id = 0;
		uint32_t width = 0;
		uint32_t height = 0;
		uint32_t row_stride = 0;
		uint32_t pixel_stride = 0;
		uint32_t source_bytes_per_pixel = 0;
		uint32_t source_stride = 0;
		uint32_t source_pixel_stride = 0;
		uint32_t buffer_size = 0;
	};

	bool resolve_functions();
	bool wait_future_until_ready(XrFutureEXT future, XrResult &poll_result, int timeout_ms = 3000);
	bool refresh_camera_image_camera_ids();
	bool select_camera_image_config(XrCameraIdPICO camera_id, int preferred_width, int preferred_height, int preferred_fps, CameraImageCaptureConfig &config);
	bool start_camera_image_eye(CameraImageEyeState &eye_state, const CameraImageCaptureConfig &config);
	void stop_camera_image_eye(CameraImageEyeState &eye_state);
	// NONE: no update / acquire failed. FRAME: `out` filled. DROPPED: a new
	// image arrived but was unusable (zero-dim or layout larger than the
	// buffer) — the class the capture pump reports as "skipped".
	enum class CameraAcquire { NONE, FRAME, DROPPED };
	CameraAcquire acquire_camera_frame(CameraImageEyeState &eye_state, AcquiredCameraFrame &out);
	Dictionary camera_metadata_from_session(const CameraImageEyeState &eye_state, XrResult intrinsics_result, const XrCameraIntrinsicsPICO &intrinsics, XrResult extrinsics_result, const XrCameraExtrinsicsPICO &extrinsics) const;
	void refresh_camera_image_info();
	void reset_camera_image_state();
	bool has_camera_image_functions() const;
	bool ensure_native_recording_view_space();
	void destroy_native_recording_view_space();
	bool ensure_hand_trackers();
	void destroy_hand_trackers();
	bool ensure_body_tracker(const Dictionary &bone_lengths);
	void destroy_body_tracker();
	bool refresh_external_camera_info();
	XrSession current_session() const;
	XrSpace current_play_space() const;
	XrTime current_display_time() const;
	Transform3D transform_from_pose(const XrPosef &pose) const;
	Dictionary pose_record(const XrPosef &pose) const;
	Dictionary vector3_record(const Vector3 &value) const;
	Dictionary xr_vector3_record(const XrVector3f &value) const;
	Dictionary quaternion_record(const Quaternion &value) const;
	void add_motion_tracker_id(XrMotionTrackerIdPICO tracker_id);
	void remove_motion_tracker_id(XrMotionTrackerIdPICO tracker_id);
	bool has_motion_tracker_id(XrMotionTrackerIdPICO tracker_id) const;
	XrBodyBoneLengthPICO body_bone_length_from_dict(const Dictionary &bone_lengths) const;
	bool has_nonzero_bone_length(const XrBodyBoneLengthPICO &bone_length) const;

	HashMap<String, bool *> request_extensions;
	bool external_camera_ext = false;
	bool future_ext = false;
	bool camera_image_ext = false;
	bool motion_tracking_ext = false;
	bool pico_body_tracking2_ext = false;
	bool bd_body_tracking_ext = false;
	bool hand_tracking_ext = false;

	XrInstance instance = nullptr;
	XrSession session = nullptr;
	XrSystemBodyTrackingPropertiesBD system_body_tracking_properties = {
		XR_TYPE_SYSTEM_BODY_TRACKING_PROPERTIES_BD,
		nullptr,
		XR_FALSE,
	};

	PFN_xrGetExternalCameraInfoPICO xrGetExternalCameraInfoPICO_ptr = nullptr;
	PFN_xrPollFutureEXT xrPollFutureEXT_ptr = nullptr;
	PFN_xrEnumerateAvailableCamerasPICO xrEnumerateAvailableCamerasPICO_ptr = nullptr;
	PFN_xrEnumerateCameraPropertyTypesPICO xrEnumerateCameraPropertyTypesPICO_ptr = nullptr;
	PFN_xrGetCameraPropertiesPICO xrGetCameraPropertiesPICO_ptr = nullptr;
	PFN_xrEnumerateCameraCapabilityTypesPICO xrEnumerateCameraCapabilityTypesPICO_ptr = nullptr;
	PFN_xrGetCameraSupportedCapabilitiesPICO xrGetCameraSupportedCapabilitiesPICO_ptr = nullptr;
	PFN_xrCreateCameraDeviceAsyncPICO xrCreateCameraDeviceAsyncPICO_ptr = nullptr;
	PFN_xrCreateCameraDeviceCompletePICO xrCreateCameraDeviceCompletePICO_ptr = nullptr;
	PFN_xrDestroyCameraDevicePICO xrDestroyCameraDevicePICO_ptr = nullptr;
	PFN_xrCreateCameraCaptureSessionAsyncPICO xrCreateCameraCaptureSessionAsyncPICO_ptr = nullptr;
	PFN_xrCreateCameraCaptureSessionCompletePICO xrCreateCameraCaptureSessionCompletePICO_ptr = nullptr;
	PFN_xrDestroyCameraCaptureSessionPICO xrDestroyCameraCaptureSessionPICO_ptr = nullptr;
	PFN_xrGetCameraIntrinsicsPICO xrGetCameraIntrinsicsPICO_ptr = nullptr;
	PFN_xrGetCameraExtrinsicsPICO xrGetCameraExtrinsicsPICO_ptr = nullptr;
	PFN_xrBeginCameraCapturePICO xrBeginCameraCapturePICO_ptr = nullptr;
	PFN_xrEndCameraCapturePICO xrEndCameraCapturePICO_ptr = nullptr;
	PFN_xrAcquireCameraImagePICO xrAcquireCameraImagePICO_ptr = nullptr;
	PFN_xrGetCameraImageDataPICO xrGetCameraImageDataPICO_ptr = nullptr;
	PFN_xrReleaseCameraImagePICO xrReleaseCameraImagePICO_ptr = nullptr;
	PFN_xrRequestMotionTrackerDevicePICO xrRequestMotionTrackerDevicePICO_ptr = nullptr;
	PFN_xrGetMotionTrackerBatteryStatePICO xrGetMotionTrackerBatteryStatePICO_ptr = nullptr;
	PFN_xrLocateMotionTrackerPICO xrLocateMotionTrackerPICO_ptr = nullptr;
	PFN_xrCreateBodyTrackerBD xrCreateBodyTrackerBD_ptr = nullptr;
	PFN_xrDestroyBodyTrackerBD xrDestroyBodyTrackerBD_ptr = nullptr;
	PFN_xrLocateBodyJointsBD xrLocateBodyJointsBD_ptr = nullptr;
	PFN_xrStartBodyTrackingCalibrationAppPICO xrStartBodyTrackingCalibrationAppPICO_ptr = nullptr;
	PFN_xrGetBodyTrackingStatePICO xrGetBodyTrackingStatePICO_ptr = nullptr;
	PFN_xrCreateHandTrackerEXT xrCreateHandTrackerEXT_ptr = nullptr;
	PFN_xrDestroyHandTrackerEXT xrDestroyHandTrackerEXT_ptr = nullptr;
	PFN_xrLocateHandJointsEXT xrLocateHandJointsEXT_ptr = nullptr;

	// Core OpenXR ref-space probe; resolved at the same time as PICO extensions.
	PFN_xrCreateReferenceSpace xrCreateReferenceSpace_ptr = nullptr;
	PFN_xrDestroySpace xrDestroySpace_ptr = nullptr;
	PFN_xrLocateSpace xrLocateSpace_ptr = nullptr;

	bool function_resolution_attempted = false;
	XrBodyTrackerBD body_tracker = XR_NULL_BODY_TRACKER_BD;
	Array motion_tracker_ids;
	bool motion_request_sent = false;
	int requested_motion_tracker_count = 0;
	Dictionary last_motion_power_key_event;
	CameraImageEyeState camera_left{"left", 1};
	CameraImageEyeState camera_right{"right", 2};
	uint64_t camera_sink_instance_id = 0;
	int camera_pump_next_eye = 0;
	bool camera_image_capture_active = false;
	bool camera_image_stereo = true;
	int camera_image_width = 640;
	int camera_image_height = 480;
	int camera_image_fps = 30;
	NativeRecordingPipeline native_recording_pipeline;
	XrSpace native_recording_view_space = nullptr;
	XrHandTrackerEXT left_hand_tracker = XR_NULL_HAND_TRACKER_EXT;
	XrHandTrackerEXT right_hand_tracker = XR_NULL_HAND_TRACKER_EXT;
	mutable Dictionary cached_camera_image_info;

	mutable Dictionary cached_external_camera_info;
	XrResult last_external_camera_result = XR_ERROR_HANDLE_INVALID;
	XrResult last_camera_image_result = XR_ERROR_HANDLE_INVALID;
	XrResult last_motion_request_result = XR_ERROR_HANDLE_INVALID;
	XrResult last_body_create_result = XR_ERROR_HANDLE_INVALID;
	XrResult last_body_state_result = XR_ERROR_HANDLE_INVALID;
	XrResult last_body_locate_result = XR_ERROR_HANDLE_INVALID;
};
