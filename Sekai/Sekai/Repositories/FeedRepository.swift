import Foundation
import Combine

struct FeedState: Equatable {
    var items: [SekaiItem] = []
    var isLoading = false
    var hasMore = true
    var needsContinue = false
    var error: DisplayFailure?
    var syncFeedback: String?
}

@MainActor protocol FeedRepositoryProviding: AnyObject {
    var states: AnyPublisher<FeedState, Never> { get }
    func loadNextPage() async
    func refresh() async
    func cancelRequests()
    func report(_ id: SekaiID, reason: String) async throws
    func blockCreator(_ id: CreatorID) async throws
}

@MainActor final class FeedRepository: FeedRepositoryProviding {
    private let api: any SekaiAPI
    private let commands: any ModerationCommands
    private let pageSize: Int
    private let raw = CurrentValueSubject<FeedState, Never>(FeedState())
    private let output = CurrentValueSubject<FeedState, Never>(FeedState())
    private var subscriptions = Set<AnyCancellable>()
    private var nextPage = 0
    private var generation = 0

    var states: AnyPublisher<FeedState, Never> { output.eraseToAnyPublisher() }

    init(api: any SekaiAPI, moderation: any ModerationStateProviding,
         commands: any ModerationCommands, pageSize: Int = 10) {
        self.api = api
        self.commands = commands
        self.pageSize = pageSize
        raw.combineLatest(moderation.snapshots.map(\.rules).removeDuplicates())
            .map { raw, rules in
                var state = raw
                state.items = SekaiVisibilityPolicy.visibleItems(in: raw.items, rules: rules)
                return state
            }
            .sink { [weak self] state in
                guard let self else { return }
                var state = state
                state.syncFeedback = self.output.value.syncFeedback
                self.output.send(state)
            }.store(in: &subscriptions)
        moderation.snapshots.map(\.feedback).removeDuplicates().sink { [weak self] feedback in
            guard let self else { return }
            var state = self.output.value
            state.syncFeedback = feedback
            self.output.send(state)
        }.store(in: &subscriptions)
    }

    func loadNextPage() async {
        guard !raw.value.isLoading, raw.value.hasMore else { return }
        generation += 1
        let requestGeneration = generation
        raw.value.isLoading = true
        raw.value.error = nil
        raw.value.needsContinue = false
        for attempt in 0..<3 {
            let visibleIDs = Set(output.value.items.map(\.id))
            do {
                let items = try await api.fetchFeed(page: nextPage, limit: pageSize)
                guard generation == requestGeneration, !Task.isCancelled else {
                    finishCancellation(requestGeneration)
                    return
                }
                nextPage += 1
                var state = raw.value
                state.items = SekaiVisibilityPolicy.deduplicated(state.items + items)
                state.hasMore = items.count == pageSize
                raw.send(state)
                let gainedVisibleItems = output.value.items.contains { !visibleIDs.contains($0.id) }
                if gainedVisibleItems || !state.hasMore { break }
                if attempt == 2 { raw.value.needsContinue = true }
            } catch {
                guard generation == requestGeneration else { return }
                if !Task.isCancelled { raw.value.error = DisplayFailure(message: error.localizedDescription) }
                break
            }
        }
        guard generation == requestGeneration else { return }
        raw.value.isLoading = false
    }

    func refresh() async {
        cancelRequests()
        nextPage = 0
        raw.send(FeedState())
        await loadNextPage()
    }

    func cancelRequests() {
        generation += 1
        raw.value.isLoading = false
    }

    private func finishCancellation(_ requestGeneration: Int) {
        if requestGeneration == generation { raw.value.isLoading = false }
    }

    func report(_ id: SekaiID, reason: String) async throws {
        try await commands.report(sekaiID: id, reason: reason)
    }

    func blockCreator(_ id: CreatorID) async throws {
        try await commands.block(creatorID: id)
    }
}
