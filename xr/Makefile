# xr/Makefile — Godot project orchestration.
#
# Owns project-level concerns: export targets (build-{quest,pico,androidxr}),
# device install/run/stop/ship, top-level clean, and the editor entrypoint.
#
# Plugin/library build rules live in makefiles/Makefile.addons and are
# pulled in via `include` below. Anything that ships *inside* the APK as
# a Godot addon or native GDExtension belongs there.

.PHONY: verify-host-tools verify-ndk setup-vendors-patched log build-quest build-quest-teleop build-quest-test build-pico build-pico-teleop build-androidxr build-mujoco-quest build-mujoco-pico print-build-profile install-quest install-pico install-androidxr run run-live-feed run-live-capture run-teleop run-ego run-mujoco stop clean godot reverse ship-fast ship-quest ship-pico ship-pico-fast crash uninstall build-install-quest build-install-pico

ADB?=$(firstword $(wildcard $(HOME)/Library/Android/sdk/platform-tools/adb) $(wildcard $(HOME)/Android/Sdk/platform-tools/adb) adb)
ADB_BASE:=$(ADB)
QUEST_SERIAL?=
PICO_SERIAL?=
ADB_QUEST=$(if $(QUEST_SERIAL),$(ADB_BASE) -s $(QUEST_SERIAL),$(ADB_BASE))
ADB_PICO=$(if $(PICO_SERIAL),$(ADB_BASE) -s $(PICO_SERIAL),$(ADB_BASE))
GRADLE_USER_HOME?=$(HOME)/.gradle

# Build profile controls which product surface and native dependencies are
# included in this invocation. It selects *which export preset Godot runs* and
# which native dependencies Make builds first:
#
#   OPERATOR_BUILD_PROFILE=teleop make build-pico
#   make build-quest OPERATOR_BUILD_PROFILE=teleop
#
# `full` preserves the existing build exactly ("Meta Quest" / "Pico"). `teleop`
# runs the paired Teleop presets ("Meta Quest Teleop" / "Pico Teleop"), which
# keep both Outside and Inside Robot support (AHB video, MuJoCo, retargeting,
# Pico tracking) while dropping the capture-only FFmpeg/AAR/hand-capture stack
# and its resources. The presets are ordinary Godot presets: exporting one from
# the editor produces the same APK as the matching make target. Nothing here
# edits export_presets.cfg. validate_xr_features.py enforces that each Teleop
# preset stays identical to its base except for features, quick entry and the
# resource filter.
OPERATOR_BUILD_PROFILE ?= full
OPERATOR_BUILD_PROFILE := $(strip $(OPERATOR_BUILD_PROFILE))
OPERATOR_QUICK_ENTRY ?=
OPERATOR_QUICK_ENTRY := $(strip $(OPERATOR_QUICK_ENTRY))
VALID_OPERATOR_BUILD_PROFILES := full teleop
VALID_OPERATOR_QUICK_ENTRIES := launcher teleop ego_capture live_feed

ifeq ($(filter $(OPERATOR_BUILD_PROFILE),$(VALID_OPERATOR_BUILD_PROFILES)),)
$(error Unsupported OPERATOR_BUILD_PROFILE='$(OPERATOR_BUILD_PROFILE)'; expected one of: $(VALID_OPERATOR_BUILD_PROFILES))
endif
ifneq ($(OPERATOR_QUICK_ENTRY),)
ifeq ($(filter $(OPERATOR_QUICK_ENTRY),$(VALID_OPERATOR_QUICK_ENTRIES)),)
$(error Unsupported OPERATOR_QUICK_ENTRY='$(OPERATOR_QUICK_ENTRY)'; expected one of: $(VALID_OPERATOR_QUICK_ENTRIES))
endif
endif
ifeq ($(OPERATOR_BUILD_PROFILE),teleop)
ifneq ($(OPERATOR_QUICK_ENTRY),)
ifeq ($(filter $(OPERATOR_QUICK_ENTRY),launcher teleop),)
$(error OPERATOR_BUILD_PROFILE=teleop only supports OPERATOR_QUICK_ENTRY=launcher or teleop)
endif
endif
endif

