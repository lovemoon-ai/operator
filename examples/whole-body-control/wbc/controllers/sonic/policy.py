"""Official SONIC v1.1 ONNX encoder/decoder with deployment-mode observations.

The official manager selects G1/planner (0), VR_3PT (1) or SMPL/POSE (2).
Unused fields are zero-filled exactly as GatherEncoderObservations does outside
the selected mode mask. POSE inputs come from the real upstream SMPL pipeline.
"""
from pathlib import Path
import numpy as np
import yaml


ENCODER_FIELDS = (
    ("encoder_mode_4", 4),
    ("motion_joint_positions_10frame_step5", 290),
    ("motion_joint_velocities_10frame_step5", 290),
    ("motion_anchor_orientation_heading_10frame_step5", 60),
    ("motion_anchor_orientation_heading", 6),
    ("motion_joint_positions_lowerbody_10frame_step5", 120),
    ("motion_joint_velocities_lowerbody_10frame_step5", 120),
    ("vr_3point_local_target", 9),
    ("vr_3point_local_orn_target", 12),
    ("smpl_joints_10frame_step1", 720),
    ("smpl_anchor_orientation_heading_10frame_step1", 60),
    ("motion_joint_positions_wrists_10frame_step1", 60),
)
DECODER_FIELDS = (
    ("token_state", 64),
    ("his_base_angular_velocity_10frame_step1", 30),
    ("his_body_joint_positions_10frame_step1", 290),
    ("his_body_joint_velocities_10frame_step1", 290),
    ("his_last_actions_10frame_step1", 290),
    ("his_gravity_dir_10frame_step1", 30),
)
TELEOP_FIELDS = {
    "encoder_mode_4", "motion_joint_positions_lowerbody_10frame_step5",
    "motion_joint_velocities_lowerbody_10frame_step5", "vr_3point_local_target",
    "vr_3point_local_orn_target", "motion_anchor_orientation_heading",
}
MODE_FIELDS = {
    0: {"encoder_mode_4", "motion_joint_positions_10frame_step5",
        "motion_joint_velocities_10frame_step5", "motion_anchor_orientation_heading_10frame_step5"},
    1: TELEOP_FIELDS,
    2: {"encoder_mode_4", "smpl_joints_10frame_step1", "smpl_anchor_orientation_heading_10frame_step1",
        "motion_joint_positions_wrists_10frame_step1"},
}


def validate_config(config):
    encoder = config["encoder"]
    for entries, expected in ((encoder["encoder_observations"], ENCODER_FIELDS),
                              (config["observations"], DECODER_FIELDS)):
        names = [item["name"] for item in entries if item.get("enabled", True)]
        if names != [name for name, _ in expected]:
            raise ValueError("Unsupported observation layout; use SONIC v1.1 encoder/decoder/config together")
    modes = [mode for mode in encoder["encoder_modes"] if mode["mode_id"] == 1]
    if encoder["dimension"] != 64 or len(modes) != 1 or modes[0]["name"] != "teleop" \
            or set(modes[0]["required_observations"]) != TELEOP_FIELDS:
        raise ValueError("Invalid SONIC teleop mode mask")
    for mode, fields in MODE_FIELDS.items():
        matches = [item for item in encoder["encoder_modes"] if item["mode_id"] == mode]
        if len(matches) != 1 or set(matches[0]["required_observations"]) != fields:
            raise ValueError(f"Invalid SONIC encoder mode {mode}")


def pack(fields, values, *, allowed=None):
    result = np.zeros((1, sum(size for _, size in fields)), dtype=np.float32)
    offset = 0
    for name, size in fields:
        if allowed is None or name in allowed:
            value = np.asarray(values[name], dtype=np.float32).reshape(-1)
            if value.size != size or not np.isfinite(value).all():
                raise ValueError(f"Invalid SONIC observation {name}: expected {size} finite values")
            result[0, offset:offset + size] = value
        offset += size
    return result


class Policy:
    def __init__(self, checkpoint: Path, *, device="cuda", threads=2):
        if threads < 1:
            raise ValueError("threads must be positive")
        validate_config(yaml.safe_load((checkpoint / "observation_config.yaml").read_text()))
        import onnxruntime as ort
        self.device = device
        self.backend = "onnxruntime"
        if device not in ("cpu", "cuda"):
            raise ValueError("SONIC device must be cpu or cuda")
        provider = "CUDAExecutionProvider" if device == "cuda" else "CPUExecutionProvider"
        if provider not in ort.get_available_providers():
            raise RuntimeError(f"Missing ONNX Runtime {provider}; install the matching runtime or explicitly select cpu")
        if device == "cuda" and hasattr(ort, "preload_dlls"):
            ort.preload_dlls()
        options = ort.SessionOptions()
        options.intra_op_num_threads = threads
        options.inter_op_num_threads = 1
        options.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
        self.sessions = []
        for kind, in_dim, out_dim in (("encoder", 1751, 64), ("decoder", 994, 29)):
            path = checkpoint / f"model_{kind}.onnx"
            if not path.is_file() or path.stat().st_size < 1024:
                raise ValueError(f"Missing real ONNX weights (not an LFS pointer): {path}")
            session = ort.InferenceSession(str(path), options, providers=[provider])
            if session.get_providers()[0] != provider:
                raise RuntimeError(f"ONNX Runtime failed to initialize {provider}; refusing silent fallback")
            session.disable_fallback()
            inputs, outputs = session.get_inputs(), session.get_outputs()
            if len(inputs) != 1 or inputs[0].shape != [1, in_dim] or inputs[0].type != "tensor(float)" \
                    or len(outputs) != 1 or outputs[0].shape != [1, out_dim]:
                raise ValueError(f"Wrong SONIC {kind} model contract")
            self.sessions.append(session)

    def infer(self, encoder_values, decoder_values, mode=1):
        if mode not in MODE_FIELDS: raise ValueError("Unsupported SONIC encoder mode")
        encoder_input = pack(ENCODER_FIELDS, encoder_values, allowed=MODE_FIELDS[mode])
        encoder, decoder = self.sessions
        token = encoder.run(None, {encoder.get_inputs()[0].name: encoder_input})[0]
        decoder_input = pack(DECODER_FIELDS, {**decoder_values, "token_state": token})
        action = decoder.run(None, {decoder.get_inputs()[0].name: decoder_input})[0].reshape(-1)
        if not np.isfinite(action).all():
            raise ValueError("SONIC produced non-finite actions")
        return action
