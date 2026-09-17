"""Shared G1 presentation; no controller or physics assumptions."""
from collections import deque
from pyoperator import Blueprint, BlueprintComponent, BlueprintTransform, RobotModelAsset

def claim_reset_request(event, recent_requests: deque[str]) -> str:
    """Deduplicate remote gesture requests; acknowledgements echo this ID."""
    if event is None or event.action != "reset" or not isinstance(event.value, str) \
            or not event.value or event.value in recent_requests:
        return ""
    recent_requests.append(event.value)
    return event.value


def blueprint(asset: RobotModelAsset, asset_port: int, distance: float, controller: str = "scalebfm") -> Blueprint:
    # Preserve ScaleBFM's original identity/visibility preferences across migration.
    components = (
        BlueprintComponent.ground_grid(
            "ground", placement_target="g1", visible_binding="g1.visible",
            transform=BlueprintTransform(position=(0, 0.002, -distance)),
            properties={"settings_label": "Ground grid", "size": 8.0, "spacing": 0.5},
        ),
        BlueprintComponent.model_lighting(
            "lighting", visible_binding="g1.visible",
            properties={"settings_label": "Robot lighting", "key_energy": 1.6, "fill_energy": 0.6},
        ),
        asset.component(
            "g1", asset_port=asset_port,
            joint_positions_binding="g1.joints", base_pose_binding="g1.base",
            sample_binding="g1.sample", visible_binding="g1.visible",
            transform=BlueprintTransform(position=(0, 0, -distance)),
        ),
    )
    # Shared gamepad semantics are handled by the host. No dual-trigger binding
    # may reserve hand controls or enqueue reset requests in either backend.
    components += (BlueprintComponent.label(
        "control_status", anchor="left_controller", text_binding="control.message",
        transform=BlueprintTransform(position=(0, .09, 0)),
        properties={"settings_label": "Controller status", "font_size": 24},
    ),)
    return Blueprint(blueprint_id=f"example.{controller}", components=components)
