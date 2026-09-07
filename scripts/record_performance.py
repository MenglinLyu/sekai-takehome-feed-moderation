#!/usr/bin/env python3
"""Record physical-device FPS/signposts, optionally including process memory with --memory."""

import argparse
import csv
import ctypes
import datetime as dt
import errno
import json
import math
import os
from pathlib import Path
import re
import selectors
import shlex
import signal
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid
import xml.etree.ElementTree as ET

from summarize_xctrace import rows, number
from xcscheme_env import set_scheme_env
from summarize_memory import summarize_memory

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = "com.sekai.takehome.Sekai"
DEFAULT_PORT = 8787


def announce(message):
    print(f"[{dt.datetime.now().astimezone().isoformat(timespec='seconds')}] {message}", flush=True)


def run(command, log=None, timeout=120):
    announce("$ " + shlex.join(map(str, command)))
    if log:
        with log.open("w") as output:
            result = subprocess.run(command, stdout=output, stderr=subprocess.STDOUT, timeout=timeout)
        if result.returncode:
            raise RuntimeError(f"Command failed ({result.returncode}); see {log}")
        return ""
    return subprocess.check_output(command, stderr=subprocess.STDOUT, text=True, timeout=timeout)


def port_is_occupied(port):
    """Return whether a listener already prevents binding the local mock port."""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as candidate:
        try:
            candidate.bind(("0.0.0.0", port))
        except OSError as error:
            if error.errno == errno.EADDRINUSE:
                return True
            if error.errno in (errno.EACCES, errno.EPERM):
                result = subprocess.run(
                    ["/usr/sbin/lsof", "-nP", f"-iTCP:{port}", "-sTCP:LISTEN", "-t"],
                    capture_output=True, text=True, check=False)
                return result.returncode == 0 and bool(result.stdout.strip())
            raise
    return False


def start_mock_if_needed(port, log):
    if port_is_occupied(port):
        announce(f"Port {port} is already occupied; assuming the mock service is running and skipping startup.")
        return None

    command = [sys.executable, "-u", str(ROOT / "mock/server.py"),
               "--host", "0.0.0.0", "--port", str(port),
               "--fail-rate", "0", "--seed", "42"]
    announce("$ " + shlex.join(command))
    process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, text=True)
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    deadline = time.monotonic() + 10
    health_url = f"http://127.0.0.1:{port}/health"
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"Mock exited during startup; see {log.name}")
        try:
            with opener.open(health_url, timeout=1) as response:
                if response.status == 200:
                    announce(f"Mock service started on port {port}.")
                    return process
        except (OSError, urllib.error.URLError):
            pass
        time.sleep(0.1)
    stop_mock(process)
    raise RuntimeError(f"Mock did not become reachable on port {port}; see {log.name}")


def stop_mock(process):
    if process is None or process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()


class StartNotification:
    """Listen to xctrace's real start notification, without parsing its startup message."""

    def __init__(self):
        self.name = "com.sekai.recording." + uuid.uuid4().hex
        self.lib = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
        self.lib.notify_register_file_descriptor.argtypes = [
            ctypes.c_char_p, ctypes.POINTER(ctypes.c_int), ctypes.c_int, ctypes.POINTER(ctypes.c_int)]
        self.lib.notify_register_file_descriptor.restype = ctypes.c_uint32
        self.lib.notify_cancel.argtypes = [ctypes.c_int]
        self.fd, self.token = ctypes.c_int(-1), ctypes.c_int()
        status = self.lib.notify_register_file_descriptor(
            self.name.encode(), ctypes.byref(self.fd), 0, ctypes.byref(self.token))
        if status:
            raise RuntimeError(f"Cannot register recording-start notification: {status}")

    def close(self):
        # notify_cancel closes descriptors allocated by notify_register_file_descriptor.
        self.lib.notify_cancel(self.token.value)


