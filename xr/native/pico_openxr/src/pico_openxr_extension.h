#pragma once

#include "pico_openxr_defs.h"

#include <godot_cpp/classes/open_xr_extension_wrapper_extension.hpp>
#include <godot_cpp/classes/open_xrapi_extension.hpp>
#include <godot_cpp/templates/hash_map.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
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
	void stop_camera_image_capture();
	Dictionary get_camera_image_info() const;
	bool request_motion_trackers(int count);
	Array sample_motion_trackers(int max_count);
	bool start_body_tracking(Dictionary bone_lengths = Dictionary());
	void stop_body_tracking();
	bool start_body_tracking_calibration_app();
	Dictionary sample_body_joints();

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
	};

	struct CameraImageCaptureConfig {
		XrExtent2Di resolution{ 0, 0 };
		XrCameraImageFormatPICO format = XR_CAMERA_IMAGE_FORMAT_RGBA_8888_PICO;
		XrCameraDataTransferTypePICO transfer_type = XR_CAMERA_DATA_TRANSFER_TYPE_RAW_BUFFER_PICO;
		XrCameraModelPICO model = XR_CAMERA_MODEL_PINHOLE_PICO;
		XrCameraImageFpsPICO fps = XR_CAMERA_IMAGE_FPS_30_PICO;
	};

	bool resolve_functions();
	bool wait_future_until_ready(XrFutureEXT future, XrResult &poll_result, int timeout_ms = 3000);
	bool refresh_camera_image_camera_ids();
	bool select_camera_image_config(XrCameraIdPICO camera_id, int preferred_width, int preferred_height, int preferred_fps, CameraImageCaptureConfig &config);
	bool start_camera_image_eye(CameraImageEyeState &eye_state, const CameraImageCaptureConfig &config);
	void stop_camera_image_eye(CameraImageEyeState &eye_state);
	Dictionary camera_metadata_from_session(const CameraImageEyeState &eye_state, XrResult intrinsics_result, const XrCameraIntrinsicsPICO &intrinsics, XrResult extrinsics_result, const XrCameraExtrinsicsPICO &extrinsics) const;
	void refresh_camera_image_info();
	void reset_camera_image_state();
	bool has_camera_image_functions() const;
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

	bool function_resolution_attempted = false;
	XrBodyTrackerBD body_tracker = XR_NULL_BODY_TRACKER_BD;
	Array motion_tracker_ids;
	bool motion_request_sent = false;
	int requested_motion_tracker_count = 0;
	Dictionary last_motion_power_key_event;
	CameraImageEyeState camera_left{"left", 1};
	CameraImageEyeState camera_right{"right", 2};
	bool camera_image_capture_active = false;
	bool camera_image_stereo = true;
	int camera_image_width = 640;
	int camera_image_height = 480;
	int camera_image_fps = 30;
	mutable Dictionary cached_camera_image_info;

	mutable Dictionary cached_external_camera_info;
	XrResult last_external_camera_result = XR_ERROR_HANDLE_INVALID;
	XrResult last_camera_image_result = XR_ERROR_HANDLE_INVALID;
	XrResult last_motion_request_result = XR_ERROR_HANDLE_INVALID;
	XrResult last_body_create_result = XR_ERROR_HANDLE_INVALID;
	XrResult last_body_state_result = XR_ERROR_HANDLE_INVALID;
	XrResult last_body_locate_result = XR_ERROR_HANDLE_INVALID;
};
