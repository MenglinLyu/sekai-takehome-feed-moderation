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
```

Use `--build` for the first run after adding or changing signposts. Direct mode
cannot verify the installed binary's configuration, coverage, or source revision.
Both modes launch Sekai through xctrace; they do not attach to an existing PID.
If xctrace reports that Sekai is already running, close the app and retry.

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
Generated recordings are ignored by Git. Each successful run contains:

- `recording.trace`: Animation Hitches plus Points of Interest recording.
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

For the predefined 30-second window in a completed 50-second run:

```sh
python3 scripts/summarize_xctrace.py docs/artifacts/recordings/RUN --start 10 --end 40
```

FPS here counts display surface presentations, not JavaScript animation callbacks.
Static pages can produce zero presentations without a hitch. The summary is not
automatically restricted to scrolling; correlate it with the signpost timeline.
The first and last bins can include launch or partial-recording time.

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
```

These tests cover Darwin start notifications, failed startup, Ctrl+C saving,
timeout cleanup, device selection, and XML reference resolution/deduplication.
They do not establish application performance.
