#!/usr/bin/env python3
"""Export Activity Monitor process memory intervals and an explicitly scoped summary."""

import argparse
import csv
import json
import math
from pathlib import Path
import re
import xml.etree.ElementTree as ET

MIB = 1024 * 1024


def memory_samples(path, host_pid):
    root = ET.parse(path).getroot()
    references = {e.get("id"): e for e in root.iter() if e.get("id")}

    def resolve(element):
        seen = set()
        while element is not None and element.get("ref"):
            ref = element.get("ref")
            if ref in seen or ref not in references:
                raise ValueError("Invalid memory XML reference: " + ref)
            seen.add(ref)
            element = references[ref]
        return element

    def numeric(element):
        element = resolve(element)
        if element is None or element.tag == "sentinel":
            return None
        try:
            result = float(element.text)
        except (TypeError, ValueError):
            return None
        return result if math.isfinite(result) and result >= 0 else None

    def process_info(element):
        element = resolve(element)
        if element is None:
            return "", None, ""
        pid = numeric(element.find("pid"))
        name = element.findtext("name") or re.sub(r" \(\d+\)$", "", element.get("fmt", ""))
        return name, int(pid) if pid is not None else None, element.get("id", "")

    samples, seen = [], set()
    fields = []
    for node in root.findall("node"):
        fields = [c.findtext("mnemonic") for c in node.findall("schema/col")] or fields
        required = {"start", "duration", "pid", "process", "memory-physical-footprint"}
        if not required.issubset(fields):
            raise ValueError("Unsupported memory schema; required process/footprint columns are missing.")
        for row in node.findall("row"):
            values = dict(zip(fields, row))
            name, _, identity = process_info(values.get("process"))
            pid = numeric(values.get("pid"))
            if pid is None:
                continue
            pid = int(pid)
            if pid != host_pid and "webkit" not in name.lower() and "webcontent" not in name.lower():
                continue
            start, duration = numeric(values.get("start")), numeric(values.get("duration"))
            if start is None or duration is None or duration == 0:
                raise ValueError("Relevant memory row has an invalid sampling interval.")
            responsible, responsible_pid, _ = process_info(values.get("responsible-process"))
            kind = "app" if pid == host_pid else ("webcontent" if "webcontent" in name.lower() else "webkit_helper")
            attribution = "app" if pid == host_pid else (
                "responsible_pid_matches_app" if responsible_pid == host_pid else "unverified")
            sample = dict(start_s=start / 1e9, duration_s=duration / 1e9,
                          process=name, pid=pid, process_instance=identity or f"{name}:{pid}",
                          kind=kind, attribution=attribution,
                          responsible_process=responsible, responsible_pid=responsible_pid,
                          footprint_bytes=numeric(values.get("memory-physical-footprint")),
                          real_bytes=numeric(values.get("memory-real")),
                          compressed_bytes=numeric(values.get("memory-compressed")))
            key = tuple(sample.values())
            if key not in seen:
                seen.add(key)
                samples.append(sample)
    return sorted(samples, key=lambda s: (s["start_s"], s["pid"], s["process_instance"]))


def window_stats(samples, start, end):
    selected = []
    for sample in samples:
        left = max(start, sample["start_s"])
        right = min(end, sample["start_s"] + sample["duration_s"])
        if right > left and sample["footprint_bytes"] is not None:
            selected.append((left, right, sample["footprint_bytes"] / MIB))
    if not selected:
        return None
    selected.sort()
    for previous, current in zip(selected, selected[1:]):
        if current[0] < previous[1] - 1e-8:
            raise ValueError("Overlapping memory intervals for one process; refusing to double-count.")
    duration = sum(right - left for left, right, _ in selected)
    mean = sum((right - left) * value for left, right, value in selected) / duration
    mean_time = sum((right - left) * (left + right) / 2 for left, right, _ in selected) / duration
    variance = sum((right - left) * ((left + right) / 2 - mean_time) ** 2 for left, right, _ in selected)
    covariance = sum((right - left) * ((left + right) / 2 - mean_time) * (value - mean)
                     for left, right, value in selected)
    return dict(sample_count=len(selected), observed_duration_s=duration,
                requested_window_start_s=start, requested_window_end_s=end,
                coverage_fraction=duration / (end - start), first_observed_s=selected[0][0],
                last_observed_s=selected[-1][1], peak_mib=max(v for _, _, v in selected),
                minimum_mib=min(v for _, _, v in selected), time_weighted_mean_mib=mean,
                first_mib=selected[0][2], last_mib=selected[-1][2],
                delta_mib=selected[-1][2] - selected[0][2],
                trend_mib_per_minute=covariance / variance * 60 if variance > 0 else None)


