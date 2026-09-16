from collections import deque
from types import SimpleNamespace
from main import blueprint, claim_reset_request
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


def test_reset_is_a_chord_without_robot_owned_menus_or_scene_text():
    spec = blueprint(ContractAsset(), 63904, 2.0)
    assert {component.type for component in spec.components} == {
        "robot_model", "input_binding", "ground_grid", "model_lighting"}
    reset = next(component for component in spec.components if component.type == "input_binding")
    assert reset.properties["gesture"] == "dual_trigger_hold"
    assert reset.properties["hold_seconds"] == 1.0
    assert reset.properties["target_component"] == "g1"
    assert reset.bindings["required"] == "control.reset_required"
    assert reset.bindings["acknowledged_request"] == "control.reset_ack"
    spec.validate_event(BlueprintEvent(
        blueprint_id=spec.blueprint_id, blueprint_revision=spec.revision,
        sequence=1, timestamp_ns=1, component_id=reset.id, action="reset", value="request-id",
    ))
    spec.validate_state_values({"control.reset_ack": "request-id", "control.reset_success": True,
        "control.reset_required": False, "control.available": True, "control.message": "Ready"})


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
