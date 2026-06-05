# xr/Makefile — Godot project orchestration.
#
# Owns project-level concerns: export targets (build-{quest,pico,androidxr}),
# device install/run/stop/ship, top-level clean, and the editor entrypoint.
#
# Plugin/library build rules live in makefiles/Makefile.addons and are
# pulled in via `include` below. Anything that ships *inside* the APK as
# a Godot addon or native GDExtension belongs there.

.PHONY: log build-quest build-pico build-androidxr install-quest install-pico install-androidxr run run-teleop run-ego stop clean godot reverse ship-pico ship-pico-fast crash uninstall build-install-quest build-install-pico

# ADB=adb -s PB321XKGL4210070B
ADB=adb
GRADLE_USER_HOME?=$(HOME)/.gradle

apk_quest=build/quest/Operator.apk
apk_pico=build/pico/Operator.apk
apk_androidxr=build/androidxr/Operator.apk
package=com.lovemoon.operator
activity=com.godot.game.GodotApp
mode_extra=$(if $(MODE),--es operator.mode $(MODE),)
release_manifest=android/build/src/release/AndroidManifest.xml

define godot_export_release
	@tmp_manifest=$$(mktemp); \
	cp $(release_manifest) $$tmp_manifest; \
	set +e; \
	$(1) godot --headless --verbose --path . --export-release "$(2)" $(3); \
	status=$$?; \
	cp $$tmp_manifest $(release_manifest); \
	rm -f $$tmp_manifest; \
	exit $$status
endef

# Plugin/library build rules (setup-vendors, prepare-android-libs, build-ahb,
# build-capture-plugins, prepare-capture-plugins, clean-addons).
include makefiles/Makefile.addons

# ---------------------------------------------------------------------------
# Godot export targets
# ---------------------------------------------------------------------------

build-quest: setup-vendors prepare-android-libs build-ahb clean-pico-openxr-loader-stage prepare-capture-plugins
	@mkdir -p $(dir $(apk_quest)) $(GRADLE_USER_HOME)
	$(call godot_export_release,GRADLE_USER_HOME=$(GRADLE_USER_HOME),Meta Quest,$(apk_quest))

build-pico: setup-vendors prepare-android-libs build-ahb build-pico-openxr prepare-capture-plugins
	@mkdir -p $(dir $(apk_pico)) $(GRADLE_USER_HOME)
	$(call godot_export_release,PICO_OPENXR_LOADER_ENABLED=1 GRADLE_USER_HOME=$(GRADLE_USER_HOME),Pico,$(apk_pico))

build-androidxr: setup-vendors prepare-android-libs build-ahb clean-pico-openxr-loader-stage prepare-capture-plugins
	@mkdir -p $(dir $(apk_androidxr)) $(GRADLE_USER_HOME)
	$(call godot_export_release,GRADLE_USER_HOME=$(GRADLE_USER_HOME),Glass XR,$(apk_androidxr))

# ---------------------------------------------------------------------------
# Device install / run / ship
# ---------------------------------------------------------------------------

install-quest:
	$(ADB) install -r -d $(apk_quest)

install-pico:
	$(ADB) install -r -d $(apk_pico)

install-androidxr:
	$(ADB) install -r -d $(apk_androidxr)

uninstall:
	$(ADB) uninstall $(package)

run:
	$(ADB) shell am start -n $(package)/$(activity) $(mode_extra)
	$(ADB) logcat -c | $(ADB) logcat | grep -e "Operator" -e "godot" -e "OpenXR"

run-teleop:
	$(ADB) shell am start -n $(package)/$(activity) --es operator.mode teleop
	$(ADB) logcat -c | $(ADB) logcat | grep -e "Operator" -e "godot" -e "OpenXR"

run-ego:
	$(ADB) shell am start -n $(package)/$(activity) --es operator.mode ego
	$(ADB) logcat -c | $(ADB) logcat | grep -e "Operator" -e "godot" -e "OpenXR"

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
	$(ADB) logcat -c | $(ADB) logcat | grep -e "OpenXR"

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
