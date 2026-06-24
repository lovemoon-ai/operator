
SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

UV ?= uv
RERUN_PYTHON_VERSION ?= 3.13
RERUN_SDK_VERSION ?= 0.33.*
RERUN_WEB_PORT ?= 9090
RERUN_BIND ?= 127.0.0.1
RERUN_SETUP_SPATIALMP4 ?= auto
RERUN_ALLOW_PORT_IN_USE ?= 0
RERUN_RENDERER ?= webgl
OPERATOR_DEPS_CACHE_ROOT ?= $(abspath ../.deps)
SPATIALMP4_HOME ?= $(OPERATOR_DEPS_CACHE_ROOT)/src/SpatialMP4
SPATIALMP4_REVISION_STAMP ?= $(OPERATOR_DEPS_CACHE_ROOT)/build/spatialmp4/.source-revision
# Single converter; the device profile (quest/pico) is auto-detected from the
# mp4's embedded operator_static `provider`, falling back to the manifest's
# device.device_type, then quest. Force one with DEVICE=pico / --device-type.
# The old spatialmp4_to_rrd_pico.py wrapper hard-forced --device-type pico,
# which mis-projected quest captures (skipped the Quest-only Camera2 overlay).
RERUN_SCRIPT ?= app/scripts/spatialmp4_to_rrd.py

RRD ?= $(basename $(MP4)).rrd

export OPERATOR_DEPS_CACHE_ROOT
export RERUN_PYTHON_VERSION
export SPATIALMP4_HOME
export RERUN_SCRIPT

.PHONY: run-dev vis-rerun spatialmp4-deps

run-dev:
	PORT=3001 npm run dev

spatialmp4-deps:
	../scripts/setup_spatialmp4.sh

vis-rerun:
ifndef MP4
	$(error Usage: make vis-rerun MP4=../tmp_data/20260608_123420.mp4 [RRD=out.rrd] [FORCE=1])
