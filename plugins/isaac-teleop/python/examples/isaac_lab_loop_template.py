"""Task-neutral Isaac Lab loop for an Operator-backed teleop device.

Create ``simulation_app`` and ``env`` with the task's normal Isaac Lab setup,
and build the patched external TeleopSession with
``session_factory_template.make_session()``. The plugin deliberately does not
own task selection, scene creation, or ``env.step`` semantics.
"""

from __future__ import annotations

from typing import Any

from operator_isaacteleop import (
    OperatorIsaacTeleopDevice,
    UnixDatagramReceiver,
)
from operator_isaacteleop.session import ExternalTeleopSession


def run_isaac_lab_loop(
    simulation_app: Any,
    env: Any,
    session: ExternalTeleopSession,
    *,
    socket_path: str = "/tmp/operator-isaacteleop.sock",
    add_batch_dimension: bool = True,
) -> None:
    """Advance one IsaacTeleop action per environment step.

    Most single-environment Isaac Lab tasks expect ``[1, action_dim]`` while
    IsaacTeleop returns ``[action_dim]``; disable ``add_batch_dimension`` when
    the task's action consumer already handles batching.
    """

    receiver = UnixDatagramReceiver(socket_path)
    device_name = str(getattr(env, "device", "cuda:0"))
    device = OperatorIsaacTeleopDevice(
        receiver,
        session,
        device=device_name,
    )
    env.reset()
    with device:
        while simulation_app.is_running():
            action = device.advance()
            if add_batch_dimension and getattr(action, "ndim", 0) == 1:
                action = action.unsqueeze(0)
            env.step(action)
