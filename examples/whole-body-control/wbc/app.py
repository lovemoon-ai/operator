"""Unified host whole-body control: ScaleBFM or SONIC, rendered in Operator XR."""
import argparse
import math
import time

from operator_xr import BridgeConfig, XrSession, RobotAssetServer
from operator_xr.mujoco_asset import from_mujoco
from .desktop_viewer import DesktopViewer
from .loop import ControlLoop
from .presentation import blueprint
from .controls import HELP


def parse_args(argv=None, *, default_controller=None):
    selector = argparse.ArgumentParser(add_help=False)
    selector.add_argument("--controller", choices=("scalebfm", "sonic"), default=default_controller)
    choice, _ = selector.parse_known_args(argv)
    parser = argparse.ArgumentParser(description=__doc__, parents=[selector])
    if choice.controller == "scalebfm":
        from .controllers.scalebfm.runtime import add_policy_arguments
        add_policy_arguments(parser)
        parser.add_argument("--future-last", type=int, default=10, choices=range(5, 34), metavar="5..33")
        parser.add_argument("--tracking", choices=("local", "global"), default="global")
    elif choice.controller == "sonic":
        from .controllers.sonic.controller import add_arguments
        add_arguments(parser)
    parser.add_argument("--headset-ip", action="append", default=[])
    parser.add_argument("--asset-port", type=int, default=63904)
    parser.add_argument("--scale", type=float, default=None,
                        help="ScaleBFM displacement scale (default .75); official SONIC requires 1")
    parser.add_argument("--distance", type=float, default=2.)
    parser.add_argument("--tracking-timeout", type=float, default=.25)
    parser.add_argument("--viewer", action=argparse.BooleanOptionalAction, default=True)
    args = parser.parse_args(argv)
    if args.controller is None:
        parser.error("select --controller scalebfm or --controller sonic (then --help for its options)")
    if args.scale is None:
        args.scale = 1.0 if args.controller == "sonic" else .75
    if args.controller == "sonic" and args.scale != 1.0:
        parser.error("official SONIC does not scale human motion; --scale must be 1")
    if not 1 <= args.asset_port <= 65535:
        parser.error("asset-port must be in 1..65535")
    if any(not math.isfinite(v) or v <= 0 for v in (args.scale, args.distance, args.tracking_timeout)):
        parser.error("scale, distance, and tracking-timeout must be finite and positive")
    return args


def make_controller(args):
    if args.controller == "scalebfm":
        from .controllers.scalebfm.controller import ScaleBFMController
        return ScaleBFMController(args)
    from .controllers.sonic.controller import SonicController
    return SonicController(args)


def run(args):
    controller = make_controller(args)
    try:
        sim = controller.simulation
        asset = from_mujoco(sim.model, root_body="pelvis", joint_names=sim.joint_names)
        loop = ControlLoop(controller, args.tracking_timeout)
        config = BridgeConfig(name=controller.name, discovery_unicast_targets=tuple(args.headset_ip),
                              streams=("head", "controllers", "body"))
        with RobotAssetServer([asset], port=args.asset_port) as assets, \
                DesktopViewer(sim, enabled=args.viewer, title=controller.name) as desktop, XrSession(config) as session:
            session.blueprint.set_blueprint(blueprint(asset, assets.port, args.distance, controller.key))
            print(f"Select Outside Robot > Operator > {controller.name}", flush=True)
            print(f"Robot asset: {asset.sha256} ({len(asset.data)} bytes), port {assets.port}", flush=True)
            print(HELP + "; left Menu: connection/recenter; Ctrl-C: stop", flush=True)
            deadline = next_report = time.monotonic()
            try:
                while session.is_running and desktop.is_running():
                    now = time.monotonic()
                    state = loop.tick(session.latest(), session.stats().connected,
                                      session.blueprint.poll_event(timeout=0), now)
                    session.blueprint.update(state)
                    desktop.sync(loop.status)
                    if now >= next_report:
                        print(f"{loop.status} | XR frame={loop.frame_id} sim={sim.data.time:.2f}s", flush=True)
                        next_report = now + 2
                    deadline += controller.dt
                    delay = deadline - time.monotonic()
                    if delay > 0:
                        time.sleep(delay)
                    else:
                        deadline = time.monotonic()  # Never burst queued control ticks.
            finally:
                session.blueprint.clear()
    finally:
        if hasattr(controller, "close"):
            controller.close()


def main(argv=None, *, default_controller=None):
    try:
        run(parse_args(argv, default_controller=default_controller))
    except KeyboardInterrupt:
        print("Whole-body control stopped")
