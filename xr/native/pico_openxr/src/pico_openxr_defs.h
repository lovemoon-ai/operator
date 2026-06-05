#pragma once

#include <cstdint>

#if !defined(XRAPI_ATTR)
#define XRAPI_ATTR
#endif

#if !defined(XRAPI_CALL)
#define XRAPI_CALL
#endif

#if !defined(XRAPI_PTR)
#define XRAPI_PTR *
#endif

#if !defined(XR_MAY_ALIAS)
#define XR_MAY_ALIAS
#endif

using XrBool32 = uint32_t;
using XrFlags64 = uint64_t;
using XrResult = int32_t;
using XrStructureType = int32_t;
using XrTime = int64_t;
using XrSpaceLocationFlags = XrFlags64;
using XrSpaceVelocityFlags = XrFlags64;
using XrSpaceAccelerationFlagsPICO = XrFlags64;

struct XrInstance_T;
struct XrSession_T;
struct XrSpace_T;
struct XrBodyTrackerBD_T;
struct XrCameraDevicePICO_T;
struct XrCameraCaptureSessionPICO_T;

using XrInstance = XrInstance_T *;
using XrSession = XrSession_T *;
using XrSpace = XrSpace_T *;
using XrBodyTrackerBD = XrBodyTrackerBD_T *;
using XrCameraDevicePICO = XrCameraDevicePICO_T *;
using XrCameraCaptureSessionPICO = XrCameraCaptureSessionPICO_T *;
using XrFutureEXT = uint64_t;
using XrMotionTrackerIdPICO = uint64_t;
using XrCameraIdPICO = uint64_t;
using XrCameraImageIdPICO = uint64_t;
using PFN_xrVoidFunction = void(XRAPI_PTR)();

static constexpr XrResult XR_SUCCESS = 0;
static constexpr XrResult XR_ERROR_VALIDATION_FAILURE = -1;
static constexpr XrResult XR_ERROR_HANDLE_INVALID = -12;
static constexpr XrResult XR_ERROR_CAMERA_UNAVAILABLE_PICO = -1010033000;
static constexpr XrResult XR_ERROR_CAMERA_OCCUPIED_PICO = -1010033001;
static constexpr XrResult XR_ERROR_CAMERA_CAPTURE_SESSION_CAPTURING_PICO = -1010033002;
static constexpr XrResult XR_ERROR_CAMERA_CAPTURE_SESSION_NOT_CAPTURING_PICO = -1010033003;
static constexpr XrResult XR_ERROR_CAMERA_ID_INVALID_PICO = -1010033004;
static constexpr XrResult XR_ERROR_CAMERA_IMAGE_ID_INVALID_PICO = -1010033005;
static constexpr XrResult XR_ERROR_CAMERA_PROPERTY_TYPE_INVALID_PICO = -1010033006;
static constexpr XrResult XR_ERROR_CAMERA_CAPABILITY_TYPE_INVALID_PICO = -1010033007;
static constexpr XrResult XR_CAMERA_IMAGE_NO_UPDATE_PICO = 1010033000;
static constexpr XrBool32 XR_FALSE = 0;
static constexpr XrBool32 XR_TRUE = 1;
static constexpr XrBodyTrackerBD XR_NULL_BODY_TRACKER_BD = nullptr;
static constexpr XrCameraDevicePICO XR_NULL_CAMERA_DEVICE_PICO = nullptr;
static constexpr XrCameraCaptureSessionPICO XR_NULL_CAMERA_CAPTURE_SESSION_PICO = nullptr;
static constexpr XrFutureEXT XR_NULL_FUTURE_EXT = 0;

#define XR_FAILED(result) ((result) < 0)
#define XR_SUCCEEDED(result) ((result) >= 0)

static constexpr XrSpaceLocationFlags XR_SPACE_LOCATION_ORIENTATION_VALID_BIT = 0x00000001;
static constexpr XrSpaceLocationFlags XR_SPACE_LOCATION_POSITION_VALID_BIT = 0x00000002;
static constexpr XrSpaceLocationFlags XR_SPACE_LOCATION_ORIENTATION_TRACKED_BIT = 0x00000004;
static constexpr XrSpaceLocationFlags XR_SPACE_LOCATION_POSITION_TRACKED_BIT = 0x00000008;
static constexpr XrSpaceVelocityFlags XR_SPACE_VELOCITY_LINEAR_VALID_BIT = 0x00000001;
static constexpr XrSpaceVelocityFlags XR_SPACE_VELOCITY_ANGULAR_VALID_BIT = 0x00000002;
static constexpr XrSpaceAccelerationFlagsPICO XR_SPACE_ACCELERATION_LINEAR_VALID_BIT_PICO = 0x00000001;
static constexpr XrSpaceAccelerationFlagsPICO XR_SPACE_ACCELERATION_ANGULAR_VALID_BIT_PICO = 0x00000002;

