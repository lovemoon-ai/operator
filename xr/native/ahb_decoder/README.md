# ahb_decoder — Vulkan AHardwareBuffer GDExtension

This addon implements the optional zero-copy Android video presentation path.
When enabled, a `MediaCodec`-decoded H.264 frame goes
straight from the codec's `AHardwareBuffer` into a Vulkan `VkImage`
sampled by our existing fragment shader, with **zero CPU bytes
touched** between decoder output and the GPU.

## Status

**Builds and ships.** All five scaffold steps are done:

1. ✅ `godot-cpp` is synced into `.deps/src/godot-cpp` by
   `make -C xr deps`; this plugin consumes it through
   `xr/native/ahb_decoder/godot-cpp`, a symlink to the shared checkout.
2. ✅ The Vulkan calls in `ahb_video_texture.cpp` are filled in —
   `vkGetAndroidHardwareBufferPropertiesANDROID`,
   `VkSamplerYcbcrConversion`, dedicated-import `vkAllocateMemory`,
   image view + RD texture binding all live there.
3. ✅ `KotlinVideoDecoderPlugin.kt` declares
   `external fun nativeImportAhb(buffer, decodedNs, frameSequence, presentationTimeUs)`
   and `System.loadLibrary("ahb_decoder")` is gated on the .so being
   present in the APK.
4. ✅ `build.sh` produces and installs `libahb_decoder.so` to both
   `xr/addons/ahb_decoder/` (for the GDExtension manifest) and
   `xr/android/build/libs/arm64-v8a/` (for `System.loadLibrary`).
5. ✅ When `KotlinVideoDecoderPlugin` detects libahb_decoder.so is
   loaded, it switches MediaCodec into Surface mode (ImageReader →
   AHardwareBuffer → nativeImportAhb) and skips the YUV plane copy.

See `claw/architecture/xr-client.md` and
`claw/architecture/wire-protocol.md` for the current video architecture.

## Build

```sh
# One-shot helper (recommended):
xr/native/ahb_decoder/build.sh           # Release
xr/native/ahb_decoder/build.sh Debug     # for symbol-level debugging

# Manual equivalent:
cd xr/native/ahb_decoder
cmake -B build-arm64 \
    -DCMAKE_TOOLCHAIN_FILE=$ANDROID_NDK/build/cmake/android.toolchain.cmake \
    -DANDROID_ABI=arm64-v8a \
    -DANDROID_PLATFORM=android-29 \
    -DCMAKE_BUILD_TYPE=Release \
    -DGODOT_CPP_DIR=$PWD/godot-cpp \
    -DGODOT_CPP_BUILD_DIR=$PWD/../../../.deps/build/godot-cpp
cmake --build build-arm64
cp build-arm64/libahb_decoder.so ../../addons/ahb_decoder/libahb_decoder.so
cp build-arm64/libahb_decoder.so ../../android/build/libs/arm64-v8a/libahb_decoder.so
```

The output is `build-arm64/libahb_decoder.so` (~600 KiB stripped,
ARM64 ELF). The build.sh script installs it to both the GDExtension
addon path and the gradle JNI lib path so the Godot exporter and
Kotlin's `System.loadLibrary("ahb_decoder")` both find it.
godot-cpp's own CMake output is shared at `.deps/build/godot-cpp`.

## Architecture

