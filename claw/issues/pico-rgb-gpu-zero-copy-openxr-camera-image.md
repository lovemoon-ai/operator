# Pico RGB GPU zero-copy follow-up

## Status

The Pico OpenXR RGB encoder now uses a MediaCodec input Surface with GLES
composition instead of Kotlin RGBA -> YUV byte-buffer conversion.

## Remaining problem

`XR_PICO_camera_image` still exposes frames to this app as `RGBA_8888` raw
buffers. The current bridge copies each runtime buffer into a Godot
`PackedByteArray`, then the Android plugin receives a Java `ByteArray` and
uploads it as a GL texture.

That removes the largest CPU color-conversion hotspot, but it is not fully
zero-copy. At high resolutions, the native -> Godot -> Java buffer movement and
GL texture upload can still limit throughput.

## Target architecture

- Keep Pico camera frames in native code after `xrGetCameraImageDataPICO`.
- Prefer a vendor-supported texture, `AHardwareBuffer`, or other GPU-importable
  handle if PICO exposes one in a newer SDK/runtime.
- If only raw RGBA is available, bypass GDScript and Java arrays:
  - convert/copy through native code,
  - reuse fixed staging buffers,
  - upload into GL/Vulkan from the native capture thread.
- Compose stereo side-by-side on GPU.
- Feed `MediaCodec` through an input Surface for both low and high resolutions.

## Acceptance

- Pico OpenXR RGB recording does not invoke Kotlin per-pixel RGBA -> YUV
  conversion at any resolution.
- The OpenXR frame pump does not perform large per-frame work on the Godot main
  thread beyond the runtime call itself.
- 640x480, 1280x960, and the largest supported 4:3 Pico mode are profiled on
  device with encoded RGB FPS, frame gaps, CPU load, and thermals.