static constexpr XrStructureType XR_TYPE_SYSTEM_BODY_TRACKING_PROPERTIES_BD = 1000385004;
static constexpr XrStructureType XR_TYPE_BODY_TRACKER_CREATE_INFO_BD = 1000385001;
static constexpr XrStructureType XR_TYPE_BODY_JOINTS_LOCATE_INFO_BD = 1000385002;
static constexpr XrStructureType XR_TYPE_BODY_JOINT_LOCATIONS_BD = 1000385003;
static constexpr XrStructureType XR_TYPE_EXTERNAL_CAMERA_PARAMETER_PICO = 1010000002;
static constexpr XrStructureType XR_TYPE_MOTION_TRACKER_BATTERY_STATE_PICO = 1010002000;
static constexpr XrStructureType XR_TYPE_MOTION_TRACKER_LOCATION_INFO_PICO = 1010002001;
static constexpr XrStructureType XR_TYPE_MOTION_TRACKER_SPACE_LOCATION_PICO = 1010002002;
static constexpr XrStructureType XR_TYPE_MOTION_TRACKER_SPACE_VELOCITY_PICO = 1010002003;
static constexpr XrStructureType XR_TYPE_EVENT_DATA_REQUEST_MOTION_TRACKER_COMPLETE_PICO = 1010002004;
static constexpr XrStructureType XR_TYPE_EVENT_DATA_MOTION_TRACKER_CONNECTION_STATE_CHANGED_PICO = 1010002005;
static constexpr XrStructureType XR_TYPE_EVENT_DATA_MOTION_TRACKER_POWER_KEY_EVENT_PICO = 1010002006;
static constexpr XrStructureType XR_TYPE_BODY_BONE_LENGTH_PICO = 1010009001;
static constexpr XrStructureType XR_TYPE_BODY_TRACKING_POSTURE_FLAGS_DATA_PICO = 1010009002;
static constexpr XrStructureType XR_TYPE_BODY_JOINT_VELOCITIES_PICO = 1010009003;
static constexpr XrStructureType XR_TYPE_BODY_JOINT_ACCELERATIONS_PICO = 1010009004;
static constexpr XrStructureType XR_TYPE_BODY_TRACKING_STATE_PICO = 1010009005;
static constexpr XrStructureType XR_TYPE_FUTURE_POLL_INFO_EXT = 1000469001;
static constexpr XrStructureType XR_TYPE_FUTURE_POLL_RESULT_EXT = 1000469003;
static constexpr XrStructureType XR_TYPE_AVAILABLE_CAMERAS_ENUMERATE_INFO_PICO = 1010033000;
static constexpr XrStructureType XR_TYPE_CAMERA_PROPERTIES_GET_INFO_PICO = 1010033001;
static constexpr XrStructureType XR_TYPE_CAMERA_PROPERTIES_PICO = 1010033002;
static constexpr XrStructureType XR_TYPE_CAMERA_PROPERTY_FACING_PICO = 1010033003;
static constexpr XrStructureType XR_TYPE_CAMERA_PROPERTY_POSITION_PICO = 1010033004;
static constexpr XrStructureType XR_TYPE_CAMERA_PROPERTY_CAMERA_TYPE_PICO = 1010033005;
static constexpr XrStructureType XR_TYPE_CAMERA_DEVICE_CREATE_INFO_PICO = 1010033018;
static constexpr XrStructureType XR_TYPE_CREATE_CAMERA_DEVICE_COMPLETION_PICO = 1010033019;
static constexpr XrStructureType XR_TYPE_CAMERA_CAPTURE_SESSION_CREATE_INFO_PICO = 1010033020;
static constexpr XrStructureType XR_TYPE_CREATE_CAMERA_CAPTURE_SESSION_COMPLETION_PICO = 1010033021;
static constexpr XrStructureType XR_TYPE_CAMERA_INTRINSICS_PICO = 1010033022;
static constexpr XrStructureType XR_TYPE_CAMERA_EXTRINSICS_PICO = 1010033023;
static constexpr XrStructureType XR_TYPE_CAMERA_CAPTURE_BEGIN_INFO_PICO = 1010033024;
static constexpr XrStructureType XR_TYPE_CAMERA_IMAGE_ACQUIRE_INFO_PICO = 1010033025;
static constexpr XrStructureType XR_TYPE_CAMERA_IMAGE_PICO = 1010033026;
static constexpr XrStructureType XR_TYPE_CAMERA_IMAGE_DATA_RAW_BUFFER_PICO = 1010033027;
static constexpr XrStructureType XR_TYPE_CAMERA_SUPPORTED_CAPABILITIES_GET_INFO_PICO = 1010033006;
static constexpr XrStructureType XR_TYPE_CAMERA_SUPPORTED_CAPABILITIES_PICO = 1010033007;
static constexpr XrStructureType XR_TYPE_CAMERA_SUPPORTED_CAPABILITY_IMAGE_RESOLUTION_PICO = 1010033008;
static constexpr XrStructureType XR_TYPE_CAMERA_SUPPORTED_CAPABILITY_DATA_TRANSFER_TYPE_PICO = 1010033010;
static constexpr XrStructureType XR_TYPE_CAMERA_SUPPORTED_CAPABILITY_IMAGE_FORMAT_PICO = 1010033012;
static constexpr XrStructureType XR_TYPE_CAMERA_SUPPORTED_CAPABILITY_CAMERA_MODEL_PICO = 1010033014;
static constexpr XrStructureType XR_TYPE_CAMERA_SUPPORTED_CAPABILITY_IMAGE_FPS_PICO = 1010033016;
static constexpr XrStructureType XR_TYPE_CAMERA_CAPABILITY_IMAGE_RESOLUTION_PICO = 1010033009;
static constexpr XrStructureType XR_TYPE_CAMERA_CAPABILITY_DATA_TRANSFER_TYPE_PICO = 1010033011;
static constexpr XrStructureType XR_TYPE_CAMERA_CAPABILITY_IMAGE_FORMAT_PICO = 1010033013;
static constexpr XrStructureType XR_TYPE_CAMERA_CAPABILITY_CAMERA_MODEL_PICO = 1010033015;
static constexpr XrStructureType XR_TYPE_CAMERA_CAPABILITY_IMAGE_FPS_PICO = 1010033017;
static constexpr XrStructureType XR_TYPE_CAMERA_CAPABILITIES_PICO = 1010033028;

