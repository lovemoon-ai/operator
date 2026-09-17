from collections import deque
from types import SimpleNamespace
from wbc.presentation import blueprint, claim_reset_request
from pyoperator import BlueprintEvent
from pyoperator.blueprint import BlueprintComponent


class ContractAsset:
    def component(self, id, *, asset_port, **kwargs):
        return BlueprintComponent.robot_model(id, asset_sha256="a" * 64,
            asset_size=100, asset_port=asset_port, joint_names=["left_knee_joint"], **kwargs)


def test_reset_requests_are_not_replayed_or_inferred_from_local_menu_actions():
    recent = deque(maxlen=128)
    assert claim_reset_request(None, recent) == ""
    assert claim_reset_request(SimpleNamespace(action="view.recenter", value=True), recent) == ""
    assert claim_reset_request(SimpleNamespace(action="connection.toggle", value=True), recent) == ""
    assert claim_reset_request(SimpleNamespace(action="reset", value=True), recent) == ""
    assert claim_reset_request(SimpleNamespace(action="reset", value="one"), recent) == "one"
    assert claim_reset_request(SimpleNamespace(action="reset", value="two"), recent) == "two"
    assert claim_reset_request(SimpleNamespace(action="reset", value="one"), recent) == ""


def test_shared_status_without_trigger_binding_or_robot_owned_menu():
    spec = blueprint(ContractAsset(), 63904, 2.0)
    assert {component.type for component in spec.components} == {
        "robot_model", "label", "ground_grid", "model_lighting"}
    status = next(component for component in spec.components if component.type == "label")
    assert status.bindings["text"] == "control.message"
    spec.validate_state_values({"control.message": "ScaleBFM VR"})


def test_grid_and_lighting_are_host_declared_and_share_robot_visibility():
    spec = blueprint(ContractAsset(), 63904, 3.5)
    components = {component.id: component for component in spec.components}
    grid = components["ground"]
    assert grid.properties["placement_target"] == "g1"
    assert grid.transform.position == (0, 0.002, -3.5)
    assert grid.properties["spacing"] == 0.5
    assert components["lighting"].properties["fill_energy"] > 0
    assert grid.bindings["visible"] == components["lighting"].bindings["visible"] == "g1.visible"
    spec.validate_state_values({"g1.visible": False})
