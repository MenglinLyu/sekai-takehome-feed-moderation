# Saved memory graph — Sekai PID 10254

## Result

**Exactly three live `WKWebView` instances are present in `Sekai[10254].memgraph`.**
All three have a strong reference from a separate `WebViewSlotPool.Slot` in the
same pool. No fourth `WKWebView` was found in the host-process snapshot.

**Capture scenario (confirmed by the person who collected the graph): the
memory graph was captured after scrolling up and down through multiple Web
Content items.** Finding only the three pool-owned WebViews after that traversal
validates the WebView pool's effectiveness in this exercised scenario: browsing
multiple items did not leave additional WebViews alive at capture time. This is
post-scrolling evidence, rather than only an initial-launch count.

Apple's `/usr/bin/heap` enumerated all seven allocation zones. The class summary
reports one `WebViewSlotPool`, three `WebViewSlotPool.Slot` objects, and three
`WKWebView` objects. The address enumeration and `leaks` reference-tree export
independently list the same three WebView addresses.

| WKWebView address | Direct allocation size | Slot holding `__strong webView` |
| --- | ---: | --- |
| `0x106b9c000` | 2,560 bytes | `0x1069ed8c0` |
| `0x106b9de00` | 2,560 bytes | `0x1069edc80` |
| `0x106b9f200` | 2,560 bytes | `0x1069edd40` |

Each reverse reference tree contains the same ownership path:

```text
AppCompositionRoot 0x10681ab00
  → __strong pool: WebViewSlotPool 0x106a3d860
  → __strong slots: array storage 0x106b70a40
  → WebViewSlotPool.Slot (one of the three addresses above)
  → __strong webView: WKWebView
```

The top-down reference tree chooses a WebKit ownership branch; it does not show
every incoming reference. The per-address reverse trees supply the explicit
application ownership paths above. Multiple reference paths do not represent
additional WebViews. The six `WKWebViewConfiguration` objects and three
`WKWebViewContentProviderRegistry` objects in the class summary are separate
supporting object types, not additional `WKWebView` instances.

Xcode MCP inspection of the current project agrees with this structure:
`AppCompositionRoot` constructs the pool, and `WebViewSlotPool` creates slots
with `(0..<3).map`, each initializing one `WKWebView`. This source inspection
supports the intended lifetime but does not establish the captured binary's
source revision. Snapshot evidence, rather than the configured capacity alone,
establishes the observed count.

## Capture and memory scope

| Field | Value from the saved graph / heap output |
| --- | --- |
| Process | `Sekai [10254]`, `com.sekai.takehome.Sekai`, version 1.0 (1) |
| Device / OS | `iPhone18,1`, ARM64, iPhone OS 27.0 (`24A5418b`) |
| Capture time | September 6, 2026, 21:17:20.724 PDT |
| Launch time | September 6, 2026, 21:16:02.190 PDT |
| Parent | `debugserver [10255]` |
| Workload context supplied by the collector | Scrolled up and down through multiple Web Content items before capture |
| Host physical footprint | `22.7M`, as formatted by `heap` |
| Host physical footprint peak | `24.9M`, as formatted by `heap` |
| Direct allocations of the three WKWebViews | 7,680 bytes total |
| Input size | 2,533,284 bytes |
| Input SHA-256 | `31535c0c4b8869756f891a30d5bcbe84ccae62ece3e931110e8e0a8e7b27f813` |

The 7,680 bytes cover only the three object allocations; they are not the total
retained memory of the views, documents, or WebKit. The footprint values describe
the Sekai host process, excluding separate WebContent, networking, and GPU
processes. The graph provides a host snapshot and its reported peak, not a
steady-state mean, a long-scroll trend, or a combined WebKit memory budget.

This is a separate process and capture from the
[frame-timing retest](../20260906-203252-734998/report.md), which used PID 9781.
Its numbers must not be attributed to that trace. The collector confirmed the
up/down traversal described above; exact item IDs, gesture count, duration,
loaded payload sizes, and document readiness/playback were not recorded with
this graph. A single snapshot cannot establish whether the count transiently
exceeded three earlier. Allocation backtraces are unavailable, and
the class inventory includes `Sekai.debug.dylib`; Release/source provenance is
unverified. This analysis verifies snapshot count and pool ownership, without
claiming leak freedom or completion of the Release memory acceptance work.

## Evidence and reproduction

- [WebView address enumeration and process header](heap-wkwebview.txt).
- [Selected class-summary rows](heap-class-summary.txt), including pool, slots,
  WebViews, and supporting types; this is an excerpt of the full `heap` output.
- [Filtered top-down reference tree](reference-tree-wkwebview.txt).
- Full reverse reference trees for [0x106b9c000](references-0x106b9c000.txt),
  [0x106b9de00](references-0x106b9de00.txt), and
  [0x106b9f200](references-0x106b9f200.txt).
- [Input identity and observed values](metadata.json).

Run from the repository root on macOS with the original local file present:

```sh
shasum -a 256 'Sekai[10254].memgraph'
/usr/bin/heap --noContent --addresses=WKWebView 'Sekai[10254].memgraph'
/usr/bin/heap --noContent 'Sekai[10254].memgraph'
/usr/bin/leaks --noContent --referenceTree=WKWebView 'Sekai[10254].memgraph'
for address in 0x106b9c000 0x106b9de00 0x106b9f200; do
  /usr/bin/leaks --noContent --traceTree="$address" 'Sekai[10254].memgraph'
done
```

The original graph remains at the repository root; the text exports above make
the finding reviewable without opening it. This was offline artifact analysis
and documentation work. No application code changed, and no new XCTest or
RocketSim smoke run was needed or performed.
