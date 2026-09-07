"""Tests for the timestamped mock-server launcher."""

import unittest
from unittest.mock import patch

from record_mock import main, requested_port, server_command


class ServerCommandTests(unittest.TestCase):
    def test_binds_all_ipv4_interfaces_by_default(self):
        command = server_command(["--fail-rate", "0"])
        self.assertEqual(command[-2:], ["--host", "0.0.0.0"])

    def test_required_host_overrides_an_earlier_host_argument(self):
        command = server_command(["--host", "127.0.0.1"])
        self.assertEqual(command[-2:], ["--host", "0.0.0.0"])

    def test_uses_default_or_explicit_port(self):
        self.assertEqual(requested_port([]), 8787)
        self.assertEqual(requested_port(["--port", "9000"]), 9000)
        self.assertEqual(requested_port(["--port=9001"]), 9001)

    @patch("record_mock.subprocess.Popen")
    @patch("record_mock.port_is_occupied", return_value=True)
    def test_skips_startup_when_port_is_occupied(self, _occupied, popen):
        self.assertEqual(main([]), 0)
        popen.assert_not_called()


if __name__ == "__main__":
    unittest.main()
