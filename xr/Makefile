# xr/Makefile — Godot project orchestration.
#
# Owns project-level concerns: export targets (build-{quest,pico,androidxr}),
# device install/run/stop/ship, top-level clean, and the editor entrypoint.
#
# Plugin/library build rules live in makefiles/Makefile.addons and are
# pulled in via `include` below. Anything that ships *inside* the APK as
# a Godot addon or native GDExtension belongs there.

.PHONY: verify-ndk log build-quest build-quest-test build-pico build-androidxr build-mujoco-quest build-mujoco-pico install-quest install-pico install-androidxr run run-live-feed run-live-capture run-vr run-teleop run-ego run-mujoco stop clean godot reverse ship-fast ship-quest ship-pico ship-pico-fast crash uninstall build-install-quest build-install-pico

ADB?=adb
ADB_BASE:=$(ADB)
QUEST_SERIAL?=
PICO_SERIAL?=
ADB_QUEST=$(if $(QUEST_SERIAL),$(ADB_BASE) -s $(QUEST_SERIAL),$(ADB_BASE))
ADB_PICO=$(if $(PICO_SERIAL),$(ADB_BASE) -s $(PICO_SERIAL),$(ADB_BASE))
GRADLE_USER_HOME?=$(HOME)/.gradle

# ---------------------------------------------------------------------------
# Pinned Android NDK — single source of truth: android/build/config.gradle
# ---------------------------------------------------------------------------
# gradle's `ndkVersion` only governs AGP itself. Every native sub-build
# (mujoco, retargeting, ahb, hand_capture, pico, pinocchio, ffmpeg) instead
# reads the NDK from $ANDROID_NDK*, so a stray host NDK silently compiles the
# GDExtensions against the wrong toolchain — which is how the APK ended up with
# empty/incompatible libgodot_retargeting.so. Force every recipe onto the same
# gradle-pinned NDK and fail loudly if it is not installed.
# Prefer an explicit ANDROID_SDK_ROOT/ANDROID_HOME from the env, else fall back
# to the first SDK dir that actually exists (macOS then Linux default).
ANDROID_SDK_ROOT ?= $(firstword $(ANDROID_HOME) $(wildcard $(HOME)/Library/Android/sdk) $(wildcard $(HOME)/Android/Sdk) $(HOME)/Library/Android/sdk)
NDK_VERSION := $(shell sed -n "s/.*ndkVersion[^']*'\([^']*\)'.*/\1/p" android/build/config.gradle)
PINNED_ANDROID_NDK := $(ANDROID_SDK_ROOT)/ndk/$(NDK_VERSION)
export ANDROID_NDK := $(PINNED_ANDROID_NDK)
export ANDROID_NDK_HOME := $(PINNED_ANDROID_NDK)
export ANDROID_NDK_ROOT := $(PINNED_ANDROID_NDK)

verify-ndk:
	@if [ -z "$(NDK_VERSION)" ]; then \
		echo "[ndk] could not parse ndkVersion from android/build/config.gradle" >&2; exit 1; fi
	@if [ ! -d "$(PINNED_ANDROID_NDK)" ]; then \
		echo "[ndk] required NDK $(NDK_VERSION) not found at $(PINNED_ANDROID_NDK)" >&2; \
		echo "[ndk] install it: sdkmanager \"ndk;$(NDK_VERSION)\"  (or set ANDROID_SDK_ROOT/ANDROID_HOME)" >&2; \
		exit 1; fi
	@echo "[ndk] using pinned NDK $(NDK_VERSION) at $(PINNED_ANDROID_NDK)"

apk_quest=build/quest/Operator.apk
apk_quest_test=build/quest_test/Operator.apk
apk_pico=build/pico/Operator.apk
apk_androidxr=build/androidxr/Operator.apk
package=com.lovemoon.operator
activity=com.godot.game.GodotApp
mode_extra=$(if $(MODE),--es operator.mode $(MODE),)
release_manifest=android/build/src/release/AndroidManifest.xml

