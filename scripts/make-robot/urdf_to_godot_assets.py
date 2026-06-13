#!/usr/bin/env python3
"""Convert robot URDFs into Godot-facing robot assets."""

from __future__ import annotations

import argparse
import copy
import math
import shutil
import sys
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Tuple

import numpy as np


@dataclass
class Visual:
    mesh_filename: str
    origin: np.ndarray
    scale: np.ndarray
    color: Optional[Tuple[int, int, int, int]] = None


@dataclass
class Link:
    name: str
    visuals: List[Visual] = field(default_factory=list)


@dataclass
class Joint:
    name: str
    joint_type: str
    parent: str
    child: str
    origin: np.ndarray
    xyz: np.ndarray
    rpy: np.ndarray
    axis: np.ndarray
    lower: Optional[float]
    upper: Optional[float]
    effort: Optional[float]
    velocity: Optional[float]


AXIS_URDF_TO_GODOT = np.array(
    [
        [0.0, -1.0, 0.0, 0.0],
        [0.0, 0.0, 1.0, 0.0],
        [-1.0, 0.0, 0.0, 0.0],
        [0.0, 0.0, 0.0, 1.0],
    ],
    dtype=float,
)
AXIS_GODOT_TO_URDF = np.linalg.inv(AXIS_URDF_TO_GODOT)
URDF_NATIVE_MESH_SUFFIXES = {".dae", ".stl"}


def parse_vec(text: Optional[str], default: Iterable[float]) -> np.ndarray:
    if text is None or not text.strip():
        return np.array(list(default), dtype=float)
    return np.array([float(part) for part in text.split()], dtype=float)


def rotation_from_rpy(rpy: np.ndarray) -> np.ndarray:
    roll, pitch, yaw = rpy
    cr, sr = math.cos(roll), math.sin(roll)
    cp, sp = math.cos(pitch), math.sin(pitch)
    cy, sy = math.cos(yaw), math.sin(yaw)

    rx = np.array([[1, 0, 0], [0, cr, -sr], [0, sr, cr]], dtype=float)
    ry = np.array([[cp, 0, sp], [0, 1, 0], [-sp, 0, cp]], dtype=float)
    rz = np.array([[cy, -sy, 0], [sy, cy, 0], [0, 0, 1]], dtype=float)
    return rz @ ry @ rx


def transform_from_xyz_rpy(xyz: np.ndarray, rpy: np.ndarray) -> np.ndarray:
    matrix = np.eye(4, dtype=float)
    matrix[:3, :3] = rotation_from_rpy(rpy)
    matrix[:3, 3] = xyz
    return matrix


def transform_from_origin(origin: Optional[ET.Element]) -> Tuple[np.ndarray, np.ndarray, np.ndarray]:
    xyz = parse_vec(origin.get("xyz") if origin is not None else None, (0.0, 0.0, 0.0))
    rpy = parse_vec(origin.get("rpy") if origin is not None else None, (0.0, 0.0, 0.0))
    return transform_from_xyz_rpy(xyz, rpy), xyz, rpy


def godot_transform(urdf_transform: np.ndarray) -> np.ndarray:
    return AXIS_URDF_TO_GODOT @ urdf_transform @ AXIS_GODOT_TO_URDF


