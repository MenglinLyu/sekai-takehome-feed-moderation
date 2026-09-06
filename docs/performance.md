# Physical-device performance procedure

Use a physical iPhone and a Release build. Build and configure the project with
Xcode MCP; disable code coverage and disconnect the debugger before measurement.
Use [the recording script](recording-performance.md) for command-line capture,
export, and device selection. Keep the mock implementation unchanged.

## Capture a repeatable workload

1. Record device model, OS, display refresh rate, thermal state, source revision,
   build configuration, coverage audit, server arguments, and network conditions.
2. Confirm Feed and HTML requests work from the phone before starting capture.
   Preserve the default approximately 5 MB HTML payload and record actual latency.
3. Select the measurement window before inspecting results. For a 50-second
   recording, use trace seconds [10, 40). Maintain continuous scrolling throughout
   that window, including normal, rapid, and reverse paging.
4. Synchronize gesture boundaries with Feed signposts or a screen recording.
   Keep loading pauses and static content distinguishable from active scrolling.
5. Capture Animation Hitches and Points of Interest. Add Time Profiler, Hangs,
   and memory instruments in separate diagnostic runs as needed; record which
   instruments were enabled because profiling changes workload overhead.

The acceptance target is **30 seconds of continuous scrolling, fewer than five
application hitches, every hitch below 100 ms**. Numerical hitch counts alone do
not establish a pass when continuous scrolling has not been verified.

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
- Measure host and WebContent steady/peak memory, long-scroll growth, WebView
  lifetime counts, settlement-to-visible/playable latency, and canceled loads.
  Test physical memory pressure and process termination separately from simulator
  notification-handler checks.

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
It summarizes the full recording and [10, 40); use captures that cover that window.
Open loads are incomplete observations. Summed load durations include concurrency
and do not measure CPU time or transferred bytes. Compare one change at a time
under the same workload before claiming a performance improvement.

Generated recordings and analysis outputs are local artifacts; do not commit
them as test procedures. This document contains no retained measurement results.
