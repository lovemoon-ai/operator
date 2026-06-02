.PHONY: log build build-quest build-pico build-glassxr build-ahb install install-pico install-glassxr run stop clean godot reverse ship-pico ship-pico-fast setup-vendors

# ADB=adb -s PB321XKGL4210070B
ADB=adb
GRADLE_USER_HOME?=$(CURDIR)/.gradle

apk=build/quest/Operator.apk
apk_pico=build/pico/Operator.apk
apk_glassxr=build/glassxr/Operator.apk
package=org.xrobotoolkit.client
activity=com.godot.game.GodotApp
TEMPLATE_ZIPS="$(HOME)/Library/Application Support/Godot/export_templates/4.5.1.stable/android_source.zip" "$(HOME)/.local/share/godot/export_templates/4.5.1.stable/android_source.zip"

log:
	$(ADB) logcat -c | $(ADB) logcat | grep -e "Operator" -e "godot" -e "OpenXR"

crash:
	$(ADB) logcat -d > crash.log

clean:
	cd android/build && ./gradlew clean
	rm -rf build

prepare-android-libs:
	@set -e; \
	LIB_DEBUG="android/build/libs/debug/godot-lib.template_debug.aar"; \
	LIB_RELEASE="android/build/libs/release/godot-lib.template_release.aar"; \
	if [ -f $$LIB_DEBUG ] && [ -f $$LIB_RELEASE ]; then exit 0; fi; \
	for ZIP in $(TEMPLATE_ZIPS); do \
		if [ -f "$$ZIP" ]; then TEMPLATE_ZIP="$$ZIP"; break; fi; \
	done; \
	if [ -z "$$TEMPLATE_ZIP" ]; then echo "Missing Android template zip (4.5.1.stable). Install export templates in Godot."; exit 1; fi; \
	echo "Extracting Godot Android template AARs from $$TEMPLATE_ZIP"; \
	mkdir -p android/build/libs/debug android/build/libs/release; \
	unzip -o "$$TEMPLATE_ZIP" "libs/debug/godot-lib.*.aar" -d android/build >/dev/null; \
	unzip -o "$$TEMPLATE_ZIP" "libs/release/godot-lib.*.aar" -d android/build >/dev/null

build-quest: setup-vendors prepare-android-libs build-ahb
	@mkdir -p $(dir $(apk)) $(GRADLE_USER_HOME)
	GRADLE_USER_HOME=$(GRADLE_USER_HOME) godot --headless --verbose --path . --export-release "Meta Quest" $(apk)

build-pico: setup-vendors prepare-android-libs build-ahb
	@mkdir -p $(dir $(apk_pico)) $(GRADLE_USER_HOME)
	GRADLE_USER_HOME=$(GRADLE_USER_HOME) godot --headless --verbose --path . --export-release "Pico" $(apk_pico)

# --- AHB decoder native lib --------------------------------------
# The Vulkan/AHardwareBuffer GDExtension is built by a standalone
# CMake script (native/ahb_decoder/build.sh). The Godot Android
# export only *copies* the resulting .so into the APK — it never
# rebuilds it. Trigger the script only when sources actually change.
#
# Behavior when sources changed:
#   - ANDROID_NDK set     → rebuild + install
#   - ANDROID_NDK unset,
#     .so already exists  → warn loudly, keep stale .so (no fail)
#   - ANDROID_NDK unset,
#     .so missing         → fail with a clear message
#
# The Makefile owns the JNI-side install path (libs/release/arm64-v8a)
# because that's what `release.jniLibs.srcDirs` in android/build.gradle
# actually reads. build.sh's own JNI_DST is stale — it lands in
# libs/arm64-v8a/, which nothing picks up. We copy from the addon .so
# so the path is correct regardless.
AHB_DIR := native/ahb_decoder
AHB_SRC := $(AHB_DIR)/CMakeLists.txt $(AHB_DIR)/build.sh $(shell find $(AHB_DIR)/src -type f 2>/dev/null)
AHB_ADDON_SO := addons/ahb_decoder/libahb_decoder.so
AHB_JNI_SO := android/build/libs/release/arm64-v8a/libahb_decoder.so

