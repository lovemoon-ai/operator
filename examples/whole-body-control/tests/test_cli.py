"""The old entry point selects the same ScaleBFM backend, not a forked loop."""
from pathlib import Path
import os
import subprocess
import sys
import pytest
from wbc.app import parse_args


def test_unified_cli_selects_controller_without_conflating_backend():
    args = parse_args(["--controller", "scalebfm", "--checkpoint", "a.pt", "--model", "b.xml", "--backend", "torchscript"])
    assert args.controller == "scalebfm" and args.backend == "torchscript"
    args = parse_args(["--controller", "sonic", "--upstream", "source", "--checkpoint", "weights"])
    assert args.controller == "sonic" and args.backend == "onnxruntime"
    assert args.scale == 1.
    with pytest.raises(SystemExit):
        parse_args(["--controller", "sonic", "--upstream", "source", "--checkpoint", "weights", "--scale", ".75"])


@pytest.mark.parametrize("controller", ["sonic", "scalebfm"])
def test_presentation_does_not_capture_hand_controls(controller):
    from types import SimpleNamespace
    from operator_xr import BlueprintComponent
    from wbc.presentation import blueprint
    from wbc.controllers.sonic.controller import SonicController
    assert "A+B+X+Y" in SonicController.initial_status
    def component(id, asset_port, **kwargs):
        return BlueprintComponent.robot_model(id, asset_port=asset_port,
            asset_sha256="a"*64,asset_size=100,joint_names=["left_knee_joint"],**kwargs)
    spec=blueprint(SimpleNamespace(component=component),63904,2.,controller)
    assert "input_binding" not in {item.type for item in spec.components}
    spec.validate_state_values({"g1.joints":[0.],"g1.base":[0,0,0,0,0,0,1],"g1.sample":1,
                                "g1.visible":True,"control.message":"SONIC PLANNER_VR_3PT"})


def test_imports_use_explicit_example_path_not_examples_package(tmp_path):
    repo = Path(__file__).resolve().parents[3]
    env = dict(os.environ, PYTHONPATH=os.pathsep.join((
        str(repo / "python"), str(repo / "examples/whole-body-control"),
    )))
    # Run outside the checkout: success must not depend on its root making
    # examples/ accidentally importable as an implicit namespace package.
    code = ("from wbc.controllers.sonic.pico_input import OfficialThreePoint; "
            "from wbc.controllers.scalebfm.tracking import extract_five_points; "
            "import sys; assert 'examples' not in sys.modules")
    result = subprocess.run([sys.executable, "-c", code], cwd=tmp_path, env=env,
                            text=True, capture_output=True, timeout=15)
    assert result.returncode == 0, result.stderr