def summarize_memory(output, steady_start=10, steady_end=None, host_pid=None):
    if not math.isfinite(steady_start) or steady_start < 0 or (
            steady_end is not None and (not math.isfinite(steady_end) or steady_end <= steady_start)):
        raise ValueError("Invalid memory steady window.")
    if host_pid is None:
        metadata_path = output / "metadata.json"
        metadata = json.loads(metadata_path.read_text()) if metadata_path.exists() else {}
        host_pid = metadata.get("app_pid")
    if host_pid is None:
        target = ET.parse(output / "toc.xml").find('.//run[@number="1"]/info/target/process')
        if target is not None:
            host_pid = int(target.get("pid"))
    if not isinstance(host_pid, int) or isinstance(host_pid, bool) or host_pid <= 0:
        raise ValueError("App PID is missing; cannot identify host memory. Supply --host-pid.")
    samples = memory_samples(output / "memory.xml", host_pid)
    if not any(s["kind"] == "app" and s["footprint_bytes"] is not None for s in samples):
        raise ValueError("No valid app physical-footprint samples; memory capture is incomplete.")
    with (output / "memory.csv").open("w", newline="") as file:
        writer = csv.DictWriter(file, fieldnames=list(samples[0]))
        writer.writeheader()
        writer.writerows(samples)
    end = max(s["start_s"] + s["duration_s"] for s in samples)
    groups = {}
    for sample in samples:
        groups.setdefault((sample["pid"], sample["process_instance"]), []).append(sample)
    processes = []
    warnings = []
    for group in groups.values():
        first = group[0]
        processes.append(dict(
            process=first["process"], pid=first["pid"], process_instance=first["process_instance"],
            kind=first["kind"], attributions=sorted({s["attribution"] for s in group}),
            responsible_pids=sorted({s["responsible_pid"] for s in group if s["responsible_pid"] is not None}),
            missing_footprint_samples=sum(s["footprint_bytes"] is None for s in group),
            full=window_stats(group, 0, end),
            steady_window=window_stats(group, steady_start, steady_end if steady_end is not None else end)))
    if not any(p["kind"] == "webcontent" for p in processes):
        warnings.append("No WebContent samples were observed. Host-only data does not establish total WebView memory.")
    if any("unverified" in p["attributions"] for p in processes):
        warnings.append("Some WebKit processes have unverified ownership and may belong to other apps. Do not add them to the app footprint.")
    if any(p["steady_window"] is None for p in processes if p["kind"] == "app"):
        warnings.append("The requested steady window contains no valid app samples; steady usage is unavailable.")
    if any(p["missing_footprint_samples"] for p in processes):
        warnings.append("Unavailable memory values remain blank/null; they are not counted as zero.")
    summary = dict(metric="Activity Monitor memory-physical-footprint", unit="MiB (1048576 bytes)",
                   host_pid=host_pid, observed_end_s=end, processes=processes, warnings=warnings,
                   limitations=[
                       "Peak is the largest sampled footprint, not an instantaneous peak between samples.",
                       "Steady-window mean is duration-weighted over observed intervals only; coverage is reported. The window is not proof of stability.",
                       "Trend is a duration-weighted linear fit at interval midpoints, not a leak diagnosis or a scrolling-only measurement.",
                       "Processes are reported separately. Missing/terminated processes are not zero-filled and per-process peaks are not summed.",
                       "Responsible PID matching supports attribution; WebContent visibility and responsibility depend on the OS. This is not a complete WebKit memory budget.",
                       "Activity Monitor adds profiling overhead. Compare like-for-like captures and correlate with Feed signposts."])
    (output / "memory-summary.json").write_text(json.dumps(summary, indent=2, allow_nan=False) + "\n")
    lines = ["# Memory measurements", "", "Metric: sampled physical footprint, in MiB (1,048,576 bytes).", "",
             "| Process / PID | Attribution | Peak MiB | Steady mean MiB | Steady coverage | Trend MiB/min |",
             "| --- | --- | ---: | ---: | ---: | ---: |"]
    def display(value):
        return "n/a" if value is None else f"{value:.3f}"
    for process in processes:
        full, steady = process["full"] or {}, process["steady_window"] or {}
        name = process["process"].replace("|", "\\|")
        lines.append(f"| {name} / {process['pid']} | {', '.join(process['attributions'])} | "
                     f"{display(full.get('peak_mib'))} | {display(steady.get('time_weighted_mean_mib'))} | "
                     f"{display(steady.get('coverage_fraction'))} | {display(steady.get('trend_mib_per_minute'))} |")
    window_end = steady_end if steady_end is not None else end
    lines += ["", f"Steady window: [{steady_start:.3f}, {window_end:.3f}) trace seconds. Coverage is a fraction (0–1).",
              "Full-recording deltas, trends, sample counts and observed durations are in memory-summary.json.", ""]
    lines += ["- " + note for note in warnings + summary["limitations"]]
    (output / "memory-report.md").write_text("\n".join(lines) + "\n")
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--host-pid", type=int)
    parser.add_argument("--steady-start", type=float, default=10)
    parser.add_argument("--steady-end", type=float)
    args = parser.parse_args()
    try:
        summarize_memory(args.directory, args.steady_start, args.steady_end, args.host_pid)
    except (ValueError, OSError, ET.ParseError) as error:
        parser.exit(1, f"Memory summary failed: {error}\n")
    print(args.directory / "memory-report.md")


if __name__ == "__main__":
    main()
