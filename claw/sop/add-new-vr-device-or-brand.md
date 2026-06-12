# SOP: Add A New VR Device Or Brand

This SOP explains how to support a new Android XR headset in the current
Operator architecture, assuming the device is already supported by OpenXR and
Godot at a basic level.

The default rule: support devices by capabilities, not by product names.
Product names are useful for logging, test selection, and vendor-specific bug
workarounds, but app/core behavior should ask `PlatformRegistry` for
`SensorCapability` availability.

## Decision Tree

1. Same brand, same loader, same required Android manifest features:

   Reuse the existing APK and export preset. Add or update capability probes,
   device smoke tests, and docs. This is the normal path for Quest 3 vs Quest
   3S, or for another Pico model using the same Pico loader/plugin surface.

2. Same brand, new optional capability:

   Reuse the APK. Add runtime probing in that brand adapter, add a
   `SensorCapability` only if app/core needs a new stable concept, and gate the
   feature in app/composition or core code.

3. Same brand, new required loader, permission, native library, or store target:

   Add or split an export preset and Makefile target. Keep the runtime
   capability model the same, but document why build-time packaging differs.

4. New brand:

   Add a new platform adapter and, if the generic Khronos/OpenXR path is not
   enough, add the vendor loader/plugin/native packaging needed by that brand.
   New brands usually require a new export preset and build target.

## One APK Or Separate APKs

Build-time selects packaged native loaders, Android permissions, export tags,
and vendor plugin settings. Runtime selects which provider and capabilities are
actually available on the attached headset.

For one brand family, prefer one APK when:

- the same OpenXR loader/vendor plugin works for every target model;
- Android permissions and manifest features do not differ;
- missing hardware features can be represented as `CapabilityState.UNAVAILABLE`
  or `REQUIRES_RUNTIME_EXTENSION`;
- performance differences can be handled by runtime quality settings;
- all target devices pass the same mode smoke tests.

Use separate APKs when:

- the loader or native libraries differ;
- store distribution requires binary/device targeting;
- the manifest must declare incompatible device features;
- asset or quality tiers are large enough to justify separate packages;
- one model needs code excluded for policy or stability reasons.

Cross-brand single APKs are possible only when the project uses a generic
OpenXR path and does not need vendor-specific loaders. This repo currently
ships vendor-specific packaging for Meta Quest and Pico, so Quest and Pico
should remain separate APK families unless the build system is deliberately
changed.

## Quest 3 And Quest 3S Assessment

Use one Meta Quest APK for Quest 3 and Quest 3S unless a store/distribution
requirement says otherwise.

Current reasons:

- Both devices are Meta Quest devices on the same Meta Horizon OS developer
  platform.
- Meta documents Quest 3 and Quest 3S with the same Snapdragon XR2 Gen 2B
  chipset, 8 GB memory, 120 Hz maximum refresh rate, hand tracking, color
  passthrough, Wi-Fi 6E, and Bluetooth 5.2.
- Meta also says Quest 3S supports Quest 3 experiences and has the same power
  and performance class.
- Their differences still matter: Quest 3 has higher per-eye resolution,
  wider FOV, continuous IPD adjustment, 3.5 mm audio jack, and passthrough with
  depth sensor; Quest 3S has lower resolution/FOV, preset IPD, no audio jack,
  and passthrough without the dedicated depth sensor.

For Operator that means:

- keep using the `Meta Quest` preset and `make build-quest`;
- keep `QuestPlatformAdapter` capability-driven;
- allow depth-dependent features to be unavailable or degraded on Quest 3S;
- avoid a new `quest3s` custom feature tag unless packaging or policy requires
  it;
- test both models and compare capability snapshots.

## Current Module Map

### Build And Packaging

- `xr/export_presets.cfg` - Android export presets, custom feature tags,
  vendor XR feature toggles, permissions, package id, and filters.
- `xr/Makefile` - top-level `build-*`, `install-*`, `ship-*`, and run targets.
- `xr/makefiles/Makefile.addons` - native addon, Android plugin, vendor loader,
  and third-party dependency staging.
- `xr/addons/godotopenxrvendors/` - Godot OpenXR vendors plugin.
- `xr/thirdparty/` - checked-in binary vendor loader inputs, currently Pico.

