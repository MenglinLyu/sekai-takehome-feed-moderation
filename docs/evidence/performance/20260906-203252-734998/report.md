# Physical-device performance report — 20260906-203252-734998

## Conclusion

The previous approximately 250 ms WebView-attachment stall **did not recur in
this capture**. In `[10, 40)`, application hitches fell from **one, 258.377 ms**
to **zero**. No sampled main-thread stack in the full context-switch export
contains `waitForDidUpdateActivityState`. This supports the permanent-canvas
optimization, but does not establish that all stuttering or content waiting is
resolved.

The full trace still contains **one 16.670 ms application hitch** at 1.961 s and
two potential interaction delays: **54.313 ms** at 1.184 s and **57.770 ms** at
45.668 s. The latter contains context-menu presentation and asset-lookup stacks,
outside the recorded Feed drag/deceleration intervals. Loading remains a separate
concern: all 20 fully paired navigation-to-ready observations ended in cancellation.

## Environment and comparison limits

| Field | Recorded value |
| --- | --- |
| Capture | September 6, 2026, 20:32:58–20:33:49 PDT; 51.049 s |
| Device / OS | Physical iPhone 17 Pro (`iPhone18,1`), wired; iOS 27.0 (`24A5418b`) |
| Display | Built-in 1206 × 2622, maximum 120 Hz; export also lists a 60 Hz `wireless0` display |
| Thermal state | Nominal throughout |
| Instruments | 27.0 (`27A5252f`), Animation Hitches plus Points of Interest; Hangs reports potential delays above 33 ms |
| Mock | `0.0.0.0:8787`, configured 350 ms latency, approximately 5 MB items, failure rate 0 |
| Launch | `record-installed`, `com.sekai.takehome.Sekai`, PID 9781 |
| Source change under review | `e562f48`: permanently mount the three pooled WebViews in a collection-content canvas and reposition them instead of reparenting during cell reuse |
| Build provenance | Unverified: recording metadata has no Release/coverage audit or source revision; stack symbols include `Sekai.debug.dylib` |

The source change was inspected through Xcode MCP. Its presence in the repository
does not prove which revision was installed on the phone. Both this run and the
[baseline](../20260906-191821-565605/report.md) use the same device, OS, template,
and mock configuration, but gesture paths, loaded documents, persisted visibility
state, and cache state are not controlled identically. Treat this as an observed
before/after comparison, not a controlled estimate of the optimization's speedup.

## Frame and scrolling evidence

| Metric | Baseline `191821` | Latest `203252` |
| --- | ---: | ---: |
| Comparison window | `[10, 40)` | `[10, 40)` |
| Presented surfaces | 1,340 | 1,766 |
| Average display presentations/s | 44.667 | 58.867 |
| Median one-second presentation rate | 55.5 | 62.0 |
| Minimum / maximum one-second rate | 0 / 106 | 0 / 120 |
| Zero-presentation seconds | 4.000 | 1.000 |
| Application hitches in window | 1 | 0 |
| Maximum application hitch in window | 258.377 ms | None recorded |
| Recorded Feed drag/deceleration coverage in window | 8.973 s | 8.598 s |
| Full-trace application hitches | 2 | 1 |
| Full-trace maximum application hitch | 258.377 ms | 16.670 ms |

The latest full trace contains 2,705 presentations, averaging 52.989/s, with
three zero-presentation seconds. Display counts include static/loading periods
and other app interactions; they are not scrolling-only FPS or per-frame latency
percentiles. The higher average alone does not prove smoother scrolling.

The retained Feed export contains 921 events from **16.346 to 51.342 s**. It lacks
early events and extends slightly beyond the display trace's 51.049 s boundary.
Consequently, the 8.598 s gesture coverage is only the observed coverage in
`[10, 40)`; the interval before 16.346 s cannot be classified as idle from missing
markers. Phase statistics below use the exported paired intervals, including its
short tail, rather than pretending the signpost and display ranges are identical.

There are 27 settlements and three paired page requests. The observed path starts
by reversing from `game_0003` to index 1 (`game_0001`), proceeds forward, reverses
6 → 5 → 4, then advances to index 22 (`game_0027`). One settlement stays at index
5. Recorded drag/deceleration totals 10.664 s; the longest continuous segment is
0.458 s. This remains a sequence of discrete swipes with gaps.

Neither potential interaction delay nor the single application hitch overlaps
the retained Feed gesture intervals. There are no Hangs rows in `[10, 40)`.
The early hitch precedes the available Feed markers, so its interaction context
and exact cause cannot be established from this export.

## Did the original bottleneck disappear?

The baseline contained `WKWebView.didMoveToWindow` → WebKit activity-state IPC
waits during cell attachment, including a 251.465 ms `FeedWebViewAttach` interval.
The latest Feed range contains no attach/detach markers and no approximately
250 ms render/reconcile interval. Initial mounting is outside the retained Feed
range; absence of attachment events here is not a measurement of startup mounting
or live WebView count.

