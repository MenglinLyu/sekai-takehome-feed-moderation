# Direct WebKit content metrics

The app uses `WKWebView.load(URLRequest)` and a shared persistent website data store.
See [loading design](web-content-loading.md) and [tests](web-content-testing.md).

## Records and correlation

Filter Xcode's console by `WebLoadStart|WebLoadMetrics|WebDisplayStart|WebDisplayMetrics`.
OSLog uses subsystem `com.sekai.takehome`, category `WebContentMetrics`, in Debug and
Release. Existing FeedPerformance signposts remain available. Metrics log opaque IDs,
controlled labels and numeric fields, never URLs, queries, HTML or arbitrary errors.

- `WebLoadStart` and `WebLoadMetrics`: one load UUID per actual remote navigation,
  with one terminal row for ready, failure, cancellation, replacement or termination.
  Blank reset documents are excluded. Native/JS results must match WKNavigation identity.
- `WebDisplayStart` and `WebDisplayMetrics`: one display UUID each time a settled
  item becomes eligible. Reasons distinguish `settled`, `snapshot`, `resume`, `retry`
  and `recovery`. The load UUID joins to the document used for playback.
- `initial_state=ready_pool` includes ready reuse even though it causes no new load.
  Other states are loading, unbound and failed. Interrupted waits and failures remain
  observations; they never emit a successful playback duration. Unmatched start rows
  after a crash are incomplete observations, not successes.

Native timestamps use system uptime. Browser offsets use the document performance
time origin. Never subtract browser offsets from native uptime.

## Native timings (milliseconds)

| Field | Meaning |
| --- | --- |
| `provisional_ms`, `commit_ms` | Calling load to matching provisional start / commit. Neither is first paint. |
| `navigation_ms` | Calling load to didFinish, including overlapping network/document work. |
| `finish_to_ready_ms` | didFinish to successful bridge check, including scheduling. |
| `load_to_ready_ms` | Calling load to readiness; unavailable on failure. |
| `total_ms` | Calling load to terminal outcome, including failure/cancellation. |
| `eligible_to_ready_ms` | Eligibility to readiness; zero for an already-ready document. |
| `eligible_to_play_ms` | Eligibility to successful play JS acknowledgement. |
| `ready_to_play_ms` | Readiness, clamped to eligibility, to play acknowledgement. |
| `play_js_ms` | Play request to acknowledgement; unavailable when no new play call is needed. |
| `observed_ms` | Entire display opportunity, including interrupted/failed waits. |

For `reason=settled`, eligibility follows the controller's settlement/layout work;
it is not finger-release time. Separate snapshot/resume opportunities when reporting
scroll-only distributions. JS acknowledgement is not a presented frame; verify actual
visible-content latency with screen recording or presentation instrumentation.

## Browser diagnostics

The existing readiness JS call also samples the main document's Navigation Timing
entry. It falls back to legacy performance.timing if needed. No additional HTTP
request is made. Unsupported/invalid fields and unavailable event timestamps remain
`n/a`. Failed/cancelled navigations may have no browser sample. This is page-provided
diagnostic data, not security or billing evidence.

| Field | Meaning |
| --- | --- |
| `dns_ms`, `connect_ms`, `tls_ms` | Lookup/connect phases; TLS is included in connect, so do not add them. |
| `ttfb_ms` | requestStart to responseStart, excluding DNS/connect. |
| `receive_ms` | responseStart to responseEnd; cache reads can also have a duration. |
| `fetch_to_response_end_ms` | fetchStart to responseEnd. |
| `post_response_to_dcl_ms` | responseEnd to DOMContentLoaded end, if ordered. Not total parsing cost: parsing overlaps transfer. |
| `dom_interactive_ms`, `dcl_ms`, `load_event_ms` | Browser event offsets from navigation start. |
| `fcp_ms` | First-contentful-paint offset if exposed when sampled; not native visibility, possibly for an off-screen neighbor. |
| `transfer_bytes` | Browser-reported response transfer size including headers; not a packet-level wire counter. |
| `encoded_body_bytes`, `decoded_body_bytes` | Body sizes before/after decoding, including possibly cached bodies. |
| `body_bytes_per_second_estimate` | Encoded body size / receive duration for eligible network-looking samples only. |

Cache evidence is conservative:

- `local_cache_likely`: modern timing, zero transfer size, positive decoded size and
  no observed Service Worker involvement.
- `network_or_revalidated`: positive transfer and decoded sizes under those conditions.
  This may be revalidation rather than a complete body download.
- `unknown`: legacy/missing data, ambiguous zeros or Service Worker involvement.

No body-rate estimate is emitted for cache hits, zero/invalid duration, unavailable
data, or transfer size smaller than encoded body size (possible revalidation).
The estimate is not link bandwidth. Exact bytes, HTTP statuses and redirects require
server logs or Web Inspector. Do not sum body sizes as actual network traffic.

## Reporting

Separate cold loads, cache evidence, ready-pool reuse, first display and revisits.
Report P50/P95 plus interrupted, failed and incomplete fractions. Do not count load
calls as HTTP requests or infer cache hits from fast navigation. To establish a likely
network bottleneck, compare cold/warm routes under controlled bandwidth on a physical
device in Release without debugger. Correlate receive phases with actual traffic and
inspect readiness, frame timing and memory. These measurements cannot prove all client
code is problem-free. Simulator tests establish behavior/instrumentation only.

References: [Navigation Timing](https://developer.mozilla.org/en-US/docs/Web/API/PerformanceNavigationTiming),
[transferSize](https://developer.mozilla.org/en-US/docs/Web/API/PerformanceResourceTiming/transferSize).
