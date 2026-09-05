import Foundation
import Combine
import XCTest
@testable import Sekai

enum TestError: Error { case expected }

func item(_ id: String, creator: String = "creator_a") -> SekaiItem {
    SekaiItem(gameID: id, title: id, gameURL: URL(string: "http://127.0.0.1:8787/content/" + id)!,
              coverURL: URL(string: "http://127.0.0.1:8787/avatar/" + creator)!,
              creatorID: creator, creatorName: creator, likeCount: 1)
}

func profile(_ id: String) -> CreatorProfile {
    CreatorProfile(userID: id, nickName: id, avatar: URL(string: "http://127.0.0.1:8787/avatar/" + id)!,
                   bio: "Bio", followingCount: 1, followerCount: 2, likeCount: 3)
}

actor StubAPI: SekaiAPI {
    var feedPages: [Int: [SekaiItem]] = [:]
    var creatorPages: [Int: GamePage] = [:]
    var failFeed = false
    var failProfile = false
    var failGames = false
    var failModeration = false
    var heldFeed = false
    var heldGames = false
    private(set) var feedCalls: [Int] = []
    private(set) var gameCalls: [(String, Int)] = []
    private(set) var intents: [ModerationIntent] = []
    private var feedWaiters: [Int: CheckedContinuation<[SekaiItem], Error>] = [:]
    private var gameWaiters: [Int: CheckedContinuation<GamePage, Error>] = [:]

    func setFeed(_ pages: [Int: [SekaiItem]]) { feedPages = pages }
    func setGames(_ pages: [Int: GamePage]) { creatorPages = pages }
    func setFailures(feed: Bool = false, profile: Bool = false, games: Bool = false, moderation: Bool = false) {
        failFeed = feed; failProfile = profile; failGames = games; failModeration = moderation
    }
    func holdFeed() { heldFeed = true }
    func holdGames() { heldGames = true }

    func fetchFeed(page: Int, limit: Int) async throws -> [SekaiItem] {
        let index = feedCalls.count
        feedCalls.append(page)
        if heldFeed {
            return try await withCheckedThrowingContinuation { feedWaiters[index] = $0 }
        }
        if failFeed { throw TestError.expected }
        return feedPages[page] ?? []
    }
    func completeFeed(_ index: Int, items: [SekaiItem]) {
        feedWaiters.removeValue(forKey: index)?.resume(returning: items)
    }
    func fetchProfile(creatorID: CreatorID) async throws -> CreatorProfile {
        if failProfile { throw TestError.expected }
        return profile(creatorID)
    }
    func fetchCreatorGames(creatorID: CreatorID, page: Int, size: Int) async throws -> GamePage {
        let index = gameCalls.count
        gameCalls.append((creatorID, page))
        if heldGames {
            return try await withCheckedThrowingContinuation { gameWaiters[index] = $0 }
        }
        if failGames { throw TestError.expected }
        return creatorPages[page] ?? GamePage(list: [], page: page, size: size, hasMore: false)
    }
    func completeGames(_ index: Int, items: [SekaiItem], hasMore: Bool = false) {
        gameWaiters.removeValue(forKey: index)?.resume(returning:
            GamePage(list: items, page: gameCalls[index].1, size: 2, hasMore: hasMore))
    }
    func block(creatorID: CreatorID) async throws {
        intents.append(.block(creatorID))
        if failModeration { throw TestError.expected }
    }
    func report(sekaiID: SekaiID, reason: String) async throws {
        intents.append(.report(sekaiID, reason: reason))
        if failModeration { throw TestError.expected }
    }
}

