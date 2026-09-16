#!/usr/bin/env python3
"""VR five-point ScaleBFM control of a host MuJoCo G1, displayed by Blueprint."""
from __future__ import annotations

import argparse
from collections import deque
from pathlib import Path
import time

from pyoperator import Blueprint, BlueprintComponent, BlueprintTransform, BridgeConfig, XrSession, RobotModelAsset, RobotAssetServer
from pyoperator.mujoco_asset import from_mujoco

from desktop_viewer import DesktopViewer
from runtime import Simulation, add_policy_arguments, policy_from_args
from tracking import Calibration, ReferenceBuffer, TrackingUnavailable, extract_five_points


def claim_reset_request(event, recent_requests: deque[str]) -> str:
    """Deduplicate remote gesture requests; acknowledgements echo this ID."""
    if event is None or event.action != "reset" or not isinstance(event.value, str) \
            or not event.value or event.value in recent_requests:
        return ""
    recent_requests.append(event.value)
    return event.value


def blueprint(asset: RobotModelAsset, asset_port: int, distance: float) -> Blueprint:
    return Blueprint(blueprint_id="example.scalebfm", components=(
        BlueprintComponent.ground_grid(
            "ground", placement_target="g1", visible_binding="g1.visible",
            transform=BlueprintTransform(position=(0, 0.002, -distance)),
            properties={"settings_label": "Ground grid", "size": 8.0, "spacing": 0.5},
        ),
        BlueprintComponent.model_lighting(
            "lighting", visible_binding="g1.visible",
            properties={"settings_label": "Robot lighting", "key_energy": 1.6, "fill_energy": 0.6},
        ),
        asset.component(
            "g1", asset_port=asset_port,
            joint_positions_binding="g1.joints", base_pose_binding="g1.base",
            sample_binding="g1.sample", visible_binding="g1.visible",
            transform=BlueprintTransform(position=(0, 0, -distance)),
        ),
        BlueprintComponent.input_binding(
            "reset", action="reset", hold_seconds=1.0, target_component="g1",
            available_binding="control.available", required_binding="control.reset_required",
            acknowledged_request_binding="control.reset_ack", success_binding="control.reset_success",
            message_binding="control.message",
        ),
    ))


