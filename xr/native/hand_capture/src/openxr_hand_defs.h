#pragma once

// Minimal OpenXR declarations used by NativeOpenXRHandCapture.  The
// extension resolves every function through Godot's OpenXRAPIExtension and
// deliberately does not link an OpenXR loader, which keeps the same binary
// usable with Meta and PICO runtimes.

#include <cstdint>

#if !defined(XRAPI_PTR)
#define XRAPI_PTR *
#endif

#if !defined(XR_MAY_ALIAS)
#define XR_MAY_ALIAS
#endif

using XrBool32 = uint32_t;
using XrResult = int32_t;
using XrStructureType = int32_t;
using XrTime = int64_t;
using XrSpaceLocationFlags = uint64_t;

struct XrInstance_T;
struct XrSession_T;
struct XrSpace_T;
struct XrHandTrackerEXT_T;
struct timespec;

using XrInstance = XrInstance_T *;
using XrSession = XrSession_T *;
using XrSpace = XrSpace_T *;
using XrHandTrackerEXT = XrHandTrackerEXT_T *;

static constexpr XrResult XR_SUCCESS = 0;
static constexpr XrBool32 XR_FALSE = 0;
static constexpr XrHandTrackerEXT XR_NULL_HAND_TRACKER_EXT = nullptr;

#define XR_FAILED(result) ((result) < 0)
#define XR_SUCCEEDED(result) ((result) >= 0)

static constexpr XrSpaceLocationFlags XR_SPACE_LOCATION_ORIENTATION_VALID_BIT = 0x00000001;
static constexpr XrSpaceLocationFlags XR_SPACE_LOCATION_POSITION_VALID_BIT = 0x00000002;
static constexpr XrSpaceLocationFlags XR_SPACE_LOCATION_ORIENTATION_TRACKED_BIT = 0x00000004;
static constexpr XrSpaceLocationFlags XR_SPACE_LOCATION_POSITION_TRACKED_BIT = 0x00000008;

static constexpr XrStructureType XR_TYPE_HAND_TRACKER_CREATE_INFO_EXT = 1000051001;
static constexpr XrStructureType XR_TYPE_HAND_JOINTS_LOCATE_INFO_EXT = 1000051002;
static constexpr XrStructureType XR_TYPE_HAND_JOINT_LOCATIONS_EXT = 1000051003;

static constexpr const char *XR_EXT_HAND_TRACKING_EXTENSION_NAME = "XR_EXT_hand_tracking";
static constexpr const char *XR_KHR_CONVERT_TIMESPEC_TIME_EXTENSION_NAME = "XR_KHR_convert_timespec_time";

struct XrVector3f {
	float x;
	float y;
	float z;
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

enum XrHandEXT : int32_t {
	XR_HAND_LEFT_EXT = 1,
	XR_HAND_RIGHT_EXT = 2,
};

enum XrHandJointSetEXT : int32_t {
	XR_HAND_JOINT_SET_DEFAULT_EXT = 0,
};

static constexpr uint32_t XR_HAND_JOINT_COUNT_EXT = 26;

struct XrHandTrackerCreateInfoEXT {
	XrStructureType type;
	const void *XR_MAY_ALIAS next;
	XrHandEXT hand;
	XrHandJointSetEXT handJointSet;
};

struct XrHandJointsLocateInfoEXT {
	XrStructureType type;
	const void *XR_MAY_ALIAS next;
	XrSpace baseSpace;
	XrTime time;
};

struct XrHandJointLocationEXT {
	XrSpaceLocationFlags locationFlags;
	XrPosef pose;
	float radius;
};

struct XrHandJointLocationsEXT {
	XrStructureType type;
	void *XR_MAY_ALIAS next;
	XrBool32 isActive;
	uint32_t jointCount;
	XrHandJointLocationEXT *jointLocations;
};

using PFN_xrCreateHandTrackerEXT = XrResult(XRAPI_PTR)(XrSession, const XrHandTrackerCreateInfoEXT *, XrHandTrackerEXT *);
using PFN_xrDestroyHandTrackerEXT = XrResult(XRAPI_PTR)(XrHandTrackerEXT);
using PFN_xrLocateHandJointsEXT = XrResult(XRAPI_PTR)(XrHandTrackerEXT, const XrHandJointsLocateInfoEXT *, XrHandJointLocationsEXT *);
using PFN_xrConvertTimespecTimeToTimeKHR = XrResult(XRAPI_PTR)(XrInstance, const struct timespec *, XrTime *);
