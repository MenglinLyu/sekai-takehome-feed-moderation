# Class and function interface design

All UI, page-repository, and Combine interfaces are `@MainActor`. API, storage, moderation command, and clock protocols are `Sendable`. Dependencies enter through initializers. No test constructs the application composition root.

## Values and services

| Type | Interface and contract |
| --- | --- |
| `SekaiItem`, `CreatorProfile`, `GamePage` | Immutable, equatable Sendable DTOs. Explicit snake_case coding keys; `GamePage` carries backend `hasMore`. Feed uses the raw response count to determine completion. |
| `VisibilityRules` | Codable blocked/reported sets; the only persisted model. |
| `ModerationSnapshot` | Rules, runtime pending operations, revision, and optional sync feedback. |
| `PendingOperation` | UUID identity, block/report intent, attempt count, next retry date. Deduplication key is kind plus target ID. |
| `SekaiAPI` / `SekaiAPIClient` actor | `fetchFeed(page:limit:)`, `fetchProfile(creatorID:)`, `fetchCreatorGames(creatorID:page:size:)`, `block(creatorID:)`, `report(sekaiID:reason:)`, all async throwing. Validate HTTP status and nonzero envelope codes. Own no cursors. |
| `ModerationStorage` / `ModerationFileStore` | `load() async throws -> VisibilityRules`, `save(_:) async throws`. Dedicated serial DispatchQueue, checked continuations, atomic JSON replacement. A missing file means empty rules; corruption is an error. |
| `RetryClock` / `SystemRetryClock` | `sleep() async throws`, `now() async -> Date`; injected deterministic clocks support retry tests. |

## Shared moderation

| Type | Functions and invariants |
| --- | --- |
| `ModerationCommands` | `block(creatorID:) async throws`, `report(sekaiID:reason:) async throws`. Return after local durable publication, before remote completion. |
| `ModerationRepository` actor | `restore()` gates startup; `block`, `report`, `retryPending`, `snapshot`, `shutdown`. Private enqueue/drain/process functions serialize restoration, commands, and sync results across awaits. Save candidate rules before committing; a failed save publishes nothing and starts no sync. Duplicate intents restart only dormant matching operations. |
| `ModerationSyncing` / `ModerationSyncWorker` actor | Injectable Sendable synchronization boundary. `start(_:deliver:)` owns one task per operation, immediately attempts and retries once after the clock delay. Delivers results by UUID, never writes hidden sets. `cancelAll()` supports explicit shutdown. |
| `ModerationStateProviding` / `ModerationStateStore` | `snapshots: AnyPublisher<ModerationSnapshot, Never>`. `accept(_:)` ignores old revisions; only committed snapshots cross to MainActor through an awaited Sendable closure. |
| `SekaiVisibilityPolicy` | `visibleItems(in:rules:)` and `deduplicated(_:)` are pure functions shared by both pages. |

## Page repositories and view models

`FeedState` and `CreatorProfileState` expose visible items, pagination/loading/error state, and moderation feedback. Mutable raw arrays and subjects stay private. Combine joins a current raw-page value with deduplicated visibility rules, then applies the shared policy. Retry metadata updates feedback independently of filtering.

| Type | Functions and ownership |
| --- | --- |
| `FeedRepositoryProviding` / `FeedRepository` | `states`, `loadNextPage() async`, `refresh() async`, `cancelRequests()`, `report(_:reason:) async throws`, `blockCreator(_:) async throws`. One request generation per pagination cycle; stale responses cannot append or clear current loading. At most three consecutive invisible pages per call, then expose Continue Loading. |
| `CreatorProfileRepositoryProviding` / `CreatorProfileRepository` | Immutable `creatorID`; `states`, `loadInitial() async`, `loadNextPage() async`, `refresh() async`, `cancelRequests()`, `blockCreator() async throws`. Profile and first works load concurrently; independent page sessions never share cursors. |
| `FeedViewModel` | `@Published state`, `feedback`, `selectedCreatorID`; `loadNextPage`, `refresh`, `report`, `blockCreator`, `openCreator`, `stop`, `retryAction`, `dismissFeedback`. Owns page/action tasks; forwards actions only through its repository. |
| `CreatorProfileViewModel` | Same state/feedback pattern; `loadInitial`, `loadNextPage`, `blockCreator`, `stop`, `retryAction`, `dismissFeedback`. Captures immutable page identity. |
| `CreatorProfileFactory` | `make(creatorID:) -> CreatorProfileViewModel` creates a fresh repository and view model every time. |
| `AppCompositionRoot` | Constructs application dependencies once. `start() async` restores before constructing the feed session. `foreground()` requests dormant sync retries. Exposes startup error with retry. |

## Presentation and playback

| Type | Functions and contracts |
| --- | --- |
| `PlaybackPolicy` | `eligibleTarget(...)` requires foreground, displayed feed, settlement, and visible membership. `replacement(oldIDs:newIDs:currentID:)` preserves current ID or chooses the first surviving successor, then predecessor. |
| `WebViewSlotPool` | Exactly three pool-owned `WKWebView`s. `assign(items:currentID:)`, `setEligibleTarget(_:)`, `removeHiddenItems(survivingIDs:)`, `presentation(for:)`, `retry(itemID:)`, `memoryWarning()`. One owned reconciliation task serializes pause, obsolete-binding reset, loads, and play; latest desired state is reconsidered after each await. Navigation delegates validate WKNavigation identity. Failed pause resets the old document to blank before another slot can play. |
| `FeedCell` | `configure(item:pool:...)`, `detach()`, `cover()`. Attaches a pooled view, overlays loading/error state and creator/moderation buttons; never loads or selects playback. |
| `FeedViewController` | Owns collection view, diffable snapshots, current stable ID, settlement and lifecycle. Covers removed cells synchronously, revokes playback, applies snapshots, then positions replacement and assigns pool. Pool callbacks update attached cells. Dragging only revokes eligibility; settlement updates assignments. |
| `FeedContainerView` | Wraps one stable controller. Repeated updates apply state without reconstructing dependencies. |
| `CreatorProfileView` | Metadata, native rasterized mock SVG avatars/covers, paged titles, explicit empty state, top-right Block menu. No WebViews. |

## Verification plan

- Moderation: durable restore, failed write, suspended concurrent commits, deduplication, one delayed retry, retained hiding after failure, foreground restart, stale result identity.
- Moderation test synchronization: read-only `queuedCommandCount` confirms a second command is queued while storage is suspended. An observing worker wraps the real retry worker and acknowledges cycle completion only after repository result delivery returns. A controlled worker supports out-of-order and late-result delivery. Failed-write tests retain preexisting block/report sets and compare every publication, persisted state, and API call against their baselines.
- Pages: shared cross-page filtering, later hidden redelivery, stable deduplication, backend completion, bounded filtered pagination, parallel request suppression, stale response after refresh/cancel, independent profile sessions, error recovery.
- View models: supplied publisher values, action forwarding, local confirmation/error retry, navigation, owned cancellation.
- Pure playback: all eligibility gates and stable-ID successor/predecessor selection.
- Xcode build and XCTest execution. Physical-device frame/memory traces and manual playback checks remain separately reported evidence, never inferred from unit tests.