def run(args: argparse.Namespace) -> None:
    policy = policy_from_args(args)
    print(f"ScaleBFM inference: backend={policy.backend} device={policy.device}", flush=True)
    sim = Simulation(args.model, policy.metadata)
    asset = from_mujoco(sim.model, root_body="pelvis", joint_names=sim.joint_names)
    reference = ReferenceBuffer(args.future_last)
    calibration = None
    frame_id, source_timestamp, sample = -1, 0, 0
    last_body_time = 0.0
    status = "Match the G1 pose; hold both triggers for 1 second to reset"
    reset_ack, reset_success = "", False
    recent_resets: deque[str] = deque(maxlen=128)
    was_connected = False
    # Fail incompatible models before starting the XR session.
    neutral_pos, neutral_rot = sim.reference_pose()
    import numpy as np
    policy.infer(sim.inputs(np.repeat(neutral_pos[None], 6, axis=0),
                            np.repeat(neutral_rot[None], 6, axis=0), reference.offsets,
                            args.tracking == "local"))
    config = BridgeConfig(name="ScaleBFM G1", discovery_unicast_targets=tuple(args.headset_ip))
    with RobotAssetServer([asset], port=args.asset_port) as assets, \
            DesktopViewer(sim, enabled=args.viewer) as desktop, XrSession(config) as session:
        session.blueprint.set_blueprint(blueprint(asset, assets.port, args.distance))
        print(f"Robot asset: {asset.sha256} ({len(asset.data)} bytes), port {assets.port}", flush=True)
        if args.viewer:
            print("Desktop MuJoCo viewer opened; closing its window stops this example.", flush=True)
        print("Select Outside Robot > Operator > ScaleBFM G1 on the headset.", flush=True)
        print("Left Menu: connect/disconnect or recenter the displayed robot.", flush=True)
        print("Reset: hold both triggers for 1 second; keep pose until confirmation vibration.", flush=True)
        print(f"Reference delay: {args.future_last * 20} ms; tracking: {args.tracking}", flush=True)
        deadline = time.monotonic()
        next_report = deadline
        try:
            while session.is_running and desktop.is_running():
                now = time.monotonic()
                connected = session.stats().connected
                if was_connected and not connected:
                    calibration = None
                    reference = ReferenceBuffer(args.future_last)
                    sim.reset()
                    last_body_time = 0.0
                    status = "Disconnected; reset after reconnecting"
                was_connected = connected
                event = session.blueprint.poll_event(timeout=0)
                reset_id = claim_reset_request(event, recent_resets)
                reset = bool(reset_id)
                frame = session.latest()
                fresh = None
                if frame is not None and frame.frame_id != frame_id:
                    frame_id = frame.frame_id
                    try:
                        fresh = extract_five_points(frame)
                        if source_timestamp and fresh.timestamp_ns < source_timestamp:
                            calibration = None
                            status = "Tracking clock changed; hold both triggers to reset"
                        if fresh.timestamp_ns != source_timestamp:
                            source_timestamp = fresh.timestamp_ns
                            last_body_time = now
                        else:
                            fresh = None
                    except TrackingUnavailable as exc:
                        status = str(exc) + "; restore tracking and reset"
                        calibration = None
                        last_body_time = 0.0
                if reset:
                    reset_ack = reset_id
                    reset_success = False
                    calibration = None
                    reference = ReferenceBuffer(args.future_last)
                    sim.reset()
                    if connected and frame is not None and now - last_body_time <= args.tracking_timeout:
                        try:
                            fresh = extract_five_points(frame)
                            calibration = Calibration(fresh, *sim.reference_pose(), sim.body_names, args.scale)
                            reset_success = True
                            status = "Buffering five-point targets"
                        except TrackingUnavailable as exc:
                            status = str(exc)
                    else:
                        status = "Reset failed: no fresh full-body pose"
                if calibration is not None and now - last_body_time > args.tracking_timeout:
                    calibration = None
                    status = "Body tracking timed out; restore tracking and reset"
                if calibration is None and fresh is not None and not reset:
                    status = "Tracking ready; hold both triggers for 1 second to reset"
                if calibration is not None and fresh is not None:
                    reference.append(fresh.timestamp_ns, *calibration.apply(fresh))
                targets = reference.targets() if calibration is not None else None
                if targets is not None:
                    target, action = policy.infer(sim.inputs(*targets, reference.offsets, args.tracking == "local"))
                    sim.step(target, action)
                    status = "Running: pelvis + hands + feet → G1 (29 DoF)"
                # A paused simulation still has a valid robot pose. Keep it
                # visible for alignment/recentering; controller lamps indicate
                # that input is paused and reset is required. Silence from the
                # service itself still trips the XR renderer's stale timeout.
                sample += 1
                session.blueprint.update({
                    **sim.blueprint_state(), "g1.sample": sample,
                    "g1.visible": True,
                    "control.message": status,
                    "control.available": connected and last_body_time > 0.0 and now - last_body_time <= args.tracking_timeout,
                    "control.reset_required": calibration is None,
                    "control.reset_ack": reset_ack,
                    "control.reset_success": reset_success,
                })
                desktop.sync(status)
                if now >= next_report:
                    print(f"{status} | XR frame={frame_id} sim={sim.data.time:.2f}s", flush=True)
                    next_report = now + 2
                deadline += sim.DT
                delay = deadline - time.monotonic()
                if delay > 0:
                    time.sleep(delay)
                else:
                    # Do not build a backlog or burst multiple physics ticks.
                    deadline = time.monotonic()
        finally:
            session.blueprint.clear()


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    add_policy_arguments(parser)
    parser.add_argument("--headset-ip", action="append", default=[], help="Optional unicast discovery address")
    parser.add_argument("--asset-port", type=int, default=63904, help="HTTP port for robot-owned visual assets")
    parser.add_argument("--scale", type=float, default=0.75, help="Human-to-G1 motion scale")
    parser.add_argument("--distance", type=float, default=2.0, help="Display offset along XR -Z, metres")
    parser.add_argument("--future-last", type=int, default=10, choices=range(5, 34), metavar="5..33")
    parser.add_argument("--tracking", choices=("local", "global"), default="global")
    parser.add_argument("--tracking-timeout", type=float, default=0.25)
    parser.add_argument("--viewer", action=argparse.BooleanOptionalAction, default=True,
                        help="Show the desktop MuJoCo viewer (default); use --no-viewer on a headless host")
    args = parser.parse_args(argv)
    if not 1 <= args.asset_port <= 65535:
        parser.error("asset-port must be in 1..65535")
    import math
    if any(not math.isfinite(v) or v <= 0 for v in (args.scale, args.distance, args.tracking_timeout)):
        parser.error("scale, distance, and tracking-timeout must be finite and positive")
    return args


if __name__ == "__main__":
    try:
        run(parse_args())
    except KeyboardInterrupt:
        print("ScaleBFM example stopped")
