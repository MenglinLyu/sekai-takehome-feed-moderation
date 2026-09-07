#!/usr/bin/env python3
"""Run the mock on all IPv4 interfaces and timestamp its output.

Example: python3 scripts/record_mock.py --fail-rate 1.0
Redirect stdout to an evidence log. Stop with Ctrl+C. Arguments are forwarded
to mock/server.py, with the bind host forced to 0.0.0.0. The default HTML
payload remains approximately 5 MB.
"""

import datetime
import errno
import pathlib
import socket
import subprocess
import sys


DEFAULT_PORT = 8787


def requested_port(arguments):
    """Return the last forwarded --port value, matching argparse semantics."""
    port = DEFAULT_PORT
    for index, argument in enumerate(arguments):
        if argument == "--port" and index + 1 < len(arguments):
            try:
                port = int(arguments[index + 1])
            except ValueError:
                return None
        elif argument.startswith("--port="):
            try:
                port = int(argument.split("=", 1)[1])
            except ValueError:
                return None
    return port


def port_is_occupied(port):
    """Return whether a listener already prevents binding the mock port."""
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


def server_command(arguments):
    server = pathlib.Path(__file__).resolve().parents[1] / "mock" / "server.py"
    # Keep this option last so argparse uses the required bind address even if a
    # caller supplies an earlier --host value.
    return [sys.executable, "-u", str(server), *arguments, "--host", "0.0.0.0"]


def main(argv=None):
    arguments = sys.argv[1:] if argv is None else argv
    port = requested_port(arguments)
    if port is not None and port_is_occupied(port):
        print(f"Port {port} is already occupied; assuming the mock service is running and skipping startup.",
              flush=True)
        return 0

    command = server_command(arguments)
    print("Command: " + repr(command), flush=True)
    process = subprocess.Popen(command, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, text=True)
    try:
        for line in process.stdout:
            timestamp = datetime.datetime.now(datetime.timezone.utc).isoformat()
            print(f"{timestamp} {line.rstrip()}", flush=True)
        return process.wait()
    except KeyboardInterrupt:
        return 130
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


if __name__ == "__main__":
    sys.exit(main())
