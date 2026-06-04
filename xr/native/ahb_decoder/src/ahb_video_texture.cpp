// AhbVideoTexture implementation. The five TODOs from the scaffold
// are now filled in. The flow per-frame is:
//
//   1. Kotlin's onOutputBufferAvailable hands us an AHardwareBuffer
//      via JNI (jni_bridge.cpp) -> push_buffer().
//   2. push_buffer() calls _ensure_device() the first time
//      (TODO #1 — pull VkDevice out of Godot's RenderingDevice).
//   3. push_buffer() calls _ensure_ycbcr_sampler() if not yet set
//      up (TODO #2 — VkSamplerYcbcrConversion based on the buffer's
//      suggested format properties).
//   4. _import_buffer() releases any previous VkImage and creates a
//      new VkImage + VkDeviceMemory + VkImageView that aliases the
//      AHardwareBuffer's memory (TODO #3).
//   5. push_buffer() then calls texture_create_from_extension on
//      Godot's RenderingDevice and assigns the resulting RID to this
//      Texture2DRD via set_texture_rd_rid (TODO #5).
//   6. _release_vk_resources() destroys the previous-frame Vulkan
//      objects when we swap to a new buffer (TODO #4).

#include "ahb_video_texture.h"

#include "shaders/ycbcr_to_rgba.spv.h"

#include <godot_cpp/classes/rendering_device.hpp>
#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <android/log.h>
#include <vulkan/vulkan_android.h>

#include <cstring>

#define LOG_TAG "AhbVideoTexture"
#define LOGI(fmt, ...) __android_log_print(ANDROID_LOG_INFO,  LOG_TAG, fmt, ##__VA_ARGS__)
#define LOGW(fmt, ...) __android_log_print(ANDROID_LOG_WARN,  LOG_TAG, fmt, ##__VA_ARGS__)
#define LOGE(fmt, ...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, fmt, ##__VA_ARGS__)

