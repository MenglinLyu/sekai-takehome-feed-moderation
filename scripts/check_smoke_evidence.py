#!/usr/bin/env python3
"""Check the September 5 smoke evidence, not a substitute for driving the app.

Usage: python3 scripts/check_smoke_evidence.py [evidence-directory]
The assertions are specific to the recorded scenario and its existing hidden IDs.
"""

import datetime
import json
import pathlib
import re
import sys


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def read_log(directory, name):
    log = json.loads((directory / name).read_text())
    require(not log["truncated"], f"{name}: truncated evidence")
    return [unit["content"] for unit in log["units"]]


def check_playback(lines):
    created = [re.search(r"Created WebView slot (\d)", line) for line in lines]
    require([m[1] for m in created if m] == ["0", "1", "2"],
            "Expected exactly three creation events in each process")
    active = None
    plays = 0
    for line in lines:
        match = re.search(r"(Paused|Play completion) (game_\d+)", line)
        if not match:
            continue
        action, item = match.groups()
        if action == "Paused":
            require(active == item, f"Unexpected pause: {item}, active={active}")
            active = None
        else:
            require(active is None, f"Play without prior pause: {active} -> {item}")
            active = item
            plays += 1
    require(plays > 0, "Missing playback events")
    return plays


def main():
    default = pathlib.Path(__file__).resolve().parents[1] / "docs/artifacts/smoke-2026-09-05"
    directory = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else default
    first = read_log(directory, "playback.json")
    restarted = read_log(directory, "restart-runtime.json")
    counts = [check_playback(first), check_playback(restarted)]

    memory_index = next(i for i, line in enumerate(first) if "Memory warning:" in line)
    loads = re.findall(r"\bLoad (game_\d+)", "".join(first[memory_index:]))
    require(loads == ["game_0007", "game_0010", "game_0011", "game_0012"],
            f"Unexpected post-warning loads: {loads}")
    debugger = "".join(read_log(directory, "debugger.json"))
    require("(BOOL) YES" in debugger and "(BOOL) $0 = NO" in debugger,
            "Missing observed prefetch transition")

    server = (directory / "mock-failure.log").read_text().splitlines()
    def times(endpoint):
        return [datetime.datetime.fromisoformat(line.split()[0])
                for line in server if f"POST {endpoint} →" in line]
    report = times("/api/report/content/v1/reportContent")
    block = times("/api/user/block/v1/blockUser")
    require(len(report) == 4 and len(block) == 2,
            f"Unexpected request counts: report={len(report)}, block={len(block)}")
    gaps = [(report[1] - report[0]).total_seconds(),
            (report[3] - report[2]).total_seconds(),
            (block[1] - block[0]).total_seconds()]
    require(all(5 <= gap < 7 for gap in gaps), f"Unexpected retry gaps: {gaps}")
    require((report[2] - report[1]).total_seconds() > 20,
            "Missing dormant interval before foreground retry")

    restart_loads = re.findall(r"\bLoad (game_\d+)", "".join(restarted))
    require("game_0012" in restart_loads, "Did not traverse reported/blocked gap")
    for item in restart_loads:
        require(item not in {"game_0003", "game_0010"}, f"Reported item loaded: {item}")
        creator = int(item.split("_")[1]) % 7 + 1
        require(creator not in {2, 3, 5}, f"Blocked creator loaded: {item}")
    require(any("refresh=1" in line for line in server), "Missing second feed page")
    scroll = json.loads((directory / "restart-scroll.json").read_text())
    require(scroll["ok"] and scroll["data"]["all_succeeded"], "Restart gestures failed")

    def durable_states(lines):
        return [json.loads(line) for line in lines
                if line.startswith('{"blockedCreatorIDs"')]
    before = durable_states(read_log(directory, "debugger.json"))
    after = durable_states(restarted)
    require(before and after, "Missing durable state reads")
    for state in [before[-1], after[-1]]:
        require(set(state["blockedCreatorIDs"]) == {"creator_2", "creator_3", "creator_5"},
                "Blocked IDs were not preserved")
        require(set(state["reportedSekaiIDs"]) == {"game_0003", "game_0010"},
                "Reported IDs were not preserved")

    samples = {}
    for line in restarted:
        match = re.match(r"SMOKE_JS(?: (\w+))? slot=(\d) value=Optional\((\{.*\})\) error=nil", line)
        if match:
            stage, slot, value = match.groups()
            samples.setdefault(stage or "INITIAL", {})[int(slot)] = json.loads(value)
    for stage in ["INITIAL", "PROFILE_A", "PROFILE_B", "RETURN"]:
        require(len(samples.get(stage, {})) == 3, f"Missing three JS samples: {stage}")
        playing = [v["id"] for v in samples[stage].values() if v["playing"]]
        expected = [] if stage.startswith("PROFILE") else ["/content/game_0012"]
        require(playing == expected, f"Unexpected JS playback in {stage}: {playing}")
    for slot in range(3):
        require(samples["PROFILE_A"][slot] == samples["PROFILE_B"][slot],
                f"Off-screen document changed during profile dwell: slot {slot}")
    current_slot = next(slot for slot, value in samples["RETURN"].items() if value["playing"])
    require(samples["RETURN"][current_slot]["frames"] > samples["PROFILE_B"][current_slot]["frames"],
            "Current document frame counter did not resume")

    print(json.dumps({"result": "passed", "play_completions_by_process": counts,
                      "retry_response_gaps_seconds": gaps,
                      "report_requests": len(report), "block_requests": len(block),
                      "post_warning_loads": loads,
                      "dom_sample_stages": list(samples)}, indent=2))


if __name__ == "__main__":
    main()