def selected_device(devices, udid=None):
    candidates = {}
    for device in devices:
        properties = device.get("properties", {})
        hardware = properties.get("hardware", device.get("hardwareProperties", {}))
        connection = properties.get("connection", device.get("connectionProperties", {}))
        state = properties.get("state", device.get("deviceProperties", {}))
        device_udid = hardware.get("udid")
        if not device_udid or (udid is not None and device_udid != udid):
            continue
        if hardware.get("reality") != "physical" or hardware.get("platform") != "iOS":
            if udid is not None:
                raise RuntimeError("The selected device is not a physical iOS device.")
            continue
        if connection.get("state", connection.get("tunnelState")) != "connected":
            if udid is not None:
                raise RuntimeError("The selected iOS device is not connected. Unlock it and check the connection.")
            continue
        candidates[device_udid] = dict(udid=device_udid, name=state.get("name"),
                                      model=hardware.get("productType"),
                                      transport=connection.get("transportType"))
    if not candidates:
        if udid is not None:
            raise RuntimeError(f"Device {udid} was not found. Use --device with its UDID.")
        raise RuntimeError("No connected physical iOS device found. Connect and unlock an iPhone or iPad.")
    if len(candidates) > 1:
        choices = "\n".join(f"  {device['name'] or 'Unnamed device'} ({device['model'] or 'iOS'}): "
                            f"--device {device['udid']}" for device in candidates.values())
        raise RuntimeError("Multiple physical iOS devices are connected. Choose one with --device:\n" + choices)
    return next(iter(candidates.values()))


def base_url(args):
    value = args.base_url or os.environ.get("SEKAI_BASE_URL")
    if not value:
        address = run(["/usr/sbin/ipconfig", "getifaddr", args.interface]).strip()
        value = f"http://{address}:{args.port}"
    value = value.rstrip("/")
    if not re.match(r"^https?://[^/]+", value):
        raise RuntimeError("--base-url must be an HTTP(S) URL.")
    # This checks the Mac-to-server path; phone reachability still requires a shared network.
    request = urllib.request.Request(value + "/game/feed?refresh=0&limit=1")
    with urllib.request.urlopen(request, timeout=10) as response:
        if response.status != 200:
            raise RuntimeError("Feed preflight did not return HTTP 200.")
    return value


def record(command, output, seconds, startup_timeout, save_timeout, metadata, on_started=None):
    notification = StartNotification()
    target_index = command.index("--all-processes") if "--all-processes" in command else command.index("--launch")
    command = command[:target_index] + ["--notify-tracing-started", notification.name] + command[target_index:]
    metadata["record_command"] = command
    announce("Preparing xctrace. Keep the iPhone unlocked; wait for RECORDING STARTED.")
    announce("$ " + shlex.join(command))
    started = stopped = False
    process = None
    selector = selectors.DefaultSelector()
    previous_handler = signal.getsignal(signal.SIGINT)
    interrupted = False
    deadline = time.monotonic() + startup_timeout
    buffer = ""

    def interrupt(_signum, _frame):
        nonlocal interrupted, deadline
        if not interrupted:
            interrupted = True
            announce("STOP REQUESTED: asking xctrace to finish and save; please wait.")
            if process and process.poll() is None:
                process.send_signal(signal.SIGINT)
            deadline = time.monotonic() + save_timeout

    def line_received(line):
        nonlocal stopped, deadline
        print(line, flush=True)
        if ("Reached specified time limit" in line or "Recording completed" in line) and not stopped:
            stopped = True
            metadata["capture_ended_at"] = dt.datetime.now(dt.timezone.utc).isoformat()
            announce("RECORDING ENDED: you can stop operating the phone. Saving trace…")
            deadline = time.monotonic() + save_timeout

    try:
        with (output / "record.log").open("w") as log:
            process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                       start_new_session=True)
            signal.signal(signal.SIGINT, interrupt)
            selector.register(process.stdout, selectors.EVENT_READ, "output")
            selector.register(notification.fd.value, selectors.EVENT_READ, "started")
            while True:
                for key, _ in selector.select(timeout=0.2):
                    if key.data == "started":
                        os.read(notification.fd.value, 4)
                        selector.unregister(notification.fd.value)
                        started = True
                        metadata["capture_started_at"] = dt.datetime.now(dt.timezone.utc).isoformat()
                        if not interrupted:
                            deadline = time.monotonic() + seconds + save_timeout
                            if on_started:
                                on_started()
                            if not interrupted:
                                announce("RECORDING STARTED: operate the Feed now. Ctrl+C stops early and saves.")
                    else:
                        chunk = os.read(process.stdout.fileno(), 65536)
                        if not chunk:
                            selector.unregister(process.stdout)
                        else:
                            value = chunk.decode("utf-8", errors="replace")
                            log.write(value)
                            log.flush()
                            buffer += value
                            while "\n" in buffer:
                                line, buffer = buffer.split("\n", 1)
                                line_received(line)
                if process.poll() is not None and not any(
                        key.data == "output" for key in selector.get_map().values()):
                    break
                if time.monotonic() > deadline:
                    raise RuntimeError("xctrace timed out during startup or saving; trace is incomplete.")
            if buffer:
                line_received(buffer)
            metadata["xctrace_exit_code"] = process.returncode
            if process.returncode != 0 or not started:
                raise RuntimeError(f"xctrace failed or never confirmed start (exit {process.returncode}). See record.log.")
            if not stopped:
                announce("RECORDING ENDED: you can stop operating the phone.")
                metadata["capture_ended_at"] = dt.datetime.now(dt.timezone.utc).isoformat()
            metadata["stopped_early"] = interrupted
    finally:
        signal.signal(signal.SIGINT, previous_handler)
        if process and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        if process and process.stdout:
            process.stdout.close()
        selector.close()
        notification.close()


