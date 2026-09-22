import contextlib
import io
from pathlib import Path
import unittest

import operator_xr

from operator_xr import cli
from operator_xr.services import retargeting as retargeting_service


class CliTests(unittest.TestCase):
    def setUp(self) -> None:
        self.calls: list[dict] = []
        self._original = retargeting_service.serve
        retargeting_service.serve = lambda **kwargs: self.calls.append(kwargs)
        self.addCleanup(setattr, retargeting_service, "serve", self._original)

    def test_serve_defaults_to_the_retargeting_service(self) -> None:
        cli.main(["serve"])
        self.assertEqual(
            self.calls, [{"host": "0.0.0.0", "port": 8000, "log_level": "info"}]
        )

    def test_serve_forwards_host_port_and_log_level(self) -> None:
        cli.main(
            ["serve", "--service", "retargeting", "--host", "127.0.0.1", "--port", "63920",
             "--log-level", "debug"]
        )
        self.assertEqual(
            self.calls,
            [{"host": "127.0.0.1", "port": 63920, "log_level": "debug"}],
        )

    def test_retargeting_service_entry_point_shares_the_parser(self) -> None:
        retargeting_service.main(["--port", "9001"])
        self.assertEqual(self.calls, [{"host": "0.0.0.0", "port": 9001, "log_level": "info"}])

    def test_a_command_is_required(self) -> None:
        with self.assertRaises(SystemExit):
            cli.main([])

    def test_unknown_service_is_rejected(self) -> None:
        with self.assertRaises(SystemExit):
            cli.main(["serve", "--service", "nope"])

    def test_version_matches_the_repo_version(self) -> None:
        if operator_xr.__version__ == "0+unknown":
            self.skipTest("operator-xr is not installed; its version comes from the package metadata")
        # VERSION is SemVer; the wheel carries its PEP 440 form (0.3.0-rc.1 -> 0.3.0rc1).
        version = (Path(__file__).resolve().parents[2] / "VERSION").read_text().strip()
        for semver, pep440 in (("-alpha.", "a"), ("-beta.", "b"), ("-rc.", "rc")):
            version = version.replace(semver, pep440)
        self.assertEqual(
            operator_xr.__version__, version,
            "stale install: reinstall ./python after scripts/version.py set",
        )
        out = io.StringIO()
        with contextlib.redirect_stdout(out), self.assertRaises(SystemExit):
            cli.main(["--version"])
        self.assertEqual(out.getvalue().strip(), f"operator {version}")

    def test_version_falls_back_outside_an_install(self) -> None:
        import importlib
        from unittest import mock

        def not_installed(name: str) -> str:
            raise importlib.metadata.PackageNotFoundError(name)

        with mock.patch("importlib.metadata.version", not_installed):
            importlib.reload(operator_xr)
            self.assertEqual(operator_xr.__version__, "0+unknown")
        importlib.reload(operator_xr)
