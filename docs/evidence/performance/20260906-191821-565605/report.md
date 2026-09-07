# Physical-device performance report — 20260906-191821-565605

## Findings

In trace window `[10, 40)`, Instruments recorded one application hitch lasting
**258.377 ms**. Feed gesture signposts cover **8.973 s** of this window; the longest
continuous drag/deceleration segment is **1.175 s**. These describe the observed
workload, including idle gaps.

The README requires a frame-timing measurement and scrolling without dropped
frames. This capture identifies a scrolling stall: the main thread waits for
WebKit while attaching a pooled WebView. It does not establish smooth scrolling.

## Environment and provenance

| Field | Recorded value |
| --- | --- |
| Capture | September 6, 2026, 19:18:24–19:19:15 PDT; 50.998 s |
| Device | iPhone 17 Pro (`iPhone18,1`), physical device over a wired developer connection |
| OS | iOS 27.0 (`24A5418b`) |
| Built-in display | 1206 × 2622, maximum refresh rate 120 Hz |
| Thermal state | Nominal for the full recording |
| Instruments | 27.0 (`27A5252f`), Animation Hitches plus Points of Interest |
| Mock | `0.0.0.0:8787`, 350 ms configured latency, approximately 5 MB per item, failure rate 0 |
| App launch | `record-installed`; bundle `com.sekai.takehome.Sekai` |
| Build/source provenance | Not verified. Direct recording does not audit Release configuration, coverage sections, or source revision. Sample symbols include `Sekai.debug.dylib`, so this run must not be represented as verified Release evidence. |

The observed path first reversed from feed index 2 to 0, then paged forward to
index 20. Twenty-two settlements were recorded, including two additional feed
page requests. This was a sequence of discrete swipes with idle gaps.

## Frame and responsiveness results

| Metric | `[10, 40)` result |
| --- | ---: |
| Window duration | 30.000 s |
| Presented surfaces | 1,340 |
| Average display presentation rate | 44.667 presentations/s |
| Median one-second presentation rate | 55.5 presentations/s |
| Minimum / maximum one-second rate | 0 / 106 presentations/s |
| Zero-presentation time | 4.000 s |
| Application hitches | 1 |
| Maximum application hitch | 258.377 ms |
| Feed drag/deceleration coverage | 8.973 s |

Display presentations are not JavaScript callbacks or scrolling-only frame
times. The four zero-presentation seconds include static/loading periods and
must not be interpreted as zero FPS while actively scrolling. Conversely, the
average cannot establish smooth scrolling because most of the window was not
inside Feed drag/deceleration signposts.

Across the full 50.998-second trace, 1,905 surfaces were presented at an average
rate of 37.354 presentations/s. There were two application hitch rows: the
258.377 ms hitch at 15.454 s and a 12.498 ms hitch at 49.264 s.

## Root cause of the long hitch

The 258.377 ms animation hitch overlaps a 254.995 ms main-thread microhang that
starts at 15.428 s. Its sampled main-thread stack is:

```text
FeedViewController.collectionView(_:willDisplay:forItemAt:)
→ FeedCell.render(_:)
→ UIView.addSubview
→ WKWebView.didMoveToWindow
→ WebKit::WebPageProxy::activityStateDidChange
→ RemoteLayerTreeDrawingAreaProxy::waitForDidUpdateActivityState
→ IPC::Connection::waitForMessage
→ WTF::Condition::wait
→ __psynch_cvwait
```

The main thread was blocked waiting for WebKit's remote layer tree/activity-state
acknowledgement while a pooled `WKWebView` was attached to a visible cell. This
is a synchronous WebKit IPC wait, not evidence of expensive application-side
filtering, snapshot construction, or network work.

The behavior repeated at 18.703 s. That second microhang lasted 252.894 ms and
coincided with:

- `WebPoolReconcile`: 252.128 ms;
- `FeedRenderCells`: 251.578 ms;
- `FeedWebViewAttach` for `game_0005`: 251.465 ms.

Its stack again ends in `WKWebView.didMoveToWindow` waiting for the WebKit
activity-state IPC reply. It did not produce a separate Animation Hitches row,
which demonstrates that the Hangs and Animation Hitches instruments expose
different symptoms. The repeated stack makes view-hierarchy attachment of a
live WebView the primary observed bottleneck.