endif
	@mp4="$(MP4)"; \
	rrd="$(RRD)"; \
	if [ ! -f "$$mp4" ]; then \
		echo "MP4 not found: $$mp4" >&2; \
		exit 2; \
	fi; \
	spatialmp4_so="$$(find "$(SPATIALMP4_HOME)" "$(OPERATOR_DEPS_CACHE_ROOT)/build/spatialmp4" -path '*/python/spatialmp4.cpython-*.so' -type f -print -quit 2>/dev/null || true)"; \
	spatialmp4_wanted_rev="$$(sed -n 's/^SPATIALMP4_COMMIT="\([^"]*\)".*/\1/p' ../scripts/sync_deps.sh | head -1)"; \
	spatialmp4_current_rev="$$(git -C "$(SPATIALMP4_HOME)" rev-parse HEAD 2>/dev/null || true)"; \
	spatialmp4_built_rev="$$(cat "$(SPATIALMP4_REVISION_STAMP)" 2>/dev/null || true)"; \
	spatialmp4_setup_reason=""; \
	if [ "$(RERUN_SETUP_SPATIALMP4)" != "0" ]; then \
		if [ -z "$$spatialmp4_so" ]; then \
			spatialmp4_setup_reason="SpatialMP4 Python extension not found"; \
		elif [ -n "$$spatialmp4_wanted_rev" ] && [ "$$spatialmp4_current_rev" != "$$spatialmp4_wanted_rev" ]; then \
			spatialmp4_setup_reason="SpatialMP4 source revision is $${spatialmp4_current_rev:-missing}, expected $$spatialmp4_wanted_rev"; \
		elif [ -n "$$spatialmp4_wanted_rev" ] && [ "$$spatialmp4_built_rev" != "$$spatialmp4_wanted_rev" ]; then \
			spatialmp4_setup_reason="SpatialMP4 Python extension was built from $${spatialmp4_built_rev:-unknown}, expected $$spatialmp4_wanted_rev"; \
		fi; \
	fi; \
	if [ -n "$$spatialmp4_setup_reason" ]; then \
		echo "$$spatialmp4_setup_reason; running ../scripts/setup_spatialmp4.sh"; \
		../scripts/setup_spatialmp4.sh; \
		spatialmp4_so="$$(find "$(SPATIALMP4_HOME)" "$(OPERATOR_DEPS_CACHE_ROOT)/build/spatialmp4" -path '*/python/spatialmp4.cpython-*.so' -type f -print -quit 2>/dev/null || true)"; \
	fi; \
	mkdir -p "$$(dirname "$$rrd")"; \
	manifest=""; \
	if [ -n "$${MANIFEST:-}" ]; then \
		manifest="$$MANIFEST"; \
	elif [ -f "$${mp4%.*}/manifest.json" ]; then \
		manifest="$${mp4%.*}/manifest.json"; \
	elif [ -f "$$(dirname "$$mp4")/manifest.json" ]; then \
		manifest="$$(dirname "$$mp4")/manifest.json"; \
	fi; \
	manifest_args=(); \
	if [ -n "$$manifest" ]; then \
		manifest_args=(--manifest "$$manifest"); \
		echo "Using manifest: $$manifest"; \
	fi; \
	convert_reason=""; \
	if [ "$${FORCE:-0}" = "1" ]; then \
		convert_reason="FORCE=1"; \
	elif [ ! -s "$$rrd" ]; then \
		convert_reason="RRD missing or empty"; \
	elif [ "$$mp4" -nt "$$rrd" ]; then \
		convert_reason="MP4 is newer"; \
	elif [ "$(RERUN_SCRIPT)" -nt "$$rrd" ]; then \
		convert_reason="converter script is newer"; \
	elif [ -n "$$spatialmp4_so" ] && [ "$$spatialmp4_so" -nt "$$rrd" ]; then \
		convert_reason="SpatialMP4 Python extension is newer"; \
	fi; \
	if [ -n "$$convert_reason" ]; then \
		echo "Converting $$mp4 -> $$rrd ($$convert_reason)"; \
		"$(UV)" run --script --no-project --python "$(RERUN_PYTHON_VERSION)" \
		    "$(RERUN_SCRIPT)" \
			--input "$$mp4" \
			--output "$$rrd" \
			"$${manifest_args[@]}" \
			$${RERUN_CONVERT_ARGS:-}; \
	else \
		echo "Using existing RRD: $$rrd"; \
	fi; \
	if [ "$(RERUN_ALLOW_PORT_IN_USE)" != "1" ] && command -v lsof >/dev/null 2>&1; then \
		if lsof_output="$$(lsof -nP -iTCP:$(RERUN_WEB_PORT) -sTCP:LISTEN 2>/dev/null)" && [ -n "$$lsof_output" ]; then \
			echo "Rerun web port $(RERUN_WEB_PORT) is already in use; refusing to open a stale or unrelated viewer." >&2; \
			echo "$$lsof_output" >&2; \
			echo "Use RERUN_WEB_PORT=<free port>, stop that process, or set RERUN_ALLOW_PORT_IN_USE=1." >&2; \
			exit 3; \
		fi; \
	fi; \
	viewer_args=(); \
	if [ -n "$(RERUN_RENDERER)" ]; then \
		viewer_args+=(--renderer "$(RERUN_RENDERER)"); \
	fi; \
	echo "Opening Rerun Web Viewer at 127.0.0.1:$(RERUN_WEB_PORT)"; \
	"$(UV)" run --no-project --python "$(RERUN_PYTHON_VERSION)" --with 'rerun-sdk==$(RERUN_SDK_VERSION)' \
		rerun "$$rrd" --web-viewer --bind "$(RERUN_BIND)" --web-viewer-port "$(RERUN_WEB_PORT)" \
		"$${viewer_args[@]}" \
		$${RERUN_VIEWER_ARGS:-}
