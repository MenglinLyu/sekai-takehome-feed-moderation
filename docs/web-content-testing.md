# Direct WebKit loading verification

Build/run/test through Xcode MCP. Use the RocketSim skill/CLI for simulator gestures
and screenshots. Preserve moderation state; keep mock/server.py unchanged.

## Automated coverage

- Existing moderation, repository, visibility, view-model and playback-policy tests.
- WebContentMetricsTests: phase boundaries, exactly-once terminal rows, failed and
  abandoned displays, zero ready wait for pool reuse, unavailable browser values,
  revalidation and Service Worker ambiguity, and body-rate estimate units.
- WebViewCacheTests: a test-only loopback HTTP server and the real three-slot pool.
  Load A/B, move to C/D (removing A/B), return to A/B. Explicit max-age responses must
  reuse cached bytes; no-store responses must fetch again. Verify shared store identity
  and new document identity on revisit. Unique URLs isolate tests without clearing data.

The fixture is separate from the mock. These small-document tests establish behavior
under controlled cache headers, not guaranteed caching for arbitrary 5 MB responses.

## Simulator smoke

1. Start the unchanged mock with the existing launcher; verify the endpoint and use
   Xcode MCP to run. Record simulator, OS, scheme and source state.
2. Inspect with RocketSim. If accessibility is unavailable, follow its screenshot and
   coordinate-interaction fallback.
3. Check initial playback, normal/rapid/reverse paging beyond the pool window, and
   exactly three creation events. Only the settled eligible item may play.
4. Inspect new load/display records, including ready reuse and interrupted waits.
   Unsupported browser fields must remain n/a.
5. Check Profile/background return, report/block and survivor playback. Exercise the
   existing simulated memory-warning recipe; only current loading should continue.
6. Record actual evidence and limits.

## Performance

Follow performance.md: physical device, Release, no coverage/debugger, unchanged
approximately 5 MB mock. Measure continuous-scroll hitches and app/WebContent memory
separately from document latency. Compare cold navigation, browser-cache evidence and
ready-pool reuse with request logs and response headers. Include normal, rapid, reverse
and lifecycle routes; retain failed/abandoned samples. JS acknowledgement/FCP are not
proof of native presentation. There is no zero-refetch guarantee for the mock.

## Current execution record

Build passed through Xcode MCP on September 6, 2026. Final automated and simulator
results will be recorded after execution. No new physical-device result is claimed.
