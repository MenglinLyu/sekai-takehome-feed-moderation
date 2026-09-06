"""Analyze exported Feed intervals and interaction delays without modifying raw exports."""
import argparse
import collections
import csv
import json
from pathlib import Path
import statistics
import xml.etree.ElementTree as ET

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("directory", type=Path, help="Recording directory containing analysis exports")
args = parser.parse_args()
RUN = args.directory.resolve()
HERE = RUN / "analysis"
events = list(csv.DictReader((RUN / "feed-signposts.csv").open()))
pending, intervals, unmatched_ends = {}, [], []
for event in events:
    key = (event["process"], event["name"], event["signpost_id"])
    if event["event_type"] == "Begin":
        assert key not in pending
        pending[key] = event
    elif event["event_type"] == "End":
        if key not in pending:
            unmatched_ends.append(event)
            continue
        begin = pending.pop(key)
        start, end = float(begin["time_s"]), float(event["time_s"])
        assert end >= start
        intervals.append(dict(name=event["name"], signpost_id=event["signpost_id"],
                              start_s=start, end_s=end, duration_ms=(end-start)*1000,
                              begin_message=begin["message"], outcome=event["message"]))

def xml_rows(path):
    root = ET.parse(path).getroot()
    refs = {e.get("id"): e for e in root.iter() if e.get("id")}
    def resolve(e):
        while e.get("ref"):
            e = refs[e.get("ref")]
        return e
    return root, resolve

fps = list(csv.DictReader((RUN / "fps.csv").open()))
def fps_summary(start, end):
    selected = [s for s in fps if start <= float(s["start_s"]) < end]
    duration = sum(float(s["duration_s"]) for s in selected)
    surfaces = sum(int(s["presented_surfaces"]) for s in selected)
    return dict(duration_s=duration, surfaces=surfaces, average_fps=surfaces/duration,
                zero_presentation_s=sum(float(s["duration_s"]) for s in selected
                                        if int(s["presented_surfaces"]) == 0))

scroll = [i for i in intervals if i["name"] in ("FeedDrag", "FeedDeceleration")]
segments = []
for interval in sorted(scroll, key=lambda i: i["start_s"]):
    start, end = interval["start_s"], interval["end_s"]
    # Bridge only the few microseconds between paired end/begin marker calls.
    if segments and start - segments[-1][1] < 0.00001:
        segments[-1][1] = max(segments[-1][1], end)
    else:
        segments.append([start, end])

stats = {}
for name in sorted({i["name"] for i in intervals}):
    selected = [i for i in intervals if i["name"] == name]
    durations = [i["duration_ms"] for i in selected]
    stats[name] = dict(count=len(selected), median_ms=statistics.median(durations),
                       max_ms=max(durations), outcomes=dict(collections.Counter(i["outcome"] for i in selected)))

# Multi-schema exports omit later schema definitions. Identify nodes using the
# original TOC's table indices instead of reusing the first node's column names.
toc_tables = ET.parse(RUN / "toc.xml").findall(".//run/data/table")
root, resolve = xml_rows(HERE / "context.xml")
hangs, thermal = [], []
for node in root.findall("node"):
    index = int(node.get("xpath").split("table[")[-1].split("]")[0]) - 1
    schema = toc_tables[index].get("schema")
    for row in node.findall("row"):
        values = [resolve(e) for e in row]
        if schema == "potential-hangs":
            hangs.append(dict(start_s=int(values[0].text)/1e9,
                              duration_ms=int(values[1].text)/1e6,
                              kind=values[2].get("fmt"), thread=values[3].get("fmt")))
        elif schema == "device-thermal-state-intervals":
            thermal.append(dict(start_s=int(values[0].text)/1e9,
                                duration_s=int(values[1].text)/1e9, state=values[3].text))

root, resolve = xml_rows(HERE / "context-switch-sample.xml")
wait_stacks = []
for row in root.findall(".//row"):
    values = [resolve(e) for e in row]
    t = int(values[0].text)/1e9
    if any(h["start_s"] <= t < h["start_s"] + h["duration_ms"] / 1000 for h in hangs) and "Main Thread" in values[1].get("fmt", ""):
        frames = [resolve(e).get("name", "") for e in values[5]]
        if any("waitForDidUpdateActivityState" in f for f in frames):
            wait_stacks.append(dict(time_s=t, state=values[4].get("fmt"), frames=frames))

loads = [i for i in intervals if i["name"] == "WebLoadToReady"]
summary = dict(
    recording=RUN.name, full_recording=fps_summary(0, float("inf")),
    window_10_40=fps_summary(10, 40),
    hitch_rows=len(ET.parse(RUN / "hitches.xml").findall(".//row")),
    interaction_delays=hangs, thermal=thermal, event_count=len(events),
    scroll_duration_s=sum((i["end_s"]-i["start_s"]) for i in scroll),
    scroll_duration_in_10_40_s=sum(max(0, min(i["end_s"],40)-max(i["start_s"],10)) for i in scroll),
    scroll_segments=segments, longest_scroll_segment_s=max((e-s for s,e in segments), default=0),
    interval_stats=stats, loads=loads,
    canceled_load_elapsed_sum_s=sum(i["duration_ms"]/1000 for i in loads if i["outcome"] == "reset or cancelled"),
    unmatched_ends=unmatched_ends, open_intervals=list(pending.values()),
    microhang_wait_stacks=wait_stacks,
    limitations=["FPS is display presentation rate, not scrolling-only frame rate.",
                 "Open loads are right-censored at trace end, not failed loads.",
                 "Summed load elapsed time includes concurrency and is not CPU time or transferred bytes.",
                 "record-installed metadata does not verify Release configuration, coverage, or source revision."])
(HERE / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
with (HERE / "intervals.csv").open("w", newline="") as file:
    writer = csv.DictWriter(file, fieldnames=["name", "signpost_id", "start_s", "end_s", "duration_ms", "begin_message", "outcome"])
    writer.writeheader()
    writer.writerows(sorted(intervals, key=lambda i: i["start_s"]))
print(json.dumps({k: summary[k] for k in ["full_recording", "window_10_40", "interaction_delays", "scroll_duration_s", "scroll_duration_in_10_40_s", "canceled_load_elapsed_sum_s"]}, indent=2))
