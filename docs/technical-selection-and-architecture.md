# iOS Implementation Instructions

Implement the iOS take-home according to this document. These are implementation requirements and validation targets, not claims about completed work or measured performance. Use the [original assignment](../README.md) for API contracts and product requirements.

Work within approximately six focused hours. Complete and verify core functionality first, then measure performance and make necessary optimizations. Persist pending network operations only if time remains after those tasks. Keep the mock server unchanged.

## 0. Core technical decisions

- Target iOS 15. Use a standard `.xcodeproj` with App and unit-test targets; do not introduce Tuist, Swinject, or another DI container.
- Construct dependencies in an `@MainActor AppCompositionRoot` and pass them through initializers. Keep instance lifetimes explicit; do not use a service locator.
- Use SwiftUI for the app shell, navigation, action panels, feedback, and Creator Profile. Embed a UIKit `UICollectionView` feed through `UIViewControllerRepresentable`; use full-screen vertical paging and a Diffable Data Source. Profile displays metadata, covers, and titles without WebViews.
- Use Swift Concurrency for finite asynchronous work: `async throws` APIs, owned and cancellable tasks, and `Sendable` values across isolation boundaries. Use Combine for shared current state and derived lists. Bridge single callbacks with checked continuations; use `AsyncStream` only for local repeated callbacks when needed.
- Make one application-wide `ModerationRepository` actor the sole moderation writer. Serialize commits with a single-consumer queue across suspension points.
- Isolate page repositories, view models, the Combine state adapter, and all UIKit/WebKit operations to `@MainActor`. Derive visible lists inside repositories from fetched content and moderation rules using `combineLatest`.
- Persist blocked and reported IDs before publishing the local change; restore them before displaying content. Keep content hidden after network failure and perform one delayed retry per attempt cycle. Pending-operation persistence is optional; unblocking is out of scope.
- Create exactly three application-owned `WKWebView` instances in `WebViewSlotPool`. Assign them to previous/current/next items around the settled feed position. Pool ownership and loading must be independent of cell reuse and prefetch callbacks.
- Let `FeedViewController` choose playback eligibility, the pool own navigation callbacks/readiness and execute play/pause, and cells attach pooled views and render state. Allow playback only for the settled, visible, ready item while the feed is displayed and the app is foregrounded.
- Implement conservative loading after a memory warning. Automatic restoration of adjacent preloading is optional.

For a shorter repository instruction block, copy [the AGENTS.md snippet](agents-core-instructions.md).

## 1. Project structure and dependency lifetimes

Organize code under `App/Composition`, `Features`, `Repositories`, `Services`, and `Playback`. Default classes to `final`. Define protocols where needed to inject test doubles; use immutable `Sendable` values for cross-actor models.

| Scope | Ownership and requirements |
| --- | --- |
| Application | Construct one moderation repository, moderation state adapter, storage service, sync worker, API client, and WebView pool in `AppCompositionRoot`. Inject the same moderation dependencies into every page. |
| Feed session | Keep `FeedRepository`, `FeedViewModel`, and `FeedViewController` alive under one stable feed host. SwiftUI redraws must not recreate them. |
| Profile page session | `CreatorProfileFactory.make(creatorID:)` creates a fresh repository/view-model pair bound to an immutable creator ID. Do not share mutable pagination state between separate pages, even for the same creator. The factory does not cache instances. |
| Cell | Attach a pool-owned WebView when assigned. Never create, destroy, or own an independent WebView. |
| Test | Inject in-memory storage, controllable APIs, and clocks through protocols and initializers without starting the app composition root. |

Run asynchronous restoration after constructing the composition root. Show a startup/loading state until restoration completes. Do not synchronously wait for disk or network work in initializers.

Keep SwiftUI view-model identity stable, for example with `@StateObject`. Do not construct dependencies, subscriptions, pagination tasks, or controllers in `body` or repeated representable update callbacks. Cancel page requests and release subscriptions when the page session ends. Accepted global moderation commits and synchronization must survive page cancellation.

## 2. Type responsibilities and data flow

