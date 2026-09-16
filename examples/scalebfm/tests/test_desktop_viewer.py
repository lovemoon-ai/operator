"""Host viewer lifecycle/state-copy checks, independent of XR device coverage."""
import os
from pathlib import Path
import sys

import mujoco
import numpy as np
import pytest

from desktop_viewer import DesktopViewer
from main import parse_args
from runtime import Simulation
from test_runtime import metadata_for_contract_tests


def test_viewer_is_on_by_default_and_can_be_disabled():
    required = ["--checkpoint", "policy.pt", "--model", "g1.xml"]
    assert parse_args(required).viewer is True
    assert parse_args([*required, "--no-viewer"]).viewer is False
    assert parse_args([*required, "--viewer"]).viewer is True


def test_disabled_viewer_does_not_require_display_or_simulation(monkeypatch):
    monkeypatch.delenv("DISPLAY", raising=False)
    monkeypatch.delenv("WAYLAND_DISPLAY", raising=False)
    with DesktopViewer(None, enabled=False) as desktop:
        assert desktop.is_running()
        desktop.sync("headless")
        assert desktop.handle is None and desktop.model is None and desktop.data is None


@pytest.mark.skipif(not sys.platform.startswith("linux"), reason="Linux display preflight")
def test_missing_display_has_actionable_error(monkeypatch):
    monkeypatch.delenv("DISPLAY", raising=False)
    monkeypatch.delenv("WAYLAND_DISPLAY", raising=False)
    with pytest.raises(RuntimeError, match="--no-viewer"):
        with DesktopViewer(None):
            pass


@pytest.mark.skipif(not os.getenv("SCALEBFM_G1_XML"), reason="Set SCALEBFM_G1_XML to the real ScaleBridge model")
def test_render_snapshot_does_not_advance_or_mutate_physics():
    sim = Simulation(Path(os.environ["SCALEBFM_G1_XML"]), metadata_for_contract_tests())
    desktop = DesktopViewer(sim)
    desktop._prepare_render_state()
    assert desktop.model is not sim.model and desktop.data is not sim.data
    gravity = sim.model.opt.gravity.copy()
    source_q = sim.data.qpos.copy()
    # Viewer-side perturbations/model edits must not affect the live simulation.
    desktop.model.opt.gravity[:] = 0
    desktop.data.qpos[0] = 100
    desktop.data.ctrl[:] = 100
    desktop._copy_state()
    np.testing.assert_array_equal(sim.model.opt.gravity, gravity)
    np.testing.assert_array_equal(sim.data.qpos, source_q)
    np.testing.assert_array_equal(sim.data.ctrl, 0)
    np.testing.assert_array_equal(desktop.data.qpos, source_q)
    assert sim.data.time == desktop.data.time == 0
    # A new actual state is copied, including the floating base and time.
    sim.data.qpos[0] = .3
    sim.data.time = .12
    mujoco.mj_forward(sim.model, sim.data)
    desktop._copy_state()
    np.testing.assert_array_equal(desktop.data.qpos, sim.data.qpos)
    np.testing.assert_allclose(desktop.data.xpos, sim.data.xpos, atol=1e-9)
    assert sim.data.time == desktop.data.time == .12
