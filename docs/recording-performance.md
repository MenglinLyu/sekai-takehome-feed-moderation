# Command-line physical-device recording

Run these commands from the repository root. Recording and export use `xcrun
xctrace`; the Instruments GUI is not opened. Python 3 and the selected Xcode
command-line tools are required.

```sh
# Build Release with coverage disabled, install, launch, and record for 50 seconds.
./scripts/record_performance.py --build

# Launch and record the already installed app, without building or installing.
./scripts/record_performance.py

# Change duration or provide an explicit server address after switching networks.
./scripts/record_performance.py --duration 60 --base-url http://YOUR_MAC_IP:8787

# Add per-process memory measurements during a longer scrolling scenario.
./scripts/record_performance.py --build --memory --duration 120

# Select a repeatable steady observation window in trace-relative seconds.
./scripts/record_performance.py --memory --duration 120 \
  --memory-steady-start 30 --memory-steady-end 110
```

Use `--build` for the first run after adding or changing signposts. Direct mode
cannot verify the installed binary's configuration, coverage, or source revision.
Without `--memory`, both modes launch Sekai through xctrace; they do not attach
to an existing PID. Memory mode starts an all-process recording, then launches
Sekai through `devicectl` after the tracing-start notification. This includes
observable WebKit helpers instead of limiting Activity Monitor to the host.
The app PID returned by devicectl is retained for attribution. Close Sekai before
recording when a fresh launch is required; the script does not terminate it for you.

## Device and server

By default, the script discovers devices with `xcrun devicectl list devices`
and automatically selects the sole connected physical iOS device. It prints
the selected name and UDID and uses that UDID for building, installing, and
recording. Simulators, watches, and disconnected devices are excluded; wired
and connected wireless iOS devices are eligible.

If multiple eligible devices are connected, the script lists their names,
models, and UDIDs and exits before building or recording. Select one explicitly
with `--device UDID`. If none are connected, it exits with connection guidance.
An explicitly selected device must also be connected and physical; there is
no fallback to another device, simulator, or the Mac.
Keep the phone unlocked, with Developer Mode enabled and the development
certificate trusted. Operate the physical device manually; RocketSim controls
simulators.

The default build scheme is `Sekai`; use `--scheme NAME` for a local performance
scheme if needed. Configure signing for your own development team in Xcode MCP. The script builds with
`-configuration Release ENABLE_CODE_COVERAGE=NO` into
`Sekai/DerivedData/Performance`, checks the executable for LLVM coverage sections,
and installs only after a successful build. Existing signing settings are used.

The server address comes from `--base-url`, then `SEKAI_BASE_URL`, then the Mac's
current IPv4 address on `en0`, port 8787. Use `--interface` or `--port` to change
automatic discovery. The address is passed to the launched app through its
`SEKAI_BASE_URL` environment variable.

The resolved address is also written into the `--scheme` target's `LaunchAction`
environment variables (`SEKAI_BASE_URL`) in its user-specific `.xcscheme`, so a
later manual run/debug of that same scheme from Xcode uses the same server
instead of falling back to `http://127.0.0.1:8787`. This only updates a scheme
that already has a user-specific xcscheme file (for example, one that has been
run from Xcode at least once); it does not create one from scratch, and it is
skipped with a note when no such file exists yet.

The script reuses any service already listening on port 8787. If the port is
free, it starts the mock for the recording and stops only that owned process on
exit. An explicit `--base-url` or `SEKAI_BASE_URL` remains externally managed.

The phone must reach the Mac on the same network. The script checks the feed
endpoint from the Mac before recording; that does not prove phone-to-Mac
reachability. It does not stop or reconfigure an existing server.

## Terminal lifecycle and output

Wait for `RECORDING STARTED` before performing the scenario. This message follows
xctrace's Darwin start notification, not subprocess creation or a fixed delay.
At the time limit, `RECORDING ENDED` indicates that interaction can stop. Saving
may take substantially longer than the recording. `SAVED` is printed only after
xctrace exits successfully and the trace's FPS data is exported and validated.

