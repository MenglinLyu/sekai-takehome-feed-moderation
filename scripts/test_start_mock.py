"""Regression checks for endpoint configuration and mock process ownership."""

import pathlib
import signal
import socket
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

import start_mock


class MockLauncherTests(unittest.TestCase):
    def test_occupied_port_is_skipped_without_stopping_listener(self):
        with socket.socket() as occupied:
            occupied.bind(("0.0.0.0", 0))
            occupied.listen()
            port = occupied.getsockname()[1]
            self.assertGreater(start_mock.available_port(port), port)
            with socket.create_connection(("127.0.0.1", port), timeout=1):
                pass

    def test_scheme_updates_url_and_preserves_other_settings(self):
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(start_mock, "PROJECT", pathlib.Path(directory)):
                path = start_mock.write_scheme("http://192.168.1.2:8787")
                tree = ET.parse(path)
                variables = tree.find("LaunchAction/EnvironmentVariables")
                ET.SubElement(variables, "EnvironmentVariable", key="KEEP_ME", value="yes", isEnabled="YES")
                tree.write(path)
                start_mock.write_scheme("http://192.168.1.3:8789")
                variables = ET.parse(path).findall("LaunchAction/EnvironmentVariables/EnvironmentVariable")
                self.assertEqual(len(variables), 2)
                self.assertEqual({v.get("key"): v.get("value") for v in variables},
                                 {"KEEP_ME": "yes", "SEKAI_BASE_URL": "http://192.168.1.3:8789"})
                self.assertTrue(all(v.get("isEnabled") == "YES" for v in variables))

    def test_explicit_interface_and_ifconfig_fallback(self):
        with patch.object(start_mock, "command_output", side_effect=["", "inet 192.168.2.4 netmask 0xffffff00"]):
            self.assertEqual(start_mock.lan_ip("en5"), ("192.168.2.4", "en5"))

    def test_rejects_loopback_interface(self):
        with patch.object(start_mock, "command_output", return_value="127.0.0.1"):
            with self.assertRaises(RuntimeError):
                start_mock.lan_ip("lo0")

    def test_cleanup_terminates_only_owned_process(self):
        owned = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
        other = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
        try:
            start_mock.stop_server(owned)
            self.assertEqual(owned.returncode, -signal.SIGTERM)
            self.assertIsNone(other.poll())
            start_mock.stop_server(owned)
        finally:
            start_mock.stop_server(owned)
            start_mock.stop_server(other)


if __name__ == "__main__":
    unittest.main()
