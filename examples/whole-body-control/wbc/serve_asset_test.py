"""Serve the actual host G1 model for on-headset Blueprint asset integration tests."""
import argparse
import json
from pathlib import Path
import threading

import mujoco
from pyoperator.mujoco_asset import from_mujoco
from pyoperator import RobotAssetServer


def scalar_joint_names(model) -> list[str]:
    """Return named MuJoCo hinge/slide joints across enum binding versions."""
    scalar_types = {
        int(mujoco.mjtJoint.mjJNT_HINGE),
        int(mujoco.mjtJoint.mjJNT_SLIDE),
    }
    return [
        model.joint(joint).name
        for joint in range(model.njnt)
        if int(model.jnt_type[joint]) in scalar_types
    ]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--config", type=Path, required=True)
    args = parser.parse_args()
    model = mujoco.MjModel.from_xml_path(str(args.model.resolve()))
    names = scalar_joint_names(model)
    asset = from_mujoco(model, root_body="pelvis", joint_names=names)
    with RobotAssetServer([asset], host="127.0.0.1") as server:
        component = asset.component("g1", asset_port=server.port,
            joint_positions_binding="q", base_pose_binding="base", sample_binding="sample")
        args.config.write_text(json.dumps({"properties": dict(component.properties),
                                          "expected_joint_names": names}))
        print(f"Serving real G1: port={server.port} bytes={len(asset.data)} sha256={asset.sha256}", flush=True)
        try:
            threading.Event().wait()
        except KeyboardInterrupt:
            print(f"Asset requests: {server.requests}", flush=True)


if __name__ == "__main__":
    main()
