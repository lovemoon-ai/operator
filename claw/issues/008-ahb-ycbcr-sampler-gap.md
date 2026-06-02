# AHB Vulkan zero-copy display — YCbCr sampler gap

Status: open
Category: video transport and decode
Spawned-from: issue 005

## Problem

The AHB import path in `xr/native/ahb_decoder` correctly:
- Imports an `AHardwareBuffer` (from `MediaCodec` ImageReader output) into
  a Vulkan `VkImage` with `VK_FORMAT_UNDEFINED` + `externalFormat` and
  the dedicated `VkImportAndroidHardwareBufferInfoANDROID`.
- Creates a `VkSamplerYcbcrConversion` parametrised by the AHB's
  suggested model / range / chroma offsets.
- Creates a `VkImageView` referencing that conversion via
  `VkSamplerYcbcrConversionInfo` in `pNext`.
- Hands the `VkImage` to Godot's `RenderingDevice` via
  `texture_create_from_extension` and binds the resulting RID through
  `Texture2DRD::set_texture_rd_rid`.
- Hits a sustained `AHB import: ~30 fps` rate, confirmed on a real Pico
  B3110 over Wi-Fi (see issue 005 logs).

But the user sees **black** in the headset.

## Root cause

Vulkan requires that **every** `VkImageView` *and* `VkSampler` used to
sample a `VK_FORMAT_UNDEFINED + externalFormat` image carry the same
`VkSamplerYcbcrConversion` via `pNext`, AND that the descriptor set
layout used at draw time bind that sampler as an **immutable
combined image sampler**. Without the conversion in the sampler the
driver can't decode the externalFormat, so it samples zero.

Godot's standard fragment shader binding `uniform sampler2D
video_texture` resolves to a generic `sampler2D` which Godot's
`RenderingDevice` creates a default sampler for — that sampler has no
YCbCr conversion → black sample. Our `_vk_sampler` (with conversion)
in `AhbVideoTexture` is created but never plumbed to Godot's pipeline.

## Workaround (shipped in issue 005)

```
adb shell setprop debug.xrobo.force_yuv_plane 1
```

`KotlinVideoDecoderPlugin` then refuses to load `libahb_decoder.so`
even when present, falls back to the ByteBuffer-mode
`extractYuvPlanesTight` path, and `robot_view.gd` uploads three
`L8` `ImageTexture`s that the existing GPU YUV→RGB shader samples.

Cost: ~3 KB/frame CPU copy (Y + U + V planes) + 3 ImageTexture
uploads per frame. Measured on Pico B3110 @ 30 fps:
- decode_avg ≈ 35–40 ms
- present_avg ≈ 14–17 ms
- total_avg ≈ 50–55 ms (motion-to-photons end-to-end is ~120 ms
  including encoder + Wi-Fi tx)

That's well within the 100 ms headroom over the original 4-Mbps
baseline. This is "good enough" for now; the AHB win we forfeited is
~3–5 ms of CPU and ~350 KB/frame of memory bandwidth — nice to have,
not blocking.

## Resolution options (pick one)

1. **Compute-shader blit AHB → RGBA** — write a Godot RD compute pass
   that uses our YCbCr-aware sampler (immutable in the descriptor
   layout we control) to read the AHB-imported image and writes an
   RGBA `Texture2DRD` that the existing fragment shader samples
   normally. Keeps the CPU-free invariant; adds one GPU pass per
   frame. Best long-term answer.

2. **Patch godot-cpp / Godot RD API** — expose immutable sampler
   bindings to GDExtension so we can register a YCbCr-aware sampler
   that the standard `sampler2D` binding uses. Invasive; requires
   upstream PR.

3. **OES SurfaceTexture path** — what Android apps usually do: render
   MediaCodec to a SurfaceTexture, then sample via `samplerExternalOES`
   in a GLSL ES shader. Doesn't fit Godot 4's Vulkan-on-Android
   pipeline, would need a separate GL context + interop. Rejected in
   ADR D-6 (issue 005).

4. **Drop AHB entirely** — delete `xr/native/ahb_decoder/`, keep the
   YUV plane path as the only fast path. Simplest. Defensible if the
   3–5 ms CPU savings never matter.

Recommended: **option 1** when there's time, **option 4** if AHB stays
unused for another 2–3 sessions.

## Acceptance criteria for closure

- Headset displays the Mac camera feed without setting
  `debug.xrobo.force_yuv_plane=1`.
- `AhbVideoTexture::is_ready()` returns true AND the texture content
  shown in the fragment shader matches the source camera frame
  (validated visually).
- No Vulkan validation errors during sustained 30 fps decode.
- Reverts the workaround documented in `005-decisions.md` D-6 (or
  updates D-6 to reflect option 4 if we delete AHB).