Do not add one export preset per device model by default. Presets represent
packaging differences, not every runtime capability variation.

### Runtime Platform Layer

- `xr/scripts/platform/registry/platform_registry.gd` - app/core entry point
  for capability queries and provider lookup.
- `xr/scripts/platform/quest/quest_platform_adapter.gd` - Meta Quest singleton
  names, Quest provider probing, depth/boundary/timebase capability reporting.
- `xr/scripts/platform/pico/pico_platform_adapter.gd` - Pico singleton names,
  Pico build/runtime heuristics, Pico OpenXR bridge access.
- `xr/scripts/platform/openxr/generic_openxr_adapter.gd` - generic pose,
  controller, and hand-tracking fallback.
- `xr/scripts/contracts/platform/sensor_capability.gd` - stable capability ids.
- `xr/scripts/contracts/platform/capability_state.gd` - availability states.
- `xr/scripts/contracts/platform/capability_info.gd` - capability payload.

Vendor singleton names belong only in `xr/scripts/platform/<brand>/` or
brand-specific shims. App, core, sinks, and UI should not call
`Engine.has_singleton("QuestCapturePlugin")` or similar directly.

### Feature And Composition Gates

- `xr/scripts/app/features/feature_set.gd` - export-time feature tags.
- `xr/scripts/contracts/features/` - feature definitions and dependency rules.
- `xr/scripts/app/composition/` - mode-specific dependency graph and
  capability gates.
- `xr/scripts/app/modes/` - mode lifecycle scripts.

Use export features to include product modes and sinks. Use platform
capabilities to decide what is usable on the current headset.

### Native And Android Surfaces

- `xr/android_plugin/` - Android plugins for capture, live feed, QR, muxing,
  and contracts.
- `xr/native/` - GDExtensions such as AHB decode, Pico OpenXR, MuJoCo,
  Pinocchio.
- `xr/addons/` - Godot-facing plugin wrappers and exported addon assets.

Add new native surfaces only when Godot/OpenXR/Vendors Plugin cannot expose the
needed capability.

## Adding A New Model In An Existing Brand

Use this for examples like Quest 3S under Meta Quest, or another Pico headset
under the Pico family.

1. Confirm package compatibility.

   Check the vendor docs for loader/plugin requirements, Android permissions,
   and store targeting. If the existing preset packages the right loader and
   permissions, do not add a new preset.

2. Capture device identity for logs and tests.

   Use shell-side props in test scripts when needed:

   ```bash
   adb -s <serial> shell 'printf "manufacturer=%s\nbrand=%s\nmodel=%s\ndevice=%s\nproduct=%s\n" "$(getprop ro.product.manufacturer)" "$(getprop ro.product.brand)" "$(getprop ro.product.model)" "$(getprop ro.product.device)" "$(getprop ro.product.name)"'
   ```

   In Godot, `OS.get_model_name()` is acceptable for snapshots. Avoid using it
   as a feature gate outside a platform adapter.

3. Update the brand adapter only when runtime probing is wrong.

   Examples:

   - Quest depth extension reports present on one model and absent on another:
     fix `QuestPlatformAdapter.depth_extension_info()` or its capability state.
   - Pico motion trackers expose a new runtime name pattern:
     update `PicoPlatformAdapter.looks_like_motion_tracker_name()` or
     `is_pico_openxr_runtime_name()`.

4. Add a capability only for a new app-facing concept.

   If the difference is quality, resolution, FOV, or performance tier, do not
   add a new `SensorCapability`; add runtime tuning or profile data. If the
   difference is "can provide depth map" or "can provide motion trackers", use
   a capability.

5. Add device coverage.

   Extend device smoke coverage if the current Quest/Pico snapshot is too
   broad. Prefer one snapshot test per brand plus model metadata unless a model
   requires model-specific assertions.

6. Build and test the existing APK on both old and new devices.

   ```bash
   cd xr
   make build-quest        # Meta Quest family
   make build-pico         # Pico family
   ```

   Then install the same APK on every supported model and run the relevant
   device tests.

## Adding A New Brand

1. Start with generic OpenXR.

   If pose, controllers, and hand tracking are enough, first try the generic
   path through `GenericOpenXRPlatformAdapter`. Add a new export preset only if
   the device requires different packaging.

