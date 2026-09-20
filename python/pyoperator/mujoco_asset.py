"""Export a compiled host MuJoCo model as a data-only articulated GLB.

Optional MuJoCo/numpy dependencies are imported only when exporting. This is
independent of Inside Robot and never reads/writes the XR checkout's assets.
The profile supports triangle meshes, boxes and spheres with solid PBR colors,
scalar hinge/slide joints (one per body), and one externally driven floating
root.
"""
from __future__ import annotations

import json
import struct

from .robot_assets import RobotModelAsset, ROBOT_ASSET_SCHEMA


def from_mujoco(model, *, root_body: str, joint_names, visual_groups=(1,)) -> RobotModelAsset:
    import mujoco as mj
    import numpy as np

    names = tuple(joint_names)
    if not names or len(set(names)) != len(names):
        raise ValueError("joint_names must be unique and nonempty")
    root = mj.mj_name2id(model, mj.mjtObj.mjOBJ_BODY, root_body)
    if root <= 0:
        raise ValueError("root_body must name a non-world body")
    basis = np.array([[0., -1., 0.], [0., 0., 1.], [-1., 0., 0.]])
    document = {
        "asset": {"version": "2.0", "generator": "pyoperator.mujoco_asset"},
        "scene": 0, "scenes": [{"nodes": [0]}], "nodes": [],
        "meshes": [], "materials": [], "bufferViews": [], "accessors": [],
    }
    binary = bytearray()

    def transform(pos, quat):
        rotation = np.empty(9)
        mj.mju_quat2Mat(rotation, quat)
        matrix = np.eye(4)
        matrix[:3, :3] = basis @ rotation.reshape(3, 3) @ basis.T
        matrix[:3, 3] = basis @ pos
        return matrix.flatten(order="F").tolist()

    def accessor(values):
        values = np.asarray(values, dtype="<f4").reshape(-1, 3)
        if not np.isfinite(values).all():
            raise ValueError("mesh contains non-finite data")
        payload = values.tobytes()
        view = len(document["bufferViews"])
        document["bufferViews"].append({"buffer": 0, "byteOffset": len(binary), "byteLength": len(payload)})
        binary.extend(payload)
        index = len(document["accessors"])
        document["accessors"].append({
            "bufferView": view, "componentType": 5126, "count": len(values), "type": "VEC3",
            "min": values.min(axis=0).tolist(), "max": values.max(axis=0).tolist(),
        })
        return index

    def geom_triangles(geom):
        geom_type = int(model.geom_type[geom])
        if geom_type == int(mj.mjtGeom.mjGEOM_MESH):
            mesh_id = int(model.geom_dataid[geom])
            start = int(model.mesh_vertadr[mesh_id])
            vertices = model.mesh_vert[start:start + model.mesh_vertnum[mesh_id]]
            start = int(model.mesh_faceadr[mesh_id])
            faces = model.mesh_face[start:start + model.mesh_facenum[mesh_id]]
            return vertices[faces]
        if geom_type == int(mj.mjtGeom.mjGEOM_BOX):
            x, y, z = np.asarray(model.geom_size[geom], dtype=float)
            vertices = np.asarray(
                [
                    [-x, -y, -z],
                    [x, -y, -z],
                    [x, y, -z],
                    [-x, y, -z],
                    [-x, -y, z],
                    [x, -y, z],
                    [x, y, z],
                    [-x, y, z],
                ]
            )
            faces = np.asarray(
                [
                    [0, 2, 1],
                    [0, 3, 2],
                    [4, 5, 6],
                    [4, 6, 7],
                    [0, 1, 5],
                    [0, 5, 4],
                    [1, 2, 6],
                    [1, 6, 5],
                    [2, 3, 7],
                    [2, 7, 6],
                    [3, 0, 4],
                    [3, 4, 7],
                ]
            )
            return vertices[faces]
        if geom_type == int(mj.mjtGeom.mjGEOM_SPHERE):
            radius = float(model.geom_size[geom, 0])
            latitude_segments, longitude_segments = 8, 12
            vertices = [[0.0, 0.0, radius]]
            for latitude in range(1, latitude_segments):
                phi = np.pi * latitude / latitude_segments
                for longitude in range(longitude_segments):
                    theta = 2.0 * np.pi * longitude / longitude_segments
                    vertices.append(
                        [
                            radius * np.sin(phi) * np.cos(theta),
                            radius * np.sin(phi) * np.sin(theta),
                            radius * np.cos(phi),
                        ]
                    )
            vertices.append([0.0, 0.0, -radius])
            north, south = 0, len(vertices) - 1
            faces = []
            for longitude in range(longitude_segments):
                following = (longitude + 1) % longitude_segments
                faces.append([north, 1 + longitude, 1 + following])
            for latitude in range(latitude_segments - 2):
                first = 1 + latitude * longitude_segments
                following = first + longitude_segments
                for longitude in range(longitude_segments):
                    right = (longitude + 1) % longitude_segments
                    faces.extend(
                        [
                            [
                                first + longitude,
                                following + longitude,
                                following + right,
                            ],
                            [first + longitude, following + right, first + right],
                        ]
                    )
            last = 1 + (latitude_segments - 2) * longitude_segments
            for longitude in range(longitude_segments):
                following = (longitude + 1) % longitude_segments
                faces.append([last + longitude, south, last + following])
            return np.asarray(vertices)[np.asarray(faces)]
        raise ValueError(
            "selected visual groups must contain triangle meshes, boxes, or spheres"
        )

    body_nodes = {}
    joints = {}
    for body in range(root, model.nbody):
        parent = int(model.body_parentid[body])
        if body != root and parent not in body_nodes:
            continue
        index = len(document["nodes"])
        body_nodes[body] = index
        node = {"name": mj.mj_id2name(model, mj.mjtObj.mjOBJ_BODY, body) or f"body_{body}", "children": []}
        document["nodes"].append(node)
        if body != root:
            node["matrix"] = transform(model.body_pos[body], model.body_quat[body])
            document["nodes"][body_nodes[parent]]["children"].append(index)
        body_joints = list(range(int(model.body_jntadr[body]), int(model.body_jntadr[body] + model.body_jntnum[body])))
        if body == root:
            if any(model.jnt_type[j] != mj.mjtJoint.mjJNT_FREE for j in body_joints):
                raise ValueError("root motion must be supplied by base_pose")
        elif body_joints:
            if len(body_joints) != 1:
                raise ValueError("robot asset profile supports one scalar joint per body")
            j = body_joints[0]
            kind = {int(mj.mjtJoint.mjJNT_HINGE): "hinge", int(mj.mjtJoint.mjJNT_SLIDE): "slide"}.get(int(model.jnt_type[j]))
            if kind is None:
                raise ValueError("robot asset profile supports hinge and slide joints only")
            name = mj.mj_id2name(model, mj.mjtObj.mjOBJ_JOINT, j)
            joints[name] = {
                "name": name, "node": index, "type": kind,
                "axis": (basis @ model.jnt_axis[j]).tolist(),
                "pivot": (basis @ model.jnt_pos[j]).tolist(),
                "reference": float(model.qpos0[model.jnt_qposadr[j]]),
            }
        for geom in range(int(model.body_geomadr[body]), int(model.body_geomadr[body] + model.body_geomnum[body])):
            if int(model.geom_group[geom]) not in visual_groups:
                continue
            triangles = geom_triangles(geom) @ basis.T
            normals = np.cross(triangles[:, 1] - triangles[:, 0], triangles[:, 2] - triangles[:, 0])
            lengths = np.linalg.norm(normals, axis=1)
            keep = lengths > 1e-12
            triangles = triangles[keep]
            normals = normals[keep] / lengths[keep, None]
            if not len(triangles):
                continue
            material_id = int(model.geom_matid[geom])
            rgba = model.mat_rgba[material_id] if material_id >= 0 else model.geom_rgba[geom]
            material = len(document["materials"])
            document["materials"].append({"pbrMetallicRoughness": {
                "baseColorFactor": np.clip(rgba, 0, 1).tolist(), "metallicFactor": 0.0, "roughnessFactor": 0.75,
            }})
            mesh = len(document["meshes"])
            document["meshes"].append({"primitives": [{"attributes": {
                "POSITION": accessor(triangles), "NORMAL": accessor(np.repeat(normals, 3, axis=0)),
            }, "material": material, "mode": 4}]})
            visual = len(document["nodes"])
            document["nodes"].append({"name": f"visual_{geom}", "mesh": mesh,
                                      "matrix": transform(model.geom_pos[geom], model.geom_quat[geom])})
            node["children"].append(visual)
    if set(names) != set(joints):
        raise ValueError("joint_names must exactly cover all scalar joints under root_body")
    if not document["meshes"]:
        raise ValueError("selected visual groups contain no meshes")
    document["buffers"] = [{"byteLength": len(binary)}]
    document["extras"] = {"operator_robot": {
        "schema": ROBOT_ASSET_SCHEMA, "coordinate_space": "xr_y_up", "root": 0,
        "joints": [joints[name] for name in names],
    }}
    encoded = json.dumps(document, allow_nan=False, separators=(",", ":")).encode()
    encoded += b" " * (-len(encoded) % 4)
    binary += b"\0" * (-len(binary) % 4)
    data = (struct.pack("<III", 0x46546C67, 2, 28 + len(encoded) + len(binary))
            + struct.pack("<II", len(encoded), 0x4E4F534A) + encoded
            + struct.pack("<II", len(binary), 0x004E4942) + binary)
    return RobotModelAsset(data)