def recording_command(device_udid, output, duration, server_url, memory=False):
    command = ["xcrun", "xctrace", "record", "--template", "Animation Hitches",
               "--instrument", "Points of Interest"]
    if memory:
        command += ["--instrument", "Activity Monitor"]
    command += ["--device", device_udid, "--time-limit", f"{duration}s",
                "--output", str(output / "recording.trace")]
    # A launch-targeted Activity Monitor only samples the host, excluding WebContent.
    if memory:
        return command + ["--all-processes"]
    return command + ["--env", f"SEKAI_BASE_URL={server_url}", "--launch", "--", BUNDLE]


def launch_for_memory(device_udid, output, server_url, metadata):
    command = ["xcrun", "devicectl", "device", "process", "launch", "--device", device_udid,
               "--timeout", "30", "--environment-variables", json.dumps({"SEKAI_BASE_URL": server_url}),
               "--json-output", str(output / "launch.json"), BUNDLE]
    metadata["launch_command"] = command
    run(command, output / "launch.log", timeout=35)
    result = json.loads((output / "launch.json").read_text())
    pid = result.get("result", {}).get("process", {}).get("processIdentifier")
    if not isinstance(pid, int) or isinstance(pid, bool) or pid <= 0:
        raise RuntimeError("devicectl did not return the launched app PID; memory attribution is unavailable.")
    metadata["app_pid"] = pid
    metadata["app_launched_at"] = dt.datetime.now(dt.timezone.utc).isoformat()


def export_memory(output, schemas, steady_start=10, steady_end=None, host_pid=None):
    schema = "activity-monitor-process-live"
    if schema not in schemas:
        raise RuntimeError(f"Trace is missing {schema}; memory measurements are unavailable.")
    run(["xcrun", "xctrace", "export", "--input", str(output / "recording.trace"),
         "--xpath", f'/trace-toc/run[@number="1"]/data/table[@schema="{schema}"]',
         "--output", str(output / "memory.xml")])
    return summarize_memory(output, steady_start=steady_start, steady_end=steady_end, host_pid=host_pid)


def export_trace(output, memory=False, steady_start=10, steady_end=None, host_pid=None):
    trace = output / "recording.trace"
    run(["xcrun", "xctrace", "export", "--input", str(trace), "--toc", "--output", str(output / "toc.xml")])
    toc = ET.parse(output / "toc.xml")
    schemas = {table.get("schema") for table in toc.findall(".//run/data/table")}
    if memory:
        summary = export_memory(output, schemas, steady_start, steady_end, host_pid)
        for warning in summary["warnings"]:
            announce("MEMORY NOTE: " + warning)
    required = {"displayed-surfaces-per-second": "fps", "hitches": "hitches"}
    for schema, name in required.items():
        if schema not in schemas:
            raise RuntimeError(f"Trace is missing {schema}; no valid FPS result was produced.")
        run(["xcrun", "xctrace", "export", "--input", str(trace), "--xpath",
             f'/trace-toc/run[@number="1"]/data/table[@schema="{schema}"]',
             "--output", str(output / f"{name}.xml")])
    for index, schema in enumerate(sorted(s for s in schemas if s and s.startswith("os-signpost"))):
        run(["xcrun", "xctrace", "export", "--input", str(trace), "--xpath",
             f'/trace-toc/run[@number="1"]/data/table[@schema="{schema}"]',
             "--output", str(output / f"signposts-{index}.xml")])
    samples = []
    for row in rows(output / "fps.xml"):
        if row["display-name"].text == "Built-In Display":
            duration = number(row["duration"]) / 1e9
            if duration > 0:
                samples.append(dict(start_s=number(row["start"]) / 1e9, duration_s=duration,
                                    presented_surfaces=int(number(row["count"])),
                                    fps=number(row["count"]) / duration))
    if not samples:
        raise RuntimeError("Trace contains no Built-In Display FPS samples.")
    with (output / "fps.csv").open("w", newline="") as file:
        writer = csv.DictWriter(file, fieldnames=list(samples[0]))
        writer.writeheader()
        writer.writerows(sorted(samples, key=lambda row: row["start_s"]))
    has_feed_signposts = export_feed_signposts(output)
    if not has_feed_signposts:
        announce("NOTE: no Feed signposts found. Use --build to install this source version and exercise the Feed.")
    return has_feed_signposts


