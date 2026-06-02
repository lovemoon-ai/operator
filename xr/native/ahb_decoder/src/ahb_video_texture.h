// AhbVideoTexture: a Godot Texture2DRD subclass backed by a Vulkan
// VkImage that was imported from an AHardwareBuffer (the exact buffer
// MediaCodec wrote into). One instance is shared between the decoder
// callback (writer) and the fragment shader sampler (reader); access
// is single-writer, single-reader so we use atomics rather than locks
// for the swap.

#pragma once

#include <godot_cpp/classes/texture2drd.hpp>
#include <godot_cpp/core/binder_common.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/rid.hpp>

#include <android/hardware_buffer.h>
// Bring in the AHB-import extension typedefs (PFN_*_ANDROID,
// VkAndroidHardwareBufferPropertiesANDROID, etc). Plain vulkan.h
// does not include them — that's why our header forward-declares
// them as members and immediately fails compile.
#include <vulkan/vulkan.h>
#include <vulkan/vulkan_android.h>

#include <atomic>
#include <mutex>

namespace godot {

class AhbVideoTexture : public Texture2DRD {
	GDCLASS(AhbVideoTexture, Texture2DRD);

public:
	AhbVideoTexture();
	~AhbVideoTexture() override;

	/// Called from the JNI bridge on the decoder thread. `buffer` is
	/// already AHardwareBuffer_acquire()-ed by the caller; this class
	/// takes ownership and releases when it swaps to a newer one.
	/// `decoded_ns` is the wall-clock time the decoder produced the
	/// frame, used for latency reporting.
	void push_buffer(AHardwareBuffer *buffer, int64_t decoded_ns);

	/// GDScript-callable: poll the most recently decoded buffer's
	/// metadata. Returns a Dictionary like
	///   { "decoded_ns": int, "width": int, "height": int, "frames": int }
	/// or empty if no frame has arrived yet.
	Dictionary get_latest_info() const;

	/// GDScript-callable: report whether the Vulkan import path actually
	/// initialised correctly. Useful for the GDScript side to decide
	/// whether to use this texture or fall back to plan B.
	bool is_ready() const;

protected:
	static void _bind_methods();

private:
	// Imported VkImage backing the active AHardwareBuffer. Recreated
	// on each push_buffer call (the underlying memory imports cheaply
	// because AHB just bumps a refcount).
	VkDevice _vk_device = VK_NULL_HANDLE;
	VkPhysicalDevice _vk_phys_device = VK_NULL_HANDLE;
	VkImage _vk_image = VK_NULL_HANDLE;
	VkDeviceMemory _vk_memory = VK_NULL_HANDLE;
	VkImageView _vk_image_view = VK_NULL_HANDLE;
	VkSamplerYcbcrConversion _vk_ycbcr = VK_NULL_HANDLE;
	VkSampler _vk_sampler = VK_NULL_HANDLE;

	// ---- Plan A: compute blit YCbCr -> RGBA ------------------------
	// Persistent destination image. We hand THIS to Godot, not the AHB
	// VkImage above, because Godot's RenderingDevice can't express the
	// immutable YCbCr sampler needed to read the AHB image. Allocated
	// once on first frame, recreated only if the source size changes.
	VkImage _dst_image = VK_NULL_HANDLE;
	VkDeviceMemory _dst_memory = VK_NULL_HANDLE;
	VkImageView _dst_image_view = VK_NULL_HANDLE;
	int32_t _dst_width = 0;
	int32_t _dst_height = 0;
	bool _dst_first_use = true; // controls UNDEFINED vs SHADER_READ_ONLY barrier

	// Compute pipeline that does the conversion. Created once after
	// the YCbCr sampler is known (the immutable sampler is part of the
	// descriptor set layout so it must exist before pipeline creation).
	VkDescriptorSetLayout _ds_layout = VK_NULL_HANDLE;
	VkPipelineLayout _pipeline_layout = VK_NULL_HANDLE;
	VkPipeline _compute_pipeline = VK_NULL_HANDLE;
	VkDescriptorPool _descriptor_pool = VK_NULL_HANDLE;
	VkDescriptorSet _descriptor_set = VK_NULL_HANDLE;
	bool _descriptor_set_initialized = false;

	// Command pool + reusable command buffer for the per-frame dispatch.
	// Reset (not freed) every frame — TRANSIENT + RESET_COMMAND_BUFFER
	// flags let us call vkBeginCommandBuffer cheaply each frame.
	VkCommandPool _cmd_pool = VK_NULL_HANDLE;
	VkCommandBuffer _cmd_buffer = VK_NULL_HANDLE;
	// Fence so we can wait for the blit to finish before destroying the
	// source AHB-import resources (otherwise we'd race the GPU).
	VkFence _blit_fence = VK_NULL_HANDLE;

	// Cached queue + queue-family for vkQueueSubmit. Pulled from
	// Godot's RenderingDevice via DRIVER_RESOURCE_COMMAND_QUEUE /
	// DRIVER_RESOURCE_QUEUE_FAMILY (PoC confirmed both are non-zero
	// on Pico 4 / Adreno).
	VkQueue _vk_queue = VK_NULL_HANDLE;
	uint32_t _vk_queue_family = 0;
	// ----------------------------------------------------------------

	// Cached function pointers — these are extension entry points that
	// must be resolved via vkGetDeviceProcAddr after we have a device.
	PFN_vkGetAndroidHardwareBufferPropertiesANDROID _fn_get_ahb_props = nullptr;
	PFN_vkCreateSamplerYcbcrConversion _fn_create_ycbcr = nullptr;
	PFN_vkDestroySamplerYcbcrConversion _fn_destroy_ycbcr = nullptr;

