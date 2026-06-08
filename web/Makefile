
SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

UV ?= uv
RERUN_PYTHON_VERSION ?= 3.13
RERUN_SDK_VERSION ?= 0.33.*
RERUN_WEB_PORT ?= 9090
RERUN_BIND ?= 127.0.0.1
RERUN_SETUP_SPATIALMP4 ?= auto
OPERATOR_DEPS_CACHE_ROOT ?= $(abspath ../.deps)
SPATIALMP4_HOME ?= $(OPERATOR_DEPS_CACHE_ROOT)/src/SpatialMP4

RRD ?= $(basename $(MP4)).rrd

export OPERATOR_DEPS_CACHE_ROOT
export RERUN_PYTHON_VERSION
export SPATIALMP4_HOME

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
	if [ "$(RERUN_SETUP_SPATIALMP4)" != "0" ] && \
		! find "$(SPATIALMP4_HOME)" "$(OPERATOR_DEPS_CACHE_ROOT)/build/spatialmp4" -path '*/python/spatialmp4.cpython-*.so' -type f -print -quit 2>/dev/null | grep -q .; then \
		echo "SpatialMP4 Python extension not found; building it once via ../scripts/setup_spatialmp4.sh"; \
		../scripts/setup_spatialmp4.sh; \
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
	if [ "$${FORCE:-0}" = "1" ] || [ ! -s "$$rrd" ] || [ "$$mp4" -nt "$$rrd" ]; then \
		echo "Converting $$mp4 -> $$rrd"; \
		"$(UV)" run --script --no-project --python "$(RERUN_PYTHON_VERSION)" \
			app/scripts/spatialmp4_to_rrd.py \
			--input "$$mp4" \
			--output "$$rrd" \
			"$${manifest_args[@]}" \
			$${RERUN_CONVERT_ARGS:-}; \
	else \
		echo "Using existing RRD: $$rrd"; \
	fi; \
	echo "Opening Rerun Web Viewer at 127.0.0.1:$(RERUN_WEB_PORT)"; \
	"$(UV)" run --no-project --python "$(RERUN_PYTHON_VERSION)" --with 'rerun-sdk==$(RERUN_SDK_VERSION)' \
		rerun "$$rrd" --web-viewer --bind "$(RERUN_BIND)" --web-viewer-port "$(RERUN_WEB_PORT)" \
		$${RERUN_VIEWER_ARGS:-}
