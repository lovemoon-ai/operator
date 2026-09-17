#!/usr/bin/env python3
"""Measure the real checkpoint in a host MuJoCo closed loop (not VR coverage)."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess
import time

import numpy as np

from .runtime import Simulation, add_policy_arguments, policy_from_args
from .tracking import FIVE_POINTS


def gpu_process_mib() -> int | None:
    try:
        result = subprocess.run(
            ["nvidia-smi", "--query-compute-apps=pid,used_gpu_memory", "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=5, check=True,
        )
        for line in result.stdout.splitlines():
            pid, memory = line.split(",", 1)
            if int(pid.strip()) == os.getpid():
                return int(memory.strip())
    except (OSError, ValueError, subprocess.SubprocessError):
        return None
    return 0


def export_script(policy, arrays, output: Path) -> None:
    """Trace the fixed batch=1 contract and compare non-neutral inputs before saving.

    Traces retain their device constants. CPU traces run on CPU, CUDA traces on
    CUDA; the sidecar records this and Policy refuses a mismatched device.
    """
    import tempfile
    import warnings

    torch = policy.torch
    metadata_path = output.with_name(output.stem + "_metadata.json")
    if output.exists() or metadata_path.exists():
        raise FileExistsError("Export destination already exists; choose a new --export path")
    old_fastpath = torch.backends.mha.get_fastpath_enabled()
    torch.backends.mha.set_fastpath_enabled(False)
    try:
        with torch.inference_mode(), warnings.catch_warnings():
            warnings.simplefilter("ignore", torch.jit.TracerWarning)
            traced = torch.jit.trace(policy.module, tuple(policy.tensors(arrays)), check_trace=False)
            traced = torch.jit.freeze(traced.eval())
            # Test dynamic joint observations, base attitude, mode and future slots;
            # these must not be baked to the tracing sample's values.
            rng = np.random.default_rng(42)
            for mode in (0, 2, 4, 1, 7):
                inputs = [a.copy() for a in arrays]
                inputs[0][:] = [np.cos(.1), 0, np.sin(.1), 0]
                inputs[2] += rng.normal(0, .03, inputs[2].shape).astype(np.float32)
                inputs[4] += rng.normal(0, .01, inputs[4].shape).astype(np.float32)
                inputs[7][:] = mode
                inputs[8][0, -1, 0] = 10
                tensors = policy.tensors(inputs)
                expected = policy.module(*tensors)
                actual = traced(*tensors)
                for left, right in zip(expected, actual):
                    torch.testing.assert_close(left, right, rtol=1e-4, atol=1e-5)
        output.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(dir=output.parent, suffix=".pt", delete=False) as temporary:
            temporary_path = Path(temporary.name)
        try:
            torch.jit.save(traced, str(temporary_path))
            # Also verify serialization, not just the in-memory traced module.
            restored = torch.jit.load(str(temporary_path), map_location=policy.device)
            with torch.inference_mode():
                for left, right in zip(policy.module(*policy.tensors(arrays)), restored(*policy.tensors(arrays))):
                    torch.testing.assert_close(left, right, rtol=1e-4, atol=1e-5)
            metadata = dict(policy.metadata)
            metadata["operator_export"] = {"backend": "torchscript", "device": policy.device, "batch_size": 1}
            with metadata_path.open("x") as handle:
                json.dump(metadata, handle, indent=2)
            temporary_path.rename(output)
        finally:
            temporary_path.unlink(missing_ok=True)
    finally:
        torch.backends.mha.set_fastpath_enabled(old_fastpath)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    add_policy_arguments(parser)
    parser.add_argument("--steps", type=int, default=500)
    parser.add_argument("--motion", choices=("standing", "wave"), default="standing")
    parser.add_argument("--export", type=Path, help="Save a validated TorchScript trace and metadata")
    args = parser.parse_args()
    if args.steps < 1:
        parser.error("steps must be positive")
    policy = policy_from_args(args)
    torch = policy.torch
    sim = Simulation(args.model, policy.metadata)
    positions, rotations = sim.reference_pose()
    offsets = np.asarray(policy.metadata["future_idx"], dtype=np.int64)
    baseline = sim.inputs(np.repeat(positions[None], 6, axis=0),
                          np.repeat(rotations[None], 6, axis=0), offsets, False)
    for _ in range(20):
        policy.infer(baseline)
    if args.export:
        export_script(policy, baseline, args.export)
    if policy.device == "cuda":
        torch.cuda.reset_peak_memory_stats()
    inference_ms, tick_ms, heights = [], [], []
    body_errors = []
    five = [sim.body_names.index(name) for name in FIVE_POINTS]
    hands = [sim.body_names.index(name) for name in ("left_wrist_yaw_link", "right_wrist_yaw_link")]
    for i in range(args.steps):
        tick_start = time.perf_counter()
        targets = np.repeat(positions[None], 6, axis=0)
        if args.motion == "wave":
            times = sim.data.time + offsets * sim.DT
            targets[:, hands, 2] += (.04 * (1 - np.cos(2 * np.pi * .5 * times)))[:, None]
        inputs = sim.inputs(targets, np.repeat(rotations[None], 6, axis=0), offsets, False)
        start = time.perf_counter()
        target, action = policy.infer(inputs)
        inference_ms.append((time.perf_counter() - start) * 1000)
        sim.step(target, action)
        tick_ms.append((time.perf_counter() - tick_start) * 1000)
        heights.append(float(sim.data.qpos[2]))
        body_errors.append(float(np.linalg.norm(sim.data.xpos[sim.body_ids][five] - targets[0, five], axis=-1).mean()))
    report = {
        "checkpoint": str(args.checkpoint), "backend": policy.backend, "device": policy.device,
        "torch": torch.__version__, "threads": args.threads, "motion": args.motion,
        "steps": args.steps, "simulated_seconds": float(sim.data.time),
        "inference_ms_mean": float(np.mean(inference_ms)),
        "inference_ms_p95": float(np.percentile(inference_ms, 95)),
        "tick_ms_p95": float(np.percentile(tick_ms, 95)),
        "pelvis_height_min_m": min(heights), "pelvis_final_xyz": sim.data.qpos[:3].tolist(),
        "five_point_error_mean_m": float(np.mean(body_errors)),
        "within_50hz_budget_p95": bool(np.percentile(tick_ms, 95) < 20),
        "gpu_process_mib": gpu_process_mib() if policy.device == "cuda" else 0,
        "torch_cuda_peak_allocated_mib": torch.cuda.max_memory_allocated() / 2**20 if policy.device == "cuda" else 0,
        "torch_cuda_peak_reserved_mib": torch.cuda.max_memory_reserved() / 2**20 if policy.device == "cuda" else 0,
        "export": str(args.export) if args.export else None,
    }
    print(json.dumps(report, indent=2), flush=True)
    if min(heights) < .4:
        raise SystemExit("Closed-loop check failed: the robot fell")


if __name__ == "__main__":
    main()
