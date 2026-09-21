"""The XR host loop against a fake native session: no headset, checkout, or GPU."""
import json
import time
from types import SimpleNamespace

import pytest

import pyoperator
import pyoperator.session
from pyoperator import ControllerInput, ControllerPair, ControllerState, HandPair, Pose, XrFrame
from pyoperator._blueprint_spec import SPEC_SHA256
from pyoperator.models import frame_to_dict

from light_o1_vr import app
from light_o1_vr.app import parse_args, run
from fakes import JOINT_NAMES, FakeGenerator, FakeLightO1, FakeSimulator


def frame_json(frame_id, right_values=None):
    """Wire-format XrFrame with a tracked right controller and the given input values."""
    right = ControllerState(pose=Pose(valid=True, sample_timestamp_ns=frame_id),
                            input=ControllerInput(sample_timestamp_ns=frame_id, values=right_values or {}))
    frame = XrFrame(schema_version=1, frame_id=frame_id, timestamp_ns=frame_id * 1_000_000,
                    coordinate_space="xr_origin", head=Pose(valid=True),
                    controllers=ControllerPair(left=None, right=right), hands=HandPair(), body=None,
                    motion_trackers=())
    return json.dumps(frame_to_dict(frame))


class FakeNative:
    """Just enough of pyoperator's native session for BlueprintClient and XrSession.

    ``inputs`` maps a host tick to the right-controller values reported from
    that tick on; ``stop_when`` ends the loop deterministically.
    """

    def __init__(self, ticks=60, inputs=None, stop_when=None):
        self.ticks = ticks  # safety cap
        self.inputs = dict(inputs or {})
        self.stop_when = stop_when
        self.tick = 0
        self.current_values = {}
        self.blueprints = []
        self.updates = []
        self.cleared = 0
        self.started = False
        self.closed = False
        self.sequence = 0

    def start(self):
        self.started = True

    def close(self):
        self.closed = True

    def is_running(self):
        self.tick += 1
        if self.tick in self.inputs:
            self.current_values = self.inputs[self.tick]
        if self.stop_when is not None and self.updates and self.stop_when(self.updates[-1]):
            return False
        time.sleep(0.0005)  # let the pipeline thread progress between host ticks
        return self.tick <= self.ticks

    def stats_json(self):
        return json.dumps({"connected": True})

    def latest_json(self):
        return frame_json(self.tick, self.current_values)

    def blueprint_spec_sha256(self):
        return SPEC_SHA256

    def set_blueprint_json(self, payload):
        self.blueprints.append(json.loads(payload))

    def clear_blueprint(self):
        self.cleared += 1

    def update_blueprint_values_json(self, payload, timestamp_ns):
        self.sequence += 1
        self.updates.append(json.loads(payload))
        return self.sequence

    def poll_blueprint_event_json(self, timeout):
        return None


class FakeAssetServer:
    def __init__(self, assets, port=0):
        self.assets = assets
        self.port = port or 63904

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False


class FakeAsset:
    sha256 = "b" * 64
    data = b"glb-bytes" * 8
    joint_names = JOINT_NAMES

    def component(self, id, *, asset_port, **kwargs):
        return pyoperator.BlueprintComponent.robot_model(
            id, asset_sha256=self.sha256, asset_size=len(self.data), asset_port=asset_port,
            joint_names=list(JOINT_NAMES), **kwargs)


@pytest.fixture
def harness(monkeypatch):
    simulator = FakeSimulator()
    light_o1 = FakeLightO1()
    light_o1.simulator = lambda checkpoint: simulator
    generator = FakeGenerator(frames=4)
    native = FakeNative()
    sessions = []
    real_session = pyoperator.session.XrSession

    def xr_session(config, *, _native_factory=None):
        sessions.append(config)
        return real_session(config, _native_factory=lambda **kwargs: native)

    monkeypatch.setattr(app, "LightO1", lambda root: light_o1)
    monkeypatch.setattr(app, "make_generator", lambda args: generator)
    monkeypatch.setattr(pyoperator, "XrSession", xr_session)
    monkeypatch.setattr(pyoperator, "RobotAssetServer", FakeAssetServer)
    monkeypatch.setattr("pyoperator.mujoco_asset.from_mujoco",
                        lambda model, *, root_body, joint_names: FakeAsset())
    return SimpleNamespace(simulator=simulator, light_o1=light_o1, generator=generator, native=native,
                           sessions=sessions)


