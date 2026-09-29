"""Drive the REAL VROperator plugin against the REAL Rust driver.

Same CLI shape as stub_vr_plugin.py, but this is not a stub: it is the shipped
lerobot_teleoperator_vr_operator plugin, doing real placo IK. Used by
`tests/real_plugin_conformance.rs` to catch the Rust and Python halves of the
link protocol drifting apart -- something neither side's own tests can see,
since each tests against a model of the other.

No hardware or headset needed: this drives the teleoperator directly rather
than through `lerobot-teleoperate`, so no follower is involved.
"""
import argparse, sys, time
from lerobot_teleoperator_vr_operator import VROperator, VROperatorConfig

p = argparse.ArgumentParser()
p.add_argument("--endpoint", required=True)
p.add_argument("--urdf", required=True)
a = p.parse_args()

cfg = VROperatorConfig(endpoint=a.endpoint, urdf_path=a.urdf)
t = VROperator(cfg)
t.connect()
print("CONNECTED", flush=True)
deadline = time.time() + 25
while time.time() < deadline:
    act = t.get_action()
    if act:
        print("ACTION " + " ".join(f"{k}={v:.3f}" for k, v in sorted(act.items())), flush=True)
    time.sleep(0.02)
t.disconnect()
