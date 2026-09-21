"""Export a compiled host MuJoCo model as a data-only articulated GLB.

Optional MuJoCo/numpy dependencies are imported only when exporting. This is
independent of Inside Robot and never reads/writes the XR checkout's assets.
The profile supports triangle meshes, boxes and spheres with safe PBR colors,
zero or more scalar hinge/slide joints (one per child body), and one externally
driven root pose. Zero-joint assets represent rigid scene objects.
"""
from __future__ import annotations

import json
import struct

from .robot_assets import RobotModelAsset, ROBOT_ASSET_SCHEMA


def from_mujoco(model, *, root_body: str, joint_names, visual_groups=(1,)) -> RobotModelAsset:
    import mujoco as mj
    import numpy as np

    names = tuple(joint_names)
    if len(set(names)) != len(names) or any(
        not isinstance(name, str) or not name for name in names
    ):
        raise ValueError("joint_names must contain unique nonempty names")
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
    texture_average_cache = {}

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

    def geom_rgba(geom):
        material_id = int(model.geom_matid[geom])
        rgba = np.asarray(
            model.mat_rgba[material_id]
            if material_id >= 0
            else model.geom_rgba[geom],
            dtype=float,
        ).copy()
        if material_id < 0 or not hasattr(model, "mat_texid"):
            return rgba
        try:
            rgb_role = int(mj.mjtTextureRole.mjTEXROLE_RGB)
            texture_id = int(model.mat_texid[material_id, rgb_role])
        except (AttributeError, IndexError, TypeError):
            return rgba
        if texture_id < 0:
            return rgba
        average = texture_average_cache.get(texture_id)
        if average is None:
            width = int(model.tex_width[texture_id])
            height = int(model.tex_height[texture_id])
            channels = int(model.tex_nchannel[texture_id])
            start = int(model.tex_adr[texture_id])
            end = start + width * height * channels
            pixels = np.asarray(model.tex_data[start:end], dtype=np.float32).reshape(
                -1, channels
            )
            # MuJoCo texture bytes are sRGB-encoded, but glTF baseColorFactor is
            # linear. Averaging in gamma space and writing the result straight
            # into a linear factor washes out mid-tones, so convert per texel
            # first and average in linear space.
            srgb = pixels[:, : min(3, channels)] / 255.0
            linear = np.where(
                srgb <= 0.04045,
                srgb / 12.92,
                np.power((srgb + 0.055) / 1.055, 2.4),
            )
            average = linear.mean(axis=0)
            if average.size == 1:
                average = np.repeat(average, 3)
            elif average.size == 2:
                average = np.asarray([average[0], average[0], average[0]])
            texture_average_cache[texture_id] = average
        rgba[:3] *= average[:3]
        return rgba

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
            # The root body's complete world transform is supplied through the
            # Blueprint base_pose binding. It may therefore be fixed, free, or
            # world-attached through scalar joints without duplicating that
            # motion in the asset articulation.
            pass
        elif body_joints:
            if len(body_joints) != 1:
                raise ValueError("robot asset profile supports one scalar joint per body")
            j = body_joints[0]
            kind = {int(mj.mjtJoint.mjJNT_HINGE): "hinge", int(mj.mjtJoint.mjJNT_SLIDE): "slide"}.get(int(model.jnt_type[j]))
            if kind is None:
                raise ValueError("robot asset profile supports hinge and slide joints only")
            name = mj.mj_id2name(model, mj.mjtObj.mjOBJ_JOINT, j)
            if not name:
                body_name = mj.mj_id2name(model, mj.mjtObj.mjOBJ_BODY, body) or f"body_{body}"
                raise ValueError(
                    f"scalar joint {j} on body {body_name!r} has no name; "
                    "name every articulated joint in the MJCF so it can be bound"
                )
            joints[name] = {
                "name": name, "node": index, "type": kind,
                "axis": (basis @ model.jnt_axis[j]).tolist(),
                "pivot": (basis @ model.jnt_pos[j]).tolist(),
                "reference": float(model.qpos0[model.jnt_qposadr[j]]),
            }
        for geom in range(int(model.body_geomadr[body]), int(model.body_geomadr[body] + model.body_geomnum[body])):
            if int(model.geom_group[geom]) not in visual_groups:
                continue
            rgba = geom_rgba(geom)
            if float(rgba[3]) <= 1e-6:
                continue
            triangles = geom_triangles(geom) @ basis.T
            normals = np.cross(triangles[:, 1] - triangles[:, 0], triangles[:, 2] - triangles[:, 0])
            lengths = np.linalg.norm(normals, axis=1)
            keep = lengths > 1e-12
            triangles = triangles[keep]
            normals = normals[keep] / lengths[keep, None]
            if not len(triangles):
                continue
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
        raise ValueError(
            "joint_names must exactly cover all scalar joints under root_body, "
            "excluding any joint on root_body itself (the root's world transform "
            "is supplied by the Blueprint base_pose binding); "
            f"expected {sorted(joints)}, got {sorted(names)}"
        )
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
