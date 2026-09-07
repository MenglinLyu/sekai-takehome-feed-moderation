# Physical-device performance procedure

Use a physical iPhone and a Release build. Build and configure the project with
Xcode MCP; disable code coverage and disconnect the debugger before measurement.
Use [the recording script](recording-performance.md) for command-line capture,
export, and device selection. Keep the mock implementation unchanged.

The current content path uses direct WebKit navigation with a shared website data
store. See [web content metrics](web-content-metrics.md) for load/display identities,
browser timing availability and cache-evidence limits.

## Latest result

The [20260906-203252-734998 perf report](evidence/performance/20260906-203252-734998/report.md)
compares permanent WebView mounting against the previous attachment implementation.
The original approximately 250 ms stall did not recur; `[10, 40)` contains zero
application hitches. The full trace still has one short hitch and two potential
interaction delays, and content loading remains unresolved. See the report for
partial signpost coverage and unverified Release/memory limitations.

## Capture a repeatable workload

1. Record device model, OS, display refresh rate, thermal state, source revision,
   build configuration, coverage audit, server arguments, and network conditions.
2. Confirm Feed and HTML requests work from the phone before starting capture.
   Preserve the default approximately 5 MB HTML payload and record actual latency.
3. Record the scroll path and measurement window, including normal, rapid, and
   reverse paging. The retained capture summarizes trace seconds [10, 40).
   Record actual gesture coverage and idle/loading periods.
4. Synchronize gesture boundaries with Feed signposts or a screen recording.
   Keep loading pauses and static content distinguishable from active scrolling.
5. Capture Animation Hitches and Points of Interest. Add Time Profiler, Hangs,
   and memory instruments in separate diagnostic runs as needed; record which
   instruments were enabled because profiling changes workload overhead.

Follow the [README requirements](../README.md#hard-requirements): measure scrolling
frame timing, report the numbers and resulting changes, and show what remains
alive with approximately 5 MB items. Report observed hitches and measurement
limits; the README specifies no numerical hitch allowance or fixed scroll duration.

## Read the measurements

- Summarize Built-In Display surface presentations with
  `python3 scripts/summarize_xctrace.py RECORDING_DIRECTORY --start 10 --end 40`.
  Keep zero-presentation samples and weight averages by sample duration. Display
  presentation FPS is different from JavaScript animation callbacks and CPU time.
- Correlate hitch events with dragging/deceleration, snapshots, WebView attachment,
  navigation, readiness, and playback markers. Elapsed asynchronous intervals are
  not continuous main-thread CPU work. Correlation alone does not identify cause.
- Inspect commit, render, GPU, and presentation stages for individual hitches.
  Do not add overlapping pipeline durations or equate frame lifetime with hitch
  duration. Use main-thread stacks and scheduling states to distinguish CPU work
  from waits, and inspect Hangs separately from Animation Hitches.
- Show memory use and the number of live WebViews while scrolling approximately
  5 MB items. Identify which processes were measured. Loading and cancellation
  timings can help investigate observed stalls.

## Analyze exported phase intervals

`scripts/analyze_performance.py` pairs Feed Begin/End markers by process, name,
and interval ID, reports unmatched boundaries, and correlates interaction delays
with WebKit wait stacks. It requires `fps.csv`, `feed-signposts.csv`, `hitches.xml`,
and `toc.xml` from the recorder, plus diagnostic exports in `analysis/`:

```sh
RUN=/path/to/recording
mkdir -p "$RUN/analysis"
xcrun xctrace export --input "$RUN/recording.trace" \
  --xpath '/trace-toc/run[@number="1"]/data/table[@schema="potential-hangs" or @schema="device-thermal-state-intervals"]' \
  --output "$RUN/analysis/context.xml"
xcrun xctrace export --input "$RUN/recording.trace" \
  --xpath '/trace-toc/run[@number="1"]/data/table[@schema="context-switch-sample"]' \
  --output "$RUN/analysis/context-switch-sample.xml"
python3 scripts/analyze_performance.py "$RUN"
```

Inspect `toc.xml` first: additional diagnostic instruments must have captured the
requested tables. The analyzer writes `analysis/summary.json` and `intervals.csv`.
It summarizes display samples over the full recording and [10, 40); use captures that cover that window. Phase statistics use the exported signpost range, which can differ from the display range. Inspect `signpost_time_range_s` before interpreting gesture coverage or absent early events. It also retains representative stacks for each potential delay and counts main-thread activity-state wait samples across the full stack export. Context-switch sample counts are not time-weighted CPU percentages.
Open loads are incomplete observations. Summed load durations include concurrency
and do not measure CPU time or transferred bytes. Compare one change at a time
under the same workload before claiming a performance improvement.

Keep results, analysis, and compact supporting exports in
[`docs/evidence/performance/`](evidence/performance/README.md), which Git can track.
Raw Instruments traces and large stack exports remain local in
`docs/artifacts/recordings/`. See the evidence index for the retained files and
how to archive another run.