namespace godot {

void AhbVideoTexture::_bind_methods() {
	ClassDB::bind_method(D_METHOD("get_latest_info"), &AhbVideoTexture::get_latest_info);
	ClassDB::bind_method(D_METHOD("is_ready"), &AhbVideoTexture::is_ready);
	// Bound so RenderingServer::call_on_render_thread can dispatch via
	// Callable(this, "_render_thread_tick"). It's an internal hook —
	// not meant to be called from GDScript.
	ClassDB::bind_method(D_METHOD("_render_thread_tick"), &AhbVideoTexture::_render_thread_tick);
}

AhbVideoTexture::AhbVideoTexture() {
	ahb_register_active(this);
	LOGI("AhbVideoTexture constructed (deferring device init until first frame)");
}

AhbVideoTexture::~AhbVideoTexture() {
	ahb_unregister_active(this);
	// Drain any AHB still queued for the render thread — push_buffer
	// owns a refcount on it that the render thread normally consumes.
	AHardwareBuffer *pending =
			_pending_buffer.exchange(nullptr, std::memory_order_acq_rel);
	if (pending) {
		AHardwareBuffer_release(pending);
	}
	std::lock_guard<std::mutex> lk(_mutex);

	// Wait for any in-flight blit before tearing anything down — the
	// GPU may still be reading _vk_image / writing _dst_image.
	if (_vk_device != VK_NULL_HANDLE && _blit_fence != VK_NULL_HANDLE) {
		vkWaitForFences(_vk_device, 1, &_blit_fence, VK_TRUE, UINT64_MAX);
	}

	_release_vk_resources();

	// Plan A teardown: pipeline objects + dst image + cmd pool + fence.
	// Order: fence, cmd pool (frees the cmd buffer), descriptor pool
	// (frees the set), pipeline, layouts, dst image. None of these
	// depend on the others in a way that would crash, but freeing in
	// reverse-creation order keeps the validation layers quiet.
	if (_vk_device != VK_NULL_HANDLE) {
		if (_blit_fence != VK_NULL_HANDLE) {
			vkDestroyFence(_vk_device, _blit_fence, nullptr);
			_blit_fence = VK_NULL_HANDLE;
		}
		if (_cmd_pool != VK_NULL_HANDLE) {
			vkDestroyCommandPool(_vk_device, _cmd_pool, nullptr);
			_cmd_pool = VK_NULL_HANDLE;
			_cmd_buffer = VK_NULL_HANDLE;
		}
		if (_descriptor_pool != VK_NULL_HANDLE) {
			vkDestroyDescriptorPool(_vk_device, _descriptor_pool, nullptr);
			_descriptor_pool = VK_NULL_HANDLE;
			_descriptor_set = VK_NULL_HANDLE;
		}
		if (_compute_pipeline != VK_NULL_HANDLE) {
			vkDestroyPipeline(_vk_device, _compute_pipeline, nullptr);
			_compute_pipeline = VK_NULL_HANDLE;
		}
		if (_pipeline_layout != VK_NULL_HANDLE) {
			vkDestroyPipelineLayout(_vk_device, _pipeline_layout, nullptr);
			_pipeline_layout = VK_NULL_HANDLE;
		}
		if (_ds_layout != VK_NULL_HANDLE) {
			vkDestroyDescriptorSetLayout(_vk_device, _ds_layout, nullptr);
			_ds_layout = VK_NULL_HANDLE;
		}
		_release_destination_image();
	}

	if (_vk_ycbcr != VK_NULL_HANDLE && _fn_destroy_ycbcr) {
		_fn_destroy_ycbcr(_vk_device, _vk_ycbcr, nullptr);
		_vk_ycbcr = VK_NULL_HANDLE;
	}
	if (_vk_sampler != VK_NULL_HANDLE) {
		vkDestroySampler(_vk_device, _vk_sampler, nullptr);
		_vk_sampler = VK_NULL_HANDLE;
	}
	if (_active_buffer) {
		AHardwareBuffer_release(_active_buffer);
		_active_buffer = nullptr;
	}
}


// ---------- TODO #1 — pull VkDevice out of Godot's RenderingDevice ----------

bool AhbVideoTexture::_ensure_device() {
	if (_vk_device != VK_NULL_HANDLE) {
		return true;
	}
	RenderingServer *rs = RenderingServer::get_singleton();
	if (!rs) {
		LOGE("RenderingServer not available");
		return false;
	}
	RenderingDevice *rd = rs->get_rendering_device();
	if (!rd) {
		LOGE("Godot is not running on the Vulkan RenderingDevice — AHB import unavailable");
		return false;
	}
	// godot-cpp 4.5 exposes get_driver_resource() returning uint64_t.
	_vk_device = (VkDevice)(uintptr_t)rd->get_driver_resource(
			RenderingDevice::DRIVER_RESOURCE_LOGICAL_DEVICE,
			RID(),
			0);
	_vk_phys_device = (VkPhysicalDevice)(uintptr_t)rd->get_driver_resource(
			RenderingDevice::DRIVER_RESOURCE_PHYSICAL_DEVICE,
			RID(),
			0);
	if (_vk_device == VK_NULL_HANDLE || _vk_phys_device == VK_NULL_HANDLE) {
		LOGE("RenderingDevice didn't return Vulkan handles (vk_device=%p vk_phys=%p)",
				(void *)_vk_device, (void *)_vk_phys_device);
		_vk_device = VK_NULL_HANDLE;
		_vk_phys_device = VK_NULL_HANDLE;
		return false;
	}

	// Resolve the AHB / YCbCr extension entry points. These are
	// _instance_-level extensions hidden behind device-level functions
	// because we need a device handle to call them. They're guaranteed
	// available on Android API 26+ if VK_ANDROID_external_memory_android_hardware_buffer
	// was loaded — Godot's Vulkan driver enables that automatically on Android.
	_fn_get_ahb_props = (PFN_vkGetAndroidHardwareBufferPropertiesANDROID)
			vkGetDeviceProcAddr(_vk_device, "vkGetAndroidHardwareBufferPropertiesANDROID");
	_fn_create_ycbcr = (PFN_vkCreateSamplerYcbcrConversion)
			vkGetDeviceProcAddr(_vk_device, "vkCreateSamplerYcbcrConversion");
	_fn_destroy_ycbcr = (PFN_vkDestroySamplerYcbcrConversion)
			vkGetDeviceProcAddr(_vk_device, "vkDestroySamplerYcbcrConversion");
	if (!_fn_get_ahb_props || !_fn_create_ycbcr || !_fn_destroy_ycbcr) {
		LOGE("Required Vulkan extension entry points not available "
				"(get_ahb_props=%p create_ycbcr=%p destroy_ycbcr=%p)",
				(void *)_fn_get_ahb_props, (void *)_fn_create_ycbcr,
				(void *)_fn_destroy_ycbcr);
		_vk_device = VK_NULL_HANDLE;
		return false;
	}

	// Plan A: pull the VkQueue + family index that Godot uses. PoC
	// confirmed both are non-zero on Pico (see [VKPOC] verdict). We
	// need them to vkQueueSubmit our compute work on the same queue
	// Godot renders on — same-queue submissions are implicitly ordered,
	// which keeps the blit's writes visible to the next frame's reads
	// without needing semaphores.
	_vk_queue = (VkQueue)(uintptr_t)rd->get_driver_resource(
			RenderingDevice::DRIVER_RESOURCE_COMMAND_QUEUE, RID(), 0);
	_vk_queue_family = (uint32_t)rd->get_driver_resource(
			RenderingDevice::DRIVER_RESOURCE_QUEUE_FAMILY, RID(), 0);
	if (_vk_queue == VK_NULL_HANDLE) {
		LOGE("RenderingDevice returned VK_NULL_HANDLE for COMMAND_QUEUE");
		_vk_device = VK_NULL_HANDLE;
		return false;
	}

	LOGI("Vulkan device acquired: vk_device=%p vk_phys=%p queue=%p family=%u",
			(void *)_vk_device, (void *)_vk_phys_device,
			(void *)_vk_queue, _vk_queue_family);
	return true;
}


// ---------- TODO #2 — VkSamplerYcbcrConversion + VkSampler -----------------

bool AhbVideoTexture::_ensure_ycbcr_sampler(AHardwareBuffer *buffer) {
	if (_vk_ycbcr != VK_NULL_HANDLE) {
		// Already initialised. Trust the format is stable.
		return true;
	}

	VkAndroidHardwareBufferFormatPropertiesANDROID fmt_props{};
	fmt_props.sType = VK_STRUCTURE_TYPE_ANDROID_HARDWARE_BUFFER_FORMAT_PROPERTIES_ANDROID;

	VkAndroidHardwareBufferPropertiesANDROID props{};
	props.sType = VK_STRUCTURE_TYPE_ANDROID_HARDWARE_BUFFER_PROPERTIES_ANDROID;
	props.pNext = &fmt_props;

	VkResult r = _fn_get_ahb_props(_vk_device, buffer, &props);
	if (r != VK_SUCCESS) {
		LOGE("vkGetAndroidHardwareBufferPropertiesANDROID failed: %d", r);
		return false;
	}

	// Save for _import_buffer.
	_ahb_external_format = fmt_props.externalFormat;
	_ahb_format_features = fmt_props.formatFeatures;
	_ahb_components = fmt_props.samplerYcbcrConversionComponents;
	_ahb_ycbcr_model = fmt_props.suggestedYcbcrModel;
	_ahb_ycbcr_range = fmt_props.suggestedYcbcrRange;
	_ahb_x_chroma_offset = fmt_props.suggestedXChromaOffset;
	_ahb_y_chroma_offset = fmt_props.suggestedYChromaOffset;

	// Build the conversion. Use the externalFormat path because the
	// buffer's underlying format is opaque (NV12, NV21, etc, vendor
	// dependent) — only the driver knows how to sample it.
	VkExternalFormatANDROID ext_fmt{};
	ext_fmt.sType = VK_STRUCTURE_TYPE_EXTERNAL_FORMAT_ANDROID;
	ext_fmt.externalFormat = _ahb_external_format;

	VkSamplerYcbcrConversionCreateInfo ycbcr_info{};
	ycbcr_info.sType = VK_STRUCTURE_TYPE_SAMPLER_YCBCR_CONVERSION_CREATE_INFO;
	ycbcr_info.pNext = &ext_fmt;
	ycbcr_info.format = VK_FORMAT_UNDEFINED; // mandatory when externalFormat != 0
	ycbcr_info.ycbcrModel = _ahb_ycbcr_model;
	ycbcr_info.ycbcrRange = _ahb_ycbcr_range;
	ycbcr_info.components = _ahb_components;
	ycbcr_info.xChromaOffset = _ahb_x_chroma_offset;
	ycbcr_info.yChromaOffset = _ahb_y_chroma_offset;
	// LINEAR if the format props say linear filtering is supported,
	// otherwise NEAREST (some hardware doesn't support linear chroma).
	if (_ahb_format_features & VK_FORMAT_FEATURE_SAMPLED_IMAGE_YCBCR_CONVERSION_LINEAR_FILTER_BIT) {
		ycbcr_info.chromaFilter = VK_FILTER_LINEAR;
	} else {
		ycbcr_info.chromaFilter = VK_FILTER_NEAREST;
	}
	ycbcr_info.forceExplicitReconstruction = VK_FALSE;

	r = _fn_create_ycbcr(_vk_device, &ycbcr_info, nullptr, &_vk_ycbcr);
	if (r != VK_SUCCESS) {
		LOGE("vkCreateSamplerYcbcrConversion failed: %d", r);
		return false;
	}

	// Build the sampler that uses this conversion. Image views that
	// alias the AHB will reference this sampler.
	VkSamplerYcbcrConversionInfo conv_info{};
	conv_info.sType = VK_STRUCTURE_TYPE_SAMPLER_YCBCR_CONVERSION_INFO;
	conv_info.conversion = _vk_ycbcr;

	VkSamplerCreateInfo sampler_info{};
	sampler_info.sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
	sampler_info.pNext = &conv_info;
	sampler_info.magFilter = VK_FILTER_LINEAR;
	sampler_info.minFilter = VK_FILTER_LINEAR;
	sampler_info.mipmapMode = VK_SAMPLER_MIPMAP_MODE_NEAREST;
	sampler_info.addressModeU = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
	sampler_info.addressModeV = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
	sampler_info.addressModeW = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
	sampler_info.borderColor = VK_BORDER_COLOR_FLOAT_OPAQUE_BLACK;
	sampler_info.unnormalizedCoordinates = VK_FALSE;

	r = vkCreateSampler(_vk_device, &sampler_info, nullptr, &_vk_sampler);
	if (r != VK_SUCCESS) {
		LOGE("vkCreateSampler failed: %d", r);
		_fn_destroy_ycbcr(_vk_device, _vk_ycbcr, nullptr);
		_vk_ycbcr = VK_NULL_HANDLE;
		return false;
	}

	LOGI("YCbCr conversion ready: external_format=0x%llx model=%d range=%d filter=%s "
			"components=(r=%d g=%d b=%d a=%d) xChroma=%d yChroma=%d features=0x%x",
			(unsigned long long)_ahb_external_format,
			(int)_ahb_ycbcr_model, (int)_ahb_ycbcr_range,
			(ycbcr_info.chromaFilter == VK_FILTER_LINEAR) ? "linear" : "nearest",
			(int)_ahb_components.r, (int)_ahb_components.g,
			(int)_ahb_components.b, (int)_ahb_components.a,
			(int)_ahb_x_chroma_offset, (int)_ahb_y_chroma_offset,
			(unsigned int)_ahb_format_features);
	return true;
}


// ---------- TODO #3 — vkCreateImage + vkAllocateMemory + vkBindImageMemory --

bool AhbVideoTexture::_import_buffer(AHardwareBuffer *buffer) {
	AHardwareBuffer_Desc desc{};
	AHardwareBuffer_describe(buffer, &desc);
	_width = (int32_t)desc.width;
	_height = (int32_t)desc.height;

	// Re-query the AHB props for THIS buffer to pick up its actual
	// memory size — it can technically vary across buffers even when
	// the format doesn't.
	VkAndroidHardwareBufferFormatPropertiesANDROID fmt_props{};
	fmt_props.sType = VK_STRUCTURE_TYPE_ANDROID_HARDWARE_BUFFER_FORMAT_PROPERTIES_ANDROID;
	VkAndroidHardwareBufferPropertiesANDROID ahb_props{};
	ahb_props.sType = VK_STRUCTURE_TYPE_ANDROID_HARDWARE_BUFFER_PROPERTIES_ANDROID;
	ahb_props.pNext = &fmt_props;
	if (_fn_get_ahb_props(_vk_device, buffer, &ahb_props) != VK_SUCCESS) {
		LOGE("vkGetAndroidHardwareBufferPropertiesANDROID failed in _import_buffer");
		return false;
	}

	VkExternalFormatANDROID ext_format{};
	ext_format.sType = VK_STRUCTURE_TYPE_EXTERNAL_FORMAT_ANDROID;
	ext_format.externalFormat = fmt_props.externalFormat;

	VkExternalMemoryImageCreateInfo ext_image{};
	ext_image.sType = VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO;
	ext_image.pNext = &ext_format;
	ext_image.handleTypes = VK_EXTERNAL_MEMORY_HANDLE_TYPE_ANDROID_HARDWARE_BUFFER_BIT_ANDROID;

	VkImageCreateInfo image_info{};
	image_info.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
	image_info.pNext = &ext_image;
	image_info.imageType = VK_IMAGE_TYPE_2D;
	image_info.format = VK_FORMAT_UNDEFINED; // externalFormat path
	image_info.extent = { desc.width, desc.height, 1 };
	image_info.mipLevels = 1;
	image_info.arrayLayers = 1;
	image_info.samples = VK_SAMPLE_COUNT_1_BIT;
	image_info.tiling = VK_IMAGE_TILING_OPTIMAL;
	image_info.usage = VK_IMAGE_USAGE_SAMPLED_BIT;
	image_info.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
	image_info.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;

	VkResult r = vkCreateImage(_vk_device, &image_info, nullptr, &_vk_image);
	if (r != VK_SUCCESS) {
		LOGE("vkCreateImage failed: %d", r);
		return false;
	}

	VkImportAndroidHardwareBufferInfoANDROID import_info{};
	import_info.sType = VK_STRUCTURE_TYPE_IMPORT_ANDROID_HARDWARE_BUFFER_INFO_ANDROID;
	import_info.buffer = buffer;

	VkMemoryDedicatedAllocateInfo dedicated{};
	dedicated.sType = VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO;
	dedicated.pNext = &import_info;
	dedicated.image = _vk_image;
	dedicated.buffer = VK_NULL_HANDLE;

	uint32_t memory_type_index = _find_memory_type(ahb_props.memoryTypeBits);
	if (memory_type_index == UINT32_MAX) {
		LOGE("No suitable memory type (mask=0x%x)", ahb_props.memoryTypeBits);
		vkDestroyImage(_vk_device, _vk_image, nullptr);
		_vk_image = VK_NULL_HANDLE;
		return false;
	}

	VkMemoryAllocateInfo alloc_info{};
	alloc_info.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
	alloc_info.pNext = &dedicated;
	alloc_info.allocationSize = ahb_props.allocationSize;
	alloc_info.memoryTypeIndex = memory_type_index;

	r = vkAllocateMemory(_vk_device, &alloc_info, nullptr, &_vk_memory);
	if (r != VK_SUCCESS) {
		LOGE("vkAllocateMemory(import-AHB) failed: %d", r);
		vkDestroyImage(_vk_device, _vk_image, nullptr);
		_vk_image = VK_NULL_HANDLE;
		return false;
	}

	r = vkBindImageMemory(_vk_device, _vk_image, _vk_memory, 0);
	if (r != VK_SUCCESS) {
		LOGE("vkBindImageMemory failed: %d", r);
		vkFreeMemory(_vk_device, _vk_memory, nullptr);
		vkDestroyImage(_vk_device, _vk_image, nullptr);
		_vk_memory = VK_NULL_HANDLE;
		_vk_image = VK_NULL_HANDLE;
		return false;
	}

	// Image view that uses the YCbCr conversion.
	VkSamplerYcbcrConversionInfo conv_info{};
	conv_info.sType = VK_STRUCTURE_TYPE_SAMPLER_YCBCR_CONVERSION_INFO;
	conv_info.conversion = _vk_ycbcr;

	VkImageViewCreateInfo view_info{};
	view_info.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
	view_info.pNext = &conv_info;
	view_info.image = _vk_image;
	view_info.viewType = VK_IMAGE_VIEW_TYPE_2D;
	view_info.format = VK_FORMAT_UNDEFINED; // YCbCr conversion handles it
	view_info.components.r = VK_COMPONENT_SWIZZLE_IDENTITY;
	view_info.components.g = VK_COMPONENT_SWIZZLE_IDENTITY;
	view_info.components.b = VK_COMPONENT_SWIZZLE_IDENTITY;
	view_info.components.a = VK_COMPONENT_SWIZZLE_IDENTITY;
	view_info.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
	view_info.subresourceRange.baseMipLevel = 0;
	view_info.subresourceRange.levelCount = 1;
	view_info.subresourceRange.baseArrayLayer = 0;
	view_info.subresourceRange.layerCount = 1;

	r = vkCreateImageView(_vk_device, &view_info, nullptr, &_vk_image_view);
	if (r != VK_SUCCESS) {
		LOGE("vkCreateImageView failed: %d", r);
		vkFreeMemory(_vk_device, _vk_memory, nullptr);
		vkDestroyImage(_vk_device, _vk_image, nullptr);
		_vk_memory = VK_NULL_HANDLE;
		_vk_image = VK_NULL_HANDLE;
		return false;
	}

	return true;
}


// ---------- TODO #4 — destroy / free everything held ------------------------

void AhbVideoTexture::_release_vk_resources() {
	if (_vk_device == VK_NULL_HANDLE) {
		return;
	}
	// Plan A note: do NOT reset _current_rd_rid here. The RID wraps the
	// PERSISTENT destination image (`_dst_image`), not the per-frame AHB
	// source — so it should survive every release_vk_resources() call.
	// Resetting it caused texture_create_from_extension to be called on
	// the same VkImage every frame; Godot then kept replacing the
	// displayed texture's underlying RID with a fresh wrapper, which
	// somehow ended up showing the placeholder colour instead of our
	// compute output (the new RID's storage isn't yet populated when
	// Godot's frame submit happens, so it samples zeros / clear colour).
	// The RID stays live for the AhbVideoTexture's lifetime and is only
	// torn down by _release_destination_image() on resize / destruction.
	if (_vk_image_view != VK_NULL_HANDLE) {
		vkDestroyImageView(_vk_device, _vk_image_view, nullptr);
		_vk_image_view = VK_NULL_HANDLE;
	}
	if (_vk_image != VK_NULL_HANDLE) {
		vkDestroyImage(_vk_device, _vk_image, nullptr);
		_vk_image = VK_NULL_HANDLE;
	}
	if (_vk_memory != VK_NULL_HANDLE) {
		vkFreeMemory(_vk_device, _vk_memory, nullptr);
		_vk_memory = VK_NULL_HANDLE;
	}
}


// ---------- Plan A: destination RGBA image + compute pipeline ----------------

bool AhbVideoTexture::_ensure_destination_image(int32_t width, int32_t height) {
	if (_dst_image != VK_NULL_HANDLE && _dst_width == width && _dst_height == height) {
		return true;
	}
	if (_dst_image != VK_NULL_HANDLE) {
		// Resize: tear down the old image. We also have to invalidate
		// the descriptor binding for it (will be rewritten next frame).
		LOGI("Destination image resize %dx%d -> %dx%d", _dst_width, _dst_height, width, height);
		// Make sure the GPU isn't still reading it. The blit fence (if
		// any) was already waited on by the caller before this runs.
		_release_destination_image();
	}

	VkImageCreateInfo info{};
	info.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
	info.imageType = VK_IMAGE_TYPE_2D;
	info.format = VK_FORMAT_R8G8B8A8_UNORM;
	info.extent = { (uint32_t)width, (uint32_t)height, 1 };
	info.mipLevels = 1;
	info.arrayLayers = 1;
	info.samples = VK_SAMPLE_COUNT_1_BIT;
	info.tiling = VK_IMAGE_TILING_OPTIMAL;
	// STORAGE for our compute write, SAMPLED for Godot's fragment read.
	// TRANSFER_SRC is required when Godot reads the Texture2DRD back, e.g.
	// for compositor screenshots while capture is stopping.
	info.usage = VK_IMAGE_USAGE_STORAGE_BIT | VK_IMAGE_USAGE_SAMPLED_BIT |
			VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT;
	info.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
	info.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;

	VkResult r = vkCreateImage(_vk_device, &info, nullptr, &_dst_image);
	if (r != VK_SUCCESS) {
		LOGE("vkCreateImage(dst RGBA8) failed: %d", r);
		return false;
	}

	VkMemoryRequirements req{};
	vkGetImageMemoryRequirements(_vk_device, _dst_image, &req);
	uint32_t mt = _find_device_local_memory_type(req.memoryTypeBits);
	if (mt == UINT32_MAX) {
		LOGE("No DEVICE_LOCAL memory type for dst image (mask=0x%x)", req.memoryTypeBits);
		vkDestroyImage(_vk_device, _dst_image, nullptr);
		_dst_image = VK_NULL_HANDLE;
		return false;
	}

	VkMemoryAllocateInfo alloc{};
	alloc.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
	alloc.allocationSize = req.size;
	alloc.memoryTypeIndex = mt;
	r = vkAllocateMemory(_vk_device, &alloc, nullptr, &_dst_memory);
	if (r != VK_SUCCESS) {
		LOGE("vkAllocateMemory(dst RGBA8) failed: %d", r);
		vkDestroyImage(_vk_device, _dst_image, nullptr);
		_dst_image = VK_NULL_HANDLE;
		return false;
	}
	r = vkBindImageMemory(_vk_device, _dst_image, _dst_memory, 0);
	if (r != VK_SUCCESS) {
		LOGE("vkBindImageMemory(dst) failed: %d", r);
		_release_destination_image();
		return false;
	}

	VkImageViewCreateInfo view{};
	view.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
	view.image = _dst_image;
	view.viewType = VK_IMAGE_VIEW_TYPE_2D;
	view.format = VK_FORMAT_R8G8B8A8_UNORM;
	view.components = { VK_COMPONENT_SWIZZLE_IDENTITY, VK_COMPONENT_SWIZZLE_IDENTITY,
			VK_COMPONENT_SWIZZLE_IDENTITY, VK_COMPONENT_SWIZZLE_IDENTITY };
	view.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
	view.subresourceRange.levelCount = 1;
	view.subresourceRange.layerCount = 1;
	r = vkCreateImageView(_vk_device, &view, nullptr, &_dst_image_view);
	if (r != VK_SUCCESS) {
		LOGE("vkCreateImageView(dst) failed: %d", r);
		_release_destination_image();
		return false;
	}

	_dst_width = width;
	_dst_height = height;
	_dst_first_use = true; // next dispatch starts from UNDEFINED layout
	// Descriptor binding 1 will be rewritten on next dispatch.
	_descriptor_set_initialized = false;
	LOGI("Destination RGBA8 image ready: %dx%d image=%p view=%p",
			width, height, (void *)_dst_image, (void *)_dst_image_view);
	return true;
}

void AhbVideoTexture::_release_destination_image() {
	if (_current_rd_rid != RID()) {
		set_texture_rd_rid(RID());
		_current_rd_rid = RID();
	}
	if (_dst_image_view != VK_NULL_HANDLE) {
		vkDestroyImageView(_vk_device, _dst_image_view, nullptr);
		_dst_image_view = VK_NULL_HANDLE;
	}
	if (_dst_image != VK_NULL_HANDLE) {
		vkDestroyImage(_vk_device, _dst_image, nullptr);
		_dst_image = VK_NULL_HANDLE;
	}
	if (_dst_memory != VK_NULL_HANDLE) {
		vkFreeMemory(_vk_device, _dst_memory, nullptr);
		_dst_memory = VK_NULL_HANDLE;
	}
	_dst_width = 0;
	_dst_height = 0;
	_dst_first_use = true;
	_descriptor_set_initialized = false;
	// The RID wraps _dst_image; when we destroy the image we must let
	// Godot rebind on the next dispatch.
}

uint32_t AhbVideoTexture::_find_device_local_memory_type(uint32_t memory_type_bits) const {
	if (_vk_phys_device == VK_NULL_HANDLE) {
		return UINT32_MAX;
	}
	VkPhysicalDeviceMemoryProperties mem_props{};
	vkGetPhysicalDeviceMemoryProperties(_vk_phys_device, &mem_props);
	for (uint32_t i = 0; i < mem_props.memoryTypeCount; ++i) {
		if (!(memory_type_bits & (1u << i))) {
			continue;
		}
		if (mem_props.memoryTypes[i].propertyFlags & VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) {
			return i;
		}
	}
	// Fall back to anything matching — better than refusing to render.
	for (uint32_t i = 0; i < mem_props.memoryTypeCount; ++i) {
		if (memory_type_bits & (1u << i)) {
			return i;
		}
	}
	return UINT32_MAX;
}

bool AhbVideoTexture::_ensure_compute_pipeline() {
	if (_compute_pipeline != VK_NULL_HANDLE) {
		return true;
	}
	if (_vk_sampler == VK_NULL_HANDLE) {
		LOGE("_ensure_compute_pipeline called before YCbCr sampler is ready");
		return false;
	}

	// --- Descriptor set layout with immutable YCbCr sampler at binding 0.
	// The immutable sampler is what makes this whole thing work: it carries
	// the VkSamplerYcbcrConversion, so the driver applies YUV->RGB inside
	// the texture() call in our shader.
	VkDescriptorSetLayoutBinding bindings[2]{};
	bindings[0].binding = 0;
	bindings[0].descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
	bindings[0].descriptorCount = 1;
	bindings[0].stageFlags = VK_SHADER_STAGE_COMPUTE_BIT;
	bindings[0].pImmutableSamplers = &_vk_sampler;
	bindings[1].binding = 1;
	bindings[1].descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_IMAGE;
	bindings[1].descriptorCount = 1;
	bindings[1].stageFlags = VK_SHADER_STAGE_COMPUTE_BIT;
	bindings[1].pImmutableSamplers = nullptr;

	VkDescriptorSetLayoutCreateInfo dsl{};
	dsl.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
	dsl.bindingCount = 2;
	dsl.pBindings = bindings;
	VkResult r = vkCreateDescriptorSetLayout(_vk_device, &dsl, nullptr, &_ds_layout);
	if (r != VK_SUCCESS) {
		LOGE("vkCreateDescriptorSetLayout failed: %d", r);
		return false;
	}

	VkPipelineLayoutCreateInfo pli{};
	pli.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
	pli.setLayoutCount = 1;
	pli.pSetLayouts = &_ds_layout;
	r = vkCreatePipelineLayout(_vk_device, &pli, nullptr, &_pipeline_layout);
	if (r != VK_SUCCESS) {
		LOGE("vkCreatePipelineLayout failed: %d", r);
		return false;
	}

	// --- Shader module from embedded SPIR-V.
	VkShaderModuleCreateInfo smi{};
	smi.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
	smi.codeSize = ycbcr_to_rgba_spv_len;
	smi.pCode = reinterpret_cast<const uint32_t *>(ycbcr_to_rgba_spv);
	VkShaderModule shader_module = VK_NULL_HANDLE;
	r = vkCreateShaderModule(_vk_device, &smi, nullptr, &shader_module);
	if (r != VK_SUCCESS) {
		LOGE("vkCreateShaderModule failed: %d", r);
		return false;
	}

	VkPipelineShaderStageCreateInfo stage{};
	stage.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
	stage.stage = VK_SHADER_STAGE_COMPUTE_BIT;
	stage.module = shader_module;
	stage.pName = "main";

	VkComputePipelineCreateInfo cpi{};
	cpi.sType = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO;
	cpi.stage = stage;
	cpi.layout = _pipeline_layout;
	r = vkCreateComputePipelines(_vk_device, VK_NULL_HANDLE, 1, &cpi, nullptr, &_compute_pipeline);
	vkDestroyShaderModule(_vk_device, shader_module, nullptr); // can drop once pipeline is built
	if (r != VK_SUCCESS) {
		LOGE("vkCreateComputePipelines failed: %d", r);
		return false;
	}

	// --- Descriptor pool + set.
	VkDescriptorPoolSize sizes[2]{};
	sizes[0].type = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
	sizes[0].descriptorCount = 1;
	sizes[1].type = VK_DESCRIPTOR_TYPE_STORAGE_IMAGE;
	sizes[1].descriptorCount = 1;
	VkDescriptorPoolCreateInfo dpi{};
	dpi.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
	dpi.maxSets = 1;
	dpi.poolSizeCount = 2;
	dpi.pPoolSizes = sizes;
	// Note: no FREE_DESCRIPTOR_SET_BIT — we never free, just re-write.
	r = vkCreateDescriptorPool(_vk_device, &dpi, nullptr, &_descriptor_pool);
	if (r != VK_SUCCESS) {
		LOGE("vkCreateDescriptorPool failed: %d", r);
		return false;
	}
	VkDescriptorSetAllocateInfo dsa{};
	dsa.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
	dsa.descriptorPool = _descriptor_pool;
	dsa.descriptorSetCount = 1;
	dsa.pSetLayouts = &_ds_layout;
	r = vkAllocateDescriptorSets(_vk_device, &dsa, &_descriptor_set);
	if (r != VK_SUCCESS) {
		LOGE("vkAllocateDescriptorSets failed: %d", r);
		return false;
	}

	// --- Command pool + buffer + fence.
	VkCommandPoolCreateInfo cpi2{};
	cpi2.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
	cpi2.queueFamilyIndex = _vk_queue_family;
	cpi2.flags = VK_COMMAND_POOL_CREATE_TRANSIENT_BIT |
			VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
	r = vkCreateCommandPool(_vk_device, &cpi2, nullptr, &_cmd_pool);
	if (r != VK_SUCCESS) {
		LOGE("vkCreateCommandPool failed: %d", r);
		return false;
	}
	VkCommandBufferAllocateInfo cba{};
	cba.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
	cba.commandPool = _cmd_pool;
	cba.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
	cba.commandBufferCount = 1;
	r = vkAllocateCommandBuffers(_vk_device, &cba, &_cmd_buffer);
	if (r != VK_SUCCESS) {
		LOGE("vkAllocateCommandBuffers failed: %d", r);
		return false;
	}

	VkFenceCreateInfo fci{};
	fci.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
	// Start signalled so the first vkResetFences works without an
	// initial special case.
	fci.flags = VK_FENCE_CREATE_SIGNALED_BIT;
	r = vkCreateFence(_vk_device, &fci, nullptr, &_blit_fence);
	if (r != VK_SUCCESS) {
		LOGE("vkCreateFence failed: %d", r);
		return false;
	}

	LOGI("Compute blit pipeline ready (pipeline=%p ds=%p cmd_pool=%p)",
			(void *)_compute_pipeline, (void *)_descriptor_set, (void *)_cmd_pool);
	return true;
}

void AhbVideoTexture::_update_descriptor_set() {
	// Binding 0 changes every frame because _vk_image_view is recreated
	// per AHB. Binding 1 changes only when the destination is realloced.
	VkDescriptorImageInfo src_info{};
	src_info.imageView = _vk_image_view;
	src_info.imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
	// sampler is immutable — pImmutableSamplers in the DS layout — so
	// we must NOT set it here per Vulkan spec.

	VkWriteDescriptorSet writes[2]{};
	writes[0].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
	writes[0].dstSet = _descriptor_set;
	writes[0].dstBinding = 0;
	writes[0].descriptorCount = 1;
	writes[0].descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
	writes[0].pImageInfo = &src_info;

	VkDescriptorImageInfo dst_info{};
	dst_info.imageView = _dst_image_view;
	dst_info.imageLayout = VK_IMAGE_LAYOUT_GENERAL;

	writes[1].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
	writes[1].dstSet = _descriptor_set;
	writes[1].dstBinding = 1;
	writes[1].descriptorCount = 1;
	writes[1].descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_IMAGE;
	writes[1].pImageInfo = &dst_info;

	uint32_t count = _descriptor_set_initialized ? 1 : 2;
	vkUpdateDescriptorSets(_vk_device, count, writes, 0, nullptr);
	_descriptor_set_initialized = true;
}

bool AhbVideoTexture::_dispatch_blit() {
	// Wait for the previous frame's blit to finish (also unblocks the
	// next vkResetFences). Timeout is generous — a stuck GPU here would
	// be a fatal driver bug. UINT64_MAX is fine in practice.
	VkResult r = vkWaitForFences(_vk_device, 1, &_blit_fence, VK_TRUE, UINT64_MAX);
	if (r != VK_SUCCESS) {
		LOGE("vkWaitForFences(prev blit) failed: %d", r);
		return false;
	}
	vkResetFences(_vk_device, 1, &_blit_fence);

	r = vkResetCommandBuffer(_cmd_buffer, 0);
	if (r != VK_SUCCESS) {
		LOGE("vkResetCommandBuffer failed: %d", r);
		return false;
	}
	VkCommandBufferBeginInfo begin{};
	begin.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
	begin.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
	r = vkBeginCommandBuffer(_cmd_buffer, &begin);
	if (r != VK_SUCCESS) {
		LOGE("vkBeginCommandBuffer failed: %d", r);
		return false;
	}

	// --- Barriers BEFORE the dispatch.
	// Source: AHB-imported VkImage. Per Vulkan spec, when doing a
	// queue-family ownership ACQUIRE from FOREIGN, the image contents
	// must be preserved — that means oldLayout must NOT be UNDEFINED
	// (which signals "you can discard the data"). MediaCodec writes
	// decoded YUV samples into this AHB's gralloc memory; if we tell
	// the driver to discard them on transition, the shader samples
	// uninitialised contents (Adreno returns solid red here, which
	// looked exactly like our bug). Use SHADER_READ_ONLY_OPTIMAL for
	// both old and new so the driver knows "treat as already in the
	// final shader-read layout, just transfer ownership to our queue".
	VkImageMemoryBarrier pre[2]{};
	pre[0].sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
	pre[0].srcAccessMask = 0;
	pre[0].dstAccessMask = VK_ACCESS_SHADER_READ_BIT;
	pre[0].oldLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
	pre[0].newLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
	pre[0].srcQueueFamilyIndex = VK_QUEUE_FAMILY_FOREIGN_EXT;
	pre[0].dstQueueFamilyIndex = _vk_queue_family;
	pre[0].image = _vk_image;
	pre[0].subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 };

