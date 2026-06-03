# SO-101 MuJoCo simulation — convenience targets.
#
# Quick start:
#     make env        # uv sync — install deps locked in uv.lock
#     make run-sim    # launch the interactive MuJoCo viewer
#
# Other targets:
#     make smoketest  # load model, step, print info
#     make render     # offscreen render all cameras to ./renders/
#     make pick       # scripted IK pick-up demo
#     make lock       # regenerate uv.lock from pyproject.toml
#     make upgrade    # bump all deps within their pyproject.toml ranges
#     make clean      # remove .venv and ./renders/
#
# Environment is described by:
#     pyproject.toml  — declared deps + version ranges (source of truth)
#     uv.lock         — pinned exact versions, committed to the repo
#
# `uv sync` reads both and makes .venv match the lock exactly. Faster
# and stricter than `pip install -r requirements.txt`.

PYTHON_VERSION ?= 3.11
VENV           ?= .venv
PY             := $(VENV)/bin/python
UV             := uv

# Use the venv's python for any python invocation.
export VIRTUAL_ENV := $(abspath $(VENV))
export PATH        := $(abspath $(VENV))/bin:$(PATH)

.PHONY: help env env-recreate lock upgrade run-sim smoketest render pick clean check-uv prepare-assets

help:
	@echo "Targets:"
	@echo "  make env             - uv sync .venv against pyproject.toml + uv.lock"
	@echo "  make env-recreate    - delete and recreate the venv from scratch"
	@echo "  make prepare-assets  - fetch SO-101 mesh STLs from upstream menagerie"
	@echo "  make lock            - regenerate uv.lock (run after editing pyproject.toml)"
	@echo "  make upgrade         - bump deps within their pyproject.toml ranges"
	@echo "  make run-sim         - launch the MuJoCo interactive viewer"
	@echo "  make smoketest       - sanity-check the model and physics step"
	@echo "  make render          - offscreen render all cameras to ./renders/"
	@echo "  make pick            - scripted IK pick-up demo, snapshots to ./renders/"
	@echo "  make clean           - remove the venv and ./renders/"

check-uv:
	@command -v $(UV) >/dev/null 2>&1 || { \
	  echo "ERROR: 'uv' not found. Install it first:"; \
	  echo "  curl -LsSf https://astral.sh/uv/install.sh | sh"; \
	  echo "  # or: brew install uv"; \
	  exit 1; \
	}

# Idempotent: `uv sync` is fast (~ms) when the venv already matches the
# lock, so no sentinel file is needed. Creates .venv if missing.
env: check-uv
	$(UV) sync --python $(PYTHON_VERSION)

# Fetch the 19 SO-101 mesh STL files (~17 MB) from upstream
# mujoco_menagerie. Kept out of this repo to save space. Idempotent:
# fast no-op when the meshes are already present.
prepare-assets:
	./prepare.sh

env-recreate:
	rm -rf $(VENV)
	$(MAKE) env

# Regenerate uv.lock from pyproject.toml without touching the venv.
# Run this after editing dependencies in pyproject.toml.
lock: check-uv
	$(UV) lock

# Bump every dep to the newest version still allowed by pyproject.toml.
# Updates both uv.lock and the venv.
upgrade: check-uv
	$(UV) sync --python $(PYTHON_VERSION) --upgrade

# Run the interactive viewer (default).
run-sim: env prepare-assets
	$(UV) run mjpython sim_so101.py viewer

smoketest: env prepare-assets
	$(UV) run python sim_so101.py smoketest

render: env prepare-assets
	$(UV) run python sim_so101.py render --steps 200 --out renders

pick: env prepare-assets
	$(UV) run python pick_cube.py --out renders

clean:
	rm -rf $(VENV) renders
