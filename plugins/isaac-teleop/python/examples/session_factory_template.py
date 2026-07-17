"""Production session-factory template using external standard inputs.

Set ``OPERATOR_ISAAC_PIPELINE_FACTORY=package.module:build_pipeline``. The
builder receives a dictionary keyed by ``Kind`` whose values are output
selectors for standard ValueInput leaves. Wire those selectors into the same
retargeters that would normally consume ``ControllersSource``, ``HandsSource``,
``HeadSource`` or ``FullBodySource`` outputs and return the final pipeline.
"""

from __future__ import annotations

import importlib
import os

from operator_isaacteleop import ExternalTeleopSession, IsaacStandardInputAdapter


def _load_pipeline_builder():
    spec = os.environ.get("OPERATOR_ISAAC_PIPELINE_FACTORY")
    if not spec or ":" not in spec:
        raise RuntimeError("set OPERATOR_ISAAC_PIPELINE_FACTORY=package.module:build_pipeline")
    module_name, attribute = spec.rsplit(":", 1)
    builder = getattr(importlib.import_module(module_name), attribute)
    if not callable(builder):
        raise TypeError(f"{spec} is not callable")
    return builder


def make_session() -> ExternalTeleopSession:
    # Imports stay inside the factory so telemetry-only CLI use does not load
    # Isaac Sim/IsaacTeleop.
    from isaacteleop.teleop_session_manager import (
        SessionMode,
        TeleopSession,
        TeleopSessionConfig,
    )

    adapter = IsaacStandardInputAdapter()
    source_outputs = adapter.source_outputs()

    # build_pipeline(source_outputs) should connect, for example,
    # source_outputs[Kind.LEFT_CONTROLLER] where a native graph previously used
    # controllers.output(ControllersSource.LEFT). No DeviceIO source may remain.
    pipeline = _load_pipeline_builder()(source_outputs)
    control = adapter.create_default_control_pipeline()
    config = TeleopSessionConfig(
        app_name="OperatorIsaacTeleop",
        pipeline=pipeline,
        teleop_control_pipeline=control.pipeline,
        mode=SessionMode.EXTERNAL,  # supplied by plugins/.../upstream patch
    )
    session = TeleopSession(config)
    return ExternalTeleopSession.for_isaacteleop(
        session,
        input_adapter=adapter,
        session_control_pipeline=True,
    )