	// Destination: first use is UNDEFINED (no prior contents). After
	// that it has been left in SHADER_READ_ONLY_OPTIMAL by the last
	// dispatch — Godot's fragment shader read it in this layout, queue
	// ordering guarantees that read is done by now.
	pre[1].sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
	pre[1].srcAccessMask = _dst_first_use ? 0 : VK_ACCESS_SHADER_READ_BIT;
	pre[1].dstAccessMask = VK_ACCESS_SHADER_WRITE_BIT;
	pre[1].oldLayout = _dst_first_use ? VK_IMAGE_LAYOUT_UNDEFINED
			: VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
	pre[1].newLayout = VK_IMAGE_LAYOUT_GENERAL;
	pre[1].srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
	pre[1].dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
	pre[1].image = _dst_image;
	pre[1].subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 };

	vkCmdPipelineBarrier(_cmd_buffer,
			VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT | VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
			VK_PIPELINE_STAGE_TRANSFER_BIT | VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
			0, 0, nullptr, 0, nullptr, 2, pre);

	// DIAGNOSTIC: instead of the compute dispatch, do a vkCmdClearColorImage
	// writing solid green. If the headset shows green, the _dst_image RID
	// is reaching Godot's display path correctly — bug is in the compute
	// pipeline (sampler / YCbCr conversion / barriers). If the headset
	// still shows the placeholder blue, the binding itself is broken — our
	// writes go to a different image than the one Godot displays.
	vkCmdBindPipeline(_cmd_buffer, VK_PIPELINE_BIND_POINT_COMPUTE, _compute_pipeline);
	vkCmdBindDescriptorSets(_cmd_buffer, VK_PIPELINE_BIND_POINT_COMPUTE,
			_pipeline_layout, 0, 1, &_descriptor_set, 0, nullptr);

	// 8x8 workgroup — matches the layout(local_size_*) in the shader.
	uint32_t gx = (uint32_t)((_dst_width + 7) / 8);
	uint32_t gy = (uint32_t)((_dst_height + 7) / 8);
	vkCmdDispatch(_cmd_buffer, gx, gy, 1);
	(void)_compute_pipeline; (void)_pipeline_layout; (void)_descriptor_set;
	(void)_dst_width; (void)_dst_height;

	// --- Barrier AFTER the dispatch: dst GENERAL -> SHADER_READ_ONLY
	// so Godot's fragment shader (next subpass on the queue) reads it.
	VkImageMemoryBarrier post{};
	post.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
	post.srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT | VK_ACCESS_TRANSFER_WRITE_BIT;
	post.dstAccessMask = VK_ACCESS_SHADER_READ_BIT;
	post.oldLayout = VK_IMAGE_LAYOUT_GENERAL;
	post.newLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
	post.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
	post.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
	post.image = _dst_image;
	post.subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 };
	vkCmdPipelineBarrier(_cmd_buffer,
			VK_PIPELINE_STAGE_TRANSFER_BIT | VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
			VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
			0, 0, nullptr, 0, nullptr, 1, &post);

	r = vkEndCommandBuffer(_cmd_buffer);
	if (r != VK_SUCCESS) {
		LOGE("vkEndCommandBuffer failed: %d", r);
		return false;
	}

	VkSubmitInfo submit{};
	submit.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
	submit.commandBufferCount = 1;
	submit.pCommandBuffers = &_cmd_buffer;
	// No semaphores: we share the queue with Godot's main render, so
	// same-queue submission ordering gives us the dependency for free.
	r = vkQueueSubmit(_vk_queue, 1, &submit, _blit_fence);
	if (r != VK_SUCCESS) {
		LOGE("vkQueueSubmit failed: %d", r);
		return false;
	}
	// IMPORTANT: do NOT vkWaitForFences here. We waited on the *previous*
	// fence at the top. Waiting on the current submit would force a
	// CPU stall every frame — same-queue ordering already serialises us
	// against Godot's fragment-shader read, so the next frame's
	// vkWaitForFences is the natural sync point.
	_dst_first_use = false;
	return true;
}