static constexpr const char *XR_PICO_EXTERNAL_CAMERA_EXTENSION_NAME = "XR_PICO_external_camera";
static constexpr const char *XR_EXT_FUTURE_EXTENSION_NAME = "XR_EXT_future";
static constexpr const char *XR_PICO_CAMERA_IMAGE_EXTENSION_NAME = "XR_PICO_camera_image";
static constexpr const char *XR_PICO_MOTION_TRACKING_EXTENSION_NAME = "XR_PICO_motion_tracking";
static constexpr const char *XR_PICO_BODY_TRACKING2_EXTENSION_NAME = "XR_PICO_body_tracking2";
static constexpr const char *XR_BD_BODY_TRACKING_EXTENSION_NAME = "XR_BD_body_tracking";

static constexpr uint32_t XR_MOTION_TRACKER_MAX_SIZE_PICO = 6;
static constexpr uint32_t XR_BODY_JOINT_COUNT_BD = 24;
static constexpr uint32_t XR_BODY_JOINT_WITHOUT_ARM_COUNT_BD = 16;

enum XrBodyJointBD {
	XR_BODY_JOINT_PELVIS_BD = 0,
	XR_BODY_JOINT_LEFT_HIP_BD = 1,
	XR_BODY_JOINT_RIGHT_HIP_BD = 2,
	XR_BODY_JOINT_SPINE1_BD = 3,
	XR_BODY_JOINT_LEFT_KNEE_BD = 4,
	XR_BODY_JOINT_RIGHT_KNEE_BD = 5,
	XR_BODY_JOINT_SPINE2_BD = 6,
	XR_BODY_JOINT_LEFT_ANKLE_BD = 7,
	XR_BODY_JOINT_RIGHT_ANKLE_BD = 8,
	XR_BODY_JOINT_SPINE3_BD = 9,
	XR_BODY_JOINT_LEFT_FOOT_BD = 10,
	XR_BODY_JOINT_RIGHT_FOOT_BD = 11,
	XR_BODY_JOINT_NECK_BD = 12,
	XR_BODY_JOINT_LEFT_COLLAR_BD = 13,
	XR_BODY_JOINT_RIGHT_COLLAR_BD = 14,
	XR_BODY_JOINT_HEAD_BD = 15,
	XR_BODY_JOINT_LEFT_SHOULDER_BD = 16,
	XR_BODY_JOINT_RIGHT_SHOULDER_BD = 17,
	XR_BODY_JOINT_LEFT_ELBOW_BD = 18,
	XR_BODY_JOINT_RIGHT_ELBOW_BD = 19,
	XR_BODY_JOINT_LEFT_WRIST_BD = 20,
	XR_BODY_JOINT_RIGHT_WRIST_BD = 21,
	XR_BODY_JOINT_LEFT_HAND_BD = 22,
	XR_BODY_JOINT_RIGHT_HAND_BD = 23,
	XR_BODY_JOINT_MAX_ENUM_BD = 0x7FFFFFFF,
};

enum XrBodyJointSetBD {
	XR_BODY_JOINT_SET_BODY_WITHOUT_ARM_BD = 1,
	XR_BODY_JOINT_SET_FULL_BODY_JOINTS_BD = 2,
	XR_BODY_JOINT_SET_MAX_ENUM_BD = 0x7FFFFFFF,
};