| Type | Isolation | Responsibility |
| --- | --- | --- |
| `AppCompositionRoot` | `@MainActor` | Dependency construction, startup restoration, feed construction, and profile factory. No visibility filtering. |
| `SekaiAPIClient: SekaiAPI` | Actor | Async URLSession requests, response validation, and DTO decoding. Provide `fetchFeed`, `fetchProfile`, `fetchCreatorGames`, `block`, and `report` as `async throws`. Do not hold page cursors. |
| `ModerationRepository: ModerationCommands` | Actor | Authoritative hidden sets, pending operations, revision, restoration, and serialized command/result commits. |
| `ModerationFileStore` | Dedicated serial I/O path | Async load/save and atomic JSON replacement. Persist only hidden sets in the core version. Do not perform blocking I/O on MainActor or an actor executor. |
| `ModerationStateStore: ModerationStateProviding` | `@MainActor` | Private `CurrentValueSubject` containing committed snapshots; expose only `AnyPublisher`. Initialize with restored state. |
| `ModerationSyncWorker` | Actor | Send operations, perform delayed retries, and return results by `operationID`. Never modify authoritative state directly. |
| `SekaiVisibilityPolicy` | Pure value logic | Apply the same block/report rules to both repositories through `visibleItems(in:rules:)`. |
| `FeedRepository` | `@MainActor` | Raw items, cursor, loading/errors, request generation, and Combine subscriptions. Publish `FeedState`; handle `loadNextPage`, `refresh`, `report`, and `blockCreator`. |
| `CreatorProfileRepository` | `@MainActor` | Immutable creator ID, profile data, raw works, pagination, request generation, and subscriptions. Publish `CreatorProfileState`; handle initial loading, pagination, retry, and blocking. |
| Feed/Profile view models | `@MainActor` | `ObservableObject` adapters for repository output; forward actions and manage page tasks, navigation, and user feedback. |
| `FeedViewController` / `FeedContainerView` | `@MainActor` | Collection view, snapshots, SwiftUI bridge, settled target, playback eligibility, and pool reassignment. |
| `WebViewSlotPool` | `@MainActor` | Three WebViews, slot bindings, navigation delegates, readiness, loading/cancellation, and serialized play/pause execution. |
| `FeedCell` | `@MainActor` | Attach/detach the assigned pooled WebView and render exposed slot state. Do not receive raw navigation callbacks, maintain readiness, or select playback targets. |
| `CreatorProfileFactory` / `CreatorProfileView` | `@MainActor` | Construct page-scoped dependencies / display profile and paged covers/titles with the top-right Block action. |

Use this flow:

```text
UI action → ViewModel → Page Repository → ModerationRepository
ModerationRepository → committed Sendable snapshot → ModerationStateStore
Fetched items + ModerationStateStore rules → combineLatest → SekaiVisibilityPolicy
    → Repository state → ViewModel → UI

Settled position + visible items + lifecycle → FeedViewController eligibility
Settled position + visible items → WebViewSlotPool assignments
Current navigation + eligibility → pool readiness and play/pause
Pool WebView + exposed state → FeedCell presentation
```

Expose `AnyPublisher<FeedState, Never>` and `AnyPublisher<CreatorProfileState, Never>` with visible items, loading/pagination state, and displayable errors. Keep raw arrays and mutable subjects private. Represent network failures in state without terminating these streams. View models must neither filter moderation state again nor call the moderation repository directly.

## 3. Concurrency and derived lists

- Mark UI/Combine protocol interfaces explicitly `@MainActor`; declare cross-actor commands/APIs `async` with appropriate `Sendable` constraints. Do not send subjects, cancellables, UIKit objects, or WebKit objects across actor boundaries, or use `@unchecked Sendable` to bypass the design.
- Before a page request's first `await`, set loading state and a request generation. Serialize pagination for each list. Reject stale responses after refresh/cancellation; they must not append data or clear a newer request's loading state. Profile metadata and its first works page may load concurrently using structured concurrency.
- Give every task an owner and cancellation entry point. Cancellation is cooperative: retain generation checks when committing results. Connect callback request cancellation to task cancellation where the underlying API supports it. Resume each checked continuation exactly once; define buffering and `onTermination` cleanup for any `AsyncStream`.
- Keep filtering, deduplication, and state publication on MainActor initially. Synchronous Combine callbacks only update derived state; they must not reenter network or moderation writes. Consume the callback's supplied value instead of rereading a potentially stale `@Published` property.
- Publish committed moderation snapshots in order by awaiting MainActor delivery. Include a monotonically increasing revision and ignore older revisions in the adapter. Do not launch unrelated tasks for individual publications. A `@MainActor @Sendable` closure can bridge publication using value snapshots.
- Deduplicate raw content by `game_id`, preserving stable order. Retain hidden items in raw storage and derive visibility using the latest rules; never patch visible arrays with `list.remove(...)` in action handlers.
- Combine fetched items with equatable visibility rules using `combineLatest`, then filter array elements inside `map`. Apply `removeDuplicates()` to rules so retry metadata and successful dequeues do not refilter unchanged visibility. Both inputs must provide initial values after restoration.
- Exclude every item whose creator is in `blockedCreatorIDs` or whose ID is in `reportedSekaiIDs`. Apply the same function in Feed and Profile, including when later pages redeliver hidden content.
- Build feed snapshots from the full visible list using `game_id` as identity. Profile uses the same derivation and shows an explicit empty state after blocking.
- Determine pagination completion from backend pagination state, not the number of newly visible items. Cap consecutive automatic requests for fully filtered pages, then provide a Continue Loading action if needed.

