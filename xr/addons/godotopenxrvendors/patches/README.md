# Godot OpenXR Vendors Patches

These patches target Godot OpenXR Vendors `4.3.1-stable`
(`22156fcab0fadd480b1bf64de57d900f750fa9a3`), as pinned in
`../VERSION`.

Apply order:

1. `0001-meta-depth-callback-metadata.patch`
2. `0002-meta-vulkan-depth-readback.patch`
3. `0003-fb-body-tracking-vformat-fix.patch`
4. `0004-meta-depth-start-result.patch`

The first patch exposes Meta environment-depth timing, FOV, near/far, and
depth-eye pose metadata through `get_environment_depth_map_async()` and adds
`get_predicted_display_time_ns()` for pose timestamping.

The second patch fixes Vulkan CPU readback for Meta D16 environment depth:
OpenXR swapchain images imported through `texture_create_from_extension()` do
not have enough Vulkan image metadata for direct `texture_2d_layer_get()`.
The patch creates a Godot-owned D16 readback texture, copies each acquired
swapchain layer into it, and reads that texture instead.

The third patch fixes a `vformat()` call in
`openxr_fb_body_tracking_extension_wrapper.cpp` whose format string was
missing the `%s` placeholder for its second argument. Every time
`xrLocateBodyJointsFB()` returned a failure the wrapper raised a
`String::format` error ("not all arguments converted during string
formatting") instead of the intended log message, spamming the per-frame
process callback on Quest 3 during OpenXR session start-up and any
transient body-tracking outage.

The fourth patch reports the real render-thread result of
`xrStartEnvironmentDepthProviderMETA` to Godot. The public started state and
started signal now change only after OpenXR succeeds; failures emit
`openxr_meta_environment_depth_start_failed` with the `XrResult` value.
Both Meta and PICO vendor AARs must embed the rebuilt shared library because
Android packaging can select the AAR copy over the standalone GDExtension.

Build patched binaries with:

```bash
./prepare.sh --build-patched
./prepare.sh --check-patched
```

The generated `.bin/` artifacts remain ignored, so the source tag, commit, and
patches are the reproducible state stored in git.