export OPERATOR_BUILD_PROFILE
export OPERATOR_QUICK_ENTRY

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
ifeq ($(origin ANDROID_SDK_ROOT), undefined)
ANDROID_SDK_ROOT := $(if $(ANDROID_HOME),$(ANDROID_HOME),$(firstword $(wildcard $(HOME)/Library/Android/sdk) $(wildcard $(HOME)/Android/Sdk) $(HOME)/Library/Android/sdk))
endif
ANDROID_HOME ?= $(ANDROID_SDK_ROOT)
export ANDROID_SDK_ROOT
export ANDROID_HOME
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

# ---------------------------------------------------------------------------
# Host build tools — cmake/ninja come from the Android SDK by default
# ---------------------------------------------------------------------------
# The build is not self-contained. `deps` clones two upstream wrapper repos
# (mujoco-android, pinocchio-android) whose scripts run `cmake -S ... -G Ninja`
# against a bare `cmake` from PATH. Nothing installs ninja, and CMake only
# reports it deep inside a configure that has already fetched sources:
#     CMake Error: CMake was unable to find a build program corresponding to
#     Ninja. CMAKE_MAKE_PROGRAM is not set.
# That failure is normally masked — the MuJoCo build is skipped whenever
# libmujoco.so already exists, so a host missing ninja looks healthy until
# something forces a rebuild (fresh checkout, cleaned tree, or a changed
# OPERATOR_DEPS_CACHE_ROOT, which orphans the old build products).
#
# So fix the toolchain, not the symptom — but only for ninja. The Android SDK's
# CMake package ships cmake and ninja together, and ninja is the half worth
# adopting: it is a pure build executor, version-insensitive, and always present
# once the SDK CMake package is installed.
#
# Its cmake is NOT adopted, and must not shadow the host's. With NDK 28's
# toolchain file, cmake 3.22.1 fails to populate CMAKE_ANDROID_NDK_VERSION, and
# CMake's own Modules/Compiler/Clang.cmake then takes this branch:
#
#     if(ANDROID AND NOT CMAKE_ANDROID_NDK_VERSION VERSION_GREATER_EQUAL "22")
#       set(CMAKE_${lang}_LINK_OPTIONS_IPO "-fuse-ld=gold")   # ndk issue #242
#
# — an empty version compares as "not >= 22", so a workaround meant for NDK < 22
# fires on NDK 28. MuJoCo enables IPO, so -fuse-ld=gold lands on the link line
# after MuJoCo's own -fuse-ld=lld and wins, and the host x86_64 /usr/bin/ld.gold
# then dies on aarch64 objects:
#     ld.gold: fatal error: crtbegin_so.o: unsupported ELF machine number 183
# Measured with identical sources, NDK and build tree, varying only cmake:
#     3.22.1 -> CMAKE_ANDROID_NDK_VERSION=''      IPO link opts=-fuse-ld=gold  FAILS
#     3.26.0 -> CMAKE_ANDROID_NDK_VERSION='28.1'  IPO link opts=(empty)        links
#     3.31.8 -> CMAKE_ANDROID_NDK_VERSION='28.1'  IPO link opts=(empty)        links
# This is NOT the -fuse-ld=lld probe in MujocoLinkOptions.cmake: SUPPORTS_LLD is
# 1 under all three. cmake_minimum_required(VERSION 3.22) in the CMakeLists here
# is therefore necessary but not sufficient. 3.26.0 is the oldest version
# actually proven on this tree; 3.23..3.25 were never tested, so the floor below
# is set to what was measured rather than to a guess.
#
# ninja is exposed through a shim directory holding only a symlink, so adding it
# to PATH cannot drag the SDK's cmake along with it. Override the SDK package
# with ANDROID_CMAKE_VERSION=x.y.z; if none is installed we fall back to
# whatever ninja is already on PATH. verify-host-tools reports which won.
ANDROID_CMAKE_VERSION ?= 3.22.1
ANDROID_SDK_NINJA := $(firstword $(wildcard $(ANDROID_SDK_ROOT)/cmake/$(ANDROID_CMAKE_VERSION)/bin/ninja) $(wildcard $(ANDROID_SDK_ROOT)/cmake/*/bin/ninja))
HOST_TOOL_DIR := $(abspath build/hosttools)
ifneq ($(ANDROID_SDK_NINJA),)
export PATH := $(HOST_TOOL_DIR):$(PATH)
endif

OPERATOR_BUILD_TOOLS ?= $(HOME)/.local/opt/operator-build-tools
REQUIRED_CMAKE_VERSION := 3.26
EXPECTED_GODOT_VERSION := 4.5.1

verify-host-tools:
	@if [ -n "$(ANDROID_SDK_NINJA)" ]; then \
	    mkdir -p "$(HOST_TOOL_DIR)"; \
	    ln -sf "$(ANDROID_SDK_NINJA)" "$(HOST_TOOL_DIR)/ninja"; \
	fi
	@missing=""; \
	for t in cmake ninja godot; do \
	    command -v $$t >/dev/null 2>&1 || missing="$$missing $$t"; \
	done; \
	if [ -n "$$missing" ]; then \
	    echo "[host] missing required build tool(s):$$missing" >&2; \
	    echo "[host] ninja ships with the Android SDK CMake package:" >&2; \
	    echo "[host]   sdkmanager \"cmake;$(ANDROID_CMAKE_VERSION)\"" >&2; \
	    echo "[host] or install on the host:  sudo apt install ninja-build" >&2; \
	    echo "[host] or source the toolchain: $(OPERATOR_BUILD_TOOLS)/env.sh" >&2; \
	    echo "[host] NOTE: do not put the SDK's cmake on PATH — 3.22.1 misreads the" >&2; \
	    echo "[host]       NDK version and forces MuJoCo onto host ld.gold. Needs >= $(REQUIRED_CMAKE_VERSION)." >&2; \
	    exit 1; \
	fi; \
	cmake_v=$$(cmake --version 2>/dev/null | head -1 | awk '{print $$3}'); \
	if [ "$$(printf '%s\n%s\n' "$(REQUIRED_CMAKE_VERSION)" "$$cmake_v" | sort -V | head -1)" != "$(REQUIRED_CMAKE_VERSION)" ]; then \
	    echo "[host] cmake $$cmake_v ($$(command -v cmake)) is older than the required $(REQUIRED_CMAKE_VERSION)" >&2; \
	    echo "[host] older cmake misreads CMAKE_ANDROID_NDK_VERSION and links MuJoCo with host ld.gold." >&2; \
	    exit 1; \
	fi; \
	godot_v=$$(godot --version 2>/dev/null | head -1); \
	case "$$godot_v" in \
	    $(EXPECTED_GODOT_VERSION).stable*) ;; \
	    *) echo "[host] WARNING: godot '$$godot_v' is not $(EXPECTED_GODOT_VERSION).stable — export templates may not match" >&2 ;; \
	esac; \
	echo "[host] cmake $$cmake_v ($$(command -v cmake))"; \
	echo "[host] ninja $$(ninja --version) ($$(readlink -f "$$(command -v ninja)"))"; \
	echo "[host] godot $$godot_v"

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
	echo "[build-profile] profile=$(OPERATOR_BUILD_PROFILE) quick_entry=$(if $(OPERATOR_QUICK_ENTRY),$(OPERATOR_QUICK_ENTRY),preset) preset=$(2)"; \
	tmp_manifest=$$(mktemp); \
	cp $(release_manifest) $$tmp_manifest; \
	restore_release_manifest() { \
		status=$$?; \
		trap - EXIT INT TERM; \
		cp $$tmp_manifest $(release_manifest); \
		rm -f $$tmp_manifest; \
		exit $$status; \
	}; \
	trap restore_release_manifest EXIT INT TERM; \
	set +e; \
	$(1) godot --headless --verbose --path . --export-release "$(2)" $(3)
endef

FULL_QUEST_BUILD_DEPS := verify-host-tools deps verify-ndk setup-vendors-patched prepare-android-libs build-ahb build-hand-capture build-godot-mujoco clean-pico-openxr-loader-stage prepare-capture-plugins build-retargeting verify-retargeting-lib
FULL_PICO_BUILD_DEPS := verify-host-tools verify-ndk setup-vendors prepare-android-libs build-ahb build-hand-capture build-godot-mujoco build-pico-openxr prepare-capture-plugins build-retargeting verify-retargeting-lib
TELEOP_QUEST_BUILD_DEPS := verify-host-tools deps-teleop verify-ndk setup-vendors prepare-android-libs build-ahb build-godot-mujoco clean-pico-openxr-loader-stage build-retargeting verify-retargeting-lib
TELEOP_PICO_BUILD_DEPS := verify-host-tools deps-teleop verify-ndk setup-vendors prepare-android-libs build-ahb build-godot-mujoco build-pico-openxr build-retargeting verify-retargeting-lib

FULL_QUEST_EXPORT_PRESET := Meta Quest
FULL_PICO_EXPORT_PRESET := Pico
TELEOP_QUEST_EXPORT_PRESET := Meta Quest Teleop
TELEOP_PICO_EXPORT_PRESET := Pico Teleop

ifeq ($(OPERATOR_BUILD_PROFILE),teleop)
QUEST_BUILD_DEPS := $(TELEOP_QUEST_BUILD_DEPS)
PICO_BUILD_DEPS := $(TELEOP_PICO_BUILD_DEPS)
QUEST_EXPORT_PRESET := $(TELEOP_QUEST_EXPORT_PRESET)
PICO_EXPORT_PRESET := $(TELEOP_PICO_EXPORT_PRESET)
PROFILE_CAPTURE_STACK := disabled
else
QUEST_BUILD_DEPS := $(FULL_QUEST_BUILD_DEPS)
PICO_BUILD_DEPS := $(FULL_PICO_BUILD_DEPS)
QUEST_EXPORT_PRESET := $(FULL_QUEST_EXPORT_PRESET)
PICO_EXPORT_PRESET := $(FULL_PICO_EXPORT_PRESET)
PROFILE_CAPTURE_STACK := enabled
endif

# Plugin/library build rules (setup-vendors, prepare-android-libs, build-ahb,
# build-capture-plugins, prepare-capture-plugins, clean-addons).
include makefiles/Makefile.addons

# ---------------------------------------------------------------------------
# Godot export targets
# ---------------------------------------------------------------------------

build-quest: $(QUEST_BUILD_DEPS)
	@mkdir -p $(dir $(apk_quest)) $(GRADLE_USER_HOME)
	$(call godot_export_release,GRADLE_USER_HOME=$(GRADLE_USER_HOME),$(QUEST_EXPORT_PRESET),$(apk_quest))
	./addons/godotopenxrvendors/prepare.sh --check-apk $(apk_quest)

build-quest-teleop:
	$(MAKE) build-quest OPERATOR_BUILD_PROFILE=teleop OPERATOR_QUICK_ENTRY=teleop

# Test-harness APK (export preset "Meta Quest Test"):
# operator_feature_test_harness=true, includes res://tests/** and
# res://scripts/test_support/**. Consumed by tests/xr_module_harness.sh.
# `override` is required, not stylistic: a plain target-specific assignment
# loses to a command-line OPERATOR_BUILD_PROFILE=teleop, which would silently
# strip the harness out of the test APK.
build-quest-test: override OPERATOR_BUILD_PROFILE := full
build-quest-test: override OPERATOR_QUICK_ENTRY := launcher
build-quest-test: $(FULL_QUEST_BUILD_DEPS)
	@mkdir -p $(dir $(apk_quest_test)) $(GRADLE_USER_HOME)
	$(call godot_export_release,GRADLE_USER_HOME=$(GRADLE_USER_HOME),Meta Quest Test,$(apk_quest_test))
	./addons/godotopenxrvendors/prepare.sh --check-apk $(apk_quest_test)

build-pico: $(PICO_BUILD_DEPS)
	@mkdir -p $(dir $(apk_pico)) $(GRADLE_USER_HOME)
	$(call godot_export_release,PICO_OPENXR_LOADER_ENABLED=1 GRADLE_USER_HOME=$(GRADLE_USER_HOME),$(PICO_EXPORT_PRESET),$(apk_pico))

build-pico-teleop:
	$(MAKE) build-pico OPERATOR_QUICK_ENTRY=teleop OPERATOR_BUILD_PROFILE=teleop

print-build-profile:
	@echo "OPERATOR_BUILD_PROFILE=$(OPERATOR_BUILD_PROFILE)"
	@echo "OPERATOR_QUICK_ENTRY=$(if $(OPERATOR_QUICK_ENTRY),$(OPERATOR_QUICK_ENTRY),(preset default))"
	@echo "QUEST_EXPORT_PRESET=$(QUEST_EXPORT_PRESET)"
	@echo "PICO_EXPORT_PRESET=$(PICO_EXPORT_PRESET)"
	@echo "CAPTURE_STACK=$(PROFILE_CAPTURE_STACK)"
	@echo "QUEST_BUILD_DEPS=$(QUEST_BUILD_DEPS)"
	@echo "PICO_BUILD_DEPS=$(PICO_BUILD_DEPS)"

# build-androidxr: setup-vendors prepare-android-libs build-ahb build-hand-capture clean-pico-openxr-loader-stage prepare-capture-plugins
# 	@mkdir -p $(dir $(apk_androidxr)) $(GRADLE_USER_HOME)
# 	$(call godot_export_release,GRADLE_USER_HOME=$(GRADLE_USER_HOME),Glass XR,$(apk_androidxr))

# Full-stack MuJoCo bring-up targets. They always build and export the full
# presets, so they pin the profile rather than inheriting a teleop invocation.
build-mujoco-quest: override OPERATOR_BUILD_PROFILE := full
build-mujoco-quest: verify-host-tools deps verify-ndk setup-vendors-patched prepare-android-libs build-ahb build-hand-capture build-godot-mujoco clean-pico-openxr-loader-stage
	@mkdir -p $(dir $(apk_quest)) $(GRADLE_USER_HOME)
	$(call godot_export_release,GRADLE_USER_HOME=$(GRADLE_USER_HOME),$(FULL_QUEST_EXPORT_PRESET),$(apk_quest))
	./addons/godotopenxrvendors/prepare.sh --check-apk $(apk_quest)

build-mujoco-pico: override OPERATOR_BUILD_PROFILE := full
build-mujoco-pico: verify-host-tools verify-ndk setup-vendors prepare-android-libs build-ahb build-hand-capture build-godot-mujoco build-pico-openxr
	@mkdir -p $(dir $(apk_pico)) $(GRADLE_USER_HOME)
	$(call godot_export_release,PICO_OPENXR_LOADER_ENABLED=1 GRADLE_USER_HOME=$(GRADLE_USER_HOME),$(FULL_PICO_EXPORT_PRESET),$(apk_pico))

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
	$(ADB) install --no-incremental -r -d $(apk_quest)

install-pico:
	$(ADB) install --no-incremental -r -d $(apk_pico)

install-androidxr:
	$(ADB) install --no-incremental -r -d $(apk_androidxr)

uninstall:
	$(ADB) uninstall $(package)

run:
	$(ADB) shell am start -n $(package)/$(activity) $(mode_extra)
	$(ADB) logcat -c | $(ADB) logcat | grep -e "Operator" -e "godot" -e "OpenXR"

run-live-feed:
	$(ADB) shell am start -n $(package)/$(activity) --es operator.mode live_feed
	$(ADB) logcat -c | $(ADB) logcat | grep -e "Operator" -e "godot" -e "OpenXR"

run-live-capture: run-live-feed

# There is deliberately no run-vr target. `operator_feature_mode_vr` has never
# been true in any preset, so the launcher refuses the `vr` route and the intent
# could only ever fail. Enabling that one option in a preset is the whole
# switch: it restores the launcher card, the `operator.mode vr` intent, and the
# scene is already packed in the full presets. Add the target back then.

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