// ---------- TODO #5 — bind to Godot's RenderingDevice as a Texture2DRD ------

// push_buffer runs on the JNI worker (ImageReader callback) thread. The
// real Vulkan + RenderingDevice work has to happen on Godot's render
// thread because of ERR_RENDER_THREAD_GUARD. So this is now a tiny
// hot-path: take ownership of `buffer`, atomically swap it into the
// pending slot (releasing any older pending one), and ask the render
// thread to do the work via `_render_thread_tick`.
//
// The schedule is gated by `_render_tick_scheduled` so a flurry of
// frames doesn't queue up dozens of redundant render-thread callbacks
// — only one outstanding tick at a time, which itself drains the
// latest pending buffer when it finally runs (matches the "drop stale
// keep newest" policy in ImageReader.acquireLatestImage).
void AhbVideoTexture::push_buffer(AHardwareBuffer *buffer, int64_t decoded_ns) {
	if (!buffer) {
		return;
	}

	// Hand the AHB ref to the pending slot. If a previous frame was
	// queued but the render thread hasn't drained it yet, release that
	// older one — we always render the newest.
	AHardwareBuffer *previous_pending =
			_pending_buffer.exchange(buffer, std::memory_order_acq_rel);
	if (previous_pending) {
		AHardwareBuffer_release(previous_pending);
	}
	_pending_decoded_ns.store(decoded_ns, std::memory_order_release);

	// Coalesce: only schedule a render-thread callback if one isn't
	// already pending. The tick will see the freshest buffer either
	// way.
	bool expected = false;
	if (_render_tick_scheduled.compare_exchange_strong(
			expected, true, std::memory_order_acq_rel)) {
		RenderingServer *rs = RenderingServer::get_singleton();
		if (rs) {
			rs->call_on_render_thread(Callable(this, "_render_thread_tick"));
		} else {
			// No RS yet — drop the schedule flag so the next push_buffer
			// can try again.
			_render_tick_scheduled.store(false, std::memory_order_release);
		}
	}
}