define godot_export_release
	@set -e; \
	tmp_manifest=$$(mktemp); \
	cp $(release_manifest) $$tmp_manifest; \
	restore_manifest() { \
		status=$$?; \
		trap - EXIT INT TERM; \
		cp $$tmp_manifest $(release_manifest); \
		rm -f $$tmp_manifest; \
		exit $$status; \
	}; \
	trap restore_manifest EXIT INT TERM; \
	set +e; \
	$(1) godot --headless --verbose --path . --export-release "$(2)" $(3)
endef

# Plugin/library build rules (setup-vendors, prepare-android-libs, build-ahb,
# build-capture-plugins, prepare-capture-plugins, clean-addons).
include makefiles/Makefile.addons

# ---------------------------------------------------------------------------
# Godot export targets
# ---------------------------------------------------------------------------

build-quest: verify-ndk setup-vendors prepare-android-libs build-ahb build-hand-capture build-godot-mujoco clean-pico-openxr-loader-stage prepare-capture-plugins build-retargeting verify-retargeting-lib
	@mkdir -p $(dir $(apk_quest)) $(GRADLE_USER_HOME)
	$(call godot_export_release,GRADLE_USER_HOME=$(GRADLE_USER_HOME),Meta Quest,$(apk_quest))

# Test-harness APK (export preset "Meta Quest Test"):
# operator_feature_test_harness=true, includes res://tests/** and
# res://scripts/test_support/**. Consumed by tests/xr_module_harness.sh.
build-quest-test: verify-ndk setup-vendors prepare-android-libs build-ahb build-hand-capture build-godot-mujoco clean-pico-openxr-loader-stage prepare-capture-plugins build-retargeting verify-retargeting-lib
	@mkdir -p $(dir $(apk_quest_test)) $(GRADLE_USER_HOME)
	$(call godot_export_release,GRADLE_USER_HOME=$(GRADLE_USER_HOME),Meta Quest Test,$(apk_quest_test))

build-pico: verify-ndk setup-vendors prepare-android-libs build-ahb build-hand-capture build-godot-mujoco build-pico-openxr prepare-capture-plugins build-retargeting verify-retargeting-lib
	@mkdir -p $(dir $(apk_pico)) $(GRADLE_USER_HOME)
	$(call godot_export_release,PICO_OPENXR_LOADER_ENABLED=1 GRADLE_USER_HOME=$(GRADLE_USER_HOME),Pico,$(apk_pico))

# build-androidxr: setup-vendors prepare-android-libs build-ahb build-hand-capture clean-pico-openxr-loader-stage prepare-capture-plugins
# 	@mkdir -p $(dir $(apk_androidxr)) $(GRADLE_USER_HOME)
# 	$(call godot_export_release,GRADLE_USER_HOME=$(GRADLE_USER_HOME),Glass XR,$(apk_androidxr))

build-mujoco-quest: verify-ndk setup-vendors prepare-android-libs build-ahb build-hand-capture build-godot-mujoco clean-pico-openxr-loader-stage
	@mkdir -p $(dir $(apk_quest)) $(GRADLE_USER_HOME)
	$(call godot_export_release,GRADLE_USER_HOME=$(GRADLE_USER_HOME),Meta Quest,$(apk_quest))

build-mujoco-pico: verify-ndk setup-vendors prepare-android-libs build-ahb build-hand-capture build-godot-mujoco build-pico-openxr
	@mkdir -p $(dir $(apk_pico)) $(GRADLE_USER_HOME)
	$(call godot_export_release,PICO_OPENXR_LOADER_ENABLED=1 GRADLE_USER_HOME=$(GRADLE_USER_HOME),Pico,$(apk_pico))

# ---------------------------------------------------------------------------
# Device install / run / ship
# ---------------------------------------------------------------------------

install-quest build-install-quest ship-quest: ADB=$(ADB_QUEST)
install-pico build-install-pico ship-pico ship-pico-fast: ADB=$(ADB_PICO)

