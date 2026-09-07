#!/usr/bin/env python3
"""Start a LAN mock and configure the local Sekai Mock Xcode scheme."""

import argparse
import errno
import ipaddress
import json
import os
from pathlib import Path
import re
import signal
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET

from xcscheme_env import set_scheme_env

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "Sekai/Sekai.xcodeproj"
SCHEME_NAME = "Sekai Mock"


def command_output(*command):
    result = subprocess.run(command, capture_output=True, text=True, check=False)
    return result.stdout.strip() if result.returncode == 0 else ""


def lan_ip(interface=None):
    interfaces = [interface] if interface else []
    if not interface:
        route = command_output("/sbin/route", "-n", "get", "default")
        match = re.search(r"interface:\s*(\S+)", route)
        if match:
            interfaces.append(match[1])
        interfaces.extend(["en0", "en1"])
    for name in dict.fromkeys(interfaces):
        address = command_output("/usr/sbin/ipconfig", "getifaddr", name)
        if not address:
            match = re.search(r"\binet (\d+\.\d+\.\d+\.\d+)",
                              command_output("/sbin/ifconfig", name))
            address = match[1] if match else ""
        try:
            parsed = ipaddress.IPv4Address(address)
        except ipaddress.AddressValueError:
            continue
        if not (parsed.is_loopback or parsed.is_unspecified or parsed.is_link_local
                or parsed.is_multicast):
            return str(parsed), name
    raise RuntimeError("No LAN IPv4 address found. Connect to Wi-Fi/Ethernet or use --interface en0.")


def available_port(preferred):
    for port in range(preferred, 65536):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as candidate:
            try:
                candidate.bind(("0.0.0.0", port))
            except OSError as error:
                if error.errno == errno.EADDRINUSE:
                    continue
                raise
            return port
    raise RuntimeError("No free port available. Choose a lower --port.")


def write_scheme(url):
    template = ROOT / "scripts/Sekai Mock.xcscheme"
    destination = set_scheme_env(PROJECT, SCHEME_NAME, "SEKAI_BASE_URL", url, template=template)
    if destination is None:
        raise RuntimeError(f"Missing both an existing '{SCHEME_NAME}' scheme and template {template}")
    return destination


def stop_server(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


def wait_for_health(process, url):
    # Ignore HTTP proxy settings for this direct LAN reachability check.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if process.poll() is not None:
            return False
        try:
            with opener.open(url + "/health", timeout=1) as response:
                healthy = response.status == 200 and json.load(response).get("ok") is True
            # Detect a child that lost the bind race to another listener.
            try:
                process.wait(timeout=0.2)
                return False
            except subprocess.TimeoutExpired:
                if healthy:
                    return True
        except (OSError, urllib.error.URLError, ValueError):
            pass
        time.sleep(0.1)
    raise RuntimeError(f"Mock did not become reachable at {url}. Check the selected interface/firewall.")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8787, help="First port to try; occupied ports are skipped")
    parser.add_argument("--interface", help="Mac LAN interface, e.g. en0 (default: route interface, then en0/en1)")
    parser.add_argument("mock_args", nargs=argparse.REMAINDER, help="Extra mock options after --")
    args = parser.parse_args(argv)
    if not 1024 <= args.port <= 65535:
        parser.error("--port must be between 1024 and 65535")
    forwarded = args.mock_args
    if forwarded[:1] == ["--"]:
        forwarded = forwarded[1:]
    # The wrapper owns binding so the advertised endpoint always matches.
    if any(value.startswith(("--ho", "--po")) for value in forwarded):
        parser.error("Use the wrapper's --port; the mock host is always 0.0.0.0")

    process = None
    previous_handlers = {}

    def interrupted(signum, frame):
        raise KeyboardInterrupt

    try:
        for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            previous_handlers[signum] = signal.signal(signum, interrupted)
        address, interface = lan_ip(args.interface)
        preferred = args.port
        for attempt in range(10):
            port = available_port(preferred)
            url = f"http://{address}:{port}"
            print(f"Starting mock at {url} ({interface}); listening on 0.0.0.0:{port}", flush=True)
            # Isolate terminal signals: the parent owns orderly child cleanup.
            process = subprocess.Popen(
                [sys.executable, "-u", str(ROOT / "mock/server.py"), *forwarded,
                 "--host", "0.0.0.0", "--port", str(port)], start_new_session=True)
            if wait_for_health(process, url):
                break
            # A competing process may bind after our availability probe.
            if available_port(port) == port:
                raise RuntimeError("Mock exited during startup; see its output above.")
            preferred = port + 1
        else:
            raise RuntimeError("Could not start mock after repeated port conflicts.")

        scheme = write_scheme(url)
        print(f"\nReady: SEKAI_BASE_URL={url}\nScheme: {scheme}\n"
              f"Select '{SCHEME_NAME}' in Xcode, choose a simulator or iPhone, then Run.\n"
              "Keep the iPhone on the same LAN and allow local network access.\n"
              f"Press Ctrl+C to stop this mock (PID {process.pid}); other servers are left running.\n"
              f"From another terminal: kill -TERM {os.getpid()}\n", flush=True)
        return process.wait()
    except KeyboardInterrupt:
        print("\nStopping this session's mock...", flush=True)
        return 0
    except (OSError, RuntimeError, ET.ParseError) as error:
        print(f"Error: {error}", file=sys.stderr)
        return 1
    finally:
        # Repeated terminal signals must not interrupt cleanup and orphan the mock.
        for signum in previous_handlers:
            signal.signal(signum, signal.SIG_IGN)
        if process is not None:
            stop_server(process)
        for signum, handler in previous_handlers.items():
            signal.signal(signum, handler)


if __name__ == "__main__":
    sys.exit(main())
