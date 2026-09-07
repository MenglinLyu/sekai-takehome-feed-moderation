# Shared WebKit cache and direct loading

One loading path: `WKWebView.load(URLRequest)` with `useProtocolCachePolicy`.
The composition root passes `WKWebsiteDataStore.default()` to the pool; all three
slots use that same object. Incremental rendering is explicitly enabled, which is
also WebKit's default. WebKit owns HTTP loading, resource caching and cache eviction.

## Ownership and reuse

The pool retains exactly three WKWebViews for previous/current/next around the settled
position. It starts current before new neighbor loads. Passing items during rapid
scrolling does not reassign the pool. Matching item ID and source URL preserve a live
document across role changes; changed URLs cause new navigation even with identical IDs.

The pool bounds live documents; WebKit caches HTTP resources independently. Resetting
a slot replaces its document with a blank page without clearing website data. A revisit
in another slot may reuse bytes but constructs a new DOM/JS session. Game progress is
not restored, and browser eviction/freshness policies prevent guaranteed instant reuse.

| Condition | Behavior |
| --- | --- |
| Ready matching document still pooled | No new navigation; record ready-pool display reuse. |
| Fresh cache entry retained | New navigation may reuse bytes without an origin request. |
| Revalidation required | A network round trip may return 304 without a new body. |
| Missing/evicted/uncacheable entry | WebKit fetches again. |

Sharing a store enables caching, not a guaranteed hit. HTTP rules and request context
still apply. The unchanged mock has no explicit HTML freshness or validators; do not
promise zero downloads on mock revisits. Production should configure HTTP freshness,
validators and versioned static resources.

## Playback and lifecycle

WKNavigation identity guards native/JS callbacks, including A → B → A reuse. The mock
starts paused; after didFinish the pool checks play/pause functions. Only the settled,
foreground, visible, unhidden item may play after the old player acknowledges pause.
Failed reset retains the safety barrier. stopLoading alone does not stop running scripts.

Inactive Feed cancels unfinished loads and prevents new ones; completed documents can
remain pooled. Reassignment cancels obsolete loads. Memory warnings keep three instances
but disable collection prefetch and neighbor loading for the session. These events do
not explicitly clear browser cache data.

Moderation remains stream-derived and gates display independently of cached bytes.
Local commits immediately cover/revoke hidden items; late callbacks cannot reveal them.
Hidden IDs restore before Feed appears. Do not clear all browser data to hide one item.

## Verification

See [metrics](web-content-metrics.md) and [tests](web-content-testing.md).
