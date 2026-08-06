import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


OPERATOR_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = OPERATOR_ROOT / "run_memworld_direct_dmd1000_worker.sh"
GATEWAY_SCRIPT = OPERATOR_ROOT / "run_quest_memworld.sh"
NV_GATEWAY_SCRIPT = OPERATOR_ROOT / "run_quest_memworld_nv.sh"
DIRECT_DMD_WORKER_SCRIPT = OPERATOR_ROOT / "run_memworld_direct_dmd1000_worker.sh"


class MemWorldWorkerScriptTests(unittest.TestCase):
    def test_gateway_script_exposes_17_frame_fast_profile(self):
        source = GATEWAY_SCRIPT.read_text(encoding="utf-8")
        self.assertIn("MEMWORLD_NUM_INFERENCE_STEPS:-4", source)
        self.assertIn("MEMWORLD_CFG_SCALE:-1.0", source)
        self.assertIn("--num-inference-steps \"$num_inference_steps\"", source)
        self.assertIn("--cfg-scale \"$cfg_scale\"", source)

    def test_nv_gateway_uses_generic_tcp_worker_and_local_initial_rgb(self):
        source = NV_GATEWAY_SCRIPT.read_text(encoding="utf-8")
        self.assertIn(
            'MEMWORLD_WORKER_URL="tcp://127.0.0.1:${local_worker_port}"',
            source,
        )
        self.assertIn("MEMWORLD_INITIAL_RGB must point", source)
        self.assertNotIn("CHECKPOINT", source)
        self.assertNotIn("Direct-DMD", source)

    def test_direct_dmd_worker_uses_step1335_checkpoint_by_default(self):
        source = DIRECT_DMD_WORKER_SCRIPT.read_text(encoding="utf-8")
        self.assertIn(
            "models/object_interaction_step1335/formal_repaired_direct_dmd_outer1335_dfa2a44f98e7e20/dit_step1335.safetensors",
            source,
        )
        self.assertNotIn("dit_step801.safetensors", source)

    def test_direct_dmd_scripts_use_anchor_for_initial_rgb_and_memory(self):
        expected = "/home/evophys/code/MemWorld-direct-dmd1000/anchor.jpg"
        worker_source = DIRECT_DMD_WORKER_SCRIPT.read_text(encoding="utf-8")
        gateway_source = GATEWAY_SCRIPT.read_text(encoding="utf-8")
        self.assertIn(
            "${MEMWORLD_INITIAL_RGB:-${memworld_root}/anchor.jpg}",
            worker_source,
        )
        self.assertIn(f"MEMWORLD_INITIAL_RGB:-{expected}", gateway_source)
        self.assertIn("MEMWORLD_STATIC_MEMORY:-${initial_rgb}", gateway_source)

    def test_script_passes_worker_arguments_without_patch_markers(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            fake_conda = Path(temp_dir) / "conda"
            fake_conda.write_text(
                "#!/usr/bin/env python3\n"
                "import json, sys\n"
                "print(json.dumps(sys.argv[1:]))\n",
                encoding="utf-8",
            )
            fake_conda.chmod(0o755)
            environment = os.environ.copy()
            environment["CONDA_BIN"] = str(fake_conda)
            result = subprocess.run(
                ["bash", str(SCRIPT)],
                check=True,
                capture_output=True,
                text=True,
                env=environment,
            )

        self.assertEqual(json.loads(result.stdout), [
            "run",
            "--no-capture-output",
            "-n",
            "memworld-egoquest",
            "python",
            "deploy/egoquest_ws/server.py",
            "--project-root",
            "/home/evophys/code/MemWorld-direct-dmd1000",
            "--model-dir",
            "/home/evophys/code/MemWorld-direct-dmd1000/models/Wan2.2-TI2V-5B",
            "--checkpoint",
            (
                "/home/evophys/code/MemWorld-direct-dmd1000/models/"
                "object_interaction_step1335/formal_repaired_direct_dmd_outer1335_dfa2a44f98e7e20/dit_step1335.safetensors"
            ),
            "--host",
            "127.0.0.1",
            "--port",
            "8765",
            "--warmup-initial-rgb",
            "/home/evophys/code/MemWorld-direct-dmd1000/anchor.jpg",
            "--warmup-static-memory",
            "/home/evophys/code/MemWorld-direct-dmd1000/anchor.jpg",
            "--warmup-runs",
            "2",
            "--warmup-num-inference-steps",
            "4",
            "--warmup-cfg-scale",
            "1.0",
            "--no-cpu-offload",
        ])


if __name__ == "__main__":
    unittest.main()