// Render-thread side of the handoff. ALL Vulkan + RenderingDevice
// access happens here. Drains the pending AHB, runs the original
// (now-correctly-threaded) device init + import + RID rebind chain.
void AhbVideoTexture::_render_thread_tick() {
	// Always clear the schedule flag first so a push_buffer that races
	// with us (between us draining and us finishing) can re-schedule.
	_render_tick_scheduled.store(false, std::memory_order_release);

	AHardwareBuffer *buffer =
			_pending_buffer.exchange(nullptr, std::memory_order_acq_rel);
	if (!buffer) {
		return;
	}
	int64_t decoded_ns = _pending_decoded_ns.load(std::memory_order_acquire);

	std::lock_guard<std::mutex> lk(_mutex);

	if (!_ensure_device()) {
		AHardwareBuffer_release(buffer);
		return;
	}
	if (!_ensure_ycbcr_sampler(buffer)) {
		AHardwareBuffer_release(buffer);
		return;
	}

	// Wait for the previous blit to finish BEFORE we tear down the
	// previous YCbCr VkImage — otherwise we'd be destroying an image
	// the GPU might still be reading. Note _dispatch_blit also calls
	// vkWaitForFences at the top, but releasing happens first here.
	if (_blit_fence != VK_NULL_HANDLE) {
		vkWaitForFences(_vk_device, 1, &_blit_fence, VK_TRUE, UINT64_MAX);
	}

	AHardwareBuffer *previous = _active_buffer;
	_release_vk_resources();
	if (!_import_buffer(buffer)) {
		AHardwareBuffer_release(buffer);
		// Try to keep the previous frame on screen rather than blanking.
		if (previous) {
			if (_import_buffer(previous)) {
				_active_buffer = previous;
				return;
			}
			AHardwareBuffer_release(previous);
		}
		return;
	}
	_active_buffer = buffer;
	if (previous) {
		AHardwareBuffer_release(previous);
	}

	// Plan A: stand up the persistent destination image + compute
	// pipeline. _ensure_compute_pipeline depends on the YCbCr sampler
	// existing (immutable sampler in the DS layout), so it has to run
	// AFTER _ensure_ycbcr_sampler above.
	if (!_ensure_destination_image(_width, _height)) {
		return;
	}
	if (!_ensure_compute_pipeline()) {
		return;
	}

	// Refresh descriptor binding 0 (new per-frame source view) and run
	// the blit. After this returns, the dst image is in
	// SHADER_READ_ONLY_OPTIMAL and the compute submit is in-flight on
	// the queue, ordered before any subsequent Godot fragment work.
	_update_descriptor_set();
	if (!_dispatch_blit()) {
		LOGE("Compute blit dispatch failed; frame dropped");
		return;
	}

	// Hand Godot the DESTINATION image (real RGBA8), not the YCbCr
	// source. The destination is persistent, so we only need to do
	// this once. Repeated set_texture_rd_rid() with the same RID is a
	// no-op but slightly wasteful; gate on _current_rd_rid emptiness.
	if (_current_rd_rid == RID()) {
		RenderingServer *rs = RenderingServer::get_singleton();
		RenderingDevice *rd = rs ? rs->get_rendering_device() : nullptr;
		if (rd) {
				RID rd_rid = rd->texture_create_from_extension(
						RenderingDevice::TEXTURE_TYPE_2D,
						RenderingDevice::DATA_FORMAT_R8G8B8A8_UNORM,
						RenderingDevice::TEXTURE_SAMPLES_1,
						RenderingDevice::TEXTURE_USAGE_SAMPLING_BIT |
								RenderingDevice::TEXTURE_USAGE_CAN_COPY_FROM_BIT,
						(uint64_t)_dst_image,
						_dst_width,
						_dst_height,
					1,
					1);
			// Texture2DRD::set_texture_rd_rid() expects a RenderingDevice
			// texture RID directly (it validates via RD::texture_is_valid).
			// The previous version wrapped through RenderingServer::
			// texture_rd_create() which creates a *server-side* texture
			// resource — that's a different RID space, and RD::
			// texture_is_valid() returns false for it, so the bind silently
			// failed and Godot kept displaying the placeholder colour.
			_current_rd_rid = rd_rid;
			set_texture_rd_rid(_current_rd_rid);
			LOGI("Bound destination RGBA8 image to Godot Texture2DRD: "
				"rd_rid=%llu valid=%d size=%dx%d",
				(unsigned long long)rd_rid.get_id(),
				(int)rd_rid.is_valid(), _dst_width, _dst_height);
		} else {
			LOGE("RenderingDevice unavailable in render_thread_tick!");
		}
	}

	_latest_decoded_ns.store(decoded_ns, std::memory_order_release);
	_frame_counter.fetch_add(1, std::memory_order_acq_rel);
	_is_ready.store(true, std::memory_order_release);
}


