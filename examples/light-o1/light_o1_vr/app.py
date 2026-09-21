"""Light-O1 text-to-motion on a Unitree G1, shown in Operator XR.

Host pipeline per prompt: Light-O1 (text -> 20 FPS human action) ->
GEAR-SONIC low-latency policy tracking that action on a G1 in MuJoCo ->
actual simulated joint angles and floating-base pose streamed to the headset's
``robot_model``. The headset downloads the host's G1 asset and renders it; no
policy, physics or robot command runs on the device or on a real robot.
"""
from __future__ import annotations

import argparse
import json
import math
import os
from pathlib import Path
import queue
import sys
import threading
import time

from .controller import MotionSession, Phase
from .generator import ControlServerClient, FileGenerator, GenerationError, GpuApiClient
from .light_o1 import LightO1
from .presentation import blueprint
from .prompts import DEFAULT_PROMPTS, load_prompts
from .rollout import SonicRollout, Trajectory, idle_state

DEFAULT_LIGHT_O1 = os.environ.get("LIGHT_O1_ROOT", "~/ws/light-o1/Light-O1")
DEFAULT_CHECKPOINT = os.environ.get("SONIC_CHECKPOINT", "~/ws/light-o1/models/GEAR-SONIC/low_latency")
DEFAULT_URLS = {"control": "http://127.0.0.1:8090", "api": "http://127.0.0.1:8030"}
SESSION_NAME = "Light-O1 G1"


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--light-o1", type=Path, default=Path(DEFAULT_LIGHT_O1),
                        help="Light-O1 checkout (examples/sonic + light_deploy); $LIGHT_O1_ROOT")
    parser.add_argument("--sonic-checkpoint", type=Path, default=Path(DEFAULT_CHECKPOINT),
                        help="GEAR-SONIC low-latency ONNX encoder/decoder directory; $SONIC_CHECKPOINT")
    parser.add_argument("--generator", choices=("control", "api", "file"), default="control",
                        help="control: light-deploy-server /api/generations (default); "
                             "api: light-deploy-api /api/generate; file: saved human_action .npy files")
    parser.add_argument("--url", default=None, help="Light-O1 service URL (default depends on --generator)")
    parser.add_argument("--actions-dir", type=Path, default=None,
                        help="directory of <name>.npy or <name>/human_action.npy for --generator file")
    parser.add_argument("--prompts", type=Path, default=None, help="prompt library, one per line")
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument("--thinking", action=argparse.BooleanOptionalAction, default=True,
                        help="ask Light-O1 to reason before acting (default on)")
    parser.add_argument("--replan-frames", type=int, default=8, choices=range(1, 41), metavar="1..40")
    parser.add_argument("--lookahead-frames", type=int, default=12, choices=range(1, 41), metavar="1..40")
    parser.add_argument("--headset-ip", action="append", default=[], help="unicast discovery target (repeatable)")
    parser.add_argument("--asset-port", type=int, default=63904)
    parser.add_argument("--distance", type=float, default=2.5, help="metres in front of the wearer")
    parser.add_argument("--face-user", action=argparse.BooleanOptionalAction, default=True,
                        help="turn the G1 towards the wearer (default) instead of facing away")
    parser.add_argument("--prebuffer", type=float, default=0.5, help="seconds of rollout to buffer before playing")
    parser.add_argument("--stdin", action=argparse.BooleanOptionalAction, default=True,
                        help="read free-text prompts from the terminal, one per line (default on)")
    parser.add_argument("--batch", metavar="PROMPT", default=None,
                        help="no XR: generate PROMPT, simulate it, print metrics, then exit")
    parser.add_argument("--output", type=Path, default=None, help="with --batch: save the trajectory .npz here")
    args = parser.parse_args(argv)
    if args.url is None:
        args.url = DEFAULT_URLS.get(args.generator)
    if args.generator == "file" and args.actions_dir is None:
        parser.error("--generator file needs --actions-dir")
    if args.generator != "file" and not str(args.url).startswith(("http://", "https://")):
        parser.error("--url must start with http:// or https://")
    if not 1 <= args.asset_port <= 65535:
        parser.error("asset-port must be in 1..65535")
    if any(not math.isfinite(v) or v <= 0 for v in (args.distance,)) or not math.isfinite(args.prebuffer) \
            or args.prebuffer < 0:
        parser.error("distance must be finite and positive; prebuffer must be finite and non-negative")
    if not 0 <= args.seed <= 2_147_483_647:
        parser.error("seed must be within 0..2147483647")
    if args.output is not None and args.batch is None:
        parser.error("--output requires --batch")
    return args


def make_generator(args):
    if args.generator == "file":
        return FileGenerator(args.actions_dir)
    if args.generator == "api":
        return GpuApiClient(args.url)
    return ControlServerClient(args.url)


def prompt_library(args, generator) -> list[str]:
    if args.prompts is not None:
        return load_prompts(args.prompts)
    if isinstance(generator, FileGenerator):
        return generator.prompts
    return list(DEFAULT_PROMPTS)