enum XrMotionTrackerConnectionStatePICO {
	XR_MOTION_TRACKER_CONNECTION_STATE_DISCONNECTED_PICO = 0,
	XR_MOTION_TRACKER_CONNECTION_STATE_CONNECTED_PICO = 1,
	XR_MOTION_TRACKER_CONNECTION_STATE_MAX_ENUM_PICO = 0x7FFFFFFF,
};

enum XrMotionTrackerChargingStatePICO {
	XR_MOTION_TRACKER_CHARGING_STATE_UNCHARGED_PICO = 0,
	XR_MOTION_TRACKER_CHARGING_STATE_TRICKLE_CHARGING_PICO = 1,
	XR_MOTION_TRACKER_CHARGING_STATE_CHARGING_PICO = 2,
	XR_MOTION_TRACKER_CHARGING_STATE_CHARGE_COMPLETED_PICO = 3,
	XR_MOTION_TRACKER_CHARGING_STATE_MAX_ENUM_PICO = 0x7FFFFFFF,
};

enum XrBodyTrackingPosturePICO {
	XR_BODY_TRACKING_POSTURE_STOMP_PICO = 1,
	XR_BODY_TRACKING_POSTURE_STATIC_PICO = 2,
	XR_BODY_TRACKING_POSTURE_MAX_ENUM_PICO = 0x7FFFFFFF,
};

enum XrBodyTrackingStatusPICO {
	XR_BODY_TRACKING_STATUS_INVALID_PICO = 0,
	XR_BODY_TRACKING_STATUS_VALID_PICO = 1,
	XR_BODY_TRACKING_STATUS_LIMITED_PICO = 2,
	XR_BODY_TRACKING_STATUS_MAX_ENUM_PICO = 0x7FFFFFFF,
};

enum XrBodyTrackingMessagePICO {
	XR_BODY_TRACKING_MESSAGE_NO_ERROR_PICO = 0,
	XR_BODY_TRACKING_MESSAGE_TRACKER_NOT_CALIBRATED_PICO = 1,
	XR_BODY_TRACKING_MESSAGE_TRACKER_NUM_NOT_ENOUGH_PICO = 2,
	XR_BODY_TRACKING_MESSAGE_TRACKER_STATE_NOT_SATISFIED_PICO = 3,
	XR_BODY_TRACKING_MESSAGE_TRACKER_PERSISTENT_INVISIBILITY_PICO = 4,
	XR_BODY_TRACKING_MESSAGE_TRACKER_DATA_ERROR_PICO = 5,
	XR_BODY_TRACKING_MESSAGE_USER_CHANGE_PICO = 6,
	XR_BODY_TRACKING_MESSAGE_TRACKING_POSE_ERROR_PICO = 7,
	XR_BODY_TRACKING_MESSAGE_MAX_ENUM_PICO = 0x7FFFFFFF,
};

enum XrFutureStateEXT {
	XR_FUTURE_STATE_PENDING_EXT = 1,
	XR_FUTURE_STATE_READY_EXT = 2,
	XR_FUTURE_STATE_MAX_ENUM_EXT = 0x7FFFFFFF,
};

enum XrCameraDataTransferTypePICO {
	XR_CAMERA_DATA_TRANSFER_TYPE_RAW_BUFFER_PICO = 1,
	XR_CAMERA_DATA_TRANSFER_TYPE_MAX_ENUM_PICO = 0x7FFFFFFF,
};

enum XrCameraImageFormatPICO {
	XR_CAMERA_IMAGE_FORMAT_RGBA_8888_PICO = 1,
	XR_CAMERA_IMAGE_FORMAT_MAX_ENUM_PICO = 0x7FFFFFFF,
};

enum XrCameraModelPICO {
	XR_CAMERA_MODEL_PINHOLE_PICO = 1,
	XR_CAMERA_MODEL_MAX_ENUM_PICO = 0x7FFFFFFF,
};

enum XrCameraImageFpsPICO {
	XR_CAMERA_IMAGE_FPS_30_PICO = 1,
	XR_CAMERA_IMAGE_FPS_60_PICO = 2,
	XR_CAMERA_IMAGE_FPS_MAX_ENUM_PICO = 0x7FFFFFFF,
};

enum XrCameraCapabilityTypePICO {
	XR_CAMERA_CAPABILITY_TYPE_IMAGE_RESOLUTION_PICO = 1,
	XR_CAMERA_CAPABILITY_TYPE_IMAGE_FORMAT_PICO = 2,
	XR_CAMERA_CAPABILITY_TYPE_DATA_TRANSFER_TYPE_PICO = 3,
	XR_CAMERA_CAPABILITY_TYPE_CAMERA_MODEL_PICO = 4,
	XR_CAMERA_CAPABILITY_TYPE_IMAGE_FPS_PICO = 5,
	XR_CAMERA_CAPABILITY_TYPE_MAX_ENUM_PICO = 0x7FFFFFFF,
};

