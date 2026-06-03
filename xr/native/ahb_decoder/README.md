# ahb_decoder — Vulkan AHardwareBuffer GDExtension

This is the scaffold for **plan.md item 10** — the terminal zero-copy
video path. When complete, a `MediaCodec`-decoded H.264 frame goes
straight from the codec's `AHardwareBuffer` into a Vulkan `VkImage`
sampled by our existing fragment shader, with **zero CPU bytes
touched** between decoder output and the GPU.

## Status

**Builds and ships.** All five scaffold steps are done:

1. ✅ `godot-cpp` is wired in as a git submodule. Initialise with
   `git submodule update --init --depth=1 third_party/godot-cpp`; this
   plugin consumes it through `xr/native/ahb_decoder/godot-cpp`, a
   symlink to the shared checkout.
2. ✅ The Vulkan calls in `ahb_video_texture.cpp` are filled in —
   `vkGetAndroidHardwareBufferPropertiesANDROID`,
   `VkSamplerYcbcrConversion`, dedicated-import `vkAllocateMemory`,
   image view + RD texture binding all live there.
3. ✅ `KotlinVideoDecoderPlugin.kt` declares
   `external fun nativeImportAhb(buffer: HardwareBuffer, decodedNs: Long)`
   and `System.loadLibrary("ahb_decoder")` is gated on the .so being
   present in the APK.
4. ✅ `build.sh` produces and installs `libahb_decoder.so` to both
   `xr/addons/ahb_decoder/` (for the GDExtension manifest) and
   `xr/android/build/libs/arm64-v8a/` (for `System.loadLibrary`).
5. ✅ When `KotlinVideoDecoderPlugin` detects libahb_decoder.so is
   loaded, it switches MediaCodec into Surface mode (ImageReader →
   AHardwareBuffer → nativeImportAhb) and skips the YUV plane copy.

See `claw/issues/005-decisions.md` D-6 for the architectural
rationale (and why we chose AHB over OES SurfaceTexture).

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
    -DGODOT_CPP_BUILD_DIR=$PWD/../../../third_party/godot-cpp-build
cmake --build build-arm64
cp build-arm64/libahb_decoder.so ../../addons/ahb_decoder/libahb_decoder.so
cp build-arm64/libahb_decoder.so ../../android/build/libs/arm64-v8a/libahb_decoder.so
```

The output is `build-arm64/libahb_decoder.so` (~600 KiB stripped,
ARM64 ELF). The build.sh script installs it to both the GDExtension
addon path and the gradle JNI lib path so the Godot exporter and
Kotlin's `System.loadLibrary("ahb_decoder")` both find it.
godot-cpp's own CMake output is shared at
`third_party/godot-cpp-build`.

## Architecture

```
MediaCodec output buffer
        │  (DRAM, allocated by Snapdragon HW decoder)
        ▼
Image.getHardwareBuffer()                    Kotlin
        │  (AHardwareBuffer*, refcounted)
        ▼
nativeImportAhb(buffer, decodedNs)           JNI
        │
        ▼
AHardwareBuffer_describe → VkAndroidHardwareBufferFormatPropertiesANDROID
        │
        ▼
vkCreateImage + vkAllocateMemory(VkImportAhbInfo) + vkBindImageMemory
        │  (no copy: VkImage references the AHardwareBuffer's memory)
        ▼
VkImageView + VkSamplerYcbcrConversion       Vulkan
        │  (driver does YUV→RGB at sample time)
        ▼
RenderingDevice::texture_create_from_extension     Godot RD
        │
        ▼
AhbVideoTexture extends Texture2DRD          GDExtension
        │
        ▼
ShaderMaterial.set_shader_parameter("y_texture", ahb_texture)
        │
        ▼
fragment shader samples it like any other 2D texture     GPU
```

Compared to the current plan B (CPU plane copy + 3 L8 ImageTexture
upload), this saves ~3-5 ms per frame of CPU and ~350 KB per frame of
DRAM bandwidth, plus eliminates the `present` deferred-callback hop
on the Godot main thread. Expected to take the displayed framerate
from ~25 fps (plan C) up to whatever the codec can sustain
(60-90 fps at 360p).
