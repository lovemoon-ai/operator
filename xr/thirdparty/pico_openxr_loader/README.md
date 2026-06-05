PICO OpenXR Loader
==================

This directory vendors the PICO OpenXR loader used only by the Pico Android
export. Godot's stock Android OpenXR loader does not expose PICO private
extensions such as `XR_PICO_camera_image`, so Pico builds stage this loader
separately and Gradle swaps it into the APK only when
`PICO_OPENXR_LOADER_ENABLED=1`.

Version:

- PICO OpenXR SDK 3.0.0-20250422

Files:

- `3.0.0-20250422/arm64-v8a/libopenxr_loader.so`

SHA-256:

- `79882748101e096550f9eccac59f4c4ea6eb99c500001975abe7736bb54d4033`

Build integration:

- `make build-pico` stages this loader into `android/build/libs/pico`.
- Non-Pico exports remove Pico loader staging before export.
- `xr/android/build/build.gradle` only replaces the APK loader when the Pico
  build flag is enabled.