enum XrCameraPropertyTypePICO {
	XR_CAMERA_PROPERTY_TYPE_FACING_PICO = 1,
	XR_CAMERA_PROPERTY_TYPE_POSITION_PICO = 2,
	XR_CAMERA_PROPERTY_TYPE_CAMERA_TYPE_PICO = 3,
	XR_CAMERA_PROPERTY_TYPE_MAX_ENUM_PICO = 0x7FFFFFFF,
};

enum XrCameraFacingPICO {
	XR_CAMERA_FACING_WORLD_PICO = 1,
	XR_CAMERA_FACING_MAX_ENUM_PICO = 0x7FFFFFFF,
};

enum XrCameraPositionPICO {
	XR_CAMERA_POSITION_UNSPECIFIED_PICO = 1,
	XR_CAMERA_POSITION_LEFT_PICO = 2,
	XR_CAMERA_POSITION_RIGHT_PICO = 3,
	XR_CAMERA_POSITION_MAX_ENUM_PICO = 0x7FFFFFFF,
};

enum XrCameraTypePICO {
	XR_CAMERA_TYPE_PASSTHROUGH_COLOR_PICO = 1,
	XR_CAMERA_TYPE_MAX_ENUM_PICO = 0x7FFFFFFF,
};

struct XrVector2f {
	float x;
	float y;
};

struct XrVector3f {
	float x;
	float y;
	float z;
};

struct XrExtent2Di {
	int32_t width;
	int32_t height;
};

struct XrQuaternionf {
	float x;
	float y;
	float z;
	float w;
};

struct XrPosef {
	XrQuaternionf orientation;
	XrVector3f position;
};

struct XrSystemBodyTrackingPropertiesBD {
	XrStructureType type;
	void *XR_MAY_ALIAS next;
	XrBool32 supportsBodyTracking;
};

struct XrBodyTrackerCreateInfoBD {
	XrStructureType type;
	const void *XR_MAY_ALIAS next;
	XrBodyJointSetBD jointSet;
};

struct XrBodyJointsLocateInfoBD {
	XrStructureType type;
	const void *XR_MAY_ALIAS next;
	XrSpace baseSpace;
	XrTime time;
};

struct XrBodyJointLocationBD {
	XrSpaceLocationFlags locationFlags;
	XrPosef pose;
};

struct XrBodyJointLocationsBD {
	XrStructureType type;
	void *XR_MAY_ALIAS next;
	XrBool32 allJointPosesTracked;
	uint32_t jointLocationCount;
	XrBodyJointLocationBD *jointLocations;
};

struct XrExternalCameraParameterPICO {
	XrStructureType type;
	void *XR_MAY_ALIAS next;
	int32_t width;
	int32_t height;
	float fov;
};

struct XrFuturePollInfoEXT {
	XrStructureType type;
	const void *XR_MAY_ALIAS next;
	XrFutureEXT future;
};

struct XrFuturePollResultEXT {
	XrStructureType type;
	void *XR_MAY_ALIAS next;
	XrFutureStateEXT state;
};

struct XrCameraCapabilityBaseHeaderPICO {
	XrStructureType type;
	const void *XR_MAY_ALIAS next;
};

struct XrCameraPropertyBaseHeaderPICO {
	XrStructureType type;
	const void *XR_MAY_ALIAS next;
};

struct XrCameraPropertiesPICO {
	XrStructureType type;
	const void *XR_MAY_ALIAS next;
	uint32_t propertyCount;
	XrCameraPropertyBaseHeaderPICO **properties;
};

struct XrCameraCapabilitiesPICO {
	XrStructureType type;
	const void *XR_MAY_ALIAS next;
	uint32_t capabilityCount;
	XrCameraCapabilityBaseHeaderPICO **capabilities;
};

struct XrAvailableCamerasEnumerateInfoPICO {
	XrStructureType type;
	const void *XR_MAY_ALIAS next;
	const XrCameraPropertiesPICO *properties;
	const XrCameraCapabilitiesPICO *capabilities;
};

struct XrCameraPropertiesGetInfoPICO {
	XrStructureType type;
	const void *XR_MAY_ALIAS next;
	XrCameraIdPICO cameraId;
};

struct XrCameraPropertyFacingPICO {
	XrStructureType type;
	const void *XR_MAY_ALIAS next;
	XrCameraFacingPICO facing;
};

struct XrCameraPropertyPositionPICO {
	XrStructureType type;
	const void *XR_MAY_ALIAS next;
	XrCameraPositionPICO position;
};