def export_feed_signposts(output):
    events = []
    seen = set()
    for path in output.glob("signposts-*.xml"):
        for row in rows(path):
            if "event-type" not in row or row["subsystem"].text != "com.sekai.takehome":
                continue
            def value(key):
                element = row[key]
                return element.attrib.get("fmt") or "".join(element.itertext())
            event = dict(time_s=number(row["time"]) / 1e9,
                         event_type=value("event-type"), name=value("name"),
                         signpost_id=value("identifier"), message=value("message"),
                         process=value("process"), thread=value("thread"))
            # Both instruments can export the same underlying signpost table.
            identity = tuple(event.values())
            if identity not in seen:
                seen.add(identity)
                events.append(event)
    fields = ["time_s", "event_type", "name", "signpost_id", "message", "process", "thread"]
    with (output / "feed-signposts.csv").open("w", newline="") as file:
        writer = csv.DictWriter(file, fieldnames=fields)
        writer.writeheader()
        writer.writerows(sorted(events, key=lambda row: row["time_s"]))
    return bool(events)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build", action="store_true", help="Build Release without coverage and install before recording")
    parser.add_argument("--scheme", default="Sekai", help="Build scheme (default: Sekai)")
    parser.add_argument("--device", help="Physical-device UDID; automatically selects the sole connected iOS device if omitted")
    parser.add_argument("--duration", type=int, default=50, help="Recording duration in seconds (default: 50)")
    parser.add_argument("--memory", action="store_true", help="Add Activity Monitor and export per-process memory measurements")
    parser.add_argument("--memory-steady-start", type=float, default=10,
                        help="Steady-window start in trace seconds (default: 10; used with --memory)")
    parser.add_argument("--memory-steady-end", type=float,
                        help="Steady-window end in trace seconds (default: observed end; used with --memory)")
    parser.add_argument("--base-url", help="Feed server URL; otherwise SEKAI_BASE_URL or current en0 address on port 8787")
    parser.add_argument("--interface", default="en0", help="Mac LAN interface for automatic server address")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--output", type=Path, help="New output directory; existing directories are never overwritten")
    parser.add_argument("--startup-timeout", type=int, default=90)
    parser.add_argument("--save-timeout", type=int, default=240)
    args = parser.parse_args()
    if min(args.duration, args.startup_timeout, args.save_timeout) <= 0:
        parser.error("Duration and timeouts must be positive.")
    if not 1 <= args.port <= 65535:
        parser.error("Port must be between 1 and 65535.")
    if not math.isfinite(args.memory_steady_start) or args.memory_steady_start < 0:
        parser.error("Memory steady start must be finite and nonnegative.")
    if args.memory_steady_end is not None and (not math.isfinite(args.memory_steady_end)
                                               or args.memory_steady_end <= args.memory_steady_start):
        parser.error("Memory steady end must be finite and exceed its start.")
    output = (args.output or ROOT / "docs/artifacts/recordings" /
              dt.datetime.now().strftime("%Y%m%d-%H%M%S-%f")).resolve()
    try:
        output.mkdir(parents=True, exist_ok=False)
    except OSError as error:
        parser.error(f"Cannot create a new output directory: {error}")
    metadata = dict(status="preparing", mode="build-and-record" if args.build else "record-installed",
                    requested_duration_s=args.duration, memory_requested=args.memory,
                    instruments=["Animation Hitches", "Points of Interest"] + (["Activity Monitor"] if args.memory else []))
    if args.memory:
        metadata["memory_steady_window"] = dict(start_s=args.memory_steady_start, end_s=args.memory_steady_end)
    mock_process = None
    mock_log = None
    try:
        announce(f"Artifacts: {output}")
        run(["xcrun", "devicectl", "list", "devices", "--timeout", "15", "--json-output", str(output / "devices.json")])
        metadata["device"] = selected_device(json.loads((output / "devices.json").read_text())["result"]["devices"], args.device)
        device_udid = metadata["device"]["udid"]
        announce(f"Device: {metadata['device']['name']} (UDID: {device_udid})")
        # Retain only selected, relevant device properties in the recording metadata.
        (output / "devices.json").unlink()
        if args.base_url is None and not os.environ.get("SEKAI_BASE_URL"):
            mock_log = (output / "mock.log").open("w")
            mock_process = start_mock_if_needed(args.port, mock_log)
            metadata["mock_started"] = mock_process is not None
        else:
            metadata["mock_started"] = False
        metadata["base_url"] = base_url(args)
        announce(f"Device: {metadata['device']['name']}; server: {metadata['base_url']}")
        scheme_path = set_scheme_env(ROOT / "Sekai/Sekai.xcodeproj", args.scheme,
                                     "SEKAI_BASE_URL", metadata["base_url"])
        metadata["scheme_updated"] = str(scheme_path) if scheme_path else None
        if scheme_path:
            announce(f"Scheme '{args.scheme}' updated so manual Xcode runs use the same server: {scheme_path}")
        else:
            announce(f"Scheme '{args.scheme}' has no user-specific xcscheme file yet; "
                     "run it once in Xcode to enable syncing SEKAI_BASE_URL there.")
        if args.build:
            derived = ROOT / "Sekai/DerivedData/Performance"
            run(["xcodebuild", "-project", str(ROOT / "Sekai/Sekai.xcodeproj"), "-scheme", args.scheme,
                 "-configuration", "Release", "-destination", f"id={device_udid}",
                 "-derivedDataPath", str(derived), "ENABLE_CODE_COVERAGE=NO", "build"],
                output / "build.log", timeout=900)
            app = derived / "Build/Products/Release-iphoneos/Sekai.app"
            load_commands = run(["xcrun", "otool", "-l", str(app / "Sekai")])
            if "__llvm_prf" in load_commands or "__llvm_cov" in load_commands:
                raise RuntimeError("Built binary still contains coverage sections; refusing to record.")
            metadata["binary_uuid"] = run(["xcrun", "dwarfdump", "--uuid", str(app / "Sekai")]).strip()
            metadata["coverage_sections_present"] = False
            run(["xcrun", "devicectl", "device", "install", "app", "--device", device_udid,
                 "--timeout", "60", str(app)], output / "install.log")
        else:
            announce("Using installed Sekai; its build configuration/coverage is not verified. Use --build after code changes.")
        command = recording_command(device_udid, output, args.duration, metadata["base_url"], args.memory)
        metadata["status"] = "recording"
        on_started = (lambda: launch_for_memory(device_udid, output, metadata["base_url"], metadata)) if args.memory else None
        record(command, output, args.duration, args.startup_timeout, args.save_timeout, metadata, on_started)
        metadata["status"] = "exporting"
        metadata["feed_signposts_present"] = export_trace(
            output, args.memory, args.memory_steady_start, args.memory_steady_end, metadata.get("app_pid"))
        if args.memory:
            metadata["memory_summary"] = "memory-summary.json"
        metadata["status"] = "complete"
        announce(f"SAVED: {output / 'recording.trace'}")
        announce(f"FPS CSV: {output / 'fps.csv'}; phase timeline: {output / 'feed-signposts.csv'}")
        if args.memory:
            announce(f"MEMORY: {output / 'memory.csv'}; report: {output / 'memory-report.md'}")
        return 0
    except (RuntimeError, OSError, subprocess.SubprocessError, ValueError, ET.ParseError) as error:
        metadata["status"] = "failed"
        metadata["error"] = str(error)
        announce(f"FAILED: {error}. Existing artifacts are retained for diagnosis.")
        return 1
    except KeyboardInterrupt:
        metadata["status"] = "cancelled"
        announce("CANCELLED before recording or during export; existing artifacts are retained.")
        return 130
    finally:
        stop_mock(mock_process)
        if mock_log is not None:
            mock_log.close()
        (output / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")


if __name__ == "__main__":
    sys.exit(main())
