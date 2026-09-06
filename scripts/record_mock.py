#!/usr/bin/env python3
"""Run the unchanged mock and timestamp its output for manual retry checks.

Example: python3 scripts/record_mock.py --host 127.0.0.1 --fail-rate 1.0
Redirect stdout to an evidence log. Stop with Ctrl+C. Arguments are forwarded
unchanged to mock/server.py; the default HTML payload remains approximately 5 MB.
"""

import datetime
import pathlib
import subprocess
import sys


def main():
    server = pathlib.Path(__file__).resolve().parents[1] / "mock" / "server.py"
    command = [sys.executable, "-u", str(server), *sys.argv[1:]]
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