| Exported phase maximum | Baseline | Latest |
| --- | ---: | ---: |
| `FeedRenderCells` | 251.578 ms | 0.285 ms |
| `WebPoolReconcile` | 252.128 ms | 1.654 ms |
| `FeedSnapshot` | 4.847 ms | 3.614 ms |
| `FeedAssignWindow` | 0.093 ms | 0.146 ms |
| `FeedSettle` | 0.233 ms | 0.373 ms |

The render and reconcile outliers are gone in this sample. Assignment and
settlement remain below 0.4 ms despite slightly higher maxima. Reconcile includes
asynchronous JS waits and is not continuous main-thread CPU time. The combination
of these phase timings, zero matching activity-state wait samples, and zero hitches
in the comparison window supports removal of the previously observed mechanism.

## Remaining interaction delays

The Hangs table reports potential interaction delays, distinct from Animation
Hitches. These two rows are not two additional dropped-frame measurements:

- **1.184–1.238 s, 54.313 ms:** sampled stacks include SwiftUI initial view/toolbar
  work, named-image/localization lookup, and dynamic library loading. This is
  consistent with startup UI work; available samples do not isolate one operation
  as the cause of the entire interval.
- **45.668–45.725 s, 57.770 ms:** stacks include
  `_UIClickPresentationInteraction._performPresentation`,
  `_UIContextMenuListView` cell configuration, `UIImage` system-image lookup,
  and `CUIStructuredThemeStore` asset access. This points to context-menu
  presentation work, rather than the previous WebView attachment path. It occurs
  between Feed gesture segments ending at 43.209 s and starting at 47.393 s,
  and has no accompanying Animation Hitches row. Investigate repeated menu opening
  if it remains perceptible; this sample alone does not prove a recurring menu stall.

[Phase analysis](analysis/summary.json) retains the five most frequent distinct
state/stack pairs in each delay, with their first sample timestamp. These are
context-switch sample counts, not time-weighted CPU percentages. The full raw
stack export was also searched for the original WebKit wait signature: zero matches.

## Content readiness and remaining validation

Twenty `WebLoadToReady` intervals are fully paired; **20/20 ended as reset or
cancelled**, with median elapsed time **2.370 s**, nearest-rank P95 **7.537 s**,
and maximum **7.623 s**. Cumulative cancellation elapsed time is 63.941 s, including
concurrent loads; this is neither CPU time nor transferred bytes. Two unmatched
ends have starts outside the export. Three loads remain open in the signpost
export, one of which starts at 51.182 s, after the display trace boundary; only
two of those starts lie within the display trace.

Unlike the baseline, there is one successful `WebPlayJS` callback for `game_0001`
at 16.738764 s (0.228 ms JS round trip), followed by a successful pause at
17.048528 s (1.588 ms). Its readiness occurred outside the retained marker range:
no `WebContentReady`, `WebNavigationFinished`, or `WebReadinessJS` event is present.
Thus the 20/20 cancellation statistic does **not** mean no content ever played,
but this run still provides no successful navigation-to-ready distribution.
The mock log contains 35 content GETs and four connection-reset exceptions;
request counts do not establish complete transfers or cache misses.

The original scrolling stall is not reproduced, while content loading/cancellation
remains unresolved. A long loading cover should not be described as a measured
main-thread freeze. Repeat with controlled dwell times and complete readiness/
display metrics to distinguish download, WebKit parsing, and navigation cancellation.

This capture has no host/WebContent steady, peak, or long-scroll memory measurement
and no live WebView creation-count evidence. It also does not validate the complete
play/pause or moderation contract. A verified Release capture with recorded source
revision, repeatable normal/rapid/reverse paging, repeated menu opening, and memory
measurements remains required. No app source was changed or simulator smoke test
rerun for this analysis; RocketSim smoke results are not physical-device perf evidence.

### Separate memory-graph follow-up

The later [PID 10254 snapshot](../memgraph-10254/report.md), captured at
21:17:20.724 PDT, confirms exactly three live `WKWebView` instances, all held by
three slots in one pool. The collector confirmed that capture followed scrolling
up and down through multiple Web Content items; the post-scrolling count validates
the pool's effectiveness in that scenario. It reports host footprint `22.7M` and
peak `24.9M`.
This is a different process from this trace's PID 9781, excludes WebContent
process memory, and does not retroactively supply memory or lifetime count
measurements for this run.

## Reproduction and retained evidence

Compact exports and generated summaries are retained beside this report; the
baseline is kept for an auditable comparison. Raw `.trace`, signpost XML, and the
18 MB context-switch export remain in the ignored local recording directory.
See the [evidence index](../README.md).

Recompute the frame summary from Git-tracked evidence:

```sh
python3 scripts/summarize_xctrace.py \
  docs/evidence/performance/20260906-203252-734998 --start 10 --end 40
```

To regenerate phase and stack analysis, export `potential-hangs`,
`device-thermal-state-intervals`, and `context-switch-sample` into the local run's
`analysis/` directory using the [performance procedure](../../../performance.md),
then run:

```sh
python3 scripts/analyze_performance.py \
  docs/artifacts/recordings/20260906-203252-734998
```

`analysis/display-info.xml` was exported from the `device-display-info` table.
The analyzer now also retains representative stacks for non-WebKit delays,
counts the original activity-state wait signature across all sampled main-thread
stacks, and reports the exported signpost time range.