2. Add a brand adapter.

   Create:

   ```text
   xr/scripts/platform/<brand>/<brand>_platform_adapter.gd
   ```

   The adapter should expose:

   - `provider_id()`;
   - `is_present()`;
   - provider accessors for native/plugin singletons;
   - `capabilities()`.

3. Register adapter priority.

   Update `PlatformRegistry._initialize()` so the new adapter is considered
   before `GenericOpenXRPlatformAdapter`. Preserve the pattern where absent
   vendor adapters still contribute unavailable capability info.

4. Add or update capabilities.

   Add ids in `SensorCapability` only when the rest of the app needs a stable
   concept. Add state transitions in `CapabilityState` only if existing states
   cannot represent the device behavior.

5. Add native or Android plugin packaging if needed.

   - Add Android plugin code under `xr/android_plugin/<brand-or-feature>/`.
   - Add Godot wrapper addon under `xr/addons/<brand-or-feature>/`.
   - Add GDExtension code under `xr/native/<brand-or-feature>/` only when
     native OpenXR/JNI/Vulkan access is required.
   - Add build rules to `xr/makefiles/Makefile.addons`.

6. Add an export preset and Makefile target.

   Update:

   - `xr/export_presets.cfg`;
   - `xr/Makefile` `.PHONY`;
   - `build-<brand>`;
   - `install-<brand>`;
   - `ship-<brand>` if the device supports `adb`.

   Use `custom_features="<brand>"` for build identity only. Runtime feature
   decisions still go through `PlatformRegistry`.

7. Add test fixtures and manifests.

   - Add fake capability fixtures under `xr/tests/fixtures/platform/`.
   - Add or extend integration tests under `xr/tests/integration/`.
   - Add device smoke under `xr/tests/device/<brand>/`.
   - Update `xr/tests/manifests/features/test_harness.json` when adding a new
     device smoke case.

8. Update shell device selection.

   If a top-level E2E script needs to detect the brand, update its
   manufacturer/model matching. Current examples are in:

   - `tests/02_ego_record.sh`;
   - `tests/03_godot_mujoco_device.sh`;
   - `tests/04_live_feed_e2e.sh`.

## Build Checklist

Run from repo root unless noted:

```bash
python3 tests/validate_xr_features.py
python3 tests/validate_xr_test_manifests.py
bash tests/03_godot_mujoco_static.sh
```

Build the APK family from `xr/`:

```bash
make build-quest
make build-pico
# or the new build-<brand> target
```

When native/plugin packaging changed, also run a clean build:

```bash
cd xr
make clean
make deps
make build-<brand>
```

## Device Test Checklist

Run on every target model in the brand family:

```bash
bash tests/xr_module_harness.sh --suite device.smoke --serial <serial> --skip-build --skip-install
bash tests/02_ego_record.sh --device quest
bash tests/04_live_feed_e2e.sh --device quest
```

For Pico, replace the device flag and APK build/install path accordingly.
For a new brand, add explicit script support before relying on `auto`.

Pull and compare capability snapshots from the module harness results. The
minimum acceptance criteria:

- OpenXR starts and reports pose/controller capabilities.
- Required mode capabilities match the exported feature set.
- Missing optional capabilities degrade cleanly.
- Capture, upload, live feed, or teleop paths that the preset exposes pass on
  the real device.
- Logs contain product/model identity and selected providers.

## Review Checklist

- App/core/UI code has no direct vendor singleton string checks.
- Capability differences are represented in `PlatformRegistry`.
- Build differences are represented in export presets and Makefile targets.
- Same-brand model differences do not create new presets without a packaging
  reason.
- Device smoke tests run on at least one old and one new model in the family.
- Docs list known unsupported or degraded capabilities.

## References

- [Meta Quest device comparison](https://developers.meta.com/horizon/resources/compare-devices/)
- [Start Building with Meta Quest 3 and 3S](https://developers.meta.com/horizon/blog/start-building-meta-quest-3s-3-launch-spatial-sdk-2D-mixed-reality/)
- [Godot XR deployment to Android](https://docs.godotengine.org/en/stable/tutorials/xr/deploying_to_android.html)
- [Android XR with Godot](https://developer.android.com/develop/xr/godot)
- [Meta OpenXR SDK](https://developers.meta.com/horizon/downloads/package/oculus-openxr-mobile-sdk/)
