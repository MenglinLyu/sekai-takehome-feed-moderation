import XCTest
import Combine
@testable import Sekai

@MainActor final class PageRepositoryTests: XCTestCase {
    func testSharedModerationFiltersFeedAndProfileIncludingLaterRedelivery() async {
        let api = StubAPI()
        let a = item("a")
        let b = item("b", creator: "creator_b")
        let c = item("c", creator: "creator_b")
        await api.setFeed([0: [a, b], 1: [a, c]])
        await api.setGames([0: GamePage(list: [a], page: 0, size: 2, hasMore: false)])
        let adapter = ModerationStateStore()
        let commands = CommandSpy()
        let feed = FeedRepository(api: api, moderation: adapter, commands: commands, pageSize: 2)
        let creator = CreatorProfileRepository(creatorID: "creator_a", api: api,
            moderation: adapter, commands: commands, pageSize: 2)
        var feedState = FeedState()
        var profileState = CreatorProfileState()
        let feedSubscription = feed.states.sink { feedState = $0 }
        let profileSubscription = creator.states.sink { profileState = $0 }
        await feed.loadNextPage()
        await creator.loadInitial()
        adapter.accept(ModerationSnapshot(
            rules: VisibilityRules(blockedCreatorIDs: ["creator_a"], reportedSekaiIDs: ["b"]), revision: 1))
        XCTAssertTrue(feedState.items.isEmpty)
        XCTAssertTrue(profileState.items.isEmpty)
        await feed.loadNextPage()
        XCTAssertEqual(feedState.items.map(\.id), ["c"])
        XCTAssertFalse(profileState.hasMore)
        withExtendedLifetime((feedSubscription, profileSubscription)) {}
    }

    func testFeedDeduplicatesStableOrderAndUsesRawResponseCountForCompletion() async {
        let api = StubAPI()
        await api.setFeed([0: [item("a"), item("b")], 1: [item("b"), item("c")], 2: []])
        let repository = FeedRepository(api: api, moderation: ModerationStateStore(), commands: CommandSpy(), pageSize: 2)
        var state = FeedState()
        let subscription = repository.states.sink { state = $0 }
        await repository.loadNextPage()
        await repository.loadNextPage()
        XCTAssertEqual(state.items.map(\.id), ["a", "b", "c"])
        XCTAssertTrue(state.hasMore)
        await repository.loadNextPage()
        XCTAssertFalse(state.hasMore)
        await repository.loadNextPage()
        let calls = await api.feedCalls
        XCTAssertEqual(calls, [0, 1, 2])
        withExtendedLifetime(subscription) {}
    }

    func testFullyHiddenFeedPagesAreBoundedAndContinueResumesNextCursor() async {
        let api = StubAPI()
        await api.setFeed([0: [item("a")], 1: [item("b")], 2: [item("c")], 3: [item("d", creator: "visible")]])
        let adapter = ModerationStateStore()
        adapter.accept(ModerationSnapshot(rules: VisibilityRules(blockedCreatorIDs: ["creator_a"]), revision: 1))
        let repository = FeedRepository(api: api, moderation: adapter, commands: CommandSpy(), pageSize: 1)
        var state = FeedState()
        let subscription = repository.states.sink { state = $0 }
        await repository.loadNextPage()
        XCTAssertTrue(state.items.isEmpty)
        XCTAssertTrue(state.hasMore)
        XCTAssertTrue(state.needsContinue)
        let initialCalls = await api.feedCalls
        XCTAssertEqual(initialCalls, [0, 1, 2])
        await repository.loadNextPage()
        XCTAssertEqual(state.items.map(\.id), ["d"])
        XCTAssertFalse(state.needsContinue)
        withExtendedLifetime(subscription) {}
    }

    func testFeedSuppressesParallelPaginationAndIgnoresStaleResponseAfterRefresh() async {
        let api = StubAPI()
        await api.holdFeed()
        let repository = FeedRepository(api: api, moderation: ModerationStateStore(), commands: CommandSpy(), pageSize: 2)
        var state = FeedState()
        let subscription = repository.states.sink { state = $0 }
        let old = Task { await repository.loadNextPage() }
        await eventually { await api.feedCalls.count == 1 }
        await repository.loadNextPage()
        let calls = await api.feedCalls.count
        XCTAssertEqual(calls, 1)
        let fresh = Task { await repository.refresh() }
        await eventually { await api.feedCalls.count == 2 }
        await api.completeFeed(0, items: [item("stale")])
        await old.value
        XCTAssertTrue(state.items.isEmpty)
        XCTAssertTrue(state.isLoading)
        await api.completeFeed(1, items: [item("fresh")])
        await fresh.value
        XCTAssertEqual(state.items.map(\.id), ["fresh"])
        XCTAssertFalse(state.isLoading)
        withExtendedLifetime(subscription) {}
    }