class StdinPrompts(threading.Thread):
    """Forward typed lines to the main loop; exits quietly at EOF or without a terminal."""

    def __init__(self, stream=None):
        super().__init__(name="light-o1-stdin", daemon=True)
        self.stream = sys.stdin if stream is None else stream
        self.lines: queue.Queue[str] = queue.Queue()

    def run(self) -> None:
        try:
            for line in self.stream:
                text = line.strip()
                if text:
                    self.lines.put(text)
        except (OSError, ValueError):
            return

    def drain(self) -> list[str]:
        result = []
        while True:
            try:
                result.append(self.lines.get_nowait())
            except queue.Empty:
                return result


def run_batch(args, light_o1: LightO1, simulator, generator) -> Trajectory:
    print(f"Generating with {generator.source}: {args.batch!r}", flush=True)
    started = time.monotonic()
    generated = generator.generate(args.batch, seed=args.seed, thinking=args.thinking)
    print(f"Action: {generated.frames} frames ({generated.seconds:.1f}s) in {time.monotonic() - started:.1f}s",
          flush=True)
    if generated.reasoning:
        print(f"Reasoning: {generated.reasoning.strip()[:600]}", flush=True)
    trajectory = Trajectory(light_o1.joint_names, prompt=generated.prompt, reasoning=generated.reasoning,
                            planned_s=generated.seconds, control_hz=light_o1.control_hz)
    started = time.monotonic()
    SonicRollout(light_o1, simulator, light_o1.to_reference(generated.action), trajectory,
                 replan_frames=args.replan_frames, lookahead_frames=args.lookahead_frames).run()
    summary = {**trajectory.summary(), "wall_s": round(time.monotonic() - started, 2)}
    if args.output is not None:
        summary["output"] = str(trajectory.save(args.output))
    print(json.dumps(summary), flush=True)
    if trajectory.error:
        raise SystemExit(f"Sonic rollout failed: {trajectory.error}")
    return trajectory


def run(args) -> None:
    light_o1 = LightO1(args.light_o1)
    simulator = light_o1.simulator(args.sonic_checkpoint)
    generator = make_generator(args)
    if args.batch is not None:
        run_batch(args, light_o1, simulator, generator)
        return
    from pyoperator import BridgeConfig, RobotAssetServer, XrSession
    from pyoperator.mujoco_asset import from_mujoco

    prompts = prompt_library(args, generator)
    asset = from_mujoco(simulator.model, root_body="pelvis", joint_names=light_o1.joint_names)
    session = MotionSession(
        generator=generator, light_o1=light_o1, simulator=simulator, prompts=prompts,
        idle_state=idle_state(simulator), control_hz=light_o1.control_hz,
        replan_frames=args.replan_frames, lookahead_frames=args.lookahead_frames,
        prebuffer_s=args.prebuffer, seed=args.seed, thinking=args.thinking)
    if not generator.ready():
        print(f"WARNING: Light-O1 ({generator.source}) is not ready; Generate will report the error", flush=True)
    config = BridgeConfig(name=SESSION_NAME, discovery_unicast_targets=tuple(args.headset_ip),
                          streams=("head", "controllers"))
    typed = StdinPrompts() if args.stdin else None
    with RobotAssetServer([asset], port=args.asset_port) as assets, XrSession(config) as xr:
        xr.blueprint.set_blueprint(blueprint(asset, assets.port, distance=args.distance, face_user=args.face_user))
        print(f"Select Outside Robot > Operator > {SESSION_NAME}", flush=True)
        print(f"Robot asset: {asset.sha256} ({len(asset.data)} bytes), port {assets.port}", flush=True)
        print(f"Prompts: {len(prompts)} (left menu: Prompt Next/Prev, Generate/Stop, Replay); "
              f"type a prompt here + Enter to run it; Ctrl-C: stop", flush=True)
        if typed is not None:
            typed.start()
        period = 1.0 / light_o1.control_hz
        deadline = next_report = time.monotonic()
        try:
            while xr.is_running:
                if typed is not None:
                    for text in typed.drain():
                        print(f"Typed prompt: {session.submit(text)!r}", flush=True)
                for _ in range(16):  # bounded per tick; events are rare
                    try:
                        event = xr.blueprint.poll_event(timeout=0)
                    except ValueError as exc:
                        print(f"Ignored invalid Blueprint event: {exc}", flush=True)
                        continue
                    if event is None or not session.handle_event(event):
                        break
                now = time.monotonic()
                xr.blueprint.update(session.tick(now))
                if now >= next_report:
                    print(f"[{session.phase.value}] {session.status_line(now)} | "
                          f"connected={xr.stats().connected}", flush=True)
                    next_report = now + 2
                deadline += period
                delay = deadline - time.monotonic()
                if delay > 0:
                    time.sleep(delay)
                else:
                    deadline = time.monotonic()  # Never burst queued ticks after a stall.
        finally:
            session.close()
            xr.blueprint.clear()


def main(argv=None) -> None:
    args = parse_args(argv)
    try:
        run(args)
    except KeyboardInterrupt:
        print("Light-O1 G1 stopped")
    except (FileNotFoundError, GenerationError) as exc:
        raise SystemExit(f"error: {exc}") from exc
    if args.batch is None:
        print("Light-O1 G1 session ended")