struct XrCameraPropertyCameraTypePICO {
	XrStructureType type;
	const void *XR_MAY_ALIAS next;
	XrCameraTypePICO cameraType;
};

struct XrCameraSupportedCapabilitiesGetInfoPICO {
	XrStructureType type;
	const void *XR_MAY_ALIAS next;
	XrCameraIdPICO id;
};

struct XrCameraSupportedCapabilityBaseHeaderPICO {
	XrStructureType type;
	const void *XR_MAY_ALIAS next;
};

struct XrCameraSupportedCapabilitiesPICO {
	XrStructureType type;
	const void *XR_MAY_ALIAS next;
	uint32_t capabilityCount;
	XrCameraSupportedCapabilityBaseHeaderPICO **capabilities;
};

struct XrCameraSupportedCapabilityImageResolutionPICO {
	XrStructureType type;
	const void *XR_MAY_ALIAS next;
	uint32_t resolutionCapacityInput;
	uint32_t resolutionCountOutput;
	XrExtent2Di *resolutions;
};

struct XrCameraSupportedCapabilityImageFormatPICO {
	XrStructureType type;
	const void *XR_MAY_ALIAS next;
	uint32_t formatCapacityInput;
	uint32_t formatCountOutput;
	XrCameraImageFormatPICO *formats;
};

struct XrCameraSupportedCapabilityDataTransferTypePICO {
	XrStructureType type;
	const void *XR_MAY_ALIAS next;
	uint32_t typeCapacityInput;
	uint32_t typeCountOutput;
	XrCameraDataTransferTypePICO *types;
};

struct XrCameraSupportedCapabilityCameraModelPICO {
	XrStructureType type;
	const void *XR_MAY_ALIAS next;
	uint32_t modelCapacityInput;
	uint32_t modelCountOutput;
	XrCameraModelPICO *models;
};

struct XrCameraSupportedCapabilityImageFpsPICO {
	XrStructureType type;
	const void *XR_MAY_ALIAS next;
	uint32_t fpsCapacityInput;
	uint32_t fpsCountOutput;
	XrCameraImageFpsPICO *fps;
};

struct XrCameraCapabilityImageResolutionPICO {
	XrStructureType type;
	const void *XR_MAY_ALIAS next;
	XrExtent2Di resolution;
};

struct XrCameraCapabilityImageFormatPICO {
	XrStructureType type;
	const void *XR_MAY_ALIAS next;
	XrCameraImageFormatPICO format;
};

struct XrCameraCapabilityDataTransferTypePICO {
	XrStructureType type;
	const void *XR_MAY_ALIAS next;
	XrCameraDataTransferTypePICO transferType;
};

struct XrCameraCapabilityCameraModelPICO {
	XrStructureType type;
	const void *XR_MAY_ALIAS next;
	XrCameraModelPICO model;
};

struct XrCameraCapabilityImageFpsPICO {
	XrStructureType type;
	const void *XR_MAY_ALIAS next;
	XrCameraImageFpsPICO fps;
};

struct XrCameraDeviceCreateInfoPICO {
	XrStructureType type;
	const void *XR_MAY_ALIAS next;
	XrCameraIdPICO cameraId;
};

struct XrCreateCameraDeviceCompletionPICO {
	XrStructureType type;
	void *XR_MAY_ALIAS next;
	XrResult futureResult;
	XrCameraDevicePICO device;
};

struct XrCameraCaptureSessionCreateInfoPICO {
	XrStructureType type;
	const void *XR_MAY_ALIAS next;
	XrCameraDevicePICO camera;
	uint32_t configCount;
	const XrCameraCapabilityBaseHeaderPICO *const *configs;
};

struct XrCreateCameraCaptureSessionCompletionPICO {
	XrStructureType type;
	void *XR_MAY_ALIAS next;
	XrResult futureResult;
	XrCameraCaptureSessionPICO captureSession;
};

struct XrCameraIntrinsicsPICO {
	XrStructureType type;
	const void *XR_MAY_ALIAS next;
	XrVector2f focalLength;
	XrVector2f principalPoint;
	XrVector2f fov;
};

struct XrCameraExtrinsicsPICO {
	XrStructureType type;
	const void *XR_MAY_ALIAS next;
	XrPosef pose;
};

struct XrCameraCaptureBeginInfoPICO {
	XrStructureType type;
	const void *XR_MAY_ALIAS next;
};

struct XrCameraImageAcquireInfoPICO {
	XrStructureType type;
	const void *XR_MAY_ALIAS next;
	XrTime lastCaptureTime;
};

struct XrCameraImagePICO {
	XrStructureType type;
	const void *XR_MAY_ALIAS next;
	XrTime captureTime;
	XrCameraImageIdPICO imageId;
};

struct XrCameraImageDataBaseHeaderPICO {
	XrStructureType type;
	const void *XR_MAY_ALIAS next;
};