def done(update):
    status = update["ui.text"].split("\n")[1]
    return status.startswith("Done") or status.startswith("Failed")


def test_run_publishes_blueprint_streams_state_and_follows_the_controller(harness, capsys):
    native = harness.native
    native.ticks = 5000
    native.stop_when = done
    # Stick right (one prompt forward), recentre, press A, release A.
    native.inputs = {5: {"primary_x": 1.0}, 7: {}, 10: {"ax_button": 1.0}, 12: {}}
    run(parse_args(["--no-stdin", "--headset-ip", "10.0.0.9", "--asset-port", "60000", "--distance", "1.5"]))
    assert native.started and native.closed and native.cleared == 1
    assert harness.sessions[0].name == "Light-O1 G1" and harness.sessions[0].discovery_unicast_targets == ("10.0.0.9",)
    assert harness.sessions[0].streams == ("head", "controllers")
    blueprint = native.blueprints[0]
    assert blueprint["blueprint_id"] == "example.light_o1"
    assert [c["type"] for c in blueprint["components"]] == ["ground_grid", "model_lighting", "robot_model", "label"]
    g1 = next(c for c in blueprint["components"] if c["id"] == "g1")
    assert g1["properties"]["asset_port"] == 60000 and g1["transform"]["position"] == [0, 0, -1.5]
    assert 12 <= len(native.updates) < 5000
    first, last = native.updates[0], native.updates[-1]
    assert set(first) == {"g1.joints", "g1.base", "g1.sample", "g1.visible", "ui.text"}
    assert len(first["g1.joints"]) == 29 and first["g1.sample"] == 1
    assert first["ui.text"].startswith("Prompt 1/")
    assert native.updates[6]["ui.text"].startswith("Prompt 2/")  # the stick step showed up on the next tick
    assert harness.generator.calls == [("walk forward and turn around", 0, True)]
    assert any("Playing" in update["ui.text"] for update in native.updates)
    assert "Done - 0.2s, G1 stayed up" in last["ui.text"]
    out = capsys.readouterr().out
    assert "Select Outside Robot > Operator > Light-O1 G1" in out and "Robot asset: " in out
    assert "A: generate" in out


def test_run_ignores_a_button_held_while_connecting(harness):
    native = harness.native
    native.ticks = 40
    native.inputs = {1: {"ax_button": 1.0}}  # held from the first frame, never released
    run(parse_args(["--no-stdin"]))
    assert harness.generator.calls == []
    assert all(update["ui.text"].split("\n")[1].startswith("Ready") for update in native.updates)


def test_run_forwards_typed_prompts(harness, monkeypatch):
    native = harness.native
    native.ticks = 5000
    native.stop_when = lambda update: "do a cartwheel" in update["ui.text"] and done(update)
    lines = ["do a cartwheel\n"]

    class Typed(app.StdinPrompts):
        def __init__(self, stream=None):
            super().__init__(stream=iter(lines))

    monkeypatch.setattr(app, "StdinPrompts", Typed)
    run(parse_args([]))
    assert harness.generator.calls[0][0] == "do a cartwheel"


def test_run_batch_path_skips_xr(harness, tmp_path, capsys):
    run(parse_args(["--batch", "wave", "--output", str(tmp_path / "w.npz")]))
    assert harness.native.blueprints == [] and (tmp_path / "w.npz").is_file()
    assert '"survived_s": 0.2' in capsys.readouterr().out


def test_main_reports_missing_inputs_cleanly(monkeypatch):
    monkeypatch.setattr(app, "LightO1", lambda root: (_ for _ in ()).throw(FileNotFoundError("no checkout")))
    with pytest.raises(SystemExit, match="no checkout"):
        app.main(["--no-stdin"])