def matrix_to_quat_wxyz(matrix: np.ndarray) -> Tuple[float, float, float, float]:
    m = matrix[:3, :3]
    trace = float(np.trace(m))
    if trace > 0.0:
        s = math.sqrt(trace + 1.0) * 2.0
        w = 0.25 * s
        x = (m[2, 1] - m[1, 2]) / s
        y = (m[0, 2] - m[2, 0]) / s
        z = (m[1, 0] - m[0, 1]) / s
    elif m[0, 0] > m[1, 1] and m[0, 0] > m[2, 2]:
        s = math.sqrt(1.0 + m[0, 0] - m[1, 1] - m[2, 2]) * 2.0
        w = (m[2, 1] - m[1, 2]) / s
        x = 0.25 * s
        y = (m[0, 1] + m[1, 0]) / s
        z = (m[0, 2] + m[2, 0]) / s
    elif m[1, 1] > m[2, 2]:
        s = math.sqrt(1.0 + m[1, 1] - m[0, 0] - m[2, 2]) * 2.0
        w = (m[0, 2] - m[2, 0]) / s
        x = (m[0, 1] + m[1, 0]) / s
        y = 0.25 * s
        z = (m[1, 2] + m[2, 1]) / s
    else:
        s = math.sqrt(1.0 + m[2, 2] - m[0, 0] - m[1, 1]) * 2.0
        w = (m[1, 0] - m[0, 1]) / s
        x = (m[0, 2] + m[2, 0]) / s
        y = (m[1, 2] + m[2, 1]) / s
        z = 0.25 * s
    quat = np.array([w, x, y, z], dtype=float)
    norm = float(np.linalg.norm(quat))
    if norm > 0.0:
        quat /= norm
    return tuple(float(v) for v in quat)


def fmt_float(value: float) -> str:
    if abs(value) < 1e-12:
        value = 0.0
    return ("%.10g" % value).rstrip("0").rstrip(".") if "." in ("%.10g" % value) else "%.10g" % value


def fmt_vec(values: Iterable[float]) -> str:
    return " ".join(fmt_float(float(value)) for value in values)


def parse_robot(urdf_path: Path) -> Tuple[ET.ElementTree, Dict[str, Link], List[Joint]]:
    tree = ET.parse(urdf_path)
    root = tree.getroot()
    links: Dict[str, Link] = {}
    joints: List[Joint] = []

    for link_el in root.findall("link"):
        name = link_el.get("name")
        if not name:
            continue
        link = Link(name=name)
        for visual_el in link_el.findall("visual"):
            mesh_el = visual_el.find("geometry/mesh")
            if mesh_el is None or not mesh_el.get("filename"):
                continue
            origin, _, _ = transform_from_origin(visual_el.find("origin"))
            scale = parse_vec(mesh_el.get("scale"), (1.0, 1.0, 1.0))
            color = None
            color_el = visual_el.find("material/color")
            if color_el is not None and color_el.get("rgba"):
                rgba = [max(0, min(255, int(round(float(v) * 255.0)))) for v in color_el.get("rgba", "").split()]
                if len(rgba) == 4:
                    color = tuple(rgba)  # type: ignore[assignment]
            link.visuals.append(
                Visual(
                    mesh_filename=mesh_el.get("filename", ""),
                    origin=origin,
                    scale=scale,
                    color=color,
                )
            )
        links[name] = link

    for joint_el in root.findall("joint"):
        name = joint_el.get("name")
        parent_el = joint_el.find("parent")
        child_el = joint_el.find("child")
        if not name or parent_el is None or child_el is None:
            continue
        parent = parent_el.get("link", "")
        child = child_el.get("link", "")
        if not parent or not child:
            continue
        origin, xyz, rpy = transform_from_origin(joint_el.find("origin"))
        axis_el = joint_el.find("axis")
        limit_el = joint_el.find("limit")
        joints.append(
            Joint(
                name=name,
                joint_type=joint_el.get("type", "fixed"),
                parent=parent,
                child=child,
                origin=origin,
                xyz=xyz,
                rpy=rpy,
                axis=parse_vec(axis_el.get("xyz") if axis_el is not None else None, (1.0, 0.0, 0.0)),
                lower=float(limit_el.get("lower")) if limit_el is not None and limit_el.get("lower") else None,
                upper=float(limit_el.get("upper")) if limit_el is not None and limit_el.get("upper") else None,
                effort=float(limit_el.get("effort")) if limit_el is not None and limit_el.get("effort") else None,
                velocity=float(limit_el.get("velocity")) if limit_el is not None and limit_el.get("velocity") else None,
            )
        )

    return tree, links, joints