struct XrCameraImageDataRawBufferPICO {
	XrStructureType type;
	const void *XR_MAY_ALIAS next;
	uint32_t width;
	uint32_t height;
	uint32_t stride;
	uint32_t bytesPerPixel;
	uint32_t pixelStride;
	uint32_t bufferSize;
	uint8_t *buffer;
};

struct XrMotionTrackerSpaceLocationPICO {
	XrStructureType type;
	void *XR_MAY_ALIAS next;
	XrSpaceLocationFlags locationFlags;
	XrPosef pose;
};

struct XrMotionTrackerSpaceVelocityPICO {
	XrStructureType type;
	void *XR_MAY_ALIAS next;
	XrSpaceVelocityFlags velocityFlags;
	XrVector3f linearVelocity;
	XrVector3f angularVelocity;
	XrVector3f linearAcceleration;
	XrVector3f angularAcceleration;
};

struct XrEventDataRequestMotionTrackerCompletePICO {
	XrStructureType type;
	const void *XR_MAY_ALIAS next;
	uint32_t trackerCount;
	XrMotionTrackerIdPICO trackerIds[XR_MOTION_TRACKER_MAX_SIZE_PICO];
	XrResult result;
};

struct XrEventDataMotionTrackerConnectionStateChangedPICO {
	XrStructureType type;
	const void *XR_MAY_ALIAS next;
	XrMotionTrackerIdPICO trackerId;
	XrMotionTrackerConnectionStatePICO state;
};

struct XrEventDataMotionTrackerPowerKeyEventPICO {
	XrStructureType type;
	const void *XR_MAY_ALIAS next;
	XrMotionTrackerIdPICO trackerId;
	XrBool32 isLongClick;
};

struct XrMotionTrackerBatteryStatePICO {
	XrStructureType type;
	void *XR_MAY_ALIAS next;
	float batteryLevel;
	XrMotionTrackerChargingStatePICO chargingState;
};

struct XrMotionTrackerLocationInfoPICO {
	XrStructureType type;
	const void *XR_MAY_ALIAS next;
	XrSpace baseSpace;
	XrTime time;
};

struct XrBodyBoneLengthPICO {
	XrStructureType type;
	void *XR_MAY_ALIAS next;
	float headBoneLength;
	float neckBoneLength;
	float torsoBoneLength;
	float hipBoneLength;
	float upperBoneLength;
	float lowerBoneLength;
	float footBoneLength;
	float shoulderBoneLength;
	float upperArmBoneLength;
	float lowerArmBoneLength;
	float handBoneLength;
};

struct XrBodyTrackingPostureFlagsDataPICO {
	XrStructureType type;
	void *XR_MAY_ALIAS next;
	uint32_t jointCount;
	XrBodyTrackingPosturePICO *postureFlag;
};

struct XrBodyJointVelocityPICO {
	XrSpaceVelocityFlags velocityFlags;
	XrVector3f linearVelocity;
	XrVector3f angularVelocity;
};

struct XrBodyJointVelocitiesPICO {
	XrStructureType type;
	void *XR_MAY_ALIAS next;
	uint32_t jointCount;
	XrBodyJointVelocityPICO *jointVelocities;
};

struct XrBodyJointAccelerationPICO {
	XrSpaceAccelerationFlagsPICO accelerationFlags;
	XrVector3f linearAcceleration;
	XrVector3f angularAcceleration;
};

struct XrBodyJointAccelerationsPICO {
	XrStructureType type;
	void *XR_MAY_ALIAS next;
	uint32_t jointCount;
	XrBodyJointAccelerationPICO *jointAccelerations;
};

struct XrBodyTrackingStatePICO {
	XrStructureType type;
	const void *XR_MAY_ALIAS next;
	XrBodyTrackingStatusPICO status;
	XrBodyTrackingMessagePICO message;
};