// ---------- helpers ---------------------------------------------------------

uint32_t AhbVideoTexture::_find_memory_type(uint32_t memory_type_bits) const {
	if (_vk_phys_device == VK_NULL_HANDLE) {
		return UINT32_MAX;
	}
	VkPhysicalDeviceMemoryProperties mem_props{};
	vkGetPhysicalDeviceMemoryProperties(_vk_phys_device, &mem_props);
	for (uint32_t i = 0; i < mem_props.memoryTypeCount; ++i) {
		if (memory_type_bits & (1u << i)) {
			// Prefer DEVICE_LOCAL but accept anything if nothing matches —
			// AHB-imported memory often carries vendor-specific bits.
			return i;
		}
	}
	return UINT32_MAX;
}

Dictionary AhbVideoTexture::get_latest_info() const {
	Dictionary out;
	out["decoded_ns"] = (int64_t)_latest_decoded_ns.load(std::memory_order_acquire);
	out["width"] = _width;
	out["height"] = _height;
	out["frames"] = _frame_counter.load(std::memory_order_acquire);
	out["ready"] = _is_ready.load(std::memory_order_acquire);
	return out;
}

bool AhbVideoTexture::is_ready() const {
	return _is_ready.load(std::memory_order_acquire);
}

} // namespace godot
