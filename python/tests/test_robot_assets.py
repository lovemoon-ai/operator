"""Host format/server tests. Actual GLTF import is tested on the headset."""
import json
import struct
import sys
import urllib.error
import urllib.request

import pytest
from operator_xr import RobotModelAsset, RobotAssetServer
from operator_xr.robot_assets import glb_document


def asset():
    doc = {"extras": {"operator_robot": {"schema": "operator.robot_asset.v1",
           "joints": [{"name": "joint"}]}}}
    encoded = json.dumps(doc).encode()
    encoded += b" " * (-len(encoded) % 4)
    return RobotModelAsset(struct.pack("<5I", 0x46546C67, 2, 20 + len(encoded), len(encoded), 0x4E4F534A) + encoded)


def rigid_asset():
    doc = {"extras": {"operator_robot": {
        "schema": "operator.robot_asset.v1", "joints": []}}}
    encoded = json.dumps(doc).encode()
    encoded += b" " * (-len(encoded) % 4)
    return RobotModelAsset(struct.pack("<5I", 0x46546C67, 2, 20 + len(encoded), len(encoded), 0x4E4F534A) + encoded)


def test_registered_assets_are_content_addressed_and_not_directory_served():
    model = asset()
    with RobotAssetServer([model], host="127.0.0.1") as server:
        url = f"http://127.0.0.1:{server.port}/blueprint-assets/{model.sha256}.glb"
        with urllib.request.urlopen(url, timeout=3) as response:
            assert response.read() == model.data
            assert response.headers["ETag"] == f'"{model.sha256}"'
            assert int(response.headers["Content-Length"]) == len(model.data)
        for path in ("/", "/../secret", "/blueprint-assets/" + "0" * 64 + ".glb", "/blueprint-assets/../../etc/passwd"):
            with pytest.raises(urllib.error.HTTPError) as failure:
                urllib.request.urlopen(f"http://127.0.0.1:{server.port}{path}", timeout=3)
            assert failure.value.code == 404
    server.close()
    with pytest.raises(RuntimeError):
        server.start()


def test_glb_identity_and_component_contract():
    model = asset()
    assert model.sha256 == asset().sha256
    component = model.component("robot", asset_port=63904, joint_positions_binding="q", base_pose_binding="base", sample_binding="seq")
    assert component.properties["asset_sha256"] == model.sha256
    assert component.properties["asset_size"] == len(model.data)
    assert component.properties["joint_names"] == ["joint"]
    assert "robot_id" not in component.properties
    for corrupted in (b"no", model.data[:-1], b"xxxx" + model.data[4:]):
        with pytest.raises(ValueError):
            glb_document(corrupted)


def test_rigid_asset_has_empty_joint_contract_and_can_replace_server_set():
    rigid = rigid_asset()
    assert rigid.joint_names == ()
    component = rigid.component(
        "prop", asset_port=63904, joint_positions_binding="q",
        base_pose_binding="base", sample_binding="seq",
    )
    assert component.properties["joint_names"] == []

    with RobotAssetServer([asset()], host="127.0.0.1") as server:
        original = asset()
        original_url = f"http://127.0.0.1:{server.port}/blueprint-assets/{original.sha256}.glb"
        with urllib.request.urlopen(original_url, timeout=3) as response:
            assert response.read() == original.data
        server.replace([rigid])
        rigid_url = f"http://127.0.0.1:{server.port}/blueprint-assets/{rigid.sha256}.glb"
        with urllib.request.urlopen(rigid_url, timeout=3) as response:
            assert response.read() == rigid.data
        # replace() must *drop* the previous set, not merely add to it.
        with pytest.raises(urllib.error.HTTPError) as excinfo:
            urllib.request.urlopen(original_url, timeout=3)
        assert excinfo.value.code == 404


@pytest.mark.parametrize("digest", ["../asset", "A" * 64, "0" * 63, "g" * 64])
def test_component_rejects_invalid_hash(digest):
    from operator_xr import BlueprintComponent
    with pytest.raises(ValueError):
        BlueprintComponent.robot_model("robot", asset_sha256=digest, asset_size=100, asset_port=63904,
            joint_names=["joint"], joint_positions_binding="q", base_pose_binding="base", sample_binding="seq")


def test_from_mujoco_names_its_optional_extra(monkeypatch):
    from operator_xr.mujoco_asset import from_mujoco

    monkeypatch.setitem(sys.modules, "mujoco", None)
    with pytest.raises(RuntimeError, match=r"operator-xr\[mujoco\]"):
        from_mujoco(None, root_body="base", joint_names=())
