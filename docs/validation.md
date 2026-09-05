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
- [ ] Normal, rapid, and reverse scrolling preserve the three-slot bound and pause off-screen content.
- [x] Feed block removes the current item; reverse paging skips it. Reporting Gagg Box as Spam confirms Content hidden and selects a survivor.
- [x] Profile top-right Block action empties works and removes that creator from Feed. Verified Dark Prince profile becomes empty and returning Feed selects Gagg Box. [Screenshot](artifacts/profile-blocked.png).
- [ ] Restart preserves reported and blocked IDs.
- [ ] Forced network failure displays feedback and performs one delayed retry; foreground starts another dormant cycle.
- [ ] Leaving Feed/backgrounding pauses; return resumes only the current ready item.
- [ ] Simulated memory warning disables collection prefetch and defers adjacent loads.
- [ ] Record the requested approximately one-minute submission demo.

Observed sequence: Lo-Fi Vibe Mixer → Giggle Pop → Yaya's Room; block yaya_room; reverse paging returns to Giggle Pop; open Dark Prince profile and block; profile shows No visible sekais; return to Gagg Box; report Spam. Initial launch logs contain exactly three WebView creation events. This smoke run does not establish the full rapid-scroll/background/memory-pressure invariant.

Recording was attempted twice. RocketSim failed during MP4 export with `Invalid IPC message length` (15,301,783 bytes and 12,630,038 bytes) and produced empty output files. Those files were removed; no usable demo video is claimed. A later simulator switch prevented completing the manual restart check on the same device; persisted-state reconstruction is covered by automated tests.

## Physical-device performance — not measured

No eligible physical-device destination was listed by Xcode during this session. Do not interpret simulator checks, payload size, or the number of WebViews as a memory/frame-timing measurement.

Acceptance target chosen before measurement: **30 seconds of continuous scrolling, fewer than five hitches, every hitch below 100 ms**. Use a Release build and Instruments Animation Hitches / Time Profiler plus memory instruments. Capture first display, normal/rapid/reverse scrolling, and memory-warning behavior. Record:

| Metric | Result |
| --- | --- |
| Device / OS / display refresh rate | Not measured |
| Mock latency / payload / scroll path | Use defaults (approximately 5 MB per HTML item); record actual arguments |
| Hitch count and maximum duration | Not measured; acceptance unverified |
| Host and WebContent steady/peak memory, long-scroll trend | Not measured |
| Three WebView creation events and lifetime count | Source bounds creation to three; trace not collected |
| Settlement-to-visible and settlement-to-playable latency | Not measured |
| Reassignment-canceled load count and duration | Pool logs events; trace not collected |
| Memory warning / process termination behavior | Implementation present; manual validation pending |

Pool logs use subsystem `com.sekai.takehome`, category `WebViewPool`. Preserve traces and record optimizations/retest results before claiming the performance target is met.
