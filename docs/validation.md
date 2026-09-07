# Validation record

## Automated validation — September 5, 2026

- Project created, configured, edited, built, and tested through Xcode MCP.
- Xcode 27 beta 6 (`Xcode-27.0.0-Beta.6.app`), Apple Swift 6.4 (`swiftlang-6.4.0.33.1`).
- App deployment target: iOS 15. Swift language mode: 5. Complete strict-concurrency checking enabled for the app.
- Build for testing: passed. The beta SDK emits an XCTest link warning because its XCTest runtime requires iOS 17; this is a test-runtime limitation, not an app availability error.
- Test destination: iPhone 17 Pro simulator, iOS 27.0.
- XCTest result: **32 passed, 0 failed, 0 skipped, 0 not run**.
- Suites: 10 moderation/storage tests, 10 page-repository tests, 8 view-model tests, 4 policy/DTO tests.

Tests exercise durable restore, corruption, failed writes, suspended concurrent commits, cancellation of accepted actions, deduplicated retry cycles, foreground retry, revision ordering, shared filtering, hidden redelivery, stable deduplication, backend pagination completion, bounded invisible-page loads, request-generation rejection, independent profile sessions, action forwarding, error feedback/retry, and page-task ownership. Tests use injected in-memory actors, controllable continuations, and a manually advanced retry clock. They do not contact the mock server.

The test-review follow-up strengthens four guarantees:

- Retry tests wait for the real worker's terminal event to finish repository delivery before requesting a foreground retry; no fixed number of `Task.yield()` calls is used.
- Concurrent-commit tests confirm the second command is queued while the first save is suspended, then check exact durable states and publication order. The storage double retains all suspended continuations so a concurrent-save regression cannot overwrite a waiter.
- Failed block and report saves preserve existing hidden sets, pending state, revisions, publication history, and the API-call baseline; a subsequent successful command still commits.
- Two added tests verify out-of-order success removes only the matching operation and late events from a completed operation cannot change another pending operation, publish state, or clear its in-flight guard.

An initial run stalled while launching the test host on iOS 26.5. The Xcode MCP workspace was reopened and the complete test plan was rerun successfully on iOS 27.0. The result below is from that completed run; the stalled attempt is not counted as a pass.

Local Xcode result bundle from this run:

`/var/folders/rk/n7k3t56j0rj0tvgx2s34tt3m0000gn/T/ActionArtifacts/default/RunAllTests/Test-Sekai-2026.09.05_16-18-56--0700.xcresult`

## Manual checks

Smoke checks used RocketSim 16.4.2 on iPhone 17 Pro / iOS 26.5 against the unchanged local mock. Passing repository tests does not prove WebKit playback or native frame timing.

- [x] Initial feed loads against the unchanged mock and the current item visibly displays PLAYING. [Screenshot](artifacts/feed-playing.png).
- [x] Normal, rapid, and reverse scrolling preserve the three-slot bound and pause off-screen content in the recorded smoke scenarios; see follow-up evidence below.
- [x] Feed block removes the current item; reverse paging skips it. Reporting Gagg Box as Spam confirms Content hidden and selects a survivor.
- [x] Profile top-right Block action empties works and removes that creator from Feed. Verified Dark Prince profile becomes empty and returning Feed selects Gagg Box. [Screenshot](artifacts/profile-blocked.png).
- [x] Restart preserves reported and blocked IDs.
- [x] Forced network failure displays feedback and performs one delayed retry; foreground starts another dormant cycle.
- [x] Leaving Feed/backgrounding pauses; return resumes only the current ready item.
- [x] Simulated memory warning notification disables collection prefetch and defers adjacent loads.
- [ ] Record the requested approximately one-minute submission demo.