using PFN_xrGetExternalCameraInfoPICO = XrResult(XRAPI_PTR)(XrSession session, XrExternalCameraParameterPICO *info);
using PFN_xrPollFutureEXT = XrResult(XRAPI_PTR)(XrInstance instance, const XrFuturePollInfoEXT *pollInfo, XrFuturePollResultEXT *pollResult);
using PFN_xrEnumerateAvailableCamerasPICO = XrResult(XRAPI_PTR)(XrInstance instance, const XrAvailableCamerasEnumerateInfoPICO *enumerateInfo, uint32_t cameraIdCapacityInput, uint32_t *cameraIdCountOutput, XrCameraIdPICO *cameraIds);
using PFN_xrEnumerateCameraPropertyTypesPICO = XrResult(XRAPI_PTR)(XrInstance instance, XrCameraIdPICO cameraId, uint32_t typeCapacityInput, uint32_t *typeCountOutput, XrCameraPropertyTypePICO *types);
using PFN_xrGetCameraPropertiesPICO = XrResult(XRAPI_PTR)(XrInstance instance, const XrCameraPropertiesGetInfoPICO *getInfo, XrCameraPropertiesPICO *properties);
using PFN_xrEnumerateCameraCapabilityTypesPICO = XrResult(XRAPI_PTR)(XrInstance instance, XrCameraIdPICO cameraId, uint32_t typeCapacityInput, uint32_t *typeCountOutput, XrCameraCapabilityTypePICO *types);
using PFN_xrGetCameraSupportedCapabilitiesPICO = XrResult(XRAPI_PTR)(XrInstance instance, const XrCameraSupportedCapabilitiesGetInfoPICO *getInfo, XrCameraSupportedCapabilitiesPICO *capabilities);
using PFN_xrCreateCameraDeviceAsyncPICO = XrResult(XRAPI_PTR)(XrInstance instance, const XrCameraDeviceCreateInfoPICO *createInfo, XrFutureEXT *future);
using PFN_xrCreateCameraDeviceCompletePICO = XrResult(XRAPI_PTR)(XrInstance instance, XrFutureEXT future, XrCreateCameraDeviceCompletionPICO *completion);
using PFN_xrDestroyCameraDevicePICO = XrResult(XRAPI_PTR)(XrCameraDevicePICO device);
using PFN_xrCreateCameraCaptureSessionAsyncPICO = XrResult(XRAPI_PTR)(XrSession session, const XrCameraCaptureSessionCreateInfoPICO *createInfo, XrFutureEXT *future);
using PFN_xrCreateCameraCaptureSessionCompletePICO = XrResult(XRAPI_PTR)(XrSession session, XrFutureEXT future, XrCreateCameraCaptureSessionCompletionPICO *completion);
using PFN_xrDestroyCameraCaptureSessionPICO = XrResult(XRAPI_PTR)(XrCameraCaptureSessionPICO captureSession);
using PFN_xrGetCameraIntrinsicsPICO = XrResult(XRAPI_PTR)(XrCameraCaptureSessionPICO session, XrCameraIntrinsicsPICO *intrinsics);
using PFN_xrGetCameraExtrinsicsPICO = XrResult(XRAPI_PTR)(XrCameraCaptureSessionPICO session, XrCameraExtrinsicsPICO *extrinsics);
using PFN_xrBeginCameraCapturePICO = XrResult(XRAPI_PTR)(XrCameraCaptureSessionPICO session, XrCameraCaptureBeginInfoPICO *beginInfo);
using PFN_xrEndCameraCapturePICO = XrResult(XRAPI_PTR)(XrCameraCaptureSessionPICO session);
using PFN_xrAcquireCameraImagePICO = XrResult(XRAPI_PTR)(XrCameraCaptureSessionPICO session, const XrCameraImageAcquireInfoPICO *acquireInfo, XrCameraImagePICO *image);
using PFN_xrGetCameraImageDataPICO = XrResult(XRAPI_PTR)(XrCameraCaptureSessionPICO session, XrCameraImageIdPICO imageId, XrCameraImageDataBaseHeaderPICO *imageData);
using PFN_xrReleaseCameraImagePICO = XrResult(XRAPI_PTR)(XrCameraCaptureSessionPICO session, XrCameraImageIdPICO imageId);
using PFN_xrRequestMotionTrackerDevicePICO = XrResult(XRAPI_PTR)(XrSession session, uint32_t deviceCount);
using PFN_xrGetMotionTrackerBatteryStatePICO = XrResult(XRAPI_PTR)(XrSession session, XrMotionTrackerIdPICO trackerId, XrMotionTrackerBatteryStatePICO *batteryState);
using PFN_xrLocateMotionTrackerPICO = XrResult(XRAPI_PTR)(XrSession session, XrMotionTrackerIdPICO trackerId, const XrMotionTrackerLocationInfoPICO *locationInfo, XrMotionTrackerSpaceLocationPICO *location);
using PFN_xrCreateBodyTrackerBD = XrResult(XRAPI_PTR)(XrSession session, const XrBodyTrackerCreateInfoBD *createInfo, XrBodyTrackerBD *bodyTracker);
using PFN_xrDestroyBodyTrackerBD = XrResult(XRAPI_PTR)(XrBodyTrackerBD bodyTracker);
using PFN_xrLocateBodyJointsBD = XrResult(XRAPI_PTR)(XrBodyTrackerBD bodyTracker, const XrBodyJointsLocateInfoBD *locateInfo, XrBodyJointLocationsBD *locations);
using PFN_xrStartBodyTrackingCalibrationAppPICO = XrResult(XRAPI_PTR)(XrSession session);
using PFN_xrGetBodyTrackingStatePICO = XrResult(XRAPI_PTR)(XrSession session, XrBodyTrackingStatePICO *state);
