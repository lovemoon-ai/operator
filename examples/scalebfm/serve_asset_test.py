"""Serve the actual host G1 model for on-headset Blueprint asset integration tests."""
import argparse
import json
from pathlib import Path
import threading

import mujoco
from pyoperator.mujoco_asset import from_mujoco
from pyoperator import RobotAssetServer


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--config", type=Path, required=True)
    args = parser.parse_args()
    model = mujoco.MjModel.from_xml_path(str(args.model.resolve()))
    names = [model.joint(j).name for j in range(model.njnt)
             if model.jnt_type[j] in (mujoco.mjtJoint.mjJNT_HINGE, mujoco.mjtJoint.mjJNT_SLIDE)]
    asset = from_mujoco(model, root_body="pelvis", joint_names=names)
    with RobotAssetServer([asset], host="127.0.0.1") as server:
        component = asset.component("g1", asset_port=server.port,
            joint_positions_binding="q", base_pose_binding="base", sample_binding="sample")
        args.config.write_text(json.dumps({"properties": dict(component.properties)}))
        print(f"Serving real G1: port={server.port} bytes={len(asset.data)} sha256={asset.sha256}", flush=True)
        try:
            threading.Event().wait()
        except KeyboardInterrupt:
            print(f"Asset requests: {server.requests}", flush=True)


if __name__ == "__main__":
    main()
