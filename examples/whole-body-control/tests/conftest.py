"""Make the example package importable without installing it as an SDK."""
from pathlib import Path
import sys

EXAMPLE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(EXAMPLE))
sys.path.insert(0, str(EXAMPLE.parents[1] / "python"))