Initial smoke sequence: Lo-Fi Vibe Mixer → Giggle Pop → Yaya's Room; block yaya_room; reverse paging returns to Giggle Pop; open Dark Prince profile and block; profile shows No visible sekais; return to Gagg Box; report Spam. Initial launch logs contain exactly three WebView creation events. That initial run did not establish the rapid-scroll/background/memory-pressure behavior; the follow-up below adds those checks.

Recording was attempted twice. RocketSim failed during MP4 export with `Invalid IPC message length` (15,301,783 bytes and 12,630,038 bytes) and produced empty output files. Those files were removed; no usable demo video is claimed. A simulator switch prevented the initial manual restart check; the follow-up completed it on one device.

### Follow-up smoke — September 5, 2026, 16:28–16:42 PDT

Xcode MCP built/launched the Debug app on iPhone 17 Pro / iOS 26.5, UDID `FBA3761E-34B1-417A-9C6D-30E09AAA4320`. RocketSim performed gestures, navigation, Home/foreground actions, accessibility reads, and screenshots. Xcode MCP supplied logs and read-only WebKit JavaScript probes; it also injected the memory-warning notification. No application source or mock implementation changes were needed for these checks. The unchanged mock used `--host 127.0.0.1 --fail-rate 1.0`, default 350 ms moderation latency and approximately 5 MB HTML items.

| Check | Observed result and evidence |
| --- | --- |
| Normal/rapid/reverse playback | 0.3-second swipes and a batch of three 0.1-second forward swipes followed by a reverse swipe. Each recorded play transition followed the previous item's pause. Exactly three creation events per process, including after navigation, memory warning, and repeated reassignment. [First process log](artifacts/smoke-2026-09-05/playback.json). |
| Actual WebKit state | After restart, direct probes of all three documents found `game_0012` PLAYING, with `game_0007` and `game_0013` PAUSED at zero frames. In Profile, all three were PAUSED; two separate probes kept frame counts at 1492/0/0. Returning resumed only `game_0012`, reaching 1619 frames. [DOM samples and second process log](artifacts/smoke-2026-09-05/restart-runtime.json), [screenshot](artifacts/smoke-2026-09-05/restart-playing.png). |
| Background | Home paused playing `game_0006` at 16:33:08; foreground resumed the same item at 16:33:15. The same sequence was observed for `game_0011` at 16:35:50 / 16:35:57. No intervening play events occurred. |
| Failure and delayed retry | Reporting `game_0010` hid it and displayed both confirmation and sync-failure feedback. Report responses were logged at 23:35:22.116 and 23:35:27.604 UTC, then no more until foregrounding at approximately 23:35:57. The new cycle responded at 23:35:58.050 and 23:36:03.479, then stopped again. Response-to-response gaps were 5.488 and 5.429 seconds, including the mock's 350 ms response delay. Block also made exactly two attempts, 5.480 seconds apart. HTTP 200 is expected: the forced failure is API `code: 50000`. [Timestamped mock log](artifacts/smoke-2026-09-05/mock-failure.log), [feedback screenshot](artifacts/smoke-2026-09-05/report-failure.png). |
| Durable restart | Existing state had blocked `creator_2` / `creator_3` and reported `game_0003`. This run added reported `game_0010` and blocked `creator_5` (bounce_kid). The on-disk JSON contained all five IDs before and after Xcode Stop/Run; PID changed from 71082 to 73089 without uninstalling or clearing storage. Feed traversal was `0000 → 0005 → 0006 → 0007 → 0012 → 0013 → 0012`, skipping reported and blocked items across `refresh=1` and reverse paging. No moderation POSTs resumed after process restart, matching the documented memory-only pending queue. [Scroll snapshots](artifacts/smoke-2026-09-05/restart-scroll.json), [blocked Profile](artifacts/smoke-2026-09-05/profile-blocked.png). |
| Memory warning | Xcode debugger read collection prefetch as YES, posted `UIApplicationDidReceiveMemoryWarningNotification`, then read NO. Pool logged conservative mode. Subsequent content loads were only the visited/replacement current items `0007`, `0010`, `0011`, `0012`; no adjacent loads or new WebViews appeared. `0010`, `0011`, and `0012` became playable. [Debugger evidence](artifacts/smoke-2026-09-05/debugger.json), [current content after warning](artifacts/smoke-2026-09-05/memory-current.png). |

