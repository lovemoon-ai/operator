"""Official planner model + upstream C++ planning and reference-timeline code."""
from __future__ import annotations
import ctypes as C
import hashlib
from pathlib import Path
import re
import subprocess
import tempfile
import threading
import weakref

import numpy as np

BASE = "gear_sonic_deploy/src/g1/g1_deploy_onnx_ref"
CPP_HASHES = {
    "src/g1_deploy_onnx_ref.cpp": "adcd05aa6abdde2f849ac3cfef6971f629a6972b680d78fb959b7eb5d8649f33",
    "include/localmotion_kplanner.hpp": "2cd8fcd975e01017f3b3d9a32a2d0e6abc9bf4bdf4a0a9503f9bf4a9f080b34b",
    "include/motion_data_reader.hpp": "0fa19bc0fff66087e0eb47e41a8f0dbd0913fbb76e9409d4d57e84a04a7572b3",
    "include/policy_parameters.hpp": "b9332adf07c2c9b75c9b1e0756e57c7a1c2a890d8bb0aa53c3f1905fb739b791",
    "include/robot_parameters.hpp": "073f8d04f292473851b6f0b923e6af7b2dc0686658eba19a8deab08c839e4fb1",
    "include/math_utils.hpp": "d85de60b9f2c6a4d26b1380264b172b3380200138173998f2a64660310f3c4d5",
    "include/utils.hpp": "bf35c0c3160bd9c8eea53e85ee1a9a64ebad689d8ece5c6b2e0da97905a6b39b",
    "include/fk.hpp": "ec500585ccfb84ec588191c1b6a975b5c3bade2afd85c095b25091ba073eeb36",
    "include/cnpy.h": "68a34a847cfed2dfcc1dc8bcd495cdb51477061536d670161a62c5103547ae93",
    "include/input_interface/streamed_motion_merger.hpp": "35f95a51e12910b7fd4a77c6ae12677181030526e393ee365509359ebbf79287",
}


def cpp_method(source, signature):
    start = source.index(signature)
    depth = 0
    # Ignore braces in comments and strings while finding the exact method end.
    tokens = re.finditer(r'//[^\n]*|/\*[\s\S]*?\*/|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|[{}]', source[start:])
    for token in tokens:
        if token.group() == "{": depth += 1
        elif token.group() == "}":
            depth -= 1
            if depth == 0:
                return source[start:start + token.end()]
    raise ValueError(f"Incomplete upstream method {signature}")


def build_bridge(upstream: Path) -> Path:
    root = upstream / BASE
    for relative, expected in CPP_HASHES.items():
        if hashlib.sha256((root / relative).read_bytes()).hexdigest() != expected:
            raise ValueError(f"Unsupported SONIC planner source: {relative}")
    source = (root / "src/g1_deploy_onnx_ref.cpp").read_text()
    methods = "\n".join(cpp_method(source, signature) for signature in
                         ("bool CurrentFrameAdvancement()", "void Planner()"))
    fields_start = source.index("MovementState last_movement_state_")
    # End of the idle-readaptation constants; only this declaration block is used.
    fields_end = source.index("static constexpr double kRecoverTrigger", fields_start)
    fields_end = source.index(";", fields_end) + 1
    template = Path(__file__).with_name("planner_bridge.cpp").read_text()
    generated = template.replace("// OPERATOR_UPSTREAM_FIELDS", source[fields_start:fields_end])
    generated = generated.replace("// OPERATOR_UPSTREAM_METHODS", methods)
    key = hashlib.sha256((generated + str(root.resolve()) + str(CPP_HASHES)).encode()).hexdigest()
    cache = Path.home() / ".cache/operator/sonic/planner"
    cache.mkdir(parents=True, exist_ok=True)
    library = cache / f"{key}.so"
    if not library.exists():
        with tempfile.TemporaryDirectory(prefix="build-", dir=cache) as temporary:
            temporary = Path(temporary)
            cpp = temporary / "planner.cpp"
            cpp.write_text(generated)
            subprocess.run(["c++", "-std=c++20", "-O2", "-shared", "-fPIC", "-pthread",
                            "-I", str(root / "include"), str(cpp), "-o", str(temporary / "planner.so")], check=True)
            (temporary / "planner.so").replace(library)
    return library


FloatPtr = C.POINTER(C.c_float)
DoublePtr = C.POINTER(C.c_double)
InferCallback = C.CFUNCTYPE(C.c_int, FloatPtr, C.c_int, C.c_float, C.c_float,
                          FloatPtr, FloatPtr, C.c_int, FloatPtr, C.POINTER(C.c_int))