$(AHB_ADDON_SO): $(AHB_SRC)
	@if [ -z "$$ANDROID_NDK" ] && [ -z "$$ANDROID_NDK_HOME" ]; then \
	    if [ -f "$@" ]; then \
	        echo "[ahb] sources newer than $@ but ANDROID_NDK not set — keeping stale .so. 'export ANDROID_NDK=…' to rebuild."; \
	        exit 0; \
	    fi; \
	    echo "[ahb] ANDROID_NDK (or ANDROID_NDK_HOME) must be set to build $@" >&2; \
	    exit 1; \
	fi; \
	$(AHB_DIR)/build.sh Release

$(AHB_JNI_SO): $(AHB_ADDON_SO)
	@mkdir -p $(@D)
	@cp -f $< $@
	@echo "[ahb] installed $@"

build-ahb: $(AHB_ADDON_SO) $(AHB_JNI_SO)

build-glassxr: setup-vendors prepare-android-libs build-ahb
	@mkdir -p $(dir $(apk_glassxr)) $(GRADLE_USER_HOME)
	GRADLE_USER_HOME=$(GRADLE_USER_HOME) godot --headless --verbose --path . --export-release "Glass XR" $(apk_glassxr)

build: build-quest

install:
	$(ADB) install -r -d $(apk)

install-pico:
	$(ADB) install -r -d $(apk_pico)

install-glassxr:
	$(ADB) install -r -d $(apk_glassxr)

uninstall:
	$(ADB) uninstall $(package)

run:
	$(ADB) shell am start -n $(package)/$(activity)
	$(ADB) logcat -c | $(ADB) logcat | grep -e "Operator" -e "godot" -e "OpenXR"

stop:
	$(ADB) shell am force-stop $(package)

build-install: build install

build-install-pico: build-pico install-pico

# Set up adb reverse for the three robot ports so the Pico can reach a
# robo-agent running on the Mac via 127.0.0.1. Must be re-run whenever
# the adb daemon is restarted or the USB cable is re-plugged.
#   12345 = video TCP (H.264 NALs)
#   63901 = command/pose TCP (telemetry + commands + clock sync)
#   63900 = UDP discovery broadcast
reverse:
	$(ADB) reverse tcp:12345 tcp:12345
	$(ADB) reverse tcp:63901 tcp:63901
	$(ADB) reverse tcp:63900 tcp:63900
	@echo "--- adb reverse list ---"
	@$(ADB) reverse --list

ship-pico-fast:
	$(ADB) shell am force-stop $(package)
	$(ADB) logcat -c
	$(ADB) shell am start -n $(package)/$(activity)
	@sleep 1
	@PID=$$($(ADB) shell "pidof $(package)" | tr -d '\r'); \
	echo "--- tailing logcat for pid $$PID (Ctrl-C to stop) ---"; \
	$(ADB) logcat --pid=$$PID -v brief | \
		grep -E "godot|Operator|RobotView|TcpHandler|KotlinVideo|AhbVideo|OpenXR"

ship-pico: build-install-pico ship-pico-fast

godot:
	godot -e .

# --- Third-party vendored addons ---------------------------------
# Two third-party addons are pulled from upstream instead of being
# vendored into this repo:
#
#   addons/godot-xr-tools        — git submodule at third_party/...,
#                                  exposed here via a symlink.
#   addons/godotopenxrvendors    — prebuilt binaries fetched by
#                                  `prepare.sh` from a pinned GitHub
#                                  release of GodotVR/godot_openxr_vendors.
#
# Run this once after `git clone`, and again after a checkout that
# bumps either pinned version. Both steps are idempotent (fast no-op
# when already in sync).
#
# To upgrade godot-xr-tools: `cd ../third_party/godot-xr-tools &&
# git fetch --tags && git checkout <new-tag>` from the repo root,
# then commit the updated submodule SHA in the parent repo.
#
# To upgrade godotopenxrvendors: edit UPSTREAM_TAG in
# `addons/godotopenxrvendors/prepare.sh`, then re-run with --force.
setup-vendors:
	cd .. && git submodule update --init --recursive third_party/godot-xr-tools
	@test -L addons/godot-xr-tools || ln -sfn ../../third_party/godot-xr-tools/addons/godot-xr-tools addons/godot-xr-tools
	@echo "[setup-vendors] godot-xr-tools $$(cat addons/godot-xr-tools/plugin.cfg | awk -F'\"' '/^version/{print $$2}') ready"
	./addons/godotopenxrvendors/prepare.sh