Keep network waits asynchronous and blocking file operations on a dedicated serial I/O path. Move pure computation off MainActor only when measurements show a bottleneck. Any future background filtering must use captured `Sendable` inputs, bounded scheduling, and `dataRevision`, `moderationRevision`, and request-generation checks before publishing on MainActor. In that case, immediately cover hidden content and revoke playback while awaiting the new list. Queue scheduling alone does not establish actor isolation.

## 4. Moderation persistence and retry

Maintain runtime state with these fields:

```text
ModerationState
  blockedCreatorIDs: Set<CreatorID>
  reportedSekaiIDs: Set<SekaiID>
  pendingOperations: [PendingOperation]  // memory only in the core version

PendingOperation
  operationID
  kind: block | report
  targetID
  reason  // for reports
  attemptCount
  nextRetryAt
```

Keep the persisted model separate from runtime state so encoding it does not accidentally persist the optional operation queue.

### Commit sequence

Route every mutation through one single-consumer commit queue inside `ModerationRepository`. Actor isolation alone does not serialize a transaction across `await` or guarantee FIFO calls.

1. Enqueue the command and deduplicate operations by kind and target ID.
2. In the sole drain, construct candidate hidden sets and the operation from the latest committed state.
3. Atomically save the hidden sets on the serial storage path.
4. On success, update actor state, enqueue the operation in memory, increment the revision, and await publication to MainActor. Hide the content and confirm the action without waiting for the moderation API.
5. Complete the commit before processing the next command. New commands may enqueue during suspension but must not mutate authoritative state or start another drain.
6. Let the sync worker perform network waits outside the commit queue. Submit results by `operationID`; remove only the matching successful operation and retain the hidden sets. Do not write an old state snapshot back into the repository.

On disk failure, retain the previous state, create no pending operation, send no request for that command, and show a local-save error with retry. Continue processing subsequent commands. Restore both hidden sets before showing content on startup. Measure local write latency to ensure it does not cause a perceptible removal delay.

### Network failure behavior

- Preserve local hiding after failure. Show feedback such as: “Hidden on this device. Sync failed; we’ll retry during this session.” Avoid repeated alerts for every retry cycle.
- Attempt immediately, then retry once after a fixed delay, such as five seconds. If that fails, retain the in-memory operation and stop automatic retries until the app returns to the foreground or the user issues another moderation action for the same target. Deduplicate the latest intent first.
- Allow at most one in-flight request per operation. Do not implement exponential backoff, jitter, or continuous polling in the core version. Treat the mock's nonzero response codes as retryable failures.
- On restart, restore hidden sets but do not reconstruct requests or report reasons from hidden IDs. The core version does not guarantee resuming unfinished synchronization.
- Do not implement unblocking, a blocked-user management screen, or unblock commands.

If time remains after performance work, persist hidden sets and pending operations atomically in the same state file. Persist dequeues, attempts, and retry times through the same serialized commit path; restore and resume the queue on startup. Add interrupted-write, migration, dequeue, and restart/retry tests. Document that retries cannot guarantee exactly-once server execution without backend idempotency support; leave the mock unchanged.

## 5. Playback and list removal

Allow playback only when all conditions hold:

```text
App is foregrounded AND Feed is the displayed page
AND scrolling has settled
AND target remains in the visible list
AND the WebView is still bound to that target
AND the current navigation is ready
```

Exactly one item plays when the settled item is ready. Zero may play during scrolling, loading, backgrounding, navigation away, or an empty list. Never allow more than one.

`FeedViewController` owns the current target and scroll/lifecycle state. Revoke eligibility at drag start; reevaluate after dragging ends without deceleration, deceleration ends, or programmatic scrolling completes. Pause on entering Profile, leaving Feed, or backgrounding, and reevaluate on return. Keep this coordination in the controller initially; a separate `PlaybackCoordinator` is not required.