def mesh_output_key(filename: str, resolved_path: Path, source_label: str) -> Path:
    normalized = filename.replace("\\", "/")
    if normalized.startswith("package://"):
        normalized = normalized[len("package://") :]
        parts = normalized.split("/", 1)
        normalized = parts[1] if len(parts) == 2 else parts[0]
    path_parts = [part for part in normalized.split("/") if part not in ("", ".")]
    had_parent = any(part == ".." for part in path_parts)
    clean_parts = [part for part in path_parts if part != ".."]
    if not clean_parts:
        clean_parts = [resolved_path.name]
    if source_label and not had_parent:
        clean_parts = [source_label] + clean_parts
    return Path(*clean_parts)


def write_urdf_copy(
    tree: ET.ElementTree,
    robot_name: str,
    output_path: Path,
    source_dir: Path,
    mesh_copy_root: Optional[Path],
    mesh_reference_prefix: Optional[str],
    mesh_source_label: str,
) -> Dict[str, int]:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    copied = copy.deepcopy(tree)
    copied.getroot().set("name", robot_name)
    copied_meshes = 0
    converted_meshes = 0
    missing_meshes = 0

    if mesh_copy_root is not None:
        mesh_copy_root.mkdir(parents=True, exist_ok=True)
        reference_prefix = (mesh_reference_prefix or mesh_copy_root.name).strip("/")
        copied_paths = set()
        trimesh = None
        for mesh_el in copied.getroot().findall(".//mesh"):
            filename = mesh_el.get("filename")
            if not filename:
                continue
            source_mesh = resolve_mesh(source_dir, filename)
            if not source_mesh.exists():
                print(f"[make-robot] warning: missing mesh {filename}", file=sys.stderr)
                missing_meshes += 1
                continue
            convert_to_stl = source_mesh.suffix.lower() not in URDF_NATIVE_MESH_SUFFIXES
            key = mesh_output_key(filename, source_mesh, mesh_source_label)
            if convert_to_stl:
                key = key.with_suffix(".stl")
            target = mesh_copy_root / key
            target.parent.mkdir(parents=True, exist_ok=True)
            if target not in copied_paths:
                if convert_to_stl:
                    if trimesh is None:
                        trimesh = import_trimesh_modules()
                    try:
                        mesh = load_mesh(trimesh, source_mesh)
                        mesh.export(target)
                    except Exception as exc:  # noqa: BLE001
                        print(f"[make-robot] warning: failed to convert {source_mesh} to STL: {exc}", file=sys.stderr)
                        missing_meshes += 1
                        continue
                    converted_meshes += 1
                else:
                    shutil.copy2(source_mesh, target)
                    copied_meshes += 1
                copied_paths.add(target)
            mesh_el.set("filename", f"{reference_prefix}/{key.as_posix()}")

    ET.indent(copied, space="  ")
    copied.write(output_path, encoding="utf-8", xml_declaration=True)
    return {"copied_meshes": copied_meshes, "converted_meshes": converted_meshes, "missing_meshes": missing_meshes}


def children_by_parent(joints: Iterable[Joint]) -> Dict[str, List[Joint]]:
    out: Dict[str, List[Joint]] = {}
    for joint in joints:
        out.setdefault(joint.parent, []).append(joint)
    return out


def root_links(links: Dict[str, Link], joints: Iterable[Joint]) -> List[str]:
    children = {joint.child for joint in joints}
    roots = [name for name in links if name not in children]
    if "pelvis" in roots:
        return ["pelvis"] + [name for name in roots if name != "pelvis"]
    return roots


def resolve_mesh(source_dir: Path, filename: str) -> Path:
    normalized = filename
    if normalized.startswith("package://"):
        normalized = normalized[len("package://") :]
        parts = normalized.split("/", 1)
        normalized = parts[1] if len(parts) == 2 else parts[0]
    path = Path(normalized)
    if path.is_absolute():
        return path
    candidate = source_dir / path
    if candidate.exists():
        return candidate
    basename_candidate = source_dir / "meshes" / path.name
    if basename_candidate.exists():
        return basename_candidate
    return candidate


def import_trimesh_modules():
    try:
        import trimesh
    except ImportError as exc:
        raise SystemExit(
            "trimesh is required for mesh conversion and GLB export. Run the make-robot script "
            "so it can create the generator venv."
        ) from exc
    return trimesh