    func testFeedCancellationAndErrorRecoveryKeepStreamAlive() async {
        let api = StubAPI()
        await api.setFailures(feed: true)
        let repository = FeedRepository(api: api, moderation: ModerationStateStore(), commands: CommandSpy())
        var state = FeedState()
        let subscription = repository.states.sink { state = $0 }
        await repository.loadNextPage()
        XCTAssertNotNil(state.error)
        XCTAssertFalse(state.isLoading)
        await api.setFailures()
        await api.holdFeed()
        let old = Task { await repository.loadNextPage() }
        await eventually { await api.feedCalls.count == 2 }
        repository.cancelRequests()
        await api.completeFeed(1, items: [item("stale")])
        await old.value
        XCTAssertTrue(state.items.isEmpty)
        XCTAssertFalse(state.isLoading)
        let retry = Task { await repository.loadNextPage() }
        await eventually { await api.feedCalls.count == 3 }
        await api.completeFeed(2, items: [item("ok")])
        await retry.value
        XCTAssertNil(state.error)
        XCTAssertEqual(state.items.map(\.id), ["ok"])
        withExtendedLifetime(subscription) {}
    }

    func testProfileUsesBackendHasMoreAndDeduplicates() async {
        let api = StubAPI()
        await api.setGames([
            0: GamePage(list: [item("a")], page: 0, size: 10, hasMore: true),
            1: GamePage(list: [item("a"), item("b")], page: 1, size: 10, hasMore: false)
        ])
        let repository = CreatorProfileRepository(creatorID: "creator_a", api: api,
            moderation: ModerationStateStore(), commands: CommandSpy())
        var state = CreatorProfileState()
        let subscription = repository.states.sink { state = $0 }
        await repository.loadInitial()
        XCTAssertTrue(state.hasMore)
        XCTAssertEqual(state.profile?.userID, "creator_a")
        await repository.loadNextPage()
        XCTAssertFalse(state.hasMore)
        XCTAssertEqual(state.items.map(\.id), ["a", "b"])
        withExtendedLifetime(subscription) {}
    }

    func testProfileInitialErrorRetryAndIndependentSessions() async {
        let api = StubAPI()
        await api.setFailures(profile: true)
        let factory = CreatorProfileFactory(api: api, moderation: ModerationStateStore(), commands: CommandSpy())
        let first = factory.make(creatorID: "creator_a")
        let second = factory.make(creatorID: "creator_a")
        XCTAssertFalse(first === second)
        await first.loadInitial()?.value
        XCTAssertNotNil(first.state.error)
        await api.setFailures()
        await api.setGames([0: GamePage(list: [item("a")], page: 0, size: 10, hasMore: true)])
        await first.loadInitial()?.value
        await first.loadNextPage()?.value
        await second.loadInitial()?.value
        XCTAssertNil(first.state.error)
        XCTAssertFalse(first.state.hasMore)
        XCTAssertTrue(second.state.hasMore)
        XCTAssertEqual(second.state.items.map(\.id), ["a"])
    }

    func testProfileCancellationRejectsLateInitialResponse() async {
        let api = StubAPI()
        await api.holdGames()
        let repository = CreatorProfileRepository(creatorID: "creator_a", api: api,
            moderation: ModerationStateStore(), commands: CommandSpy())
        var state = CreatorProfileState()
        let subscription = repository.states.sink { state = $0 }
        let old = Task { await repository.loadInitial() }
        await eventually { await api.gameCalls.count == 1 }
        repository.cancelRequests()
        let fresh = Task { await repository.loadInitial() }
        await eventually { await api.gameCalls.count == 2 }
        await api.completeGames(0, items: [item("stale")])
        await old.value
        XCTAssertTrue(state.isLoading)
        XCTAssertNil(state.profile)
        await api.completeGames(1, items: [item("fresh")])
        await fresh.value
        XCTAssertEqual(state.items.map(\.id), ["fresh"])
        withExtendedLifetime(subscription) {}
    }

    func testBlockedProfileHasExplicitEmptyStateAndBoundedPagination() async {
        let api = StubAPI()
        await api.setGames(Dictionary(uniqueKeysWithValues: (0...5).map {
            ($0, GamePage(list: [item(String($0))], page: $0, size: 1, hasMore: true))
        }))
        let adapter = ModerationStateStore()
        adapter.accept(ModerationSnapshot(rules: VisibilityRules(blockedCreatorIDs: ["creator_a"]), revision: 1))
        let repository = CreatorProfileRepository(creatorID: "creator_a", api: api,
            moderation: adapter, commands: CommandSpy(), pageSize: 1)
        var state = CreatorProfileState()
        let subscription = repository.states.sink { state = $0 }
        await repository.loadInitial()
        XCTAssertNotNil(state.profile)
        XCTAssertTrue(state.items.isEmpty)
        XCTAssertTrue(state.needsContinue)
        XCTAssertTrue(state.hasMore)
        XCTAssertFalse(state.isLoading)
        let calls = await api.gameCalls.count
        XCTAssertEqual(calls, 4)
        withExtendedLifetime(subscription) {}
    }

    func testPageModerationCommandsForwardCorrectIdentityAndReason() async throws {
        let api = StubAPI()
        let commands = CommandSpy()
        let adapter = ModerationStateStore()
        let feed = FeedRepository(api: api, moderation: adapter, commands: commands)
        let creator = CreatorProfileRepository(creatorID: "creator_b", api: api, moderation: adapter, commands: commands)
        try await feed.report("g", reason: "spam")
        try await feed.blockCreator("creator_a")
        try await creator.blockCreator()
        let intents = await commands.intents
        XCTAssertEqual(intents, [.report("g", reason: "spam"), .block("creator_a"), .block("creator_b")])
    }
}