The pool owns `isReady` and executes play/pause against the latest controller-provided eligibility. Readiness completion alone must not start a preloaded neighbor. Serialize playback transitions: revoke the old slot, finish pausing, then reevaluate the latest target before playing. Serialize JS operations per WebView and coalesce eligibility changes while awaiting completion. Validate captured WebView, item ID, and navigation identity on each JS completion; do not reuse a stale playback decision.

If pausing fails, invalidate the old binding, stop its loading, and let the pool recover/reassign it before resuming playback. Do not treat `stopLoading()` as proof that running animation stopped. Retain the pool instance and preserve the at-most-one-playing invariant during recovery.

When moderation hides the current item:

1. Immediately cover it, revoke playback, pause it, and cancel any active load.
2. Apply the new visible snapshot and clear other filtered content from configured cells, including cells prepared for display.
3. Select the first surviving successor in the previous order; if none exists, select the preceding survivor. Use stable IDs and before/after ordering, never the old `indexPath`.
4. After the snapshot and layout settle, position the replacement, update pool assignments, and reevaluate playback.
5. If no items remain, display an empty state, keep playback stopped, and follow the bounded pagination policy.

## 6. WebView pool and loading

Create three `WKWebView` instances once for the pool lifetime. Maintain logical `prev`, `current`, and `next` roles around the settled index. Each slot tracks its optional item ID, current `WKNavigation`, loading state, and readiness. Share readiness logic across slots.

Use `webView.load(URLRequest(url: gameURL))`. Start loading when binding a slot, without waiting for `willDisplay`. Preserve an existing target binding and its loaded content when only its logical role changes.

The composition root injects one `WKWebsiteDataStore.default()` into the pool. All three views use that same persistent store, `useProtocolCachePolicy`, and incremental rendering. Resetting a document does not clear browser data. Cache reuse follows HTTP rules and WebKit eviction; a shared store is not a guaranteed cache hit. Match both item ID and source URL before retaining a binding, and start current-item loads before new neighbors. Cancel unfinished loads while Feed is inactive and rebuild the settled window on return. See [the direct-loading design](web-content-loading.md).

### Navigation identity and readiness

The pool implements each slot's `WKNavigationDelegate`. Cells only consume exposed state.

| Event | Required behavior |
| --- | --- |
| `didStartProvisionalNavigation` | Validate current WebView and nonnil navigation identity; mark loading. |
| `didCommit` | Validate identity; do not start playback. |
| `didFinish` | Validate binding/navigation, check that playback functions exist, mark ready, and reevaluate current eligibility. |
| `didFailProvisionalNavigation` / `didFail` | Handle only the current navigation. Do not show deliberate cancellation during reassignment as an error. |
| `webViewWebContentProcessDidTerminate` | Identify the slot, clear navigation/readiness, and recover immediately if current; otherwise defer. Do not assume every termination means out-of-memory. |
| `stopLoading()` | Cancel loading and invalidate its identity. Pause animation separately. |
| JS completion | Validate the captured WebView, item ID, and navigation; use current eligibility before any follow-up action. |

Use `WKNavigation` object identity, including an A → B → A sequence. Do not add a separate load generation initially; introduce one only for later async work that cannot be associated with a navigation. Page-request generations remain required independently.

The mock defines `window.sekaiPlay()` and `window.sekaiPause()` synchronously and starts paused. Checking these functions after `didFinish` is sufficient for this assignment. A separate readiness protocol for asynchronously initialized production pages is out of scope.

### Reassignment and cells

When the settled position or its visible-item window changes:

1. Compute previous/current/next targets; leave out-of-bounds roles empty.
2. Retain slots already bound to any target and update their roles without reloading.
3. Revoke eligibility, pause, cancel loading, and invalidate bindings outside the new window; rebind available slots to missing targets and start permitted loads.
4. Drive reassignment from controller state, without relying on `willDisplay` or `didEndDisplaying`. Merely passing intermediate items during a fast swipe must not reassign the pool.

In `willDisplay`, attach the assigned WebView; request a pool-managed fallback load if necessary after cancellation, failure, or deferred loading. If an item has no assigned slot, show a lightweight placeholder. Never create a fourth WebView. Ensure a displayed placeholder attaches the assigned view when settlement updates the pool.

In `didEndDisplaying`, detach the view and clear the cell's attachment reference. Do not make pool cancellation, pause, or destruction depend on this callback. Pool lifecycle ownership must remain valid even if a prepared cell never displays.

## 7. Prefetching and memory pressure