actor MemoryStorage: ModerationStorage {
    var rules = VisibilityRules()
    var fails = false
    var holds = false
    private(set) var writes: [VisibilityRules] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func setFailure(_ value: Bool) { fails = value }
    func holdSave() { holds = true }
    func releaseSave() {
        holds = false
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    func load() async throws -> VisibilityRules {
        if fails { throw TestError.expected }
        return rules
    }
    func save(_ rules: VisibilityRules) async throws {
        writes.append(rules)
        if holds { await withCheckedContinuation { waiters.append($0) } }
        if fails { throw TestError.expected }
        self.rules = rules
    }
}

actor ManualClock: RetryClock {
    private var waiter: CheckedContinuation<Void, Error>?
    private(set) var sleeps = 0
    func now() -> Date { Date(timeIntervalSince1970: 100) }
    func sleep() async throws {
        sleeps += 1
        try await withCheckedThrowingContinuation { waiter = $0 }
    }
    func advance() { waiter?.resume(); waiter = nil }
}

actor CommandSpy: ModerationCommands {
    private(set) var intents: [ModerationIntent] = []
    var fails = false
    func setFailure(_ value: Bool) { fails = value }
    func block(creatorID: CreatorID) throws {
        intents.append(.block(creatorID))
        if fails { throw TestError.expected }
    }
    func report(sekaiID: SekaiID, reason: String) throws {
        intents.append(.report(sekaiID, reason: reason))
        if fails { throw TestError.expected }
    }
}

@MainActor final class FeedRepositorySpy: FeedRepositoryProviding {
    let subject = CurrentValueSubject<FeedState, Never>(FeedState())
    var states: AnyPublisher<FeedState, Never> { subject.eraseToAnyPublisher() }
    var loads = 0
    var refreshes = 0
    var cancellations = 0
    var intents: [ModerationIntent] = []
    var fails = false
    var hold = false
    var waiter: CheckedContinuation<Void, Never>?
    func loadNextPage() async {
        loads += 1
        if hold { await withCheckedContinuation { waiter = $0 } }
    }
    func refresh() async { refreshes += 1 }
    func cancelRequests() { cancellations += 1 }
    func report(_ id: SekaiID, reason: String) async throws {
        intents.append(.report(id, reason: reason))
        if fails { throw TestError.expected }
    }
    func blockCreator(_ id: CreatorID) async throws {
        intents.append(.block(id))
        if fails { throw TestError.expected }
    }
}

@MainActor final class ProfileRepositorySpy: CreatorProfileRepositoryProviding {
    let creatorID: CreatorID
    let subject = CurrentValueSubject<CreatorProfileState, Never>(CreatorProfileState())
    var states: AnyPublisher<CreatorProfileState, Never> { subject.eraseToAnyPublisher() }
    var initialLoads = 0
    var pageLoads = 0
    var blocks = 0
    var cancellations = 0
    var fails = false
    init(creatorID: CreatorID = "creator_a") { self.creatorID = creatorID }
    func loadInitial() async { initialLoads += 1 }
    func loadNextPage() async { pageLoads += 1 }
    func refresh() async { initialLoads += 1 }
    func cancelRequests() { cancellations += 1 }
    func blockCreator() async throws {
        blocks += 1
        if fails { throw TestError.expected }
    }
}

@MainActor func eventually(file: StaticString = #filePath, line: UInt = #line,
                           _ condition: @escaping @MainActor () async -> Bool) async {
    for _ in 0..<1000 {
        if await condition() { return }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTFail("Condition did not become true", file: file, line: line)
}

actor ControlledSyncWorker: ModerationSyncing {
    private(set) var starts: [PendingOperation] = []
    private var deliveries: [UUID: @Sendable (UUID, SyncEvent) async -> Void] = [:]

    func start(_ operation: PendingOperation,
               deliver: @escaping @Sendable (UUID, SyncEvent) async -> Void) {
        starts.append(operation)
        deliveries[operation.id] = deliver
    }

    // Keep completed callbacks so tests can replay late results from an old operation.
    func send(_ id: UUID, _ event: SyncEvent) async throws {
        guard let deliver = deliveries[id] else { throw TestError.expected }
        await deliver(id, event)
    }

    func cancelAll() { deliveries.removeAll() }
}

actor ObservedSyncWorker: ModerationSyncing {
    private let worker: ModerationSyncWorker
    private(set) var completedCycles: [UUID] = []

    init(api: any SekaiAPI, clock: any RetryClock) {
        worker = ModerationSyncWorker(api: api, clock: clock)
    }

    func start(_ operation: PendingOperation,
               deliver: @escaping @Sendable (UUID, SyncEvent) async -> Void) async {
        await worker.start(operation) { [weak self] id, event in
            await deliver(id, event)
            // Acknowledge only after the repository has committed the terminal result.
            if case .finished = event { await self?.recordCompletion(id) }
        }
    }

    private func recordCompletion(_ id: UUID) { completedCycles.append(id) }
    func cancelAll() async { await worker.cancelAll() }
}