# --no-incremental is required, not cosmetic: this APK ships its native
# libraries uncompressed (extractNativeLibs=false) so they mmap straight from
# the APK. adb's default incremental/streaming install can leave those Stored
# libs at a stale offset on reinstall over the same versionCode, and the loader
# then reads a ZIP header instead of ELF ("bad ELF magic: 504b0304"). MuJoCo
# fails to load and every simulated robot breaks. A full push avoids it without
# wiping app data.
install-quest:
	$(ADB) install -r -d --no-incremental $(apk_quest)

install-pico:
	$(ADB) install -r -d --no-incremental $(apk_pico)

install-androidxr:
	$(ADB) install -r -d --no-incremental $(apk_androidxr)

uninstall:
	$(ADB) uninstall $(package)

run:
	$(ADB) shell am start -n $(package)/$(activity) $(mode_extra)
	$(ADB) logcat -c | $(ADB) logcat | grep -e "Operator" -e "godot" -e "OpenXR"

run-live-feed:
	$(ADB) shell am start -n $(package)/$(activity) --es operator.mode live_feed
	$(ADB) logcat -c | $(ADB) logcat | grep -e "Operator" -e "godot" -e "OpenXR"

run-live-capture: run-live-feed

run-vr:
	$(ADB) shell am start -n $(package)/$(activity) --es operator.mode vr
	$(ADB) logcat -c | $(ADB) logcat | grep -e "Operator" -e "godot" -e "OpenXR"

run-teleop:
	$(ADB) shell am start -n $(package)/$(activity) --es operator.mode teleop
	$(ADB) logcat -c | $(ADB) logcat | grep -e "Operator" -e "godot" -e "OpenXR"

run-ego:
	$(ADB) shell am start -n $(package)/$(activity) --es operator.mode ego
	$(ADB) logcat -c | $(ADB) logcat | grep -e "Operator" -e "godot" -e "OpenXR"

run-mujoco:
	$(ADB) shell am start -n $(package)/$(activity) --es operator.mode mujoco
	$(ADB) logcat -c | $(ADB) logcat | grep -e "Operator" -e "GodotMuJoCo" -e "godot" -e "OpenXR"

stop:
	$(ADB) shell am force-stop $(package)

build-install-quest: build-quest install-quest

build-install-pico: build-pico install-pico

ship-fast:
	$(ADB) shell am force-stop $(package)
	$(ADB) logcat -c
	$(ADB) shell am start -n $(package)/$(activity) $(mode_extra)
	@sleep 1
	@PID=$$($(ADB) shell "pidof $(package)" | tr -d '\r'); \
	echo "--- tailing logcat for pid $$PID (Ctrl-C to stop) ---"; \
	$(ADB) logcat --pid=$$PID -v brief | \
		grep -E "godot|Operator|RobotView|TcpHandler|KotlinVideo|AhbVideo|OpenXR"

ship-pico: build-install-pico ship-fast

ship-quest: build-install-quest ship-fast

# ---------------------------------------------------------------------------
# Editor / logcat / crash dump
# ---------------------------------------------------------------------------

godot:
	godot -e .

log:
	$(ADB) logcat -c | $(ADB) logcat | grep -e "Operator" -e "godot"

log2:
	# $(ADB) logcat -c | $(ADB) logcat | grep -e "OpenXR"

log3:
	$(ADB) logcat -c | $(ADB) logcat | grep -e "QRScannerPlugin"

log999:
	$(ADB) logcat -c && $(ADB) logcat 2>&1 | tee android.log

crash:
	$(ADB) logcat -d > crash.log

# ---------------------------------------------------------------------------
# Top-level clean
# ---------------------------------------------------------------------------
# Chains through to clean-addons (defined in makefiles/Makefile.addons) for
# every addon/plugin artifact; here we only touch project-level outputs.
clean: clean-addons
	@if [ -x android/build/gradlew ]; then \
		cd android/build && ./gradlew clean; \
	fi
	rm -rf \
		.godot \
		.gradle \
		build \
		android/build/.gradle \
		android/build/.kotlin \
		android/build/.cxx \
		android/build/assets \
		android/build/build \
		android/build/intermediates \
		android/build/libs \
		android/build/outputs
	find . -name '*.import' -type f -delete
