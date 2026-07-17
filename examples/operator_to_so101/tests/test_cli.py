import os
import subprocess
import sys

import pytest


@pytest.mark.parametrize(
    ("module", "expected_option"),
    [
        ("operator_to_so101.teleoperate", "--teleop.max_ee_step_m"),
        ("operator_to_so101.record", "--dataset.repo_id"),
    ],
)
def test_cli_help_parses_dataclass_config(module: str, expected_option: str) -> None:
    env = {**os.environ, "PYTHONDONTWRITEBYTECODE": "1"}
    result = subprocess.run(
        [sys.executable, "-m", module, "--help"],
        capture_output=True,
        check=False,
        env=env,
        text=True,
        timeout=60,
    )
    assert result.returncode == 0, result.stderr
    assert expected_option in result.stdout