Reproduction steps and debugger probes: [smoke-testing.md](smoke-testing.md). `python3 scripts/check_smoke_evidence.py` passes against the saved scenario evidence; [summary](artifacts/smoke-2026-09-05/check-summary.json). The script checks captured evidence rather than launching or driving the app. The earlier 32-test XCTest result was not rerun for these documentation/scripts-only additions.

Limits: this is finite simulator smoke coverage, not proof over all gesture schedules. Rapid gestures use RocketSim's per-command refresh/dispatch cadence. The memory check injects the notification, not actual OS memory pressure or a WebContent process kill. Debugger pauses and simulator overhead invalidate performance conclusions. Some loads visibly took a long time: in the uninterrupted post-warning interval, `game_0010` logged Load at 16:34:41.455 and Play completion at 16:34:56.766 (about 15.3 seconds). Investigate loading/readiness latency in a separate run without debugger/perception overhead; no performance target is claimed here. RocketSim accessibility snapshots sometimes retained Loading content after the screenshot and DOM showed PLAYING, so playback conclusions use DOM probes and native logs. Xcode's captured stdio timestamps can be stale; probe stage labels, not sorting stdio timestamps, define sample order.

## Physical-device performance — September 6, 2026

[Retained measurements](evidence/performance/README.md) contain the latest local
capture and its baseline. The [latest perf report](evidence/performance/20260906-203252-734998/report.md)
records **zero application hitches in `[10, 40)`**, versus one 258.377 ms hitch
before permanent WebView mounting. `FeedRenderCells` maximum fell from 251.578 ms
to 0.285 ms, and the full sampled main-thread export contains no matching WebKit
activity-state wait. The previously observed attachment stall did not recur.

This is not a claim of zero stutter: the full 51.049 s trace has one 16.670 ms
application hitch and potential interaction delays of 54.313 ms during early UI
work and 57.770 ms during context-menu presentation. Neither delay overlaps the
retained Feed gesture intervals. The window averaged 58.867 display presentations/s,
including idle/loading periods; observed gesture coverage is 8.598 s. Feed markers
begin only at 16.346 s, so early gesture coverage is unknown.

All 20 fully paired navigation-to-ready observations ended in cancellation, though
one successful play/pause pair for an already-ready document is present. Content
loading remains unresolved. Build/source provenance, memory, and live WebView count
were not verified. Repeat with a verified Release build, controlled scrolling and
menu interactions, complete readiness metrics, and host/WebContent memory evidence.
This update analyzes saved physical-device evidence; no app code changed and no
XCTest or RocketSim smoke run was performed.

## Saved memory graph — September 6, 2026

Offline analysis of `Sekai[10254].memgraph` confirms **exactly three live
`WKWebView` instances** at 21:17:20.724 PDT. All three are strongly held by three
distinct slots in the same `WebViewSlotPool`; no fourth instance was found.
The collector confirmed that capture followed scrolling up and down through
multiple Web Content items. Retaining only the three pool-owned instances after
that traversal validates the pool's effectiveness in this exercised scenario.
The host footprint is `22.7M`, with reported peak `24.9M`, excluding separate
WebContent processes. See the [report and raw text evidence](evidence/performance/memgraph-10254/report.md)
for addresses, ownership chains, checksum, and reproducible commands.

This separate PID 10254 snapshot supplements the earlier PID 9781 frame trace;
it does not establish that trace's memory use, a lifetime maximum WebView count,
or a Release long-scroll memory trend. Xcode MCP was used to inspect the current
pool construction. No app code changed and no new XCTest or RocketSim smoke run
was performed for this saved-artifact analysis.