Normal native bookkeeping remained small: `FeedAssignWindow` had a 0.065 ms
median and 0.093 ms maximum, `FeedSettle` had a 0.179 ms median and 0.233 ms
maximum, and `FeedSnapshot` had a 4.273 ms median and 4.847 ms maximum.

## Web content and wasted loading

Nineteen fully paired `WebLoadToReady` intervals were analyzable. Every one ended
as reset or cancelled before readiness:

| Outcome | Count | Fraction of paired intervals |
| --- | ---: | ---: |
| Ready | 0 | 0% |
| Reset or cancelled | 19 | 100% |

The cancellation observation duration was 3.790 s at P50 and 6.520 s at
nearest-rank P95, with 75.831 s of cumulative elapsed cancellation time. The sum
includes concurrent loads and is neither CPU time nor transferred bytes. Two
additional loads were still open at the trace boundary, and three early end
markers had starts outside the exported Feed signpost range.

No `WebContentReady`, readiness-JS, or play-JS event was recorded. Therefore this
run provides no successful settlement-to-playable latency distribution, no
ready-pool reuse sample, and no browser Navigation Timing/cache classification.
The server log contains 29 content GET requests and three connection resets,
consistent with aggressive navigation cancellation, but GET calls alone do not
prove complete transfers or cache misses.

## Memory and playback evidence

The selected template did not record host or WebContent steady, peak, or
long-scroll memory. WebView creation logs use the `WebViewPool` category, which
was not captured. The source uses three slots, but this run does not measure the
live count or memory use requested by the README.

No load reached readiness and no play-JS event was recorded. This capture cannot
verify the settled-item play/pause contract. The requested submission screen
recording remains separate work.

## Changes to investigate and retest

The measurement points to WebView attachment during `willDisplay` or settlement.
Investigate keeping pooled WebViews attached while preserving the three-view
bound and single-playing-item behavior. No before/after improvement is established
by this capture.

Record the build configuration and source revision for the retest, repeat the
scroll path with approximately 5 MB items, and report frame/hitch numbers. Show
memory use and live WebViews during scrolling. Include the README's roughly
one-minute demo of scrolling, Feed block, scrolling back, and Profile block.

## Reproduction and generated evidence

The analysis was generated with:

```sh
python3 scripts/summarize_xctrace.py \
  docs/artifacts/recordings/20260906-191821-565605 --start 10 --end 40

xcrun xctrace export --input \
  docs/artifacts/recordings/20260906-191821-565605/recording.trace \
  --xpath '/trace-toc/run[@number="1"]/data/table[@schema="potential-hangs" or @schema="device-thermal-state-intervals"]' \
  --output docs/artifacts/recordings/20260906-191821-565605/analysis/context.xml

xcrun xctrace export --input \
  docs/artifacts/recordings/20260906-191821-565605/recording.trace \
  --xpath '/trace-toc/run[@number="1"]/data/table[@schema="context-switch-sample"]' \
  --output docs/artifacts/recordings/20260906-191821-565605/analysis/context-switch-sample.xml

xcrun xctrace export --input \
  docs/artifacts/recordings/20260906-191821-565605/recording.trace \
  --xpath '/trace-toc/run[@number="1"]/data/table[@schema="device-display-info"]' \
  --output docs/artifacts/recordings/20260906-191821-565605/analysis/display-info.xml

python3 scripts/analyze_performance.py \
  docs/artifacts/recordings/20260906-191821-565605
```

The export commands above reference the original local trace. Compact evidence
is retained beside this report in Git: [frame summary](summary.json),
[phase analysis and sampled wait stacks](analysis/summary.json),
[paired intervals](analysis/intervals.csv), [Feed events](feed-signposts.csv),
[frame export](fps.xml), and [hitch export](hitches.xml).

Recompute the frame summary from the retained exports:

```sh
python3 scripts/summarize_xctrace.py \
  docs/evidence/performance/20260906-191821-565605 --start 10 --end 40
```

Rebuilding the phase analysis requires the original local
`analysis/context-switch-sample.xml`. Its relevant wait stacks are retained in
`analysis/summary.json`; the large raw stack export and `.trace` remain local.
See the [evidence index](../README.md) for the retained files.