Press Ctrl+C during recording to request early termination and save the trace.
`STOP REQUESTED` is distinct from confirmed completion; allow the save to finish.
Failed startup, disconnected devices, missing FPS data, and timeouts return a
nonzero exit code and retain artifacts. Startup has a 90-second timeout; saving
has a 240-second allowance, configurable with `--startup-timeout` and
`--save-timeout`. Timeout cleanup targets only the subprocess started by this run.

Default output: `docs/artifacts/recordings/YYYYMMDD-HHMMSS-microseconds/`.
Use `--output PATH` for a new directory; existing directories are never overwritten.
Raw recordings are ignored by Git. Copy completed results and analysis to
[`docs/evidence/performance/`](evidence/performance/README.md) for version control.
Each successful run contains:

- `recording.trace`: Animation Hitches plus Points of Interest recording;
  Activity Monitor is included with `--memory`.
- `fps.csv` / `fps.xml`: Built-In Display presented surfaces per second.
- `hitches.xml`: application and system hitch events.
- `signposts-*.xml`: signpost tables; filter subsystem `com.sekai.takehome`.
- `feed-signposts.csv`: deduplicated Feed events with trace-relative seconds,
  Begin/End/Event type, phase name, interval ID, and message. Compare `time_s`
  directly with `start_s` in `fps.csv`; matching phase/ID pairs delimit intervals.
- `toc.xml`: table schemas and recording metadata.
- `metadata.json`: selected device, server, commands, lifecycle, coverage audit
  for build mode, and whether Feed signposts were found.
- `record.log`, `mock.log` when the script manages the local mock, plus
  `build.log` and `install.log` when building.

For the `[10, 40)` window used in the retained capture:

```sh
python3 scripts/summarize_xctrace.py docs/artifacts/recordings/RUN --start 10 --end 40
```

FPS here counts display surface presentations, not JavaScript animation callbacks.
Static pages can produce zero presentations without a hitch. The summary is not
automatically restricted to scrolling; correlate it with the signpost timeline.
The first and last bins can include launch or partial-recording time.

## Memory measurements

`--memory` is optional; FPS and Feed exports are still produced. The additional
instrument changes profiling overhead, so compare captures with the same options.
All-process capture can include activity from other apps in the raw trace. The
memory CSV/report selects only the launched app PID and observed WebKit processes.

Memory mode also produces:

- `memory.xml`: original `activity-monitor-process-live` table.
- `memory.csv`: trace-relative start/duration, process name/instance/PID,
  responsible process/PID, attribution, physical footprint, real and compressed
  memory in bytes. Unavailable measurements remain blank.
- `memory-summary.json`: per-process sampled peak, first/last values, delta,
  duration-weighted mean, observed duration/coverage, and linear trend in MiB/min.
  Full-recording and steady-window statistics are separate.
- `memory-report.md`: readable peak/steady/trend table and measurement limits.
- `launch.json` / `launch.log`: devicectl launch result, including the app PID.

The primary metric is Activity Monitor's **physical footprint**, not virtual
address space, allocated heap bytes, payload size, or device free memory. Real
and compressed memory are retained separately; they are not added to footprint.
Values in summaries use MiB (1,048,576 bytes).

The steady observation window defaults to `[10, observed end)` seconds. Set
`--memory-steady-start` and `--memory-steady-end` to match your workload. Its mean
weights valid intervals by duration and reports actual coverage. An empty window
(including a short Ctrl+C capture) yields `null`/`n/a`, not a fabricated number.
A selected window is not proof that usage stabilized. The trend is a weighted
linear fit at interval midpoints; growth alone is not a leak diagnosis.