def load_mesh(trimesh_module, path: Path):
    loaded = trimesh_module.load(path, force="scene", process=False)
    if isinstance(loaded, trimesh_module.Scene):
        dumped = loaded.to_geometry() if hasattr(loaded, "to_geometry") else loaded.dump(concatenate=True)
        if isinstance(dumped, list):
            meshes = [mesh for mesh in dumped if not mesh.is_empty]
            if not meshes:
                raise ValueError("empty scene")
            return trimesh_module.util.concatenate(meshes)
        return dumped
    return loaded


def mesh_max_extent(mesh) -> float:
    if mesh.is_empty:
        return 0.0
    bounds = mesh.bounds
    return float(np.max(bounds[1] - bounds[0]))


def colorize_mesh(trimesh_module, mesh, color: Optional[Tuple[int, int, int, int]]) -> None:
    if len(mesh.vertices) == 0:
        return
    if color is None:
        color = (170, 185, 205, 255)
    colors = np.tile(np.array(color, dtype=np.uint8), (len(mesh.vertices), 1))
    mesh.visual = trimesh_module.visual.ColorVisuals(mesh, vertex_colors=colors)


def build_glb(source_dir: Path, links: Dict[str, Link], joints: List[Joint], output_path: Path) -> Dict[str, int]:
    trimesh = import_trimesh_modules()
    scene = trimesh.Scene()
    base_frame = scene.graph.base_frame
    child_joints = children_by_parent(joints)
    roots = root_links(links, joints)
    if not roots:
        raise SystemExit("URDF has no root link")

    for root in roots:
        scene.graph.update(frame_to=root, frame_from=base_frame, matrix=np.eye(4))

    def add_link_frames(parent: str) -> None:
        for joint in child_joints.get(parent, []):
            scene.graph.update(
                frame_to=joint.child,
                frame_from=joint.parent,
                matrix=godot_transform(joint.origin),
            )
            add_link_frames(joint.child)

    for root in roots:
        add_link_frames(root)

    mesh_count = 0
    skipped = 0
    for link in links.values():
        link_meshes = []
        for visual in link.visuals:
            mesh_path = resolve_mesh(source_dir, visual.mesh_filename)
            if not mesh_path.exists() and mesh_path.suffix.lower() == ".dae":
                mesh_path = mesh_path.with_suffix(".stl")
            if not mesh_path.exists():
                print(f"[make-robot] warning: missing mesh {visual.mesh_filename}", file=sys.stderr)
                skipped += 1
                continue
            try:
                mesh = load_mesh(trimesh, mesh_path)
            except Exception as exc:  # noqa: BLE001
                fallback = mesh_path.with_suffix(".stl")
                if fallback != mesh_path and fallback.exists():
                    mesh = load_mesh(trimesh, fallback)
                else:
                    print(f"[make-robot] warning: failed to load {mesh_path}: {exc}", file=sys.stderr)
                    skipped += 1
                    continue
            if mesh_path.suffix.lower() == ".dae" and mesh_max_extent(mesh) > 3.0:
                fallback = mesh_path.with_suffix(".stl")
                if fallback.exists():
                    print(
                        f"[make-robot] warning: {mesh_path.name} has extent {mesh_max_extent(mesh):.3f}m; using {fallback.name}",
                        file=sys.stderr,
                    )
                    mesh = load_mesh(trimesh, fallback)
            if mesh.is_empty:
                skipped += 1
                continue
            mesh = mesh.copy()
            scale = np.eye(4, dtype=float)
            scale[0, 0], scale[1, 1], scale[2, 2] = visual.scale
            mesh.apply_transform(AXIS_URDF_TO_GODOT @ visual.origin @ scale)
            colorize_mesh(trimesh, mesh, visual.color)
            link_meshes.append(mesh)

        if not link_meshes:
            continue
        combined = link_meshes[0] if len(link_meshes) == 1 else trimesh.util.concatenate(link_meshes)
        scene.add_geometry(
            combined,
            geom_name=f"{link.name}_visual",
            node_name=f"{link.name}_visual",
            parent_node_name=link.name,
            transform=np.eye(4),
        )
        mesh_count += 1

    if mesh_count == 0:
        raise SystemExit("no visual meshes were exported")

    output_path.parent.mkdir(parents=True, exist_ok=True)
    scene.export(output_path)
    return {"links": len(links), "mesh_nodes": mesh_count, "skipped_visuals": skipped}


