"""Exercise recording lifecycle failures without a device or a real trace."""

import contextlib
import io
import json
import os
from pathlib import Path
import signal
import sys
import tempfile
import threading
import unittest
from unittest.mock import Mock, patch

from record_performance import (record, selected_device, export_feed_signposts, start_mock_if_needed,
                                recording_command, launch_for_memory, export_memory)


RECORDER = '''
import ctypes, signal, sys, time
mode = sys.argv[1]
if mode == "fail":
    print("Starting recording...", flush=True)
    sys.exit(19)
if mode == "hang":
    time.sleep(30)
name = sys.argv[sys.argv.index("--notify-tracing-started") + 1]
lib = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
lib.notify_post(name.encode())
if mode == "stop":
    def stop(*args):
        print("Recording completed", flush=True)
        sys.exit(0)
    signal.signal(signal.SIGINT, stop)
    time.sleep(30)
time.sleep(0.1)
print("Reached specified time limit", flush=True)
print("Recording completed", flush=True)
'''


@unittest.skipUnless(sys.platform == "darwin", "Uses Darwin recording-start notifications")
class RecordingLifecycleTests(unittest.TestCase):
    def exercise(self, mode, startup=3, on_started=None, all_processes=False):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            script = output / "fake_recorder.py"
            script.write_text(RECORDER)
            metadata = {}
            target = ["--all-processes"] if all_processes else ["--launch", "--", "fake"]
            record([sys.executable, str(script), mode] + target,
                   output, 2, startup, 3, metadata, on_started)
            return metadata

    def test_real_start_and_end_notifications(self):
        with contextlib.redirect_stdout(io.StringIO()) as console:
            metadata = self.exercise("normal")
        self.assertEqual(console.getvalue().count("RECORDING STARTED:"), 1)
        self.assertEqual(console.getvalue().count("RECORDING ENDED:"), 1)
        self.assertEqual(metadata["xctrace_exit_code"], 0)

    def test_failed_start_never_announces_recording(self):
        with contextlib.redirect_stdout(io.StringIO()) as console:
            with self.assertRaisesRegex(RuntimeError, "never confirmed start"):
                self.exercise("fail")
        self.assertNotIn("RECORDING STARTED:", console.getvalue())
        self.assertNotIn("RECORDING ENDED:", console.getvalue())

    def test_timeout_terminates_child(self):
        with contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaisesRegex(RuntimeError, "timed out"):
                self.exercise("hang", startup=0.3)

    def test_all_processes_launches_only_after_confirmed_start(self):
        callback = Mock()
        with contextlib.redirect_stdout(io.StringIO()):
            self.exercise("normal", on_started=callback, all_processes=True)
        callback.assert_called_once_with()
        callback.reset_mock()
        with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(RuntimeError):
            self.exercise("fail", on_started=callback, all_processes=True)
        callback.assert_not_called()

    def test_launch_failure_does_not_announce_ready_and_cleans_up(self):
        with contextlib.redirect_stdout(io.StringIO()) as console:
            with self.assertRaisesRegex(RuntimeError, "launch failed"):
                self.exercise("stop", on_started=Mock(side_effect=RuntimeError("launch failed")), all_processes=True)
        self.assertNotIn("RECORDING STARTED:", console.getvalue())

    def test_ctrl_c_requests_graceful_save(self):
        timer = threading.Timer(0.6, os.kill, args=(os.getpid(), signal.SIGINT))
        timer.start()
        try:
            with contextlib.redirect_stdout(io.StringIO()) as console:
                metadata = self.exercise("stop")
            self.assertTrue(metadata["stopped_early"])
            self.assertIn("STOP REQUESTED:", console.getvalue())
            self.assertEqual(metadata["xctrace_exit_code"], 0)
        finally:
            timer.cancel()
            timer.join()