App and WebContent/helper processes are reported separately. Only an exact
responsible-PID match is marked as associated with the app. Other observed WebKit
processes remain `unverified`, including helpers belonging to another app or
those whose ownership the OS does not expose. No combined memory total is claimed:
per-process peaks need not occur together, missing processes are not zero, and
three WebViews need not map to three WebContent processes. Missing WebContent is
reported as a coverage limitation. Missing memory schema or valid host footprint
samples fails the run while retaining artifacts.

For a long-scroll check, use a verified Release build and approximately 5 MB mock
content. Allow initial loading, then use repeatable normal/rapid/reverse paging
with enough dwell time for content to play. Retain Feed signposts and describe the
actual path. Include a final idle dwell to observe retained usage. Compare peak,
steady-window mean, first/last delta and trend across equal workloads; sampled
peaks can miss short spikes. This mode does not inject memory warnings or prove
the live WebView count.

Recompute a different window from the retained XML and metadata without a device:

```sh
python3 scripts/summarize_memory.py docs/artifacts/recordings/RUN \
  --steady-start 30 --steady-end 110
```

Use `--host-pid PID` only when importing an existing all-process export without
the recorder's `metadata.json`. The script otherwise reads the recorded PID, or
the launched target in `toc.xml` for a launch-targeted trace.

## Feed phase markers

The Release-enabled `os_signpost` subsystem is `com.sekai.takehome`, category
`PointsOfInterest`. Durations spanning `await` or navigation measure elapsed
latency, not continuous main-thread CPU work. Correlation with a hitch identifies
a phase to investigate; it does not establish that the phase caused the hitch.

| Marker | Meaning |
| --- | --- |
| `FeedDrag`, `FeedDeceleration` | User dragging and inertial scrolling, closed on settlement, interruption, obscuring, or backgrounding. |
| `FeedSettle`, `FeedCurrentItem` | Page settlement and the resulting index/item ID. |
| `FeedSnapshot` | Changed item IDs through diffable snapshot completion, layout, and window update; includes revision and counts. |
| `FeedLayout`, `FeedRenderCells` | Size-change layout work and visible-cell presentation updates. |
| `FeedAssignWindow` | Assignment of the current/adjacent three-slot window and pagination trigger. |
| `FeedWebViewAttach`, `FeedWebViewDetach` | Native view hierarchy changes associated with an item. |
| `FeedFilter`, `FeedPageLoad`, `FeedPageReceived` | Visibility filtering, page request/publication latency, and response count. |
| `WebPoolReconcile` | Serialized pool reconciliation, including asynchronous JS waits. |
| `WebLoadToReady` | Navigation request through playback-function readiness, with item, slot, and current/adjacent role at bind time. |
| `WebNavigationCommit`, `WebNavigationFinished`, `WebContentReady` | WebKit navigation milestones and readiness result. |
| `WebReadinessJS`, `WebPauseJS`, `WebPlayJS` | JavaScript callback round-trip latency. |
| `WebSlotReset`, `WebProcessTerminated` | Slot document replacement and WebContent process termination. |
| `FeedEligibility`, `FeedVisibility`, `FeedLifecycle`, `FeedMemoryWarning` | Playback target and lifecycle/memory transitions. |

Intervals use unique signpost IDs, including overlapping loads and snapshots.
Cancellation/reset and stale snapshot completions close their intervals, and
released interval owners have a fallback end marker. Metadata contains opaque
item IDs and counts, not content URLs. No per-frame scroll callback is logged.

## Validate the recording scripts

Run the script tests without a device or an actual performance capture:

```sh
python3 -m unittest discover -s scripts -p 'test_record_performance.py' -v
python3 -m unittest discover -s scripts -p 'test_summarize_memory.py' -v
```

These tests cover Darwin start notifications, failed startup, Ctrl+C saving,
timeout cleanup, device selection, and XML reference resolution/deduplication.
Memory tests cover all-process command selection, launch timing/PID attribution,
missing-schema failures, XML references, byte units, duration weighting, missing
values, short captures and trend calculations. They do not establish application
performance. The parser was also exercised against a short local macOS Activity
Monitor export; that validates the export format, not iPhone memory behavior.