def proxy_geom_size(link_name: str) -> Tuple[str, str]:
    name = link_name.lower()
    if "pelvis" in name:
        return "box", "0.11 0.08 0.06"
    if "torso" in name:
        return "box", "0.11 0.07 0.18"
    if "head" in name:
        return "sphere", "0.055"
    if "hip" in name or "knee" in name:
        return "sphere", "0.045"
    if "ankle" in name:
        return "sphere", "0.035"
    if "shoulder" in name or "elbow" in name:
        return "sphere", "0.035"
    if "wrist" in name:
        return "sphere", "0.025"
    if "thumb" in name or "index" in name or "middle" in name or "ring" in name or "pinky" in name:
        return "sphere", "0.012"
    if "hand" in name:
        return "sphere", "0.03"
    return "sphere", "0.025"


def add_proxy_geom(body: ET.Element, link_name: str) -> None:
    geom_type, size = proxy_geom_size(link_name)
    ET.SubElement(
        body,
        "geom",
        {
            "name": f"{link_name}_proxy",
            "type": geom_type,
            "size": size,
            "rgba": "0.55 0.65 0.75 0.55",
        },
    )


def add_body_tree(
    parent_body: ET.Element,
    link_name: str,
    child_joints: Dict[str, List[Joint]],
    is_root: bool,
    actuated_joints: List[Joint],
) -> None:
    attrs = {"name": link_name}
    if is_root:
        attrs["pos"] = "0 0 1.05"
    body = ET.SubElement(parent_body, "body", attrs)
    if is_root:
        ET.SubElement(body, "freejoint", {"name": f"{link_name}_freejoint"})
    add_proxy_geom(body, link_name)

    for joint in child_joints.get(link_name, []):
        quat = matrix_to_quat_wxyz(joint.origin)
        child_attrs = {
            "name": joint.child,
            "pos": fmt_vec(joint.xyz),
            "quat": fmt_vec(quat),
        }
        child_body = ET.SubElement(body, "body", child_attrs)
        if joint.joint_type not in ("fixed", "floating"):
            joint_attrs = {
                "name": joint.name,
                "type": "slide" if joint.joint_type == "prismatic" else "hinge",
                "axis": fmt_vec(joint.axis),
                "damping": "0.3",
                "armature": "0.01",
            }
            if joint.lower is not None and joint.upper is not None:
                joint_attrs["limited"] = "true"
                joint_attrs["range"] = fmt_vec((joint.lower, joint.upper))
            ET.SubElement(child_body, "joint", joint_attrs)
            actuated_joints.append(joint)
        add_proxy_geom(child_body, joint.child)
        for grandchild in child_joints.get(joint.child, []):
            add_body_tree_for_joint(child_body, grandchild, child_joints, actuated_joints)


def add_body_tree_for_joint(
    parent_body: ET.Element,
    joint: Joint,
    child_joints: Dict[str, List[Joint]],
    actuated_joints: List[Joint],
) -> None:
    quat = matrix_to_quat_wxyz(joint.origin)
    body = ET.SubElement(
        parent_body,
        "body",
        {
            "name": joint.child,
            "pos": fmt_vec(joint.xyz),
            "quat": fmt_vec(quat),
        },
    )
    if joint.joint_type not in ("fixed", "floating"):
        joint_attrs = {
            "name": joint.name,
            "type": "slide" if joint.joint_type == "prismatic" else "hinge",
            "axis": fmt_vec(joint.axis),
            "damping": "0.3",
            "armature": "0.01",
        }
        if joint.lower is not None and joint.upper is not None:
            joint_attrs["limited"] = "true"
            joint_attrs["range"] = fmt_vec((joint.lower, joint.upper))
        ET.SubElement(body, "joint", joint_attrs)
        actuated_joints.append(joint)
    add_proxy_geom(body, joint.child)
    for child in child_joints.get(joint.child, []):
        add_body_tree_for_joint(body, child, child_joints, actuated_joints)