class OfficialPlanner:
    def __init__(self, upstream, model_path, device="cuda", threads=2):
        import onnxruntime as ort
        if not model_path.is_file() or model_path.stat().st_size < 1024:
            raise ValueError("Missing real V2 planner_sonic.onnx; run the official model downloader")
        provider = "CUDAExecutionProvider" if device == "cuda" else "CPUExecutionProvider"
        if device == "cuda": ort.preload_dlls()
        options = ort.SessionOptions()
        options.intra_op_num_threads = threads
        options.inter_op_num_threads = 1
        options.log_severity_level = 3
        self.session = ort.InferenceSession(str(model_path), options, providers=[provider])
        if self.session.get_providers()[0] != provider:
            raise RuntimeError(f"Planner failed to initialize {provider}")
        self.session.disable_fallback()
        expected = {
            "context_mujoco_qpos": ([1,4,36], "tensor(float)"),
            "target_vel": ([1], "tensor(float)"), "height": ([1], "tensor(float)"),
            "mode": ([1], "tensor(int64)"), "random_seed": ([1], "tensor(int64)"),
            "movement_direction": ([1,3], "tensor(float)"),
            "facing_direction": ([1,3], "tensor(float)"),
            "has_specific_target": ([1,1], "tensor(int64)"),
            "specific_target_positions": ([1,4,3], "tensor(float)"),
            "specific_target_headings": ([1,4], "tensor(float)"),
            "allowed_pred_num_tokens": ([1,11], "tensor(int64)"),
        }
        inputs = {value.name:(value.shape,value.type) for value in self.session.get_inputs()}
        outputs = {value.name:(value.shape,value.type) for value in self.session.get_outputs()}
        if inputs != expected or outputs != {
                "mujoco_qpos": ([1,64,36], "tensor(float)"), "num_pred_frames": ([1], "tensor(int32)")}:
            raise ValueError("Wrong SONIC V2 planner model signature")
        self.callback_error = None
        self.last_inputs = None
        self.calls = 0
        owner = weakref.ref(self)
        def infer(*args):
            instance = owner()
            return instance._infer(*args) if instance is not None else 0
        self.callback = InferCallback(infer)
        self.lib = C.CDLL(str(build_bridge(upstream)))
        self.lib.sonic_create.argtypes = [InferCallback]
        self.lib.sonic_create.restype = C.c_void_p
        self.lib.sonic_destroy.argtypes = [C.c_void_p]
        self.lib.sonic_measurements.argtypes = [C.c_void_p, DoublePtr, DoublePtr]
        self.lib.sonic_movement.argtypes = [C.c_void_p, C.c_int, DoublePtr, DoublePtr, C.c_double, C.c_double]
        for name in ("sonic_plan", "sonic_advance", "sonic_frame", "sonic_take_heading_reset"):
            getattr(self.lib, name).argtypes = [C.c_void_p]
            getattr(self.lib, name).restype = C.c_int
        self.lib.sonic_references.argtypes = [C.c_void_p, DoublePtr, DoublePtr, DoublePtr, DoublePtr]
        self.lib.sonic_references.restype = C.c_int
        self.lib.sonic_mode.argtypes = [C.c_void_p, C.c_int]
        self.lib.sonic_stream.argtypes = [C.c_void_p, C.c_int, C.POINTER(C.c_int64), *([DoublePtr]*5)]
        self.lib.sonic_stream.restype = C.c_int
        self.lib.sonic_pose_references.argtypes = [C.c_void_p, DoublePtr, DoublePtr, DoublePtr]
        self.lib.sonic_pose_references.restype = C.c_int
        self.lib.sonic_error.restype = C.c_char_p
        self.ptr = None
        self.worker = None
        self.worker_error = None
        self.reset()

    def _infer(self, context, mode, speed, height, movement, facing, seed, output, count):
        try:
            values = {
                "context_mujoco_qpos": np.ctypeslib.as_array(context, shape=(144,)).copy().reshape(1,4,36),
                "target_vel": np.array([speed], np.float32), "height": np.array([height], np.float32),
                "mode": np.array([mode], np.int64), "random_seed": np.array([seed], np.int64),
                "movement_direction": np.ctypeslib.as_array(movement, shape=(3,)).copy().reshape(1,3),
                "facing_direction": np.ctypeslib.as_array(facing, shape=(3,)).copy().reshape(1,3),
                "has_specific_target": np.zeros((1,1), np.int64),
                "specific_target_positions": np.zeros((1,4,3), np.float32),
                "specific_target_headings": np.zeros((1,4), np.float32),
                # Active TensorRT backend's exact V2 token mask (not deprecated ORT backend).
                "allowed_pred_num_tokens": np.array([[0,0,0,1,1,1,0,0,0,0,0]], np.int64),
            }
            self.last_inputs = values
            qpos, num = self.session.run(["mujoco_qpos", "num_pred_frames"], values)
            if qpos.shape != (1,64,36) or not np.isfinite(qpos).all():
                raise ValueError("Invalid official planner output")
            np.ctypeslib.as_array(output, shape=(2304,))[:] = qpos.reshape(-1)
            count[0] = int(num[0])
            self.calls += 1
            return 1
        except BaseException as exc:
            self.callback_error = exc
            return 0

    def reset(self):
        self.close()
        self.worker_error = self.callback_error = None
        self.ptr = self.lib.sonic_create(self.callback)
        if not self.ptr: raise RuntimeError(self.lib.sonic_error().decode())

    def close(self):
        self.stop_worker()
        if getattr(self, "ptr", None):
            self.lib.sonic_destroy(self.ptr)
            self.ptr = None

    def start_worker(self):
        if self.worker is not None: return
        self.worker_error = None
        self.worker_stop, self.worker_request = threading.Event(), threading.Event()
        def run():
            while True:
                self.worker_request.wait()
                self.worker_request.clear()
                if self.worker_stop.is_set(): return
                try:
                    self.plan()
                except BaseException as exc:
                    self.worker_error = exc
                    return
        self.worker = threading.Thread(target=run, name="sonic-planner", daemon=True)
        self.worker.start()

    def stop_worker(self):
        if getattr(self, "worker", None) is None: return
        self.worker_stop.set()
        self.worker_request.set()
        self.worker.join(timeout=30)
        if self.worker.is_alive():
            raise RuntimeError("SONIC planner has not stopped; refusing to free active native state")
        self.worker = None

    def check_worker(self):
        if self.worker_error is not None:
            raise RuntimeError("Official SONIC planner worker failed") from self.worker_error

    def request_plan(self):
        self.check_worker()
        self.worker_request.set()  # coalesce superseded requests, never queue old snapshots

    @staticmethod
    def array(value):
        return np.ascontiguousarray(value, dtype=np.float64)

    def measurements(self, quat, joints):
        quat, joints = self.array(quat), self.array(joints)
        if quat.shape != (4,) or joints.shape != (29,): raise ValueError("Invalid planner measurements")
        self.lib.sonic_measurements(self.ptr, quat.ctypes.data_as(DoublePtr), joints.ctypes.data_as(DoublePtr))

    def movement(self, mode, direction, facing, speed=-1., height=-1.):
        direction, facing = self.array(direction), self.array(facing)
        if direction.shape != (3,) or facing.shape != (3,): raise ValueError("Invalid movement vectors")
        self.lib.sonic_movement(self.ptr, mode, direction.ctypes.data_as(DoublePtr),
                               facing.ctypes.data_as(DoublePtr), speed, height)

    def plan(self):
        if not self.lib.sonic_plan(self.ptr):
            raise RuntimeError(self.lib.sonic_error().decode()) from self.callback_error

    def advance(self):
        if not self.lib.sonic_advance(self.ptr): raise RuntimeError(self.lib.sonic_error().decode())

    def references(self):
        arrays = [np.empty((10,n), np.float64) for n in (29,29,4,3)]
        if not self.lib.sonic_references(self.ptr, *(a.ctypes.data_as(DoublePtr) for a in arrays)):
            return None
        return tuple(arrays)

    def set_mode(self, planner_enabled):
        self.stop_worker()
        self.lib.sonic_mode(self.ptr, int(planner_enabled))

    def take_heading_reset(self):
        return bool(self.lib.sonic_take_heading_reset(self.ptr))

    def stream(self, values):
        indices = np.ascontiguousarray(values["frame_index"], dtype=np.int64).reshape(-1)
        arrays = [self.array(values[name]) for name in
                  ("joint_pos", "joint_vel", "body_quat_w", "smpl_joints", "smpl_pose")]
        n=len(indices)
        if [a.size for a in arrays] != [n*29,n*29,n*4,n*72,n*63]:
            raise ValueError("Invalid official POSE frame dimensions")
        if not all(np.isfinite(a).all() for a in arrays): raise ValueError("Non-finite POSE input")
        if not self.lib.sonic_stream(self.ptr,n,indices.ctypes.data_as(C.POINTER(C.c_int64)),
                                    *(a.ctypes.data_as(DoublePtr) for a in arrays)):
            raise RuntimeError(self.lib.sonic_error().decode())

    def pose_references(self):
        arrays = [np.empty((10,n),np.float64) for n in (72,4,6)]
        if not self.lib.sonic_pose_references(self.ptr,*(a.ctypes.data_as(DoublePtr) for a in arrays)):
            return None
        return tuple(arrays)
