# Quest RGB 16:9 Byte-Buffer Encoding TODO

Status: open

Date noted: 2026-06-24

## Context

Quest RGB recording currently captures Camera2 `YUV_420_888` frames, packs them
into a tight I420/NV12 side-by-side stereo byte buffer, and submits that buffer
to `MediaCodec.queueInputBuffer()`.

This works for validated 4:3 capture sizes, but a Quest sample recorded at
single-eye `1280x720` produced a `2560x720` SBS H.264 stream with a corrupted
green band at the bottom of the RGB video. Extracting the raw video track with
FFmpeg showed the corruption is already present in the MP4 stream before the
SpatialMP4 reader or Rerun visualization sees it.

## Issue

The byte-buffer encoder path assumes tightly packed image planes:

- luma size: `encodedWidth * encodedHeight`
- chroma size: `encodedWidth * encodedHeight / 2`

For non-4:3 sizes, the Quest encoder may require aligned row stride and/or
slice-height padding. The current implementation does not query or fill the
encoder input planes, so padding rows or columns can be left invalid and become
visible as corrupted chroma in the encoded video.

## Current Mitigation

Quest RGB resolution selection is restricted to validated 4:3 sizes:

- `640x480`
- `800x600`
- `1280x960`

The Quest provider also rejects non-4:3 RGB size requests at runtime and falls
back to the largest safe 4:3 YUV size.

## Proposed Fix

Make the Quest byte-buffer path support 16:9 safely by writing into the actual
encoder input layout instead of assuming a tight payload:

- use `MediaCodec.getInputImage(inputIndex)` or equivalent input format data to
  discover encoder plane `rowStride`, `pixelStride`, and effective slice height
- copy each Camera2 `YUV_420_888` plane into the encoder input planes using the
  encoder-provided strides
- fill unused luma padding with limited-range black (`Y=16`) and chroma padding
  with neutral chroma (`U=128`, `V=128`)
- validate stereo SBS output for at least `1280x720` and `1024x576`

An alternative is to replace byte-buffer input with a Surface-input encoder and
compose the left/right camera frames into SBS with GPU rendering.

## Acceptance Criteria

- Quest can record single-eye `1280x720` without green bands or chroma
  corruption in the raw MP4 video stream.
- SpatialMP4 reader reports the correct per-eye RGB size for the 16:9 capture.
- Web/Rerun visualization displays the left RGB image with correct aspect and
  projection metadata.
- The 4:3 sizes remain supported.