	// Saved AHB properties from the first imported buffer. We assume
	// every subsequent buffer has the same format / external format /
	// memory size; if MediaCodec ever switches mid-stream we'd need
	// to flush and re-init.
	uint64_t _ahb_external_format = 0;
	VkFormatFeatureFlags _ahb_format_features = 0;
	VkComponentMapping _ahb_components = {};
	VkSamplerYcbcrModelConversion _ahb_ycbcr_model = VK_SAMPLER_YCBCR_MODEL_CONVERSION_RGB_IDENTITY;
	VkSamplerYcbcrRange _ahb_ycbcr_range = VK_SAMPLER_YCBCR_RANGE_ITU_FULL;
	VkChromaLocation _ahb_x_chroma_offset = VK_CHROMA_LOCATION_COSITED_EVEN;
	VkChromaLocation _ahb_y_chroma_offset = VK_CHROMA_LOCATION_COSITED_EVEN;

	AHardwareBuffer *_active_buffer = nullptr;
	std::atomic<int64_t> _latest_decoded_ns{0};
	std::atomic<int32_t> _frame_counter{0};
	std::atomic<bool> _is_ready{false};
	int32_t _width = 0;
	int32_t _height = 0;

	// push_buffer is called from the ImageReader callback thread (a
	// JNI worker thread). Godot 4.5 wraps every RenderingDevice method
	// in ERR_RENDER_THREAD_GUARD_V(0) (see PR #98782) so calling
	// get_driver_resource / texture_create_from_extension off the
	// render thread silently returns 0 — that's what produced the
	// "RenderingDevice didn't return Vulkan handles" cascade in our
	// first attempt. We instead atomically stash the latest AHB into
	// `_pending_buffer` and schedule `_render_thread_tick` via
	// RenderingServer::call_on_render_thread, which then does ALL the
	// real work (Vulkan import + RID create + set_texture_rd_rid) on
	// the render thread where the guard passes.
	std::atomic<AHardwareBuffer *> _pending_buffer{nullptr};
	std::atomic<int64_t> _pending_decoded_ns{0};
	std::atomic<bool> _render_tick_scheduled{false};
	std::mutex _mutex;
	RID _current_rd_rid;

	/// Render-thread entry point. Drains _pending_buffer and runs the
	/// full Vulkan import + RID rebinding pipeline. Bound via ClassDB
	/// so RenderingServer::call_on_render_thread(Callable(this, "...")).
	void _render_thread_tick();

	/// Lazy-initialise _vk_device, _vk_phys_device, and the function
	/// pointers. Returns false if Godot's RenderingDevice isn't a
	/// Vulkan one (e.g. the project was forced to GLES) or if the
	/// required extensions aren't supported.
	bool _ensure_device();

	/// Tear down the current VkImage/memory/view chain. Safe to call
	/// even when nothing is allocated yet.
	void _release_vk_resources();

	/// Initialise the VkSamplerYcbcrConversion + VkSampler the very
	/// first time we see a buffer. We need the buffer's actual format
	/// (BT.601 vs 709, full range vs limited) to pick the right
	/// conversion parameters.
	bool _ensure_ycbcr_sampler(AHardwareBuffer *buffer);

	/// Import an AHardwareBuffer into a fresh VkImage + VkDeviceMemory.
	/// Sets _vk_image, _vk_memory, _vk_image_view, _width, _height.
	/// Returns true on success.
	bool _import_buffer(AHardwareBuffer *buffer);

	/// Pick a Vulkan memory type that matches `memory_type_bits` and
	/// has DEVICE_LOCAL set. Returns UINT32_MAX if no match.
	uint32_t _find_memory_type(uint32_t memory_type_bits) const;

	// ---- Plan A helpers (see .cpp for details) ---------------------
	/// Allocate or reallocate the persistent RGBA destination image so
	/// it matches `width`/`height`. Idempotent when size is unchanged.
	bool _ensure_destination_image(int32_t width, int32_t height);
	/// Build the descriptor-set layout, pipeline layout, compute pipeline,
	/// descriptor pool/set, command pool/buffer, and fence. Requires
	/// `_vk_sampler` to be created first (it's an immutable sampler in
	/// the DS layout). Runs once.
	bool _ensure_compute_pipeline();
	/// Update binding 0 (YCbCr image view) and, on first call, binding 1
	/// (destination storage image). Called every frame because the
	/// source image view is recreated per AHB.
	void _update_descriptor_set();
	/// Record + submit the compute dispatch on Godot's render queue,
	/// then vkWaitForFences. Blocks for ~sub-ms on first frame, less
	/// thereafter. Returns false if the GPU submission failed.
	bool _dispatch_blit();
	/// Pick a memory type that matches `memory_type_bits` AND has the
	/// DEVICE_LOCAL bit set. Used for the destination image (which is
	/// pure GPU memory — unlike the AHB import which lives in whatever
	/// memory type the buffer was allocated from).
	uint32_t _find_device_local_memory_type(uint32_t memory_type_bits) const;
	/// Release destination image + view + memory. Called from dtor and
	/// when resizing.
	void _release_destination_image();
	// ----------------------------------------------------------------
};

// Used by the JNI bridge to find the singleton texture.
void ahb_register_active(AhbVideoTexture *tex);
void ahb_unregister_active(AhbVideoTexture *tex);

} // namespace godot
