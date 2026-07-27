import unittest

from pyoperator import cli
from pyoperator.services import retargeting as retargeting_service


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
