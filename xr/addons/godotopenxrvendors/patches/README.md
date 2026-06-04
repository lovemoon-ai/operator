# Godot OpenXR Vendors Patches

These patches target Godot OpenXR Vendors `4.3.1-stable`
(`22156fcab0fadd480b1bf64de57d900f750fa9a3`), as pinned in
`../VERSION`.

Apply order:

1. `0001-meta-depth-callback-metadata.patch`
2. `0002-meta-vulkan-depth-readback.patch`

The first patch exposes Meta environment-depth timing, FOV, near/far, and
depth-eye pose metadata through `get_environment_depth_map_async()` and adds
`get_predicted_display_time_ns()` for pose timestamping.

The second patch fixes Vulkan CPU readback for Meta D16 environment depth:
OpenXR swapchain images imported through `texture_create_from_extension()` do
not have enough Vulkan image metadata for direct `texture_2d_layer_get()`.
The patch creates a Godot-owned D16 readback texture, copies each acquired
swapchain layer into it, and reads that texture instead.

Build patched binaries with:

```bash
./prepare.sh --build-patched
./prepare.sh --check-patched
```

The generated `.bin/` artifacts remain ignored, so the source tag, commit, and
patches are the reproducible state stored in git.
