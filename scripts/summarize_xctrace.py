#!/usr/bin/env python3
"""Summarize xctrace displayed-surface FPS and application hitches.

Input XML files are exported from the Animation Hitches template. FPS measures
built-in display surface swaps, not JavaScript callbacks or CPU frame time.
"""

import argparse
import csv
import json
from pathlib import Path
import statistics
import xml.etree.ElementTree as ET


def rows(path):
    root = ET.parse(path).getroot()
    references = {e.attrib["id"]: e for e in root.iter() if "id" in e.attrib}

    def resolve(element):
        while "ref" in element.attrib:
            element = references[element.attrib["ref"]]
        return element

    names = []
    for node in root.findall("node"):
        # Exports of one schema may contain multiple nodes; later nodes can omit it.
        names = [c.findtext("mnemonic") for c in node.findall("schema/col")] or names
        for row in node.findall("row"):
            yield {name: resolve(value) for name, value in zip(names, row)}


def number(element):
    return float(element.text)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--start", type=float, default=10)
    parser.add_argument("--end", type=float, default=40)
    parser.add_argument("--process", default="Sekai")
    args = parser.parse_args()
    if args.end <= args.start:
        parser.error("end must exceed start")
    samples = []
    for row in rows(args.directory / "fps.xml"):
        display = row["display-name"].text
        if display != "Built-In Display":
            continue
        start = number(row["start"]) / 1e9
        duration = number(row["duration"]) / 1e9
        count = int(number(row["count"]))
        samples.append(dict(start_s=start, duration_s=duration,
                            presented_surfaces=count, fps=count / duration))
    samples.sort(key=lambda item: item["start_s"])
    selected = [s for s in samples if s["start_s"] >= args.start
                and s["start_s"] + s["duration_s"] <= args.end + 1e-6]
    if not selected:
        raise ValueError("No complete FPS samples in the requested interval")
    cursor = args.start
    for sample in selected:
        if abs(sample["start_s"] - cursor) > 1e-6:
            raise ValueError("FPS samples do not continuously cover the window")
        cursor += sample["duration_s"]
    if abs(cursor - args.end) > 1e-6:
        raise ValueError("FPS samples do not cover the entire requested window")
    with (args.directory / "fps.csv").open("w", newline="") as file:
        writer = csv.DictWriter(file, fieldnames=list(samples[0]))
        writer.writeheader()
        writer.writerows(samples)

    all_hitches = []
    for row in rows(args.directory / "hitches.xml"):
        start = number(row["start"]) / 1e9
        duration = number(row["duration"]) / 1e9
        process = row["process"]
        all_hitches.append(dict(start_s=start, duration_ms=duration * 1000,
                               process=process.findtext("name") or process.attrib.get("fmt", ""),
                               is_system=row["is-system"].text))
    hitch_rows = [h for h in all_hitches if h["start_s"] < args.end
                  and h["start_s"] + h["duration_ms"] / 1000 > args.start]
    app_hitches = [h for h in hitch_rows if h["process"] == args.process
                   or h["process"].startswith(args.process + " (")]
    elapsed = sum(s["duration_s"] for s in selected)
    summary = dict(
        window_start_s=args.start, window_end_s=args.end,
        duration_s=elapsed, sample_count=len(selected),
        metric="Built-In Display presented surfaces per second (xctrace)",
        presented_surfaces=sum(s["presented_surfaces"] for s in selected),
        average_fps=sum(s["presented_surfaces"] for s in selected) / elapsed,
        median_one_second_fps=statistics.median(s["fps"] for s in selected),
        minimum_one_second_fps=min(s["fps"] for s in selected),
        maximum_one_second_fps=max(s["fps"] for s in selected),
        zero_presentation_seconds=sum(s["duration_s"] for s in selected if s["presented_surfaces"] == 0),
        application_hitch_count=len(app_hitches),
        application_maximum_hitch_ms=max((h["duration_ms"] for h in app_hitches), default=0),
        all_hitches_in_window=hitch_rows,
        full_recording_duration_s=sum(s["duration_s"] for s in samples),
        full_recording_presented_surfaces=sum(s["presented_surfaces"] for s in samples),
        full_recording_average_fps=sum(s["presented_surfaces"] for s in samples) / sum(s["duration_s"] for s in samples),
        full_recording_hitches=all_hitches,
        limitation="Presentation FPS includes idle/loading intervals; correlate with Feed gesture signposts to interpret scrolling performance.",
    )
    (args.directory / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
