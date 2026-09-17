"""Optional desktop visualization of the host simulation; never steps physics."""
from __future__ import annotations

import copy
import os
import sys

import mujoco
import numpy as np


class DesktopViewer:
    def __init__(self, simulation, *, enabled: bool = True, title: str = "Whole-body control"):
        self.simulation = simulation
        self.title = title
        self.enabled = enabled
        self.handle = None
        self.model = None
        self.data = None
        self._state = None
        self._state_spec = mujoco.mjtState.mjSTATE_INTEGRATION

    def __enter__(self):
        if not self.enabled:
            return self
        if sys.platform.startswith("linux") and not (
            os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY")
        ):
            raise RuntimeError("Desktop viewer needs a graphical session; use --no-viewer on a headless host")
        import glfw
        import mujoco.viewer

        # MuJoCo's window/camera controls work more reliably through XWayland
        # when both desktop backends are advertised. Native Wayland remains
        # available when there is no DISPLAY.
        if sys.platform.startswith("linux") and os.environ.get("DISPLAY") \
                and glfw.get_version() >= (3, 4, 0) \
                and glfw.platform_supported(glfw.PLATFORM_X11):
            glfw.init_hint(glfw.PLATFORM, glfw.PLATFORM_X11)
        if not glfw.init():
            raise RuntimeError("Cannot initialize the desktop display; check DISPLAY or use --no-viewer")
        self._prepare_render_state()
        self.handle = mujoco.viewer.launch_passive(
            self.model, self.data, show_left_ui=False, show_right_ui=False,
        )
        try:
            with self.handle.lock():
                self.handle.cam.type = mujoco.mjtCamera.mjCAMERA_TRACKING
                self.handle.cam.trackbodyid = int(self.model.jnt_bodyid[0])
                self.handle.cam.distance = 2.5
                self.handle.cam.azimuth = 135
                self.handle.cam.elevation = -20
                self.handle.cam.lookat[:] = self.simulation.data.qpos[:3]
            self.sync("Waiting for full-body tracking / calibration")
        except BaseException:
            self.handle.close()
            raise
        return self

    def _prepare_render_state(self) -> None:
        # Display copies prevent mouse perturbations and viewer UI controls from
        # modifying the policy's authoritative model/state. These copies are
        # never simulated: every displayed frame comes from the same live sim.
        self.model = copy.copy(self.simulation.model)
        self.data = mujoco.MjData(self.model)
        self._state = np.empty(mujoco.mj_stateSize(self.model, self._state_spec))
        self._copy_state()

    def is_running(self) -> bool:
        return not self.enabled or (self.handle is not None and self.handle.is_running())

    def sync(self, status: str) -> None:
        if self.handle is None or not self.handle.is_running():
            return
        with self.handle.lock():
            self._copy_state()
        if hasattr(self.handle, "set_texts"):
            self.handle.set_texts((
                mujoco.mjtFontScale.mjFONTSCALE_100,
                mujoco.mjtGridPos.mjGRID_TOPLEFT,
                self.title,
                f"{status.replace('→', '->')}\nSimulation: {self.simulation.data.time:.2f} s",
            ))
        # sync locks internally. No mj_step and no writes to the live state.
        self.handle.sync(state_only=True)

    def _copy_state(self) -> None:
        mujoco.mj_getState(self.simulation.model, self.simulation.data, self._state, self._state_spec)
        mujoco.mj_setState(self.model, self.data, self._state, self._state_spec)
        # Rebuild render transforms/contact diagnostics only; time is unchanged.
        mujoco.mj_forward(self.model, self.data)

    def __exit__(self, *_):
        if self.handle is not None:
            self.handle.close()