Leave system cell prefetching enabled initially for view preparation. It must not control WebView allocation or create extra loads. Do not implement `UICollectionViewDataSourcePrefetching` or manually dequeue cells in data-prefetch callbacks; the pool's settled-position window determines loading.

On `UIApplication.didReceiveMemoryWarningNotification`:

- Disable `isPrefetchingEnabled`.
- Defer new target loads for `prev` and `next`; continue loading the current target on demand and play it only when eligible.
- Keep the three pool instances. Do not destroy and recreate them as a default cleanup strategy.
- The core version may remain conservative for the rest of the session. Automatic restoration of adjacent preloading is optional and requires explicit recovery-signal handling.

Treat `os_proc_available_memory()` as optional host-process diagnostic data, not device free memory or a combined WebView budget. Memory warnings may not arrive before termination. Observe host and available WebContent process metrics separately. A capacity of three bounds the number of WebViews, not their memory usage in bytes; the mock's roughly 5 MB HTML payload is not a runtime-memory measurement.

Change capacity or add scheduling only when measurements justify it. Keep allocation bounded and independent of cell reuse.

## 8. Validation and delivery order

### Phase 1: complete and verify core behavior

Deliver a buildable app with project composition, Feed/Profile, pagination, derived lists, report/block actions, persisted hidden sets, failure feedback, one delayed retry, the three-slot pool, playback coordination, and conservative memory behavior.

Focus automated tests on:

1. `SekaiVisibilityPolicy`: exclude blocked creators and reported items, including items redelivered in later raw pages.
2. `ModerationRepository`: write block/report state, reconstruct against the same storage, and verify both sets restore; verify disk failure leaves state unchanged and produces no pending operation.
3. Playback eligibility: each failed condition prevents playback; hiding the current item selects the correct replacement; passing items without settlement never starts playback.

Manually verify cross-page block/report visibility, report persistence after restart, network-failure feedback and session retry, pool reassignment during repeated/fast/reverse scrolling, navigation/background pause, and conservative loading after a memory warning. UI automation coverage is not required.

### Phase 2: measure, optimize, then consider optional persistence

Use a physical device and Release build. Record first display, normal paging, rapid consecutive swipes, reverse scrolling, and behavior after a memory warning. Use Instruments for frame/hitch and memory measurements; simulator memory warnings validate behavior only.

Follow the README: measure scrolling frame timing, report actual numbers and changes made in response, and show memory use with approximately 5 MB items. Record the workload and observed stalls honestly. The README specifies no numerical hitch allowance, percentile threshold, or fixed scrolling duration. Retain results and analysis in `docs/evidence/performance/`.

| Record | Required detail |
| --- | --- |
| Environment | Device, OS, refresh rate, build configuration, mock latency/payload size, and scroll path. |
| Frames | Frame timing or hitch count/duration, observed scrolling stalls, and changes made in response. |
| Memory | Peak, steady-state usage, and long-scroll trend; identify measured processes. |
| WebViews | Creation events for all three instances and whether the count ever exceeded three. Verify no instances exist outside the pool. |

Use display latency, canceled loads, and memory-pressure diagnostics when needed to explain an observed issue.

If useful, compare with system cell prefetching disabled under the same conditions. Optimize observed bottlenecks, retest, and recheck core behavior. Only then spend remaining time persisting pending operations and validating restart synchronization. Automatic preload recovery remains optional; unblocking remains out of scope.

The mock's page counter can verify play/pause but cannot measure native scrolling frame rate. Do not invent performance figures or claim unmeasured results.

Use [WebKit content metrics](web-content-metrics.md) for navigation/readiness phases and eligible-to-play intervals. Count ready-pool reuse as display opportunities even when no navigation occurs. Browser timing is feature-detected and cache evidence may be unknown; do not equate load calls with HTTP requests or browser body sizes with actual transferred bytes. [Direct-loading tests](web-content-testing.md) use an independent HTTP fixture to validate cacheable and no-store responses without modifying the mock.

In the delivery README, record verified Xcode/Swift versions, run commands, actual feature scope, failure behavior, measured performance, tradeoffs, and unfinished work. If queue persistence is absent, state: “Hidden state is persisted. Pending operations are kept in memory only; unfinished synchronization is not guaranteed to resume after exit.”

Record a demo showing continuous scrolling, blocking from the feed, scrolling back to confirm removal, and opening a creator page to block from the top-right `⋯` menu. Complete the separate manual restart/retry/background/memory-warning checks. Report implemented and validated behavior accurately.