class DeviceSelectionTests(unittest.TestCase):
    @staticmethod
    def device(udid, reality="physical", platform="iOS", state="connected", transport="wired"):
        return dict(properties=dict(
            hardware=dict(udid=udid, reality=reality, platform=platform, productType="iPhone18,1"),
            connection=dict(state=state, transportType=transport), state=dict(name=f"Phone {udid}")))

    def test_auto_selects_only_connected_ios_device(self):
        devices = [self.device("sim", reality="simulated"), self.device("watch", platform="watchOS"),
                   self.device("offline", state="disconnected"), self.device("phone")]
        self.assertEqual(selected_device(devices)["udid"], "phone")

    def test_auto_accepts_connected_wireless_device(self):
        self.assertEqual(selected_device([self.device("wifi", transport="localNetwork")])["udid"], "wifi")

    def test_no_eligible_devices(self):
        for devices in ([], [self.device("sim", reality="simulated")],
                        [self.device("offline", state="disconnected")]):
            with self.subTest(devices=devices):
                with self.assertRaisesRegex(RuntimeError, "No connected physical iOS device"):
                    selected_device(devices)

    def test_multiple_devices_require_selection(self):
        devices = [self.device("one"), self.device("two")]
        with self.assertRaises(RuntimeError) as error:
            selected_device(devices)
        for value in ("Phone one", "Phone two", "--device one", "--device two"):
            self.assertIn(value, str(error.exception))
        self.assertEqual(selected_device(devices, "two")["udid"], "two")

    def test_unknown_override_never_falls_back(self):
        with self.assertRaisesRegex(RuntimeError, "missing was not found"):
            selected_device([self.device("phone")], "missing")

    def test_legacy_devicectl_fields(self):
        device = dict(hardwareProperties=dict(udid="legacy", reality="physical", platform="iOS"),
                      connectionProperties=dict(tunnelState="connected", transportType="wired"),
                      deviceProperties=dict(name="Legacy iPhone"))
        self.assertEqual(selected_device([device])["udid"], "legacy")

    def test_simulator_and_disconnected_device_are_rejected(self):
        hardware = dict(udid="test", reality="simulated", platform="iOS")
        device = dict(properties=dict(hardware=hardware, connection=dict(state="connected")))
        with self.assertRaisesRegex(RuntimeError, "physical"):
            selected_device([device], "test")
        hardware["reality"] = "physical"
        device["properties"]["connection"]["state"] = "disconnected"
        with self.assertRaisesRegex(RuntimeError, "not connected"):
            selected_device([device], "test")


class MockStartupTests(unittest.TestCase):
    @patch("record_performance.subprocess.Popen")
    @patch("record_performance.port_is_occupied", return_value=True)
    def test_occupied_port_is_treated_as_running_service(self, _occupied, popen):
        log = Mock(name="mock.log")
        self.assertIsNone(start_mock_if_needed(8787, log))
        popen.assert_not_called()


class SignpostExportTests(unittest.TestCase):
    def test_referenced_rows_without_repeated_schema_and_duplicate_tables(self):
        fields = ["time", "event-type", "name", "identifier", "message", "process", "thread", "subsystem"]
        schema = "<schema>" + "".join(f"<col><mnemonic>{key}</mnemonic></col>" for key in fields) + "</schema>"
        values = ["1000000000", "Begin", "FeedDrag", "1", "item=sample", "Sekai", "Main", "com.sekai.takehome"]
        row = "<row>" + "".join(f'<v id="{i}">{v}</v>' for i, v in enumerate(values)) + "</row>"
        refs = "<row><v>2000000000</v><v>End</v>" + "".join(f'<v ref="{i}"/>' for i in range(2, len(values))) + "</row>"
        xml = f"<trace-query-result><node>{schema}{row}</node><node>{refs}{refs}</node></trace-query-result>"
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            (output / "signposts-0.xml").write_text(xml)
            self.assertTrue(export_feed_signposts(output))
            lines = (output / "feed-signposts.csv").read_text().splitlines()
            self.assertEqual(len(lines), 3)
            self.assertIn("1.0,Begin,FeedDrag", lines[1])
            self.assertIn("2.0,End,FeedDrag", lines[2])


class MemoryRecordingTests(unittest.TestCase):
    def test_memory_records_all_processes_and_default_still_launches(self):
        output = Path("/tmp/example")
        normal = recording_command("phone", output, 60, "http://host:8787")
        memory = recording_command("phone", output, 60, "http://host:8787", memory=True)
        self.assertNotIn("Activity Monitor", normal)
        self.assertEqual(normal[-3:], ["--launch", "--", "com.sekai.takehome.Sekai"])
        self.assertIn("Activity Monitor", memory)
        self.assertEqual(memory[-1], "--all-processes")
        self.assertNotIn("--env", memory)
        self.assertNotIn("--launch", memory)

    @patch("record_performance.run")
    def test_memory_launch_retains_pid_and_passes_environment(self, run):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            (output / "launch.json").write_text(json.dumps({"result": {"process": {"processIdentifier": 42}}}))
            metadata = {}
            launch_for_memory("phone", output, "http://host:8787", metadata)
            self.assertEqual(metadata["app_pid"], 42)
            command = run.call_args.args[0]
            self.assertEqual(json.loads(command[command.index("--environment-variables") + 1]),
                             {"SEKAI_BASE_URL": "http://host:8787"})
            (output / "launch.json").write_text('{"result": {}}')
            with self.assertRaisesRegex(RuntimeError, "app PID"):
                launch_for_memory("phone", output, "http://host:8787", {})

    @patch("record_performance.summarize_memory")
    @patch("record_performance.run")
    def test_missing_memory_table_fails_and_valid_export_is_summarized(self, run, summarize):
        with self.assertRaisesRegex(RuntimeError, "memory measurements are unavailable"):
            export_memory(Path("/tmp/example"), {"hitches"})
        run.assert_not_called()
        export_memory(Path("/tmp/example"), {"activity-monitor-process-live"}, 5, 40, 42)
        self.assertIn('activity-monitor-process-live', " ".join(run.call_args.args[0]))
        summarize.assert_called_once_with(Path("/tmp/example"), steady_start=5, steady_end=40, host_pid=42)


if __name__ == "__main__":
    unittest.main()