```
MediaCodec output buffer
        │  (DRAM, allocated by Snapdragon HW decoder)
        ▼
Image.getHardwareBuffer()                    Kotlin
        │  (AHardwareBuffer*, refcounted)
        ▼
nativeImportAhb(buffer, decodedNs, sequence, ptsUs) JNI
        │
        ▼
AHardwareBuffer_describe → VkAndroidHardwareBufferFormatPropertiesANDROID
        │
        ▼
vkCreateImage + vkAllocateMemory(VkImportAhbInfo) + vkBindImageMemory
        │  (no copy: VkImage references the AHardwareBuffer's memory)
        ▼
VkImageView + VkSamplerYcbcrConversion       Vulkan
        │  (external format; VK_FORMAT_UNDEFINED)
        ▼
compute dispatch: ycbcr_to_rgba.comp         our own pipeline
        │  descriptor set layout carries the YCbCr conversion
        │  as pImmutableSamplers; driver does YUV→RGB on read
        ▼
persistent VK_FORMAT_R8G8B8A8_UNORM VkImage
        │
        ▼
RenderingDevice::texture_create_from_extension     Godot RD
        │
        ▼
AhbVideoTexture extends Texture2DRD          GDExtension
        │
        ▼
ShaderMaterial.set_shader_parameter("video_texture", ahb_texture)
        │
        ▼
fragment shader samples it like any other 2D texture     GPU
```

### Why the compute blit is not optional

Godot cannot sample the imported image directly. An AHardwareBuffer from
MediaCodec on Adreno comes back as a vendor *external format*
(`VK_FORMAT_UNDEFINED` + `VkExternalFormatANDROID`), and Vulkan only lets
you read those through a `VkSamplerYcbcrConversion` bound as an
**immutable sampler in the descriptor set layout**. Godot's
`RenderingDevice` has no way to express that — `texture_create_from_extension`
wants a real `DataFormat` and only builds a `VkImageView`. Handing it the
YCbCr image produces a black screen.

So we do the conversion in a pipeline we own and give Godot the RGBA8
result. This is the same shape as ANGLE emulating `GL_TEXTURE_EXTERNAL_OES`
over Vulkan, and as UE's `RHICreateTexture2DFromAndroidHardwareBuffer`.

### Why not SurfaceTexture / OES

`GL_TEXTURE_EXTERNAL_OES` has no Vulkan equivalent, and more importantly the
OES path never exposes the underlying `AHardwareBuffer` — there is nothing to
import. The GL "SurfaceTexture → FBO blit" recipe cannot be ported; it has to
be rebuilt as the pipeline above.

### What this depends on that Godot does not provide

Stock Godot 4.5.1 registers neither
`VK_ANDROID_external_memory_android_hardware_buffer` nor
`VK_EXT_queue_family_foreign`, and sets
`vulkan_1_1_features.samplerYcbcrConversion = 0` when creating the device
(`drivers/vulkan/rendering_device_driver_vulkan.cpp`). Upstream
[PR #97163](https://github.com/godotengine/godot/pull/97163), which would
change both, is still an unfinished draft.

We get the extensions anyway because Godot creates its `VkDevice` through
`VulkanHooks` → `xrCreateVulkanDeviceKHR`, and `XR_KHR_vulkan_enable2`
requires the runtime to "aggregate the requirements specified by the
application with its own requirements" — Meta/PICO swapchain images are
themselves AHardwareBuffers, so their runtimes pull these in.

This is an assumption, not a guarantee. `_probe_vulkan_capabilities()` logs
the driver-side picture at init so a failure is diagnosable from logcat
alone:

```
AhbVideoTexture: Vulkan capability probe: AHB_import=yes sampler_ycbcr_ext=yes \
    queue_family_foreign=yes samplerYcbcrConversion_supported=yes (N device extensions)
AhbVideoTexture: YCbCr conversion ready: external_format=0x... model=... range=...
```

Vulkan offers no API to read back *enabled* extensions or features, so the
probe reports what the physical device supports. If it says `yes` everywhere
and frames still come out black or a solid colour, the runtime did not
aggregate the feature in and the fallback (`debug.xrobo.force_yuv_plane=1`)
is the answer.

Compared to the current plan B (CPU plane copy + 3 L8 ImageTexture
upload), this saves ~3-5 ms per frame of CPU and ~350 KB per frame of
DRAM bandwidth, plus eliminates the `present` deferred-callback hop
on the Godot main thread. Expected to take the displayed framerate
from ~25 fps (plan C) up to whatever the codec can sustain
(60-90 fps at 360p).
