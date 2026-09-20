"""Compare the exported articulated hierarchy to real MuJoCo FK."""
import os

import mujoco as mj
import numpy as np
import pytest
from scipy.spatial.transform import Rotation

from pyoperator.mujoco_asset import from_mujoco
from pyoperator.robot_assets import glb_document
from wbc.serve_asset_test import scalar_joint_names


def test_box_visual_is_tessellated_into_triangles():
    model = mj.MjModel.from_xml_string(
        """
        <mujoco>
          <worldbody>
            <body name="pelvis">
              <inertial pos="0 0 0" mass="1" diaginertia="1 1 1"/>
              <freejoint/>
              <body name="link">
                <inertial pos="0 0 0" mass="1" diaginertia="1 1 1"/>
                <joint name="joint" type="hinge"/>
                <geom type="box" size=".1 .2 .3" group="1" rgba="1 0 0 1"/>
              </body>
            </body>
          </worldbody>
        </mujoco>
        """
    )
    asset = from_mujoco(model, root_body="pelvis", joint_names=("joint",))
    document = glb_document(asset.data)
    primitive = document["meshes"][0]["primitives"][0]
    positions = document["accessors"][primitive["attributes"]["POSITION"]]
    assert positions["count"] == 36


def test_sphere_visual_is_tessellated_into_triangles():
    model = mj.MjModel.from_xml_string(
        """
        <mujoco>
          <worldbody>
            <body name="pelvis">
              <inertial pos="0 0 0" mass="1" diaginertia="1 1 1"/>
              <freejoint/>
              <body name="link">
                <inertial pos="0 0 0" mass="1" diaginertia="1 1 1"/>
                <joint name="joint" type="hinge"/>
                <geom type="sphere" size=".1" group="1" rgba="0 1 0 1"/>
              </body>
            </body>
          </worldbody>
        </mujoco>
        """
    )
    asset = from_mujoco(model, root_body="pelvis", joint_names=("joint",))
    document = glb_document(asset.data)
    primitive = document["meshes"][0]["primitives"][0]
    positions = document["accessors"][primitive["attributes"]["POSITION"]]
    assert positions["count"] > 36


def test_asset_server_joint_enumeration_handles_mujoco_enum_scalars():
    model = mj.MjModel.from_xml_string(
        """
        <mujoco>
          <worldbody>
            <body name="pelvis">
              <inertial pos="0 0 0" mass="1" diaginertia="1 1 1"/>
              <freejoint/>
              <body name="hinged">
                <inertial pos="0 0 0" mass="1" diaginertia="1 1 1"/>
                <joint name="hinge" type="hinge"/>
                <geom type="box" size=".1 .1 .1"/>
              </body>
            </body>
          </worldbody>
        </mujoco>
        """
    )
    assert scalar_joint_names(model) == ["hinge"]


@pytest.mark.parametrize("model_variable", ["SCALEBFM_G1_XML", "SCALEBFM_DEX3_XML", "SONIC_G1_XML"])
def test_real_g1_export_matches_mujoco_body_and_visual_kinematics(model_variable):
    path = os.environ.get(model_variable)
    if not path:
        pytest.skip(f"set {model_variable} to the real host G1 model")
    model = mj.MjModel.from_xml_path(path)
    names = [model.joint(i).name for i in range(1, model.njnt)]
    asset = from_mujoco(model, root_body="pelvis", joint_names=names)
    doc = glb_document(asset.data)
    rig = doc["extras"]["operator_robot"]
    assert len(rig["joints"]) == len(names)
    assert asset.joint_names == tuple(names)
    basis = np.array([[0., -1., 0.], [0., 0., 1.], [-1., 0., 0.]])
    data = mj.MjData(model)
    data.qpos[:3] = [0.15, -0.2, 0.9]
    data.qpos[3:7] = [np.cos(.2), 0, 0, np.sin(.2)]
    data.qpos[7:] = np.sin(np.arange(len(names))) * 0.15
    mj.mj_forward(model, data)
    world = {}
    joint_by_node = {j["node"]: j for j in rig["joints"]}

    def visit(index, parent):
        node = doc["nodes"][index]
        local = np.array(node.get("matrix", np.eye(4).flatten(order="F"))).reshape(4, 4, order="F")
        if index == rig["root"]:
            local[:3, :3] = basis @ data.xmat[1].reshape(3, 3) @ basis.T
            local[:3, 3] = basis @ data.xpos[1]
        elif index in joint_by_node:
            joint = joint_by_node[index]
            joint_id = mj.mj_name2id(model, mj.mjtObj.mjOBJ_JOINT, joint["name"])
            q = data.qpos[model.jnt_qposadr[joint_id]] - joint["reference"]
            delta = np.eye(4)
            delta[:3, :3] = Rotation.from_rotvec(np.array(joint["axis"]) * q).as_matrix()
            pivot = np.array(joint["pivot"])
            delta[:3, 3] = pivot - delta[:3, :3] @ pivot
            local = local @ delta
        world[index] = parent @ local
        for child in node.get("children", []):
            visit(child, world[index])

    visit(rig["root"], np.eye(4))
    binary_offset = 28 + int.from_bytes(asset.data[12:16], "little")
    for index, node in enumerate(doc["nodes"]):
        if node["name"].startswith("visual_"):
            geom = int(node["name"].removeprefix("visual_"))
            expected_pos = data.geom_xpos[geom]
            expected_rot = data.geom_xmat[geom].reshape(3, 3)
            primitive = doc["meshes"][node["mesh"]]["primitives"][0]
            accessor = doc["accessors"][primitive["attributes"]["POSITION"]]
            view = doc["bufferViews"][accessor["bufferView"]]
            local_vertices = np.frombuffer(asset.data, dtype="<f4", offset=binary_offset + view["byteOffset"], count=accessor["count"] * 3).reshape(-1, 3)
            assert np.isfinite(local_vertices).all()
        else:
            body = mj.mj_name2id(model, mj.mjtObj.mjOBJ_BODY, node["name"])
            expected_pos = data.xpos[body]
            expected_rot = data.xmat[body].reshape(3, 3)
        np.testing.assert_allclose(world[index][:3, 3], basis @ expected_pos, atol=1e-6)
        np.testing.assert_allclose(world[index][:3, :3], basis @ expected_rot @ basis.T, atol=1e-6)