def write_mjcf_proxy(robot_name: str, links: Dict[str, Link], joints: List[Joint], output_path: Path) -> None:
    child_joints = children_by_parent(joints)
    roots = root_links(links, joints)
    if not roots:
        raise SystemExit("URDF has no root link")

    mujoco = ET.Element("mujoco", {"model": robot_name})
    ET.SubElement(mujoco, "compiler", {"angle": "radian"})
    ET.SubElement(mujoco, "option", {"timestep": "0.008333333", "gravity": "0 0 -9.81"})
    default = ET.SubElement(mujoco, "default")
    ET.SubElement(default, "joint", {"damping": "0.3", "armature": "0.01"})
    ET.SubElement(default, "geom", {"friction": "0.8 0.01 0.001", "density": "250"})

    worldbody = ET.SubElement(mujoco, "worldbody")
    ET.SubElement(worldbody, "geom", {"name": "floor", "type": "plane", "size": "3 3 0.02", "rgba": "0.12 0.13 0.14 1"})
    actuated_joints: List[Joint] = []
    for root in roots:
        add_body_tree(worldbody, root, child_joints, True, actuated_joints)

    actuator = ET.SubElement(mujoco, "actuator")
    sensor = ET.SubElement(mujoco, "sensor")
    for joint in actuated_joints:
        low = joint.lower if joint.lower is not None else -1.0
        high = joint.upper if joint.upper is not None else 1.0
        if low == high:
            low, high = -1.0, 1.0
        ET.SubElement(
            actuator,
            "position",
            {
                "name": f"{joint.name}_position",
                "joint": joint.name,
                "kp": "15",
                "ctrlrange": fmt_vec((low, high)),
            },
        )
        ET.SubElement(sensor, "jointpos", {"name": f"{joint.name}_pos", "joint": joint.name})

    output_path.parent.mkdir(parents=True, exist_ok=True)
    ET.indent(mujoco, space="  ")
    ET.ElementTree(mujoco).write(output_path, encoding="utf-8", xml_declaration=True)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-dir", required=True, type=Path)
    parser.add_argument("--source-urdf", type=Path)
    parser.add_argument("--robot-name", required=True)
    parser.add_argument("--urdf-out", required=True, type=Path)
    parser.add_argument("--mjcf-out", required=True, type=Path)
    parser.add_argument("--glb-out", required=True, type=Path)
    parser.add_argument("--mesh-copy-root", type=Path)
    parser.add_argument("--mesh-reference-prefix")
    parser.add_argument("--mesh-source-label")
    parser.add_argument("--skip-glb", action="store_true")
    args = parser.parse_args()

    urdf_path = args.source_urdf if args.source_urdf is not None else args.source_dir / "H2_Plus.urdf"
    if not urdf_path.exists():
        raise SystemExit(f"missing source URDF: {urdf_path}")

    tree, links, joints = parse_robot(urdf_path)
    mesh_source_label = args.mesh_source_label if args.mesh_source_label is not None else args.source_dir.name
    stats = write_urdf_copy(
        tree,
        args.robot_name,
        args.urdf_out,
        args.source_dir,
        args.mesh_copy_root,
        args.mesh_reference_prefix,
        mesh_source_label,
    )
    write_mjcf_proxy(args.robot_name, links, joints, args.mjcf_out)

    stats.update({"links": len(links), "joints": len(joints)})
    if not args.skip_glb:
        stats.update(build_glb(args.source_dir, links, joints, args.glb_out))
    print(
        "[make-robot] generated %s links=%d joints=%d copied_meshes=%d converted_meshes=%d missing_meshes=%d glb=%s"
        % (
            args.robot_name,
            stats["links"],
            stats["joints"],
            stats["copied_meshes"],
            stats["converted_meshes"],
            stats["missing_meshes"],
            "skipped" if args.skip_glb else args.glb_out,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
