PYTHON_VERSION ?= 3.11
UV ?= uv

.PHONY: env test run run-headless clean

env:
	$(UV) sync --python $(PYTHON_VERSION)

test: env
	$(UV) run python -m unittest -v test_g1d_sim.py

run: env
	$(UV) run python teleop.py

run-headless: env
	$(UV) run python teleop.py --headless

clean:
	rm -rf .venv __pycache__
